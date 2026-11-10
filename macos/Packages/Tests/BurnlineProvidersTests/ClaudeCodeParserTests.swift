//
//  ClaudeCodeParserTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineProviders
import BurnlineTestSupport
import Foundation
import Testing

/// Writes transcript lines to a temporary file. Lines are built as JSON
/// objects so each test states only the fields it is about.
struct Transcript {
    let directory: URL
    let file: URL

    init(name: String = "11111111-2222-3333-4444-555555555555.jsonl") throws {
        directory = TestDirectory.make("ClaudeFixture")
        let project = directory.appending(path: "-Users-someone-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        file = project.appending(path: name)
    }

    static func assistant(id: String? = "msg_1", model: String? = "claude-opus-5", session: String? = "s1",
                          cwd: String? = "/nonexistent/burnline-fixture",
                          timestamp: String? = "2026-10-30T12:00:00.250Z",
                          usage: [String: Any]? = ["input_tokens": 10, "cache_read_input_tokens": 200,
                                                   "cache_creation_input_tokens": 50, "output_tokens": 30],
                          extra: [String: Any] = [:]) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": "SECRET-PROMPT-TEXT"]]]
        if let id { message["id"] = id }
        if let model { message["model"] = model }
        if let usage { message["usage"] = usage }
        var line: [String: Any] = ["type": "assistant", "uuid": UUID().uuidString, "message": message,
                                   "version": "2.1.314"]
        if let session { line["sessionId"] = session }
        if let cwd { line["cwd"] = cwd }
        if let timestamp { line["timestamp"] = timestamp }
        return line.merging(extra) { $1 }
    }

