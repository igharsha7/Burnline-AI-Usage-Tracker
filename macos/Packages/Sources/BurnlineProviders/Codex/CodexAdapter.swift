//
//  CodexAdapter.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import Foundation

/// Codex's history: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, one file
/// per thread, plus `archived_sessions`, where Codex moves old threads and may
/// compress them to `.jsonl.zst`. A compressed archive cannot be entered
/// midway, so it is always read whole; it does not change, so that happens
/// once.
///
/// What the format looks like, measured on real rollouts:
///
/// - `session_meta` opens the file with the thread id, its session, and the
///   working directory. A forked subagent's file repeats its parent's meta
///   after its own, so the first one wins.
/// - `turn_context` starts each turn and names the model. Token lines carry no
///   model, so the latest turn's model applies. Some short threads have no
///   turn context; their meta still names the model its base instructions
///   were chosen for, which stands in until a turn says otherwise.
/// - `token_usage_record` is written once per model response, keyed by its
///   response id. This is the event.
/// - `event_msg` / `token_count` follows most responses with the same usage
///   and a running thread total. It is skipped wherever records exist, or every
///   response would count twice. Compaction responses get a record but no
///   `token_count`, so records are also the more complete source.
/// - Older Codex versions, and some short threads, write `token_count` and no
///   records at all. There `token_count` is the event, with three cautions
///   learned from real files: a line whose running
///   total did not move is a re-emission, not a request; a line with no input
///   and no output reports context size; and a forked thread opens by copying
///   its parent's history in a burst of lines already counted in the parent.
/// - `thread_settings_applied` names the service tier, which pricing needs.
///
/// Because the model and directory are set once and used many lines later, a
/// pass that resumes mid-file is handed `CodexResumeState` from the pass
/// before it.
public struct CodexAdapter: UsageProviderAdapter {
    public static let sourceType = "codex_rollout_jsonl"

    public let provider = ProviderKey.codex
    let codexDirectories: [URL]
    let resolver: ProjectIdentityResolver

    /// Where threads live, live and archived, across every home.
    var historyDirectories: [URL] {
        codexDirectories.flatMap { [$0.appending(path: "sessions"), $0.appending(path: "archived_sessions")] }
    }

