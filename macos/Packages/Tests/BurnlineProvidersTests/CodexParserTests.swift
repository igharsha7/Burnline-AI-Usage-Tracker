//
//  CodexParserTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineProviders
import BurnlineTestSupport
import Foundation
import libzstd
import Testing

/// A Codex rollout in a temporary `CODEX_HOME`. Lines are built as JSON
/// objects shaped like the real format, with only the fields under test.
struct Rollout {
    let home: URL
    let file: URL

    init(name: String = "rollout-2026-10-30T12-00-00-thread-1.jsonl") throws {
        home = TestDirectory.make("CodexFixture")
        let day = home.appending(path: "sessions/2026/10/30")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        file = day.appending(path: name)
    }

    static let at = "2026-10-30T12:00:00.500Z"

    static func meta(id: String = "thread-1", session: String? = nil, cwd: String = "/nonexistent/codex-fixture",
                     version: String = "0.166.0", forkedFrom: String? = nil, at: String = at) -> [String: Any] {
        var payload: [String: Any] = ["id": id, "cwd": cwd, "cli_version": version,
                                      "base_instructions": ["text": "SECRET-PROMPT-TEXT",
                                                            "provenance": ["model": "gpt-6-astra"]],
                                      "source": ["subagent": ["other": "x"]]]
        if let session { payload["session_id"] = session }
        if let forkedFrom { payload["forked_from_id"] = forkedFrom }
        return ["timestamp": at, "type": "session_meta", "payload": payload]
    }

    static func turn(model: String = "gpt-6.1-sol", cwd: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["turn_id": "turn-1", "model": model,
                                      "collaboration_mode": ["settings": ["developer_instructions": "SECRET"]]]
        if let cwd { payload["cwd"] = cwd }
        return ["timestamp": at, "type": "turn_context", "payload": payload]
    }

