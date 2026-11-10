//
//  IncrementalIngestionTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineProviders
@testable import BurnlineServices
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import Testing

/// Syncing a history that keeps changing: appended, cut short, replaced,
/// interrupted. Through the real adapters and the real store.
struct IncrementalIngestionTests {
    let root = TestDirectory.make("Incremental")
    var projects: URL { root.appending(path: "claude/projects") }
    var transcript: URL { projects.appending(path: "p/s1.jsonl") }
    var claude: ClaudeCodeAdapter { ClaudeCodeAdapter(projectsDirectories: [projects]) }

    func database() throws -> BurnlineDatabase {
        try BurnlineDatabase.open(
            at: StoreLocation(directory: root.appending(path: "db")),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")),
            clock: ManualClock(Timestamp(epochSeconds: 1_793_450_000)))
    }

    static func line(_ id: String) -> String {
        IngestionActorTests.line(id: id, session: "s1", cwd: "/nowhere")
    }

    func write(_ text: String, append: Bool = false) throws {
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard append else {
            try text.write(to: transcript, atomically: true, encoding: .utf8)
            return
        }
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func lines(_ ids: [String]) -> String { ids.map(Self.line).joined(separator: "\n") + "\n" }

    /// The path as the adapter reports it, which is how its state is keyed.
    /// It can differ from `transcript` by a resolved symlink.
    func storedState(_ database: BurnlineDatabase) throws -> SourceState? {
        let identifier = try #require(try claude.sourceFiles().first).path
        return try database.sourceStates.state(provider: .claudeCode, identifier: identifier)
    }

    func eventIDs(_ database: BurnlineDatabase) throws -> [String] {
        try database.read { try String.fetchAll($0, sql: "SELECT source_event_id FROM usage_events ORDER BY 1") }
    }

    @Test func `an appended line is read on its own, and an untouched file not at all`() async throws {
        try write(lines(["m1", "m2"]))
        let database = try database()
        let actor = IngestionActor(database: database)
        _ = try await actor.sync(from: claude)

        let idle = try await actor.sync(from: claude)
        #expect(idle.filesUnchanged == 1 && idle.linesRead == 0)

        try write(lines(["m3"]), append: true)
        let grown = try await actor.sync(from: claude)
        #expect(grown.linesRead == 1 && grown.eventsWritten == 1)
        #expect(try eventIDs(database) == ["m1", "m2", "m3"])
    }

    @Test func `the offset is saved with the events it covers`() async throws {
        try write(lines(["m1", "m2"]))
        let database = try database()
        _ = try await IngestionActor(database: database).sync(from: claude)
        let state = try #require(try storedState(database))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: transcript.path)[.size] as? Int)
        #expect(state.lastOffset == Int64(size) && state.fileSize == Int64(size))
        #expect(state.lastEventIdentifier == "m2")
    }

    @Test func `EC-I2 a half-written final line is read once it is finished`() async throws {
        try write(lines(["m1"]) + Self.line("m2"))
        let database = try database()
        let actor = IngestionActor(database: database)
        _ = try await actor.sync(from: claude)
        #expect(try eventIDs(database) == ["m1"])

        try write("\n", append: true)
        _ = try await actor.sync(from: claude)
        #expect(try eventIDs(database) == ["m1", "m2"])
    }

    @Test func `EC-I3 shrinking only the incomplete tail forces a full scan`() async throws {
        try write(lines(["m1"]) + Self.line("unfinished"))
        let database = try database()
        let actor = IngestionActor(database: database)
        _ = try await actor.sync(from: claude)
        // The replacement prefix ends at the same newline boundary, and the
        // file is still longer than the offset but shorter than its old size.
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((lines(["m2"]) + "x").utf8))
        try handle.close()
        _ = try await actor.sync(from: claude)
        #expect(try eventIDs(database) == ["m1", "m2"])
    }