    /// `codexDirectories` defaults to every known Codex home: `$CODEX_HOME`
    /// (or `~/.codex`, matching Codex itself), then Xcode's coding assistant.
    public init(codexDirectories: [URL]? = nil, resolver: ProjectIdentityResolver = ProjectIdentityResolver(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.codexDirectories = codexDirectories ?? ProviderHomes.codex(environment: environment)
        self.resolver = resolver
    }

    /// The record types read, as they appear in a line.
    static let recordMarkers = ["\"session_meta\"", "\"turn_context\"", "\"token_usage_record\"", "\"token_count\"",
                                "\"thread_settings_applied\""]

    /// How far into a line its record type is looked for. Codex writes the
    /// line's `type`, and an event's payload `type`, among the first keys, a
    /// hundred or so bytes in; the bulk of a rollout is long message and tool
    /// lines that only mention these words further on, if at all. Searching
    /// whole lines made a first import several times slower. Nil searches
    /// every line whole.
    var markerWindow: Int? = 1_024

    /// Whether a line may hold a record. The start of the line must show
    /// where its type is: when it holds no `"type"` key, or an event's
    /// envelope without the payload's type, a later Codex may have moved the
    /// type further in, and the whole line is searched rather than a record
    /// silently skipped.
    var recordLines: LineReader.Selection {
        let markers = Self.recordMarkers.map { Array($0.utf8) }
        let type = Array(#""type""#.utf8), event = Array(#""event_msg""#.utf8)
        let window = markerWindow
        return { line in
            let anywhere = { markers.contains { LineReader.contains(line, $0) } }
            guard let window, line.count > window else { return anywhere() }
            let head = UnsafeRawBufferPointer(rebasing: line.prefix(window))
            if markers.contains(where: { LineReader.contains(head, $0) }) { return true }
            let types = LineReader.occurrences(of: type, in: head)
            if types == 0 || (types == 1 && LineReader.contains(head, event)) { return anywhere() }
            return false
        }
    }

    public func prepareForSync() { resolver.clearCache() }

    public func detect() -> ProviderDetection {
        ProviderHomes.existing(historyDirectories).first.map { .installed(dataDirectory: $0) } ?? .notInstalled
    }

    /// Archiving moves a file between these, so both are watched.
    public func watchedDirectories() -> [URL] { ProviderHomes.existing(historyDirectories) }

    /// Copied parent history arrives in a burst, lines a few milliseconds
    /// apart; a forked thread's own first request follows a model turn,
    /// seconds later. A gap this long ends the copy.
    static let forkCopyMaxGapMilliseconds: Int64 = 1_000

    public func sourceFiles() throws -> [URL] {
        ProviderHomes.existing(historyDirectories)
            .flatMap { FileManager.default.enumerator(at: $0, includingPropertiesForKeys: nil)?.allObjects ?? [] }
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" || Self.isCompressed($0) }
            .sorted { $0.path < $1.path }
    }

    static func isCompressed(_ file: URL) -> Bool { file.lastPathComponent.hasSuffix(".jsonl.zst") }

    public func parse(_ file: URL, from offset: Int64, state: String?) throws -> ParseOutput {
        let compressed = Self.isCompressed(file)
        var start = compressed ? 0 : offset
        var context = CodexResumeState()
        if start > 0 {
            if let decoded = state.flatMap(CodexResumeState.init(encoded:)) {
                context = decoded
            } else {
                start = 0   // Cannot know the model in force mid-file, so start over.
            }
        }

        var output = ParseOutput()
        let decoder = JSONDecoder()
        let body: (LineReader.Line) throws -> Void = { line in
            let record: CodexLine
            do { record = try decoder.decode(CodexLine.self, from: line.bytes) }
            catch {
                // A line that merely mentions a marker word, such as a message
                // about this very format, is not one of ours and not an error.
                let envelope = try? decoder.decode(CodexLine.Envelope.self, from: line.bytes)
                if envelope?.isRead ?? true {
                    output.record("not a valid record: \(JSONLines.describe(error))", file: file, line: line.number)
                }
                return
            }
            guard let payload = record.payload else { return }

            switch record.type {
            case "session_meta":
                if context.threadID == nil {
                    context.threadID = payload.id
                    context.sessionID = payload.sessionID ?? payload.id
                    context.version = payload.cliVersion
                    if payload.forkedFromID != nil || payload.source?.parentThreadID != nil {
                        context.forkCopyAnchor = record.timestamp.flatMap(JSONLines.milliseconds)
                    }
                }
                context.cwd = context.cwd ?? payload.cwd
                context.model = context.model ?? payload.baseInstructions?.provenance?.model
            case "turn_context":
                context.model = payload.model ?? context.model
                context.cwd = payload.cwd ?? context.cwd
            case "token_usage_record":
                guard let usage = payload.usage else {
                    output.record("usage absent", file: file, line: line.number)
                    return
                }
                let eventID = payload.responseID ?? "\(threadKey(context, file)):\(line.offset)"
                if let incoming = incoming(eventID: eventID, session: payload.sessionID, usage: usage,
                                           record: record, context: context, file: file, line: line,
                                           output: &output) {
                    context.hasRecords = true
                    output.records.append(incoming)
                }
            case "event_msg" where payload.type == "thread_settings_applied":
                context.serviceTier = payload.threadSettings?.serviceTier ?? context.serviceTier
            case "event_msg" where payload.type == "token_count" && !context.hasRecords:
                var next = context
                guard let eventID = fallbackEventID(payload.info, record: record, context: &next, file: file) else {
                    context = next
                    return
                }
                guard let last = payload.info?.lastTokenUsage,
                      let incoming = incoming(eventID: eventID, session: nil, usage: last, record: record,
                                              context: next, file: file, line: line, output: &output)
                else { return }
                context = next
                output.records.append(incoming)
            default:
                return
            }
        }
        let pass = compressed
            ? try LineReader.readCompressed(file, selecting: recordLines, body)
            : try LineReader.read(file, from: start, selecting: recordLines, body)
        output.endOffset = pass.endOffset
        output.linesRead = pass.lines
        output.endState = context.encoded
        return output
    }

    /// The event id for a `token_count` line in a file without records, or
    /// nil when the line is not a request of this thread's own. Advances the
    /// running total and the fork-copy window as a side effect, so a line is
    /// judged against the ones before it, across passes.
    private func fallbackEventID(_ info: CodexLine.Info?, record: CodexLine, context: inout CodexResumeState,
                                 file: URL) -> String? {
        // A token_count with no info only reports rate limits.
        guard let info, let last = info.lastTokenUsage, let rawTimestamp = record.timestamp else { return nil }
        let total = info.totalTokenUsage

        if let anchor = context.forkCopyAnchor, let now = JSONLines.milliseconds(rawTimestamp) {
            if now - anchor < Self.forkCopyMaxGapMilliseconds {
                // Copied from the parent, and counted there. It still sets
                // the baseline the thread's own requests are measured from.
                context.forkCopyAnchor = now
                context.lastTotal = total ?? context.lastTotal
                return nil
            }
            context.forkCopyAnchor = nil
        }
        // No input and no output: a context-size report, not a request.
        guard (last.inputTokens ?? 0) > 0 || (last.outputTokens ?? 0) > 0 else {
            // A process/context reset can report a new baseline without a request.
            // Keep it so the next real request can repeat an earlier total.
            context.lastTotal = total ?? context.lastTotal
            context.lastUsage = nil
            return nil
        }
        if let total {
            guard total != context.lastTotal else { return nil }   // re-emitted
            context.lastTotal = total
        } else {
            // Oldest format: no running total, so a repeat is a repeated line.
            guard last != context.lastUsage else { return nil }
            context.lastUsage = last
        }
        // The timestamp keeps a session resumed in a new process, whose total
        // restarts, from colliding with its own earlier requests.
        return "\(threadKey(context, file)):\(rawTimestamp):\(total?.totalTokens ?? last.totalTokens ?? 0)"
    }

    /// The thread this file records, or the file's name when no meta said.
    /// An archive keeps its name when compressed, so both forms agree.
    private func threadKey(_ context: CodexResumeState, _ file: URL) -> String {
        if let threadID = context.threadID { return threadID }
        var name = file.lastPathComponent
        for suffix in [".zst", ".jsonl"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        return "file:\(name)"
    }

    private func incoming(eventID: String, session: String?, usage: CodexLine.Usage, record: CodexLine,
                          context: CodexResumeState, file: URL, line: LineReader.Line,
                          output: inout ParseOutput) -> IncomingUsage? {
        guard let rawTimestamp = record.timestamp, let timestamp = JSONLines.timestamp(rawTimestamp) else {
            output.record("missing or unreadable timestamp", file: file, line: line.number)
            return nil
        }

        // OpenAI reports the whole prompt as input_tokens, with the cached
        // read and cache write as parts of it. Burnline's input is the
        // uncached remainder, so the parts are taken out. Codex has only
        // recently added cache_write_input_tokens and reasoning; their absence
        // is an older format, not a fault, so it is not recorded.
        let prompt = output.count(usage.inputTokens, "input_tokens", file: file, line: line.number)
        let cached = output.count(usage.cachedInputTokens, "cached_input_tokens", file: file, line: line.number)
        let cacheWrite = usage.cacheWriteInputTokens.map {
            output.count($0, "cache_write_input_tokens", file: file, line: line.number)
        } ?? 0
        let reasoning = usage.reasoningOutputTokens.map {
            output.count($0, "reasoning_output_tokens", file: file, line: line.number)
        } ?? 0
        let (parts, partsOverflow) = cached.addingReportingOverflow(cacheWrite)
        let (uncached, remainderOverflow) = prompt.subtractingReportingOverflow(parts)
        let overflow = partsOverflow || remainderOverflow
        if overflow || uncached < 0 {
            output.record("cached parts exceed input_tokens; input counted as zero", file: file, line: line.number)
        }

        let tokens: TokenCounts
        do {
            tokens = try TokenCounts(
                input: overflow ? 0 : max(uncached, 0), cachedInput: cached, cacheWrite: cacheWrite,
                output: output.count(usage.outputTokens, "output_tokens", file: file, line: line.number),
                reasoning: reasoning)
        } catch {
            output.record("token counts out of range", file: file, line: line.number)
            return nil
        }

        let project = context.cwd.flatMap { $0.isEmpty ? nil : resolver.candidate(forWorkingDirectory: $0) }
        return IncomingUsage(
            sourceEventID: eventID,
            // A subagent's records name the session it serves; without one,
            // a session is made up from the file.
            sessionSourceID: session ?? context.sessionID ?? threadKey(context, file),
            project: project, rawModel: context.model, timestamp: timestamp, tokens: tokens,
            serviceTier: context.serviceTier, sourceType: Self.sourceType, file: file.path, schemaVersion: context.version, offset: line.offset)
    }
}

/// What a Codex pass knows at the point it stops, so the next can resume.
/// Stored as JSON in the source state; never holds content, only identifiers.
struct CodexResumeState: Codable, Equatable {
    var threadID: String?
    var sessionID: String?
    var cwd: String?
    var model: String?
    var version: String?
    /// Once a file has yielded a valid `token_usage_record`, its `token_count` lines
    /// are duplicates. Carried so a pass that starts between a record and its
    /// `token_count` still knows to skip the latter.
    var hasRecords = false
    var serviceTier: String?
    /// The running total last seen, and for the oldest format the last
    /// request's usage: what a re-emitted `token_count` repeats.
    var lastTotal: CodexLine.Usage?
    var lastUsage: CodexLine.Usage?
    /// While set, the file is a forked thread still copying its parent's
    /// history, and this is the copied line's time in epoch milliseconds.
    var forkCopyAnchor: Int64?

    init() {}

    init?(encoded: String) {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8)) else { return nil }
        self = value
    }

    var encoded: String? {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// The fields of a Codex rollout line that Burnline reads. Unknown fields are
/// ignored; the CLI version is kept as the source schema version.
struct CodexLine: Decodable {
    let timestamp: String?
    let type: String?
    let payload: Payload?

    /// Just enough of a line to tell whether it is one this parser acts on.
    /// A malformed line of another type is none of its business.
    struct Envelope: Decodable {
        let type: String?
        let payload: Kind?

        struct Kind: Decodable { let type: String? }

        var isRead: Bool {
            switch type {
            case "session_meta", "turn_context", "token_usage_record": true
            case "event_msg": payload?.type == "token_count" || payload?.type == "thread_settings_applied"
            default: false
            }
        }
    }

    struct Payload: Decodable {
        let type: String?
        let id: String?
        let sessionID: String?
        let responseID: String?
        let cwd: String?
        let model: String?
        let cliVersion: String?
        let baseInstructions: BaseInstructions?
        let forkedFromID: String?
        let source: Source?
        let threadSettings: ThreadSettings?
        let usage: Usage?
        let info: Info?

        enum CodingKeys: String, CodingKey {
            case type, id, cwd, model, usage, info, source
            case forkedFromID = "forked_from_id"
            case threadSettings = "thread_settings"
            case sessionID = "session_id"
            case responseID = "response_id"
            case cliVersion = "cli_version"
            case baseInstructions = "base_instructions"
        }
    }

    struct ThreadSettings: Decodable {
        let serviceTier: String?
        enum CodingKeys: String, CodingKey { case serviceTier = "service_tier" }
    }

    /// Where a thread came from. A plain string for a top-level thread
    /// (`"vscode"`, `"exec"`); an object for a subagent, whose spawned form
    /// names the parent thread it was forked from.
    struct Source: Decodable {
        let parentThreadID: String?

        private enum Keys: String, CodingKey {
            case subagent
            case threadSpawn = "thread_spawn"
            case parentThreadID = "parent_thread_id"
        }

        init(from decoder: any Decoder) throws {
            let spawn = try? decoder.container(keyedBy: Keys.self)
                .nestedContainer(keyedBy: Keys.self, forKey: .subagent)
                .nestedContainer(keyedBy: Keys.self, forKey: .threadSpawn)
            parentThreadID = try? spawn?.decode(String.self, forKey: .parentThreadID)
        }
    }

    /// Only the provenance: the instruction text itself is never decoded.
    struct BaseInstructions: Decodable {
        let provenance: Provenance?
        struct Provenance: Decodable { let model: String? }
    }

    struct Info: Decodable {
        let totalTokenUsage: Usage?
        let lastTokenUsage: Usage?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
            case lastTokenUsage = "last_token_usage"
        }
    }

    struct Usage: Codable, Equatable {
        let inputTokens: Int64?
        let cachedInputTokens: Int64?
        let cacheWriteInputTokens: Int64?
        let outputTokens: Int64?
        let reasoningOutputTokens: Int64?
        let totalTokens: Int64?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case cacheWriteInputTokens = "cache_write_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case totalTokens = "total_tokens"
        }
    }
}
