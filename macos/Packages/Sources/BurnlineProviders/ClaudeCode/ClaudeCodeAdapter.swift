//
//  ClaudeCodeAdapter.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import Foundation

/// Claude Code's history: `~/.claude/projects/<project>/<session>.jsonl`, plus
/// subagent transcripts under `<project>/<session>/subagents/`. Token counts
/// sit on the usage object of `assistant` lines.
///
/// Two facts about the format shape this parser, both measured on real data:
///
/// - One API response is written as several lines, one per content block,
///   all repeating the same `message.id` and usage. The message id is
///   therefore the event id; counting lines would roughly double the totals.
/// - Repeated lines are streaming snapshots, and a later one can report more
///   output. Storage keeps the most complete copy.
///
/// Only the fields below are decoded. Message content is never turned into a
/// Swift value, let alone stored.
public struct ClaudeCodeAdapter: UsageProviderAdapter {
    public static let sourceType = "claude_code_jsonl"

    public let provider = ProviderKey.claudeCode
    let projectsDirectories: [URL]
    let resolver: ProjectIdentityResolver

    /// `projectsDirectories` defaults to the `projects` folder of every known
    /// Claude Code home: `$CLAUDE_CONFIG_DIR` (or `~/.claude`, matching Claude
    /// Code itself), then Xcode's coding assistant.
    public init(projectsDirectories: [URL]? = nil, resolver: ProjectIdentityResolver = ProjectIdentityResolver(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.projectsDirectories = projectsDirectories
            ?? ProviderHomes.claude(environment: environment).map { $0.appending(path: "projects") }
        self.resolver = resolver
    }

    public func prepareForSync() { resolver.clearCache() }

    public func detect() -> ProviderDetection {
        ProviderHomes.existing(projectsDirectories).first.map { .installed(dataDirectory: $0) } ?? .notInstalled
    }

    public func watchedDirectories() -> [URL] { ProviderHomes.existing(projectsDirectories) }

    public func sourceFiles() throws -> [URL] {
        ProviderHomes.existing(projectsDirectories)
            .flatMap { FileManager.default.enumerator(at: $0, includingPropertiesForKeys: nil)?.allObjects ?? [] }
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.path < $1.path }
    }

    /// Every line stands alone, so no state is needed to resume.
    public func parse(_ file: URL, from offset: Int64, state: String?) throws -> ParseOutput {
        var output = ParseOutput()
        let decoder = JSONDecoder()
        // Lines without this marker cannot be assistant records. Checking bytes
        // first skips decoding most of a transcript, including its largest lines.
        let pass = try LineReader.read(file, from: offset, containing: ["\"assistant\""]) { line in
            let record: ClaudeCodeLine
            do { record = try decoder.decode(ClaudeCodeLine.self, from: line.bytes) }
            catch {
                // The reason, never the line: it may hold a prompt.
                output.record("not a valid record: \(JSONLines.describe(error))", file: file, line: line.number)
                return
            }
            guard record.type == "assistant", let message = record.message, let usage = message.usage else { return }
            if let usage = self.incoming(record, message: message, usage: usage, file: file,
                                         line: line, output: &output) {
                output.records.append(usage)
            }
        }
        output.endOffset = pass.endOffset
        output.linesRead = pass.lines
        return output
    }

    private func incoming(_ record: ClaudeCodeLine, message: ClaudeCodeLine.Message, usage: ClaudeCodeLine.Usage,
                          file: URL, line: LineReader.Line, output: inout ParseOutput) -> IncomingUsage? {
        guard let rawTimestamp = record.timestamp, let timestamp = JSONLines.timestamp(rawTimestamp) else {
            output.record("missing or unreadable timestamp", file: file, line: line.number)
            return nil
        }

        func count(_ value: Int64?, _ name: String) -> Int64 {
            output.count(value, name, file: file, line: line.number)
        }
        let cacheWrite = count(usage.cacheCreationInputTokens, "cache_creation_input_tokens")
        // The 1-hour part may only be a subset. Real data occasionally reports
        // a split that does not sum to the total; the total is what is billed.
        let oneHour = min((usage.cacheCreation?.oneHour).map {
            count($0, "ephemeral_1h_input_tokens")
        } ?? 0, cacheWrite)

        let tokens: TokenCounts
        do {
            tokens = try TokenCounts(
                input: count(usage.inputTokens, "input_tokens"),
                cachedInput: count(usage.cacheReadInputTokens, "cache_read_input_tokens"),
                cacheWrite: cacheWrite, cacheWriteOneHour: oneHour,
                output: count(usage.outputTokens, "output_tokens"),
                reasoning: (usage.outputTokensDetails?.thinkingTokens).map {
                    count($0, "thinking_tokens")
                } ?? 0)
        } catch {
            output.record("token counts out of range", file: file, line: line.number)
            return nil
        }

        let sessionID = record.sessionId ?? record.sessionIdSnakeCase
            ?? "file:\(file.deletingPathExtension().lastPathComponent)"   // no session id: one per file
        let eventID = message.id ?? record.uuid ?? "\(file.path):\(line.offset)"
        let project = record.cwd.flatMap { $0.isEmpty ? nil : resolver.candidate(forWorkingDirectory: $0) }

        return IncomingUsage(
            sourceEventID: eventID, sessionSourceID: sessionID, project: project, rawModel: message.model,
            timestamp: timestamp, tokens: tokens,
            // Fast mode bills above the standard rate whatever the tier says.
            serviceTier: usage.speed == "fast" ? "fast" : usage.serviceTier,
            sourceType: Self.sourceType, file: file.path,
            schemaVersion: record.version, offset: line.offset)
    }

}

/// The fields of a Claude Code transcript line that Burnline reads. Unknown
/// fields are ignored; `version` is kept as the source schema version.
struct ClaudeCodeLine: Decodable {
    let type: String?
    let uuid: String?
    let sessionId: String?
    let sessionIdSnakeCase: String?
    let cwd: String?
    let timestamp: String?
    let version: String?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let inputTokens: Int64?
        let cacheReadInputTokens: Int64?
        let cacheCreationInputTokens: Int64?
        let cacheCreation: CacheCreation?
        let outputTokens: Int64?
        let outputTokensDetails: OutputDetails?
        let serviceTier: String?
        let speed: String?

        enum CodingKeys: String, CodingKey {
            case speed
            case serviceTier = "service_tier"
            case inputTokens = "input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheCreation = "cache_creation"
            case outputTokens = "output_tokens"
            case outputTokensDetails = "output_tokens_details"
        }
    }

    struct CacheCreation: Decodable {
        let oneHour: Int64?
        enum CodingKeys: String, CodingKey { case oneHour = "ephemeral_1h_input_tokens" }
    }

    struct OutputDetails: Decodable {
        let thinkingTokens: Int64?
        enum CodingKeys: String, CodingKey { case thinkingTokens = "thinking_tokens" }
    }

    enum CodingKeys: String, CodingKey {
        case type, uuid, sessionId, cwd, timestamp, version, message
        case sessionIdSnakeCase = "session_id"
    }
}