    static func usage(input: Int = 1_000, cached: Int = 800, output: Int = 50, reasoning: Int = 20,
                      cacheWrite: Int? = nil) -> [String: Any] {
        var usage: [String: Any] = ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                                    "reasoning_output_tokens": reasoning, "total_tokens": input + output]
        if let cacheWrite { usage["cache_write_input_tokens"] = cacheWrite }
        return usage
    }

    static func record(response: String? = "resp_1", session: String? = "session-1",
                       usage: [String: Any] = usage(), timestamp: String = at) -> [String: Any] {
        var payload: [String: Any] = ["thread_id": "thread-1", "turn_id": "turn-1", "usage": usage,
                                      "turn_token_usage": usage, "thread_token_usage": usage]
        if let response { payload["response_id"] = response }
        if let session { payload["session_id"] = session }
        return ["timestamp": timestamp, "type": "token_usage_record", "payload": payload]
    }

    /// A `token_count` whose running total is `total` (nil for the oldest
    /// format, which had none).
    static func tokenCount(last: [String: Any] = usage(), total: Int?, at: String = at) -> [String: Any] {
        var info: [String: Any] = ["last_token_usage": last]
        if let total {
            var cumulative = last
            cumulative["total_tokens"] = total
            info["total_token_usage"] = cumulative
        }
        return ["timestamp": at, "type": "event_msg",
                "payload": ["type": "token_count", "info": info,
                            "rate_limits": ["primary": ["used_percent": 12.5]]]]
    }

    static func settings(tier: String) -> [String: Any] {
        ["timestamp": at, "type": "event_msg",
         "payload": ["type": "thread_settings_applied", "thread_settings": ["service_tier": tier, "model": "x"]]]
    }

    /// The file's lines, compressed into a `.jsonl.zst` beside it.
    func compress() throws -> URL {
        let source = try Data(contentsOf: file)
        var compressed = Data(count: ZSTD_compressBound(source.count))
        let size = compressed.withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { ZSTD_compress(destination.baseAddress, destination.count,
                                                   $0.baseAddress, $0.count, 3) }
        }
        #expect(ZSTD_isError(size) == 0)
        let archive = home.appending(path: "archived_sessions/\(file.lastPathComponent).zst")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try compressed.prefix(size).write(to: archive)
        return archive
    }

    static func message(_ text: String) -> [String: Any] {
        ["timestamp": at, "type": "response_item",
         "payload": ["type": "message", "content": [["type": "output_text", "text": text]]]]
    }

    func write(_ lines: [Any], append: Bool = false) throws {
        let text = try lines.map { line -> String in
            if let raw = line as? String { return raw }
            return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        guard append, FileManager.default.fileExists(atPath: file.path) else {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    var adapter: CodexAdapter { CodexAdapter(codexDirectories: [URL(filePath: home.path)]) }

    func parse(from offset: Int64 = 0, state: String? = nil) throws -> ParseOutput {
        try adapter.parse(file, from: offset, state: state)
    }
}

struct CodexParserTests {
    @Test func `EC-I1 a malformed fallback timestamp does not consume the running total`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(), Rollout.tokenCount(total: 1_050, at: "yesterday")])
        let first = try rollout.parse()
        #expect(first.records.isEmpty && first.issueCount == 1)
        try rollout.write([Rollout.tokenCount(total: 1_050)], append: true)
        let resumed = try rollout.parse(from: first.endOffset, state: first.endState)
        #expect(resumed.records.count == 1)
        #expect(try rollout.parse().records.count == 1)
    }

    @Test func `EC-I1 an unusable token record does not suppress valid fallback usage`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(),
                           ["timestamp": Rollout.at, "type": "token_usage_record",
                            "payload": ["response_id": "missing-usage"]],
                           Rollout.tokenCount(total: 1_050)])
        let first = try rollout.parse()
        #expect(first.records.count == 1)
        #expect(first.issueCount == 1)
        try rollout.write([Rollout.tokenCount(total: 2_100, at: "2026-10-30T12:00:02Z")], append: true)
        #expect(try rollout.parse(from: first.endOffset, state: first.endState).records.count == 1)
    }

    @Test func `EC-I8 oversized fallback counts do not trap and the next event survives`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(),
                           Rollout.tokenCount(last: ["input_tokens": Int64.max, "cached_input_tokens": 0,
                                                     "output_tokens": 1], total: nil),
                           Rollout.tokenCount(total: 1_050, at: "2026-10-30T12:00:01Z")])
        let output = try rollout.parse()
        #expect(output.records.count == 1)
        #expect(output.issueCount == 1)
    }

    @Test func `a zero-token context marker resets the fallback running baseline`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(),
                           Rollout.tokenCount(total: 1_050),
                           Rollout.tokenCount(last: Rollout.usage(input: 0, cached: 0, output: 0), total: 0),
                           Rollout.tokenCount(total: 1_050, at: "2026-10-30T13:00:00Z")])
        #expect(try rollout.parse().records.count == 2)
    }

    @Test func `EC-I8 negative optional token counts are reported`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.record(usage: Rollout.usage(reasoning: -1, cacheWrite: -1))])
        let output = try rollout.parse()
        #expect(output.records.count == 1)
        #expect(output.issueCount == 2)
    }

    @Test func `an empty compressed archive is unreadable`() throws {
        let rollout = try Rollout(name: "empty.jsonl.zst")
        try Data().write(to: rollout.file)
        #expect(throws: ZstdStream.Failure.truncated) { try rollout.parse() }
    }

    @Test func `a token record becomes one event, input net of its cached part`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(),
                           Rollout.record(usage: Rollout.usage(input: 1_000, cached: 800, output: 50, reasoning: 20))])
        let output = try rollout.parse()
        let record = try #require(output.records.first)

        #expect(output.records.count == 1 && output.issueCount == 0)
        #expect(record.sourceEventID == "resp_1")
        #expect(record.sessionSourceID == "session-1")
        #expect(record.rawModel == "gpt-6.1-sol")
        #expect(record.schemaVersion == "0.166.0")
        #expect(record.timestamp == Timestamp(epochSeconds: 1_793_361_600))
        // Reasoning is part of output, reported beside it and not added.
        #expect(record.tokens == (try TokenCounts(input: 200, cachedInput: 800, output: 50, reasoning: 20)))
        #expect(record.tokens.processed == 1_050)
    }

    @Test func `a cache write is taken out of input too`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(),
                           Rollout.record(usage: Rollout.usage(input: 1_000, cached: 600, cacheWrite: 100))])
        let tokens = try #require(try rollout.parse().records.first?.tokens)
        #expect(tokens.input == 300 && tokens.cachedInput == 600 && tokens.cacheWrite == 100)
    }

    @Test func `token_count repeats a record, so where records exist it is skipped`() throws {
        let rollout = try Rollout()
        try rollout.write([
            Rollout.meta(), Rollout.turn(),
            Rollout.record(response: "resp_1"), Rollout.tokenCount(total: 1_050),
            // A compaction response: a record with no token_count after it.
            Rollout.record(response: "resp_compact"),
            Rollout.record(response: "resp_2"), Rollout.tokenCount(total: 2_100),
        ])
        #expect(try rollout.parse().records.map(\.sourceEventID) == ["resp_1", "resp_compact", "resp_2"])
    }

    @Test func `without records, token_count is the event and a re-emission is not`() throws {
        let rollout = try Rollout()
        try rollout.write([
            Rollout.meta(), Rollout.turn(),
            ["timestamp": Rollout.at, "type": "event_msg", "payload": ["type": "token_count", "info": NSNull()]],
            Rollout.tokenCount(total: 1_050, at: "2026-10-30T12:00:01Z"),
            Rollout.tokenCount(total: 1_050, at: "2026-10-30T12:00:02Z"),
            Rollout.tokenCount(total: 2_100, at: "2026-10-30T12:00:03Z"),
        ])
        let output = try rollout.parse()
        #expect(output.records.map(\.sourceEventID) == ["thread-1:2026-10-30T12:00:01Z:1050",
                                                        "thread-1:2026-10-30T12:00:03Z:2100"])
        #expect(output.records.first?.sessionSourceID == "thread-1")
    }

    @Test func `a token_count with no input and no output reports context size and is not counted`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(),
                           Rollout.tokenCount(last: Rollout.usage(input: 0, cached: 0, output: 0, reasoning: 0),
                                              total: 0)])
        #expect(try rollout.parse().records.isEmpty)
    }

    @Test func `the oldest format, with no running total, drops a line repeated back to back`() throws {
        let rollout = try Rollout()
        try rollout.write([
            Rollout.meta(), Rollout.turn(),
            Rollout.tokenCount(total: nil, at: "2026-10-30T12:00:01Z"),
            Rollout.tokenCount(total: nil, at: "2026-10-30T12:00:02Z"),
            Rollout.tokenCount(last: Rollout.usage(input: 5), total: nil, at: "2026-10-30T12:00:03Z"),
        ])
        #expect(try rollout.parse().records.count == 2)
    }

    @Test func `a session resumed in a new process restarts its total without losing a request`() throws {
        let rollout = try Rollout()
        try rollout.write([
            Rollout.meta(), Rollout.turn(),
            Rollout.tokenCount(total: 1_050, at: "2026-10-30T12:00:01Z"),
            Rollout.tokenCount(total: 2_100, at: "2026-10-30T12:00:02Z"),
            // Resumed: the total starts again from this request.
            Rollout.tokenCount(total: 1_050, at: "2026-10-30T13:00:00Z"),
        ])
        #expect(Set(try rollout.parse().records.map(\.sourceEventID)).count == 3)
    }

    @Test func `a forked thread's copy of its parent history is not counted again`() throws {
        let rollout = try Rollout()
        try rollout.write([
            Rollout.meta(forkedFrom: "parent-thread", at: "2026-10-30T12:00:00.000Z"),
            // Copied from the parent in a burst, milliseconds apart.
            Rollout.tokenCount(total: 1_050, at: "2026-10-30T12:00:00.010Z"),
            Rollout.tokenCount(total: 2_100, at: "2026-10-30T12:00:00.030Z"),
            Rollout.turn(),
            // The fork's own request, seconds later.
            Rollout.tokenCount(last: Rollout.usage(input: 100, cached: 0, output: 10), total: 2_210,
                               at: "2026-10-30T12:00:06Z"),
        ])
        let records = try rollout.parse().records
        #expect(records.count == 1)
        #expect(records.first?.tokens.input == 100)
    }

    @Test func `a pass resumed inside a fork's copied burst keeps skipping it`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(forkedFrom: "parent-thread", at: "2026-10-30T12:00:00.000Z"),
                           Rollout.tokenCount(total: 1_050, at: "2026-10-30T12:00:00.010Z")])
        let first = try rollout.parse()
        try rollout.write([Rollout.tokenCount(total: 2_100, at: "2026-10-30T12:00:00.020Z")], append: true)
        #expect(try rollout.parse(from: first.endOffset, state: first.endState).records.isEmpty)
    }

    @Test func `the service tier in force is carried onto each event`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(), Rollout.record(response: "before"),
                           Rollout.settings(tier: "priority"), Rollout.record(response: "after")])
        #expect(try rollout.parse().records.map(\.serviceTier) == [nil, "priority"])
    }

    @Test func `EC-I12 concatenated compressed frames retain long lines and offsets`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(),
                           Rollout.message(String(repeating: "x", count: LineReader.chunkSize * 3)),
                           Rollout.record(response: "r1")])
        let first = try rollout.parse()
        let archive = try rollout.compress()
        let frame = try Data(contentsOf: archive)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seekToEnd()
        try handle.write(contentsOf: frame)
        try handle.close()
        let output = try rollout.adapter.parse(archive, from: 0, state: nil)
        #expect(output.records.map(\.sourceEventID) == ["r1", "r1"])
        #expect(output.endOffset == first.endOffset * 2)
        #expect(output.records.last?.offset == first.records.first.map { $0.offset + first.endOffset })
    }

    @Test func `a compressed archive reads exactly as its uncompressed form`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(), Rollout.record(response: "r1"),
                           Rollout.tokenCount(total: 1_050), Rollout.record(response: "r2")])
        let archive = try rollout.compress()
        let plain = try rollout.parse()
        // Offsets and state are ignored: a compressed stream starts at the top.
        let compressed = try rollout.adapter.parse(archive, from: 999, state: "stale")
        #expect(compressed.records.map(\.sourceEventID) == plain.records.map(\.sourceEventID))
        #expect(compressed.records.map(\.tokens) == plain.records.map(\.tokens))
        #expect(compressed.endOffset == plain.endOffset)
    }

    @Test func `a cut-short or corrupt archive is an error, not an empty file`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(), Rollout.record()])
        let archive = try rollout.compress()
        let bytes = try Data(contentsOf: archive)
        try bytes.prefix(bytes.count - 4).write(to: archive)
        #expect(throws: ZstdStream.Failure.truncated) { try rollout.adapter.parse(archive, from: 0, state: nil) }

        try Data("00000000: 28b5 2ffd a0f8 4d02\n".utf8).write(to: archive)
        #expect { try rollout.adapter.parse(archive, from: 0, state: nil) } throws: {
            if case .invalid = $0 as? ZstdStream.Failure { true } else { false }
        }
    }

    @Test func `a thread with no meta is named the same compressed or not`() throws {
        let rollout = try Rollout(name: "rollout-orphan.jsonl")
        try rollout.write([Rollout.turn(), Rollout.tokenCount(total: 1_050)])
        let archive = try rollout.compress()
        #expect(try rollout.adapter.parse(archive, from: 0, state: nil).records.map(\.sessionSourceID)
                == ["file:rollout-orphan"])
    }

    @Test func `with no turn context, the meta's instruction model stands in until a turn names one`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.tokenCount(total: 1_050),
                           Rollout.turn(model: "gpt-6.1-sol"), Rollout.tokenCount(total: 2_100)])
        #expect(try rollout.parse().records.map(\.rawModel) == ["gpt-6-astra", "gpt-6.1-sol"])
    }

    @Test func `the model in force carries into a pass that resumes mid-file`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(model: "gpt-6.1-sol"), Rollout.record(response: "resp_1")])
        let first = try rollout.parse()

        try rollout.write([Rollout.record(response: "resp_2")], append: true)
        let resumed = try rollout.parse(from: first.endOffset, state: first.endState)
        let record = try #require(resumed.records.first)
        #expect(resumed.records.count == 1)
        #expect(record.rawModel == "gpt-6.1-sol" && record.schemaVersion == "0.166.0")
        #expect(record.project != nil)
    }

    @Test func `a pass that resumes between a record and its token_count does not count it twice`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(), Rollout.record(response: "resp_1")])
        let first = try rollout.parse()
        try rollout.write([Rollout.tokenCount(total: 1_050)], append: true)
        #expect(try rollout.parse(from: first.endOffset, state: first.endState).records.isEmpty)
    }

    @Test func `resuming without its state starts the file over rather than lose the model`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(), Rollout.record(response: "resp_1")])
        let first = try rollout.parse()
        try rollout.write([Rollout.record(response: "resp_2")], append: true)

        for state in [nil, "not json"] {
            let output = try rollout.parse(from: first.endOffset, state: state)
            #expect(output.records.map(\.sourceEventID) == ["resp_1", "resp_2"])
            #expect(output.records.allSatisfy { $0.rawModel == "gpt-6.1-sol" })
        }
    }

    @Test func `a forked subagent file keeps its own thread and serves its parent session`() throws {
        let rollout = try Rollout()
        try rollout.write([
            Rollout.meta(id: "child-thread", session: "parent-session", version: "0.164.0"),
            Rollout.meta(id: "parent-thread", version: "0.160.0"),
            Rollout.turn(), Rollout.record(session: nil),
        ])
        let record = try #require(try rollout.parse().records.first)
        #expect(record.sessionSourceID == "parent-session")
        #expect(record.schemaVersion == "0.164.0")
    }

    @Test func `EC-I1 a malformed record is reported by reason, and another type's is not`() throws {
        let rollout = try Rollout()
        try rollout.write([
            Rollout.meta(), Rollout.turn(),
            "{\"type\":\"token_usage_record\", SECRET-PROMPT-TEXT",
            // Valid JSON of a type this parser ignores, mentioning a marker.
            ["type": "response_item", "payload": ["id": 42, "text": "token_count"]],
            Rollout.message("talking about \"token_count\" lines"),
            Rollout.record(response: "after"),
        ])
        let output = try rollout.parse()
        #expect(output.records.map(\.sourceEventID) == ["after"])
        #expect(output.issueCount == 1)
        #expect(output.issues.allSatisfy { !$0.reason.contains("SECRET") })
    }

    @Test func `EC-I8 a cached part larger than the input is recorded and counted as zero input`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(),
                           Rollout.record(usage: Rollout.usage(input: 10, cached: 50))])
        let output = try rollout.parse()
        #expect(output.records.first?.tokens.input == 0 && output.records.first?.tokens.cachedInput == 50)
        #expect(output.issueCount == 1)
    }

    @Test func `older formats without cache writes or reasoning are not faults`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(), Rollout.turn(), Rollout.record(usage: [
            "input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 5,
        ])])
        let output = try rollout.parse()
        #expect(output.records.count == 1 && output.issueCount == 0)
    }

    @Test func `EC-I7 a record with no ids anywhere gets ones from its file`() throws {
        let rollout = try Rollout(name: "rollout-orphan.jsonl")
        try rollout.write([Rollout.turn(), Rollout.record(response: nil, session: nil)])
        let record = try #require(try rollout.parse().records.first)
        #expect(record.sessionSourceID == "file:rollout-orphan")
        #expect(record.sourceEventID.hasPrefix("file:rollout-orphan:"))
    }

    @Test func `EC-I6 a thread with no working directory has no project`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta(cwd: ""), Rollout.turn(), Rollout.record()])
        #expect(try rollout.parse().records.first?.project == nil)
    }

    @Test func `archives are found compressed and uncompressed`() throws {
        let rollout = try Rollout()
        try rollout.write([Rollout.meta()])
        let archive = rollout.home.appending(path: "archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try "".write(to: archive.appending(path: "rollout-old.jsonl"), atomically: true, encoding: .utf8)
        try "".write(to: archive.appending(path: "rollout-older.jsonl.zst"), atomically: true, encoding: .utf8)
        #expect(try rollout.adapter.sourceFiles().map(\.lastPathComponent).sorted()
                == ["rollout-2026-10-30T12-00-00-thread-1.jsonl", "rollout-old.jsonl", "rollout-older.jsonl.zst"])
    }

    @Test func `CODEX_HOME moves the main home, and Xcode's assistant home is read too`() {
        let adapter = CodexAdapter(environment: ["CODEX_HOME": "/custom/codex"])
        #expect(adapter.codexDirectories.map(\.path) == ["/custom/codex",
                                                         ProviderHomes.xcodeAssistant.appending(path: "codex").path])
    }

    @Test func `EC-I11 a missing Codex home is not installed, not an error`() throws {
        let adapter = CodexAdapter(codexDirectories: [URL(filePath: "/nonexistent/\(UUID().uuidString)")])
        #expect(adapter.detect() == .notInstalled)
        #expect(try adapter.sourceFiles().isEmpty)
    }
}