    func write(_ lines: [Any], trailingNewline: Bool = true) throws {
        let text = try lines.map { line -> String in
            if let raw = line as? String { return raw }
            return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
        }.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    var adapter: ClaudeCodeAdapter { ClaudeCodeAdapter(projectsDirectories: [directory]) }

    func parse(from offset: Int64 = 0) throws -> ParseOutput { try adapter.parse(file, from: offset, state: nil) }
}

struct ClaudeCodeParserTests {
    @Test func `EC-I8 negative optional Claude counts are reported`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant(usage: [
            "input_tokens": 1, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 10,
            "cache_creation": ["ephemeral_1h_input_tokens": -1], "output_tokens": 2,
            "output_tokens_details": ["thinking_tokens": -1],
        ])])
        let output = try transcript.parse()
        #expect(output.records.first?.tokens.cacheWriteOneHour == 0)
        #expect(output.records.first?.tokens.reasoning == 0)
        #expect(output.issueCount == 2)
    }

    @Test func `an assistant line becomes one record with every token component`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant(usage: [
            "input_tokens": 10, "cache_read_input_tokens": 200, "cache_creation_input_tokens": 50,
            "cache_creation": ["ephemeral_5m_input_tokens": 20, "ephemeral_1h_input_tokens": 30],
            "output_tokens": 40, "output_tokens_details": ["thinking_tokens": 12],
        ])])
        let output = try transcript.parse()
        let record = try #require(output.records.first)

        #expect(output.records.count == 1 && output.issues.isEmpty)
        #expect(record.sourceEventID == "msg_1")
        #expect(record.sessionSourceID == "s1")
        #expect(record.rawModel == "claude-opus-5")
        #expect(record.timestamp == Timestamp(epochSeconds: 1_793_361_600))   // fraction floored
        #expect(record.tokens == (try TokenCounts(input: 10, cachedInput: 200, cacheWrite: 50,
                                                 cacheWriteOneHour: 30, output: 40, reasoning: 12)))
        #expect(record.schemaVersion == "2.1.314")
    }

    @Test func `the service tier is kept, and fast mode is recorded as fast`() throws {
        let transcript = try Transcript()
        let usage: [String: Any] = ["input_tokens": 1, "output_tokens": 1, "cache_read_input_tokens": 0,
                                    "cache_creation_input_tokens": 0, "service_tier": "standard"]
        var fast = usage
        fast["speed"] = "fast"
        try transcript.write([Transcript.assistant(id: "a", usage: usage), Transcript.assistant(id: "b", usage: fast),
                              Transcript.assistant(id: "c")])
        #expect(try transcript.parse().records.map(\.serviceTier) == ["standard", "fast", nil])
    }

    @Test func `lines that are not assistant replies are skipped`() throws {
        let transcript = try Transcript()
        try transcript.write([
            ["type": "user", "message": ["role": "user", "content": "please say \"assistant\""]],
            ["type": "summary", "summary": "x"],
            Transcript.assistant(),
        ])
        #expect(try transcript.parse().records.count == 1)
    }

    @Test func `EC-I1 a malformed line is recorded by reason and the file continues`() throws {
        let transcript = try Transcript()
        try transcript.write([
            "{\"type\":\"assistant\",\"message\": SECRET-PROMPT-TEXT",
            Transcript.assistant(id: "msg_after"),
        ])
        let output = try transcript.parse()
        #expect(output.records.map(\.sourceEventID) == ["msg_after"])
        let issue = try #require(output.issues.first)
        #expect(issue.line == 1)
        #expect(!issue.reason.contains("SECRET"))
    }

    @Test func `EC-I1 a wrongly typed field names the field, never the content`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant(usage: ["input_tokens": "SECRET-PROMPT-TEXT"])])
        let issue = try #require(try transcript.parse().issues.first)
        #expect(issue.reason.contains("input_tokens"))
        #expect(!issue.reason.contains("SECRET"))
    }

    @Test func `EC-I5 unknown fields are ignored and the version is kept`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant(extra: ["someFutureField": ["nested": [1, 2, 3]],
                                                           "version": "9.9.9"])])
        let output = try transcript.parse()
        #expect(output.issues.isEmpty)
        #expect(output.records.first?.schemaVersion == "9.9.9")
    }

    @Test func `EC-I6 a record with no working directory has no project`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant(cwd: nil), Transcript.assistant(id: "msg_2", cwd: "")])
        #expect(try transcript.parse().records.allSatisfy { $0.project == nil })
    }

    @Test func `EC-I7 a record with no session id gets one from its file`() throws {
        let transcript = try Transcript(name: "orphan-session.jsonl")
        try transcript.write([Transcript.assistant(session: nil)])
        #expect(try transcript.parse().records.first?.sessionSourceID == "file:orphan-session")
    }

    @Test func `EC-I8 absent or negative counts become zero and are recorded`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant(usage: [
            "input_tokens": -5, "cache_read_input_tokens": 1, "cache_creation_input_tokens": 0,
        ])])
        let output = try transcript.parse()
        let record = try #require(output.records.first)
        #expect(record.tokens.input == 0 && record.tokens.output == 0 && record.tokens.cachedInput == 1)
        #expect(output.issueCount == 2)
    }

    @Test func `a missing timestamp skips the record, since it cannot be placed`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant(timestamp: nil), Transcript.assistant(timestamp: "yesterday")])
        let output = try transcript.parse()
        #expect(output.records.isEmpty && output.issueCount == 2)
    }

    @Test func `EC-M5 an empty model field still yields a counted record`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant(model: nil), Transcript.assistant(id: "msg_2", model: "")])
        #expect(try transcript.parse().records.count == 2)
    }

    @Test func `streaming snapshots of one response share an event id`() throws {
        let transcript = try Transcript()
        try transcript.write([
            Transcript.assistant(usage: ["input_tokens": 1, "cache_read_input_tokens": 0,
                                         "cache_creation_input_tokens": 0, "output_tokens": 5]),
            Transcript.assistant(usage: ["input_tokens": 1, "cache_read_input_tokens": 0,
                                         "cache_creation_input_tokens": 0, "output_tokens": 90]),
        ])
        #expect(Set(try transcript.parse().records.map(\.sourceEventID)) == ["msg_1"])
    }

    @Test func `a one-hour split larger than the total is clamped to it`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant(usage: [
            "input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 10,
            "cache_creation": ["ephemeral_1h_input_tokens": 99], "output_tokens": 0,
        ])])
        let tokens = try #require(try transcript.parse().records.first?.tokens)
        #expect(tokens.cacheWrite == 10 && tokens.cacheWriteOneHour == 10)
    }

    @Test func `EC-I2 a final line without its newline is left for the next pass`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant(id: "complete"), Transcript.assistant(id: "half-written")],
                             trailingNewline: false)
        let first = try transcript.parse()
        #expect(first.records.map(\.sourceEventID) == ["complete"])

        let handle = try FileHandle(forWritingTo: transcript.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let resumed = try transcript.parse(from: first.endOffset)
        #expect(resumed.records.map(\.sourceEventID) == ["half-written"])
    }

    @Test func `the issue log is capped per file but the count stays honest`() throws {
        let transcript = try Transcript()
        try transcript.write(Array(repeating: "{\"type\":\"assistant\", broken", count: 50))
        let output = try transcript.parse()
        #expect(output.issues.count == ParseOutput.issueCap)
        #expect(output.issueCount == 50)
    }

    @Test func `EC-I11 a missing history directory is not installed, not an error`() throws {
        let adapter = ClaudeCodeAdapter(projectsDirectories: [URL(filePath: "/nonexistent/\(UUID().uuidString)")])
        #expect(adapter.detect() == .notInstalled)
        #expect(try adapter.sourceFiles().isEmpty)
    }

    @Test func `CLAUDE_CONFIG_DIR moves the main home, and Xcode's assistant home is read too`() {
        let adapter = ClaudeCodeAdapter(environment: ["CLAUDE_CONFIG_DIR": "/custom/claude"])
        #expect(adapter.projectsDirectories.map(\.path) == [
            "/custom/claude/projects",
            ProviderHomes.xcodeAssistant.appending(path: "ClaudeAgentConfig/projects").path,
        ])
    }

    @Test func `history in several homes is read from all of them`() throws {
        let first = try Transcript()
        let second = try Transcript()
        try first.write([Transcript.assistant(id: "a")])
        try second.write([Transcript.assistant(id: "b")])
        let adapter = ClaudeCodeAdapter(projectsDirectories: [first.directory, second.directory,
                                                              URL(filePath: "/nonexistent/\(UUID().uuidString)")])
        #expect(try adapter.sourceFiles().count == 2)
        #expect(adapter.watchedDirectories().count == 2)
    }

    @Test func `subagent transcripts are found alongside sessions`() throws {
        let transcript = try Transcript()
        try transcript.write([Transcript.assistant()])
        let subagents = transcript.file.deletingPathExtension().appending(path: "subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try "".write(to: subagents.appending(path: "agent-1.jsonl"), atomically: true, encoding: .utf8)
        #expect(try transcript.adapter.sourceFiles().count == 2)
    }

    @Test func `Cursor reports why it is unavailable`() {
        guard case .unavailable(let reason) = CursorAdapter().detect() else {
            Issue.record("Cursor should be unavailable")
            return
        }
        #expect(!reason.isEmpty)
    }
}

