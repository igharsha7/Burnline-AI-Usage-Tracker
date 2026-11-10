//
//  DatabaseLifecycleTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import GRDB
import Testing

/// Opening, migrating, and refusing. Each test gets its own directory.
struct DatabaseLifecycleTests {
    static let expectedTables: Set<String> = [
        "providers", "models", "model_aliases", "projects", "sessions", "pricing_versions",
        "usage_events", "source_files", "usage_rollups", "daily_rollups", "compaction", "quota_snapshots",
        "banked_resets", "source_states", "pending_repricing", "pending_quota_resets",
        "notification_events", "achievements", "parser_errors",
    ]
    static let expectedIndexes: Set<String> = [
        "idx_pricing_model_from", "idx_usage_ts",
        "idx_usage_project_ts", "idx_usage_session", "idx_quota_key_ts", "idx_notif_dedup", "idx_notif_fired",
        "idx_pricing_identity",
    ]

    @Test func `EC-D9 backup pruning keeps the newest across schema versions`() throws {
        let fixture = try StoreFixture()
        try FileManager.default.createDirectory(at: fixture.location.backupsDirectory, withIntermediateDirectories: true)
        var backups: [URL] = []
        for (index, version) in [7, 8, 9, 10].enumerated() {
            let url = DatabaseBackups.newBackupURL(in: fixture.location, version: version,
                                                  at: fixture.clock.now.adding(seconds: Int64(index)))
            try Data("backup".utf8).write(to: url)
            backups.append(url)
        }
        DatabaseBackups.prune(in: fixture.location)
        #expect(DatabaseBackups.list(in: fixture.location).map(\.lastPathComponent)
                == backups.suffix(DatabaseBackups.kept).reversed().map(\.lastPathComponent))
    }

    @Test func `EC-D9 same-second backup suffixes sort newest first`() throws {
        let fixture = try StoreFixture()
        try FileManager.default.createDirectory(at: fixture.location.backupsDirectory, withIntermediateDirectories: true)
        var backups: [URL] = []
        for _ in 0..<12 {
            let url = DatabaseBackups.newBackupURL(in: fixture.location, version: 11, at: fixture.clock.now)
            try Data("backup".utf8).write(to: url)
            backups.append(url)
        }
        DatabaseBackups.prune(in: fixture.location)
        #expect(DatabaseBackups.list(in: fixture.location).map(\.lastPathComponent)
                == backups.suffix(DatabaseBackups.kept).reversed().map(\.lastPathComponent))
    }

    @Test func `EC-R4 upgrading from eight fills savings without queuing the same recalculation twice`() throws {
        let fixture = try StoreFixture()
        do {
            let old = try fixture.open(schema: fixture.schema(through: 8))
            let model = try StoreFixture.insertModel("fixture-model", into: old)
            try old.pricing.append(modelID: model, validFrom: Timestamp(epochSeconds: 0), validUntil: nil,
                                   rates: TokenRates(input: Nanodollars(raw: 1_000_000), output: .zero),
                                   source: "test", confidence: .exact)
            try old.write { db in
                try db.execute(sql: """
                    INSERT INTO source_files (provider_id, source_type, path) VALUES (?, 'test', '/fixture');
                    INSERT INTO usage_events (provider_id, model_id, timestamp, input_tokens,
                      source_file_id, source_event_id, created_at) VALUES (?, ?, 900, 100, 1, 'old', 0);
                    CREATE TABLE recalculations (event_id INTEGER);
                    CREATE TRIGGER count_recalculations AFTER UPDATE OF cost_nanos ON usage_events
                    BEGIN INSERT INTO recalculations VALUES (NEW.id); END;
                    """, arguments: [old.providerID(.claudeCode), old.providerID(.claudeCode), model])
            }
        }
        let upgraded = try fixture.open()
        #expect(try upgraded.pricing.repricePending() == 0)
        #expect(try upgraded.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM recalculations") } == 1)
        #expect(try upgraded.usage.events(in: IngestionTests.everything).first?.cost.amount?.raw == 100)
    }

    @Test(arguments: 1..<10)
    func `EC-D3 each released schema migrates populated usage without losing facts`(version: Int) throws {
        let fixture = try StoreFixture()
        do {
            let old = try fixture.open(schema: fixture.schema(through: version))
            try old.write { db in
                let provider = old.providerID(.claudeCode)
                if version >= 7 {
                    try db.execute(sql: "INSERT INTO source_files (provider_id, source_type, path) VALUES (?, 'test', '/fixture')",
                                   arguments: [provider])
                }
                let sourceColumns = version >= 7 ? "source_file_id" : "source_type, source_file"
                let sourceValues = version >= 7 ? "1" : "'test', '/fixture'"
                try db.execute(sql: """
                    INSERT INTO usage_events (provider_id, timestamp, input_tokens, cached_input_tokens,
                      output_tokens, source_event_id, created_at, \(sourceColumns))
                    VALUES (?, 900, 100, 20, 10, 'preserved', 0, \(sourceValues))
                    """, arguments: [provider])
            }
        }
        let upgraded = try fixture.open()
        #expect(try upgraded.schemaVersion() == StoreFixture.shippedVersion)
        let event = try #require(try upgraded.usage.events(in: IngestionTests.everything).first)
        #expect(event.tokens == (try TokenCounts(input: 100, cachedInput: 20, output: 10)))
        #expect(event.source.file == "/fixture" && event.source.eventID == "preserved")
        #expect(event.cost.amount == nil)
        #expect(try upgraded.usage.totals(in: IngestionTests.everything).events == 1)
        #expect(try upgraded.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") } == "ok")
    }

    @Test func `achievements earned before version 13 count as announced and celebrated`() throws {
        let fixture = try StoreFixture()
        do {
            let old = try fixture.open(schema: fixture.schema(through: 12))
            try old.write { db in
                try db.execute(sql: """
                    INSERT INTO achievements (key, tier, value, awarded_at, created_at)
                    VALUES ('streak', '7', 7, 100, 200)
                    """)
            }
        }
        let upgraded = try fixture.open()
        #expect(try upgraded.achievements.all().count == 1)
        #expect(try upgraded.achievements.uncelebrated().isEmpty)
        let taken = try upgraded.achievements.takeUnannounced(at: Timestamp(epochSeconds: 300))
        #expect(taken.achievements.isEmpty && !taken.firstEver)
    }

    @Test func `version 14 clears monthly awards made under the old challenge, and the retired 10M rung`() throws {
        let fixture = try StoreFixture()
        do {
            let old = try fixture.open(schema: fixture.schema(through: 13))
            try old.write { db in
                try db.execute(sql: """
                    INSERT INTO achievements (key, tier, value, awarded_at, created_at) VALUES
                      ('monthly', '2026-10', 2, 100, 200), ('lifetime-tokens', '10000000', 10000000, 100, 200),
                      ('lifetime-tokens', '100000000', 100000000, 100, 200)
                    """)
            }
        }
        let upgraded = try fixture.open()
        #expect(try upgraded.achievements.all().map(\.tier) == ["100000000"])
    }

    @Test func `a fresh database is built from the shipped schema files`() throws {
        let fixture = try StoreFixture()
        let database = try fixture.open()

        let (tables, indexes, journal, foreignKeys) = try database.read { db in
            (Set(try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                """)),
             Set(try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'
                """)),
             try String.fetchOne(db, sql: "PRAGMA journal_mode"),
             try Int.fetchOne(db, sql: "PRAGMA foreign_keys"))
        }
        #expect(tables == Self.expectedTables)
        #expect(indexes == Self.expectedIndexes)
        #expect(journal == "wal")
        #expect(foreignKeys == 1)
        #expect(try database.schemaVersion() == StoreFixture.shippedVersion)
        #expect(Set(database.providerIDs.keys) == Set(ProviderKey.allCases))
    }

    @Test func `reopening an up-to-date database changes nothing and takes no backup`() throws {
        let fixture = try StoreFixture()
        _ = try fixture.open()
        let reopened = try fixture.open()
        #expect(try reopened.schemaVersion() == StoreFixture.shippedVersion)
        #expect(DatabaseBackups.list(in: fixture.location).isEmpty)
        #expect(try reopened.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM providers") } == 3)
    }

    @Test func `an existing database migrates forward with its data and a backup`() throws {
        let fixture = try StoreFixture()
        do {
            let v1 = try fixture.open()
            try v1.usage.insert([StoreFixture.event("e1")])
        }
        let v2Schema = try fixture.schema(addingMigrations: ["ALTER TABLE usage_events ADD COLUMN note TEXT;"])
        let v2 = try fixture.open(schema: v2Schema)

        #expect(try v2.schemaVersion() == StoreFixture.shippedVersion + 1)
        #expect(try v2.usage.count() == 1)
        let backup = try #require(DatabaseBackups.list(in: fixture.location).first)
        #expect(backup.lastPathComponent.hasPrefix("burnline-v\(StoreFixture.shippedVersion)-"))
        let backedUp = try DatabaseQueue(path: backup.path)
        #expect(try backedUp.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM usage_events") } == 1)
    }

    @Test func `EC-D3 a failing migration rolls back completely and keeps its backup`() throws {
        let fixture = try StoreFixture()
        do {
            let v1 = try fixture.open()
            try v1.usage.insert([StoreFixture.event("e1")])
        }
        // The first statement succeeds, the second fails: neither may survive.
        let broken = try fixture.schema(addingMigrations: ["CREATE TABLE extra (x); CREATE TABLE providers (x);"])

        let failure = storeError { _ = try fixture.open(schema: broken) }
        guard case .migrationFailed(let version, let backup, _) = failure else {
            Issue.record("expected migrationFailed, got \(String(describing: failure))")
            return
        }
        #expect(version == StoreFixture.shippedVersion)
        #expect(backup.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        let reopened = try fixture.open()
        #expect(try reopened.schemaVersion() == StoreFixture.shippedVersion)
        #expect(try reopened.usage.count() == 1)
        #expect(try reopened.read { try Bool.fetchOne($0, sql: """
            SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = 'extra')
            """) } == false)
    }

    @Test func `EC-D3 a migration whose backup cannot be taken does not run`() throws {
        let fixture = try StoreFixture()
        do {
            let v1 = try fixture.open()
            try v1.usage.insert([StoreFixture.event("e1")])
        }
        // A file where the backups folder belongs, so no backup can be written.
        try Data().write(to: fixture.location.backupsDirectory)
        let v2Schema = try fixture.schema(addingMigrations: ["ALTER TABLE usage_events ADD COLUMN note TEXT;"])

        let failure = storeError { _ = try fixture.open(schema: v2Schema) }
        guard case .migrationFailed(let version, let backup, _) = failure else {
            Issue.record("expected migrationFailed, got \(String(describing: failure))")
            return
        }
        #expect(version == StoreFixture.shippedVersion && backup == nil)

        try FileManager.default.removeItem(at: fixture.location.backupsDirectory)
        let reopened = try fixture.open()
        #expect(try reopened.schemaVersion() == StoreFixture.shippedVersion)
        #expect(try reopened.usage.count() == 1)
    }

    @Test func `EC-D6 a database from a newer build is refused untouched`() throws {
        let fixture = try StoreFixture()
        do {
            let database = try fixture.open()
            try database.write { try $0.execute(sql: "PRAGMA user_version = \(StoreFixture.shippedVersion + 1)") }
            _ = try database.pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        }
        let before = try fixture.databaseBytes()

        let failure = storeError { _ = try fixture.open() }
        guard case .newerSchema(let found, let supported) = failure else {
            Issue.record("expected newerSchema, got \(String(describing: failure))")
            return
        }
        #expect(found == StoreFixture.shippedVersion + 1 && supported == StoreFixture.shippedVersion)
        #expect(try fixture.databaseBytes() == before)
    }

    @Test func `EC-D2 a corrupt file fails closed and is never recreated empty`() throws {
        let fixture = try StoreFixture()
        let garbage = Data("this is not a database, it is a grocery list".utf8)
        try garbage.write(to: fixture.location.databaseFile)

        let failure = storeError { _ = try fixture.open() }
        guard case .corrupt = failure else {
            Issue.record("expected corrupt, got \(String(describing: failure))")
            return
        }
        #expect(try fixture.databaseBytes() == garbage)
    }

    @Test func `EC-D2 a missing restore backup leaves the current database in place`() throws {
        let fixture = try StoreFixture()
        do {
            let database = try fixture.open()
            try database.usage.insert([StoreFixture.event("kept")])
        }
        #expect(throws: StoreError.self) {
            try DatabaseBackups.restore(fixture.location.backupsDirectory.appending(path: "missing.sqlite"),
                                        to: fixture.location, clock: fixture.clock)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.location.databaseFile.path))
        #expect(try fixture.open().usage.count() == 1)
    }

    @Test func `EC-D2 restore keeps the displaced WAL database readable with its companions`() throws {
        let sourceFixture = try StoreFixture()
        let source = try sourceFixture.open()
        _ = try source.pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        try source.usage.insert([StoreFixture.event("in-wal")])
        let target = try StoreFixture()
        // A quiescent copy of a crashed process's files, before its WAL is checkpointed.
        for file in [sourceFixture.location.databaseFile] + sourceFixture.location.companionFiles {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.copyItem(at: file, to: target.location.directory.appending(path: file.lastPathComponent))
            }
        }
        let backup = sourceFixture.location.directory.appending(path: "backup.sqlite")
        try source.pool.backup(to: DatabaseQueue(path: backup.path))
        let displaced = try #require(try DatabaseBackups.restore(backup, to: target.location, clock: target.clock))
        let previous = try DatabaseQueue(path: displaced.path)
        #expect(try previous.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM usage_events") } == 1)
        #expect(try target.open().usage.count() == 1)
    }

    @Test func `EC-D2 repeated restores at one timestamp preserve every displaced database`() throws {
        let fixture = try StoreFixture()
        let backup = fixture.location.directory.appending(path: "restore-source.sqlite")
        do {
            let database = try fixture.open()
            try database.usage.insert([StoreFixture.event("first")])
            try database.pool.backup(to: DatabaseQueue(path: backup.path))
        }
        let first = try #require(try DatabaseBackups.restore(backup, to: fixture.location, clock: fixture.clock))
        do {
            let database = try fixture.open()
            try database.usage.insert([StoreFixture.event("second")])
        }
        let second = try #require(try DatabaseBackups.restore(backup, to: fixture.location, clock: fixture.clock))
        #expect(first != second)
        let firstDatabase = try DatabaseQueue(path: first.path)
        let secondDatabase = try DatabaseQueue(path: second.path)
        #expect(try firstDatabase.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM usage_events") } == 1)
        #expect(try secondDatabase.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM usage_events") } == 2)
        #expect(try fixture.open().usage.count() == 1)
    }

    @Test func `EC-D2 restoring a backup replaces a corrupt file and keeps it aside`() throws {
        let fixture = try StoreFixture()
        do {
            let v1 = try fixture.open()
            try v1.usage.insert([StoreFixture.event("e1")])
        }
        // Upgrading takes the backup that is restored below.
        _ = try fixture.open(schema: fixture.schema(addingMigrations: ["SELECT 1;"]))
        let backup = try #require(DatabaseBackups.list(in: fixture.location).first)
        let garbage = Data("corrupted".utf8)
        try garbage.write(to: fixture.location.databaseFile)

        let setAside = try DatabaseBackups.restore(backup, to: fixture.location, clock: fixture.clock)

        #expect(try setAside.map { try Data(contentsOf: $0) } == garbage)
        let restored = try fixture.open()
        #expect(try restored.usage.count() == 1)
        #expect(try restored.schemaVersion() == StoreFixture.shippedVersion)
    }

    @Test func `EC-D4 a second writer is refused while readers are allowed`() throws {
        let fixture = try StoreFixture()
        var first: BurnlineDatabase? = try fixture.open()
        #expect(first != nil)

        let failure = storeError { _ = try fixture.open() }
        guard case .anotherWriterIsRunning = failure else {
            Issue.record("expected anotherWriterIsRunning, got \(String(describing: failure))")
            return
        }
        let reader = try fixture.open(mode: .readOnly)
        #expect(try reader.schemaVersion() == StoreFixture.shippedVersion)

        first = nil
        #expect(try fixture.open().schemaVersion() == StoreFixture.shippedVersion)
    }

    @Test func `a read-only open refuses a database that needs migrating`() throws {
        let fixture = try StoreFixture()
        _ = try fixture.open()
        let newer = try fixture.schema(addingMigrations: ["SELECT 1;"])

        let failure = storeError { _ = try fixture.open(schema: newer, mode: .readOnly) }
        guard case .schemaMismatch(let found, let expected) = failure else {
            Issue.record("expected schemaMismatch, got \(String(describing: failure))")
            return
        }
        #expect(found == StoreFixture.shippedVersion && expected == StoreFixture.shippedVersion + 1)
    }

    @Test func `EC-D1 a full disk rolls back the whole write and leaves the file intact`() throws {
        let fixture = try StoreFixture()
        let database = try fixture.open()
        try database.usage.insert([StoreFixture.event("kept")])

        // SQLite's page limit fails writes with the same error a full disk does.
        try database.pool.writeWithoutTransaction { db in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            try db.execute(sql: "PRAGMA max_page_count = \(pages)")
        }
        let batch = try (0..<5_000).map { try StoreFixture.event("bulk-\($0)") }

        let failure = storeError { try database.usage.insert(batch) }
        guard case .diskFull = failure else {
            Issue.record("expected diskFull, got \(String(describing: failure))")
            return
        }
        #expect(try database.usage.count() == 1)
        #expect(try database.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") } == "ok")
    }

    @Test(arguments: [
        ["001_a.sql", "003_c.sql"],
        ["001_a.sql", "001_b.sql"],
        ["002_b.sql"],
        ["README.md"],
    ])
    func `misnumbered schema files are rejected`(names: [String]) throws {
        let directory = TestDirectory.make("schema")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names { try "SELECT 1;".write(to: directory.appending(path: name), atomically: true, encoding: .utf8) }
        #expect(throws: StoreError.self) { try Schema(directory: directory) }
    }
}