    @Test func `EC-I3 a same-size rewrite within one second is scanned`() async throws {
        try write(lines(["m1"]))
        let second = TimeInterval(1_793_450_000)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: second + 0.1)],
                                              ofItemAtPath: transcript.path)
        let database = try database()
        let actor = IngestionActor(database: database)
        _ = try await actor.sync(from: claude)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.write(contentsOf: Data(lines(["m2"]).utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: second + 0.2)],
                                              ofItemAtPath: transcript.path)
        let result = try await actor.sync(from: claude)
        #expect(result.filesRead == 1)
        #expect(try eventIDs(database) == ["m1", "m2"])
    }

    @Test func `EC-I3 a truncated file that grows again ends with the right total`() async throws {
        try write(lines(["m1", "m2", "m3"]))
        let database = try database()
        let actor = IngestionActor(database: database)
        _ = try await actor.sync(from: claude)

        // Cut back to its first line in place, so the inode is unchanged.
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.truncate(atOffset: UInt64(lines(["m1"]).utf8.count))
        try handle.close()
        _ = try await actor.sync(from: claude)

        try write(lines(["m2", "m3", "m4"]), append: true)
        _ = try await actor.sync(from: claude)
        #expect(try eventIDs(database) == ["m1", "m2", "m3", "m4"])
        #expect(try database.usage.count() == 4)
    }

    @Test func `EC-I3 a file rewritten past its old length is read again, not from mid-line`() async throws {
        try write(lines(["m1", "m2"]))
        let database = try database()
        let actor = IngestionActor(database: database)
        _ = try await actor.sync(from: claude)

        // Same inode, longer, and the old offset now falls inside a line.
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(lines(["longer-first-id", "m5", "m6"]).utf8))
        try handle.close()
        let result = try await actor.sync(from: claude)
        #expect(result.issues == 0)
        #expect(try eventIDs(database) == ["longer-first-id", "m1", "m2", "m5", "m6"])
    }

    @Test func `EC-I3 a file replaced by a new one is read from the start`() async throws {
        try write(lines(["m1", "m2"]))
        let database = try database()
        let actor = IngestionActor(database: database)
        _ = try await actor.sync(from: claude)

        // An atomic write replaces the file, and with it the inode.
        try write(lines(["m1", "m2", "m3"]))
        let result = try await actor.sync(from: claude)
        #expect(result.linesRead == 3 && result.eventsWritten == 1)
        #expect(try database.usage.count() == 3)
    }

    @Test func `EC-I9 events stored without their offset are not stored twice`() async throws {
        try write(lines(["m1", "m2", "m3"]))
        let database = try database()
        // As if a crash came after a batch committed but before the batch
        // that would have advanced the offset.
        let parsed = try claude.parse(transcript, from: 0, state: nil)
        try database.ingest(Array(parsed.records.prefix(2)), issues: [], provider: .claudeCode)
        #expect(try storedState(database) == nil)

        _ = try await IngestionActor(database: database).sync(from: claude)
        #expect(try eventIDs(database) == ["m1", "m2", "m3"])
    }

    @Test func `EC-I9 a failed final batch retains the old offset and replay deduplicates`() async throws {
        try write(lines(["initial"]))
        let database = try database()
        let actor = IngestionActor(database: database)
        _ = try await actor.sync(from: claude)
        let before = try storedState(database)
        let count = IngestionActor.batchSize + 5
        try write(lines((0..<count).map { "m\($0)" }), append: true)
        try database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_offset BEFORE UPDATE ON source_states
                BEGIN SELECT RAISE(ABORT, 'simulated final batch failure'); END
                """)
        }
        await #expect(throws: StoreError.self) { try await actor.sync(from: claude) }
        #expect(try storedState(database) == before)
        #expect(try database.usage.count() == IngestionActor.batchSize + 1)
        try database.write { db in try db.execute(sql: "DROP TRIGGER reject_offset") }
        _ = try await actor.sync(from: claude)
        #expect(try database.usage.count() == count + 1)
        #expect(try storedState(database)?.lastOffset == FileFacts(transcript)?.size)
    }

    @Test func `a file with more records than one batch commits every batch and one offset`() async throws {
        let count = IngestionActor.batchSize + 5
        try write(lines((0..<count).map { "m\($0)" }))
        let database = try database()
        let result = try await IngestionActor(database: database).sync(from: claude)
        #expect(result.eventsWritten == count)
        let state = try storedState(database)
        #expect(state?.lastOffset == Int64(lines((0..<count).map { "m\($0)" }).utf8.count))
    }

    @Test func `a Codex thread resumed after a restart keeps its model`() async throws {
        let home = root.appending(path: "codex")
        let rollout = home.appending(path: "sessions/2026/10/30/rollout-thread-1.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        func record(_ id: String) -> String {
            """
            {"timestamp":"2026-10-30T12:00:00Z","type":"token_usage_record","payload":{"response_id":"\(id)",\
            "session_id":"thread-1","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2}}}
            """
        }
        let opening = """
            {"timestamp":"2026-10-30T12:00:00Z","type":"session_meta","payload":{"id":"thread-1","cwd":"/nowhere"}}
            {"timestamp":"2026-10-30T12:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
            """
        try (opening + "\n" + record("r1") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let adapter = CodexAdapter(codexDirectories: [URL(filePath: home.path)])
        let database = try database()
        _ = try await IngestionActor(database: database).sync(from: adapter)

        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((record("r2") + "\n").utf8))
        try handle.close()
        // A new actor, as after relaunching: the state comes from the store.
        let result = try await IngestionActor(database: database).sync(from: adapter)
        #expect(result.linesRead == 1)
        let models = try database.read {
            try String.fetchAll($0, sql: """
                SELECT m.canonical_name FROM usage_events e JOIN models m ON m.id = e.model_id
                ORDER BY e.source_event_id
                """)
        }
        #expect(models == ["gpt-6.1-sol", "gpt-6.1-sol"])
    }

    @Test func `EC-I10 a change made with no watcher running is picked up by reconciling`() async throws {
        try write(lines(["m1"]))
        let database = try database()
        let reconciler = Reconciler(ingestion: IngestionActor(database: database), adapters: [claude])
        await reconciler.reconcile()

        // Appended "while asleep": nothing is watching.
        try write(lines(["m2"]), append: true)
        await reconciler.reconcile()
        #expect(try eventIDs(database) == ["m1", "m2"])
        #expect(await reconciler.latest[.claudeCode]?.eventsWritten == 1)
    }

    @Test func `one provider failing does not stop another`() async throws {
        try write(lines(["m1"]))
        let database = try database()
        let reconciler = Reconciler(ingestion: IngestionActor(database: database),
                                    adapters: [BrokenAdapter(), claude])
        await reconciler.reconcile()
        #expect(try database.usage.count() == 1)
        #expect(await reconciler.latest[.codex]?.unreadableFiles == 1)
    }

    @Test func `EC-D1 a full disk is announced with its reason, and so is the recovery`() async throws {
        try write(lines((0..<2_000).map { "m\($0)" }))
        let database = try database()
        let announced = Announcements()
        let reconciler = Reconciler(ingestion: IngestionActor(database: database), adapters: [claude],
                                    onStorageChange: { await announced.add($0) })
        // SQLite's page limit fails writes with the same error a full disk does.
        try await database.pool.writeWithoutTransaction { db in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            try db.execute(sql: "PRAGMA max_page_count = \(pages)")
        }
        await reconciler.reconcile()
        let failure = await reconciler.storageFailure
        #expect(failure == .diskFull)
        guard case .degraded(let reason, _) = await reconciler.health()[.claudeCode] else {
            Issue.record("expected degraded health")
            return
        }
        #expect(reason == "New usage is not being saved: the disk is full.")
        #expect(try database.usage.count() == 0)

        // A second failing sync is the same failure, not a new announcement.
        await reconciler.reconcile()
        try await database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA max_page_count = 1073741823") }
        await reconciler.reconcile()
        let all = await announced.all
        #expect(all == [.diskFull, nil])
        #expect(try database.usage.count() == 2_000)
        let recovered = await reconciler.storageFailure
        #expect(recovered == nil)
    }

    @Test func `EC-I11 health says when each provider synced, and why Cursor cannot be measured`() async throws {
        try write(lines(["m1"]))
        let clock = ManualClock(Timestamp(epochSeconds: 1_800_000_000))
        let reconciler = Reconciler(ingestion: IngestionActor(database: try database()),
                                    adapters: [claude, CursorAdapter()], clock: clock)
        #expect(await reconciler.health().isEmpty)

        await reconciler.reconcile()
        let health = await reconciler.health()
        #expect(health[.claudeCode] == .healthy(lastImport: clock.now))
        #expect(health[.cursor] == .unavailable(reason: CursorAdapter.unavailableReason))
    }

    @Test func `an untracked provider is never read, and tracking it imports its history at once`() async throws {
        try write(lines(["m1", "m2"]))
        let database = try database()
        let reconciler = Reconciler(ingestion: IngestionActor(database: database), adapters: [claude], tracked: [])
        await reconciler.reconcile()
        #expect(try database.usage.count() == 0)
        #expect(await reconciler.health().isEmpty)
        // Detection still works, so the user can be told it is there.
        #expect(isInstalled(await reconciler.detections()[.claudeCode]))

        await reconciler.track(.claudeCode)
        #expect(try database.usage.count() == 2)
        #expect(await reconciler.health()[.claudeCode] != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `an appended line is imported while watching, without waiting for a sweep`() async throws {
        try write(lines(["m1"]))
        let database = try database()
        let reconciler = Reconciler(ingestion: IngestionActor(database: database), adapters: [claude])
        await reconciler.reconcile()
        let watching = Task { await reconciler.run(sweepEvery: .seconds(3_600)) }
        defer { watching.cancel() }

        // The watcher starts on the loop's task, at a moment the test cannot
        // see, so keep appending until a change is noticed. The hourly sweep
        // never runs here; only the watcher can import these lines.
        var appended = 1
        while try database.usage.count() < 2, appended < 20 {
            appended += 1
            try write(lines(["m\(appended)"]), append: true)
            try await Task.sleep(for: .seconds(1))
        }
        #expect(try database.usage.count() >= 2)
    }

    @Test func `EC-D9 a vanished file's state is forgotten, and a restored copy adds nothing twice`() async throws {
        try write(lines(["m1", "m2"]))
        let database = try database()
        let actor = IngestionActor(database: database)
        _ = try await actor.sync(from: claude)
        let saved = try #require(try storedState(database))

        let aside = root.appending(path: "aside.jsonl")
        try FileManager.default.moveItem(at: transcript, to: aside)
        _ = try await actor.sync(from: claude)
        #expect(try database.sourceStates.states(provider: .claudeCode).isEmpty)

        try FileManager.default.moveItem(at: aside, to: transcript)
        let restored = try await actor.sync(from: claude)
        #expect(restored.filesRead == 1 && restored.eventsWritten == 0)
        #expect(try eventIDs(database) == ["m1", "m2"])
        #expect(try storedState(database)?.lastOffset == saved.lastOffset)
    }
}

/// An adapter whose history cannot be listed.
private func isInstalled(_ detection: ProviderDetection?) -> Bool {
    if case .installed = detection { true } else { false }
}

private struct BrokenAdapter: UsageProviderAdapter {
    struct Failure: Error {}
    let provider = ProviderKey.codex
    func detect() -> ProviderDetection { .installed(dataDirectory: URL(filePath: "/nonexistent")) }
    func sourceFiles() throws -> [URL] { throw Failure() }
    func parse(_ file: URL, from offset: Int64, state: String?) throws -> ParseOutput { ParseOutput() }
}

private actor Announcements {
    var all: [StoreFailure?] = []
    func add(_ failure: StoreFailure?) { all.append(failure) }
}