struct LineReaderTests {
    @Test func `EC-I12 lines spanning chunk boundaries keep their bytes and offsets`() throws {
        let file = TestDirectory.file("lines.jsonl")
        let long = String(repeating: "x", count: LineReader.chunkSize + 17)
        let lines = ["a", long, "", "bc", long]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        var read: [(String, Int64)] = []
        let end = try LineReader.read(file, from: 0) { read.append((String(decoding: $0.bytes, as: UTF8.self), $0.offset)) }.endOffset

        var expectedOffset: Int64 = 0
        var expected: [(String, Int64)] = []
        for line in lines {
            if !line.isEmpty { expected.append((line, expectedOffset)) }
            expectedOffset += Int64(line.utf8.count) + 1
        }
        #expect(read.map(\.0) == expected.map(\.0))
        #expect(read.map(\.1) == expected.map(\.1))
        #expect(end == expectedOffset)
    }

    @Test func `EC-I12 markers hand over only matching lines, still numbering and counting every line`() throws {
        let file = TestDirectory.file("marked.jsonl")
        // The match sits past the first chunk, so it is found only once the
        // line is whole.
        let long = String(repeating: "x", count: LineReader.chunkSize + 5) + "\"usage\""
        let lines = ["skip", "\"usage\":1", "", long, "\"other\"", "partial \"usage\""]
        try (lines.joined(separator: "\n")).write(to: file, atomically: true, encoding: .utf8)

        var read: [(Int, Int64)] = []
        let pass = try LineReader.read(file, from: 0, containing: ["\"usage\"", "\"none\""]) {
            read.append(($0.number, $0.offset))
        }

        #expect(read.map(\.0) == [2, 4])
        #expect(read.map(\.1) == [5, 16])
        // The unterminated last line is neither read nor counted.
        #expect(pass.lines == 5)
        #expect(pass.endOffset == Int64(lines.dropLast().map { $0.utf8.count + 1 }.reduce(0, +)))
    }

    @Test func `Codex looks for record types near the start, and searches lines whose start cannot tell`() throws {
        var adapter = CodexAdapter(codexDirectories: [])
        adapter.markerWindow = 64
        let select = adapter.recordLines
        let padding = String(repeating: "x", count: 200)
        func selected(_ line: String) -> Bool { Array(line.utf8).withUnsafeBytes { select($0) } }

        // Its type near the start: read.
        #expect(selected(#"{"type":"event_msg","payload":{"type":"token_count","text":""# + padding + #""}}"#))
        // Another type near the start, mentioning a record type later: skipped.
        #expect(!selected(#"{"type":"response_item","payload":{"type":"message","text":"\"token_count\" "# + padding + #""}}"#))
        // No type near the start, as if a later Codex wrote it further in: searched whole.
        #expect(selected(#"{"meta":""# + padding + #"","type":"turn_context"}"#))
        // An event whose payload type is further in: searched whole.
        #expect(selected(#"{"type":"event_msg","payload":{"info":""# + padding + #"","type":"token_count"}}"#))
        // Short lines are searched whole anyway.
        #expect(selected(#"{"type":"session_meta"}"#))
    }
}

/// The line reader against the plainest possible splitter, on seeded random
/// files built to land lines, newlines and markers on chunk boundaries.
struct LineReaderDifferentialTests {
    struct Expected: Equatable {
        let bytes: [UInt8]
        let offset: Int64
        let number: Int
    }

    /// Every complete, non-empty line from `start`, numbered over all lines.
    static func reference(_ data: [UInt8], from start: Int, marker: [UInt8]?) -> (lines: [Expected], count: Int, end: Int64) {
        var lines: [Expected] = [], number = 0, lineStart = start
        for index in start..<data.count where data[index] == 0x0A {
            number += 1
            let line = Array(data[lineStart..<index])
            let matches = marker.map { line.firstRange(of: $0) != nil } ?? true
            if !line.isEmpty && matches { lines.append(Expected(bytes: line, offset: Int64(lineStart), number: number)) }
            lineStart = index + 1
        }
        return (lines, number, Int64(lineStart))
    }

    @Test(arguments: [1, 2, 3])
    func `EC-I12 lines, offsets, counts and markers match a plain splitter`(seed: UInt64) throws {
        var random = SeededLines(seed: seed)
        let marker = Array(#""assistant""#.utf8)
        var data: [UInt8] = []
        for _ in 0..<random.next(upTo: 20) + 10 {
            let length: Int = switch random.next(upTo: 6) {
            case 0: 0
            case 1: LineReader.chunkSize - random.next(upTo: 20)
            case 2: LineReader.chunkSize + 1 + random.next(upTo: 20)
            default: random.next(upTo: 300)
            }
            var line = (0..<length).map { _ in UInt8(ascii: "a") + UInt8(random.next(upTo: 26)) }
            if random.next(upTo: 2) == 0, line.count >= marker.count {
                let at = random.next(upTo: line.count - marker.count + 1)
                line.replaceSubrange(at..<at + marker.count, with: marker)
            }
            data += line + [0x0A]
        }
        if random.next(upTo: 2) == 0 { data += Array("unterminated \"assistant\"".utf8) }

        let file = TestDirectory.file("random-\(seed).jsonl")
        try Data(data).write(to: file)
        let starts = [0] + [Self.reference(data, from: 0, marker: nil).lines.dropFirst(3).first?.offset].compactMap { $0.map(Int.init) }
        for start in starts {
            for selected in [nil, marker] {
                var read: [Expected] = []
                let pass = try LineReader.read(file, from: Int64(start),
                                               selecting: selected.map { m in { LineReader.contains($0, m) } }) {
                    read.append(Expected(bytes: Array($0.bytes), offset: $0.offset, number: $0.number))
                }
                let expected = Self.reference(data, from: start, marker: selected)
                #expect(read == expected.lines, "seed \(seed) from \(start)")
                #expect(pass.lines == expected.count && pass.endOffset == expected.end)
            }
        }
    }
}

/// SplitMix64, so a failing seed fails the same way every run.
struct SeededLines {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(upTo bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(max(bound, 1)))
    }
}
