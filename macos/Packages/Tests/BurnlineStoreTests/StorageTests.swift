//
//  StorageTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineStore
import Foundation
import GRDB
import Testing

/// A lifetime database staying small and bounded: the source-file migration,
/// deleting history, and the files that grow beside the database.
struct StorageTests {
    static let everything = IngestionTests.everything

    /// Totals per UTC day and overall, the figures a migration must not move.
    static func totals(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT timestamp / 86400 || ':' || count(*) || ':' || sum(input_tokens) || ':' || sum(output_tokens)
                   || ':' || sum(cached_input_tokens) || ':' || coalesce(sum(cost_nanos), 0)
            FROM usage_events GROUP BY timestamp / 86400
            UNION ALL
            SELECT 'all:' || count(*) || ':' || sum(output_tokens) FROM usage_events
            """)
    }

    @Test func `EC-D7 moving source files out of events keeps every event, total and source`() throws {
        let fixture = try StoreFixture()
        let before: [String]
        do {
            let old = try fixture.open(schema: fixture.schema(through: 6))
            try old.write { db in
                for index in 0..<300 {
                    let file: String? = index % 7 == 0 ? nil : "/Users/someone/.claude/projects/p/\(index % 4).jsonl"
                    try db.execute(sql: """
                        INSERT INTO usage_events (provider_id, timestamp, input_tokens, output_tokens,
                          cached_input_tokens, cost_nanos, source_type, source_file, source_event_id, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                        """, arguments: [index % 2 + 1, 1_790_000_000 + index * 3_600, index, index * 2, index * 3,
                                         index % 3 == 0 ? nil : index * 1_000, index % 2 == 0 ? "a_jsonl" : "b_jsonl",
                                         file, "event-\(index)"])
                }
                // A file written before incremental vacuum existed.
                try db.execute(sql: "PRAGMA auto_vacuum = NONE")
            }
            try old.pool.writeWithoutTransaction { try $0.execute(sql: "VACUUM") }
            before = try old.read(Self.totals)
        }

        let migrated = try fixture.open()
        #expect(try migrated.schemaVersion() == StoreFixture.shippedVersion)
        #expect(try migrated.read(Self.totals) == before)
        let events = try migrated.usage.events(in: Self.everything)
        #expect(events.count == 300)
        for event in events {
            let index = Int(event.source.eventID.dropFirst("event-".count))!
            #expect(event.source.file == (index % 7 == 0 ? nil : "/Users/someone/.claude/projects/p/\(index % 4).jsonl"))
            #expect(event.source.sourceType == (index % 2 == 0 ? "a_jsonl" : "b_jsonl"))
        }
        let (files, vacuum, free) = try migrated.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM source_files"),
             try Int.fetchOne(db, sql: "PRAGMA auto_vacuum"),
             try Int.fetchOne(db, sql: "PRAGMA freelist_count"))
        }
        // Four paths, each written by events of one type, and no path under each type.
        #expect(files == 6)
        #expect(vacuum == Vacuum.incremental && free == 0)
        // The rollups an upgraded database starts with are its events' sums.
        let rollups = try Self.rollups(migrated)
        #expect(rollups.kept == rollups.expected && rollups.kept.count > 1)
    }

    @Test func `a new database returns freed space on request`() throws {
        let database = try StoreFixture().open()
        #expect(try database.read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") } == Vacuum.incremental)
    }

    @Test func `deleting history removes only events before the cutoff`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest((0..<25).map { try IngestionTests.record("e\($0)", at: Int64($0) * 1_000) },
                            issues: [], provider: .claudeCode)
        #expect(try database.usage.deleteEvents(before: Timestamp(epochSeconds: 10_000)) == 10)
        #expect(try database.usage.events(in: Self.everything).map(\.timestamp.epochSeconds).min() == 10_000)
    }

    @Test func `EC-D8 deleting history returns its space while ingestion keeps writing`() async throws {
        let fixture = try StoreFixture()
        let database = try fixture.open()
        let shape = SyntheticHistory.Shape(events: 40_000, years: 2, projects: 20)
        for batch in SyntheticHistory(shape: shape).batches() {
            try database.ingest(batch.records, issues: [], provider: batch.provider)
        }
        let pages = { try database.read { try Int.fetchOne($0, sql: "PRAGMA page_count") ?? 0 } }
        let before = try pages()

        // The older half goes while a later history keeps arriving.
        let cutoff = Timestamp(epochSeconds: shape.end.epochSeconds - 365 * 86_400)
        let later = SyntheticHistory(shape: .init(events: 2_000, years: 1, projects: 20, seed: 7))
        async let deleted = Task.detached {
            let count = try database.usage.deleteEvents(before: cutoff)
            try database.reclaimSpace()
            return count
        }.value
        var slowest = Duration.zero
        for batch in later.batches() {
            let started = ContinuousClock.now
            try database.ingest(batch.records, issues: [], provider: batch.provider)
            slowest = max(slowest, ContinuousClock.now - started)
        }
        let removed = try await deleted
        try database.reclaimSpace()

        let after = try pages()
        let share = Double(removed) / Double(shape.events)
        // What the concurrent writes could have added, at most.
        let added = Double(2_000 * 300) / 4_096
        #expect(Double(before - after) >= 0.9 * share * Double(before) - added)
        #expect(slowest < .seconds(1))
    }

    @Test func `EC-D9 backups are kept to the newest few`() throws {
        let fixture = try StoreFixture()
        var migrations: [String] = []
        for index in 0..<(DatabaseBackups.kept + 3) {
            migrations.append("CREATE TABLE extra_\(index) (id INTEGER PRIMARY KEY);")
            _ = try fixture.open(schema: fixture.schema(addingMigrations: migrations))
        }
        #expect(DatabaseBackups.list(in: fixture.location).count == DatabaseBackups.kept)
    }

    @Test func `EC-D9 parser errors are pruned once they are old`() throws {
        let fixture = try StoreFixture()
        let database = try fixture.open()
        let issue = ParseIssue(file: "/a.jsonl", line: 3, reason: "unreadable JSON")
        try database.ingest([], issues: [issue], provider: .codex)
        fixture.clock.advance(seconds: BurnlineDatabase.parserErrorRetention - 1)
        #expect(try database.maintain().parserErrorsRemoved == 0)
        fixture.clock.advance(seconds: 2)
        #expect(try database.maintain().parserErrorsRemoved == 1)
    }

    @Test func `EC-D9 the WAL stays within its limit across a year of syncs`() throws {
        let fixture = try StoreFixture()
        let database = try fixture.open()
        let wal = fixture.location.directory.appending(path: "burnline.sqlite-wal")
        var largest = 0
        let year = SyntheticHistory(shape: .init(events: 36_500, years: 1, projects: 10, meanSessionEvents: 100))
        for (day, batch) in year.batches().enumerated() {
            try database.ingest(batch.records, issues: [], provider: batch.provider)
            if day % 7 == 0 { try database.maintain() }
            largest = max(largest, (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0)
        }
        #expect(largest <= BurnlineDatabase.walSizeLimit)
    }

    /// The rollups of time not compacted and the daily tier, and what a fresh
    /// grouping of the events and of the rollups says they should be.
    static func rollups(_ database: BurnlineDatabase) throws -> (kept: [String], expected: [String]) {
        try database.read { db in
            let kept = try String.fetchAll(db, sql: """
                SELECT bucket || ':' || provider_id || ':' || model_id || ':' || project_id || ':' || events || ':'
                       || input_tokens || ':' || cached_input_tokens || ':' || cache_write_tokens || ':'
                       || cache_write_1h_tokens || ':' || output_tokens || ':' || reasoning_tokens || ':'
                       || cost_nanos || ':' || unpriced_events || ':' || cache_savings_nanos || ':'
                       || cache_savings_tokens
                FROM usage_rollups WHERE bucket * 900 >= (SELECT compacted_before FROM compaction) ORDER BY 1
                """)
            let expected = try String.fetchAll(db, sql: """
                SELECT c0 || ':' || c1 || ':' || c2 || ':' || c3 || ':' || c4 || ':' || c5 || ':' || c6 || ':' || c7
                       || ':' || c8 || ':' || c9 || ':' || c10 || ':' || c11 || ':' || c12 || ':' || c13 || ':' || c14
                FROM (SELECT timestamp / 900 AS c0, provider_id AS c1, coalesce(model_id, 0) AS c2,
                             coalesce(project_id, 0) AS c3, count(*) AS c4, sum(input_tokens) AS c5,
                             sum(cached_input_tokens) AS c6, sum(cache_write_tokens) AS c7,
                             sum(cache_write_1h_tokens) AS c8, sum(output_tokens) AS c9, sum(reasoning_tokens) AS c10,
                             coalesce(sum(cost_nanos), 0) AS c11, sum(cost_nanos IS NULL) AS c12,
                             coalesce(sum(cache_savings_nanos), 0) AS c13,
                             coalesce(sum(CASE WHEN cache_savings_nanos IS NULL THEN 0
                                               ELSE cached_input_tokens + cache_write_tokens END), 0) AS c14
                      FROM usage_events GROUP BY 1, 2, 3, 4)
                ORDER BY 1
                """)
            // The daily tier, compacted days included, against the rollups.
            let sums = "events, input_tokens, cached_input_tokens, cache_write_tokens, cache_write_1h_tokens, "
                + "output_tokens, reasoning_tokens, cost_nanos, unpriced_events, cache_savings_nanos, cache_savings_tokens"
            let row = (["day", "provider_id", "model_id", "project_id"] + sums.components(separatedBy: ", ")
                       + ["last_bucket"]).joined(separator: " || ':' || ")
            let daily = try String.fetchAll(db, sql: "SELECT 'day ' || \(row) FROM daily_rollups ORDER BY 1")
            let grouped = try String.fetchAll(db, sql: """
                SELECT 'day ' || \(row) FROM (
                  SELECT bucket / 96 AS day, provider_id, model_id, project_id,
                         \(sums.components(separatedBy: ", ").map { "sum(\($0)) AS \($0)" }.joined(separator: ", ")),
                         max(bucket) AS last_bucket
                  FROM usage_rollups GROUP BY 1, 2, 3, 4)
                ORDER BY 1
                """)
            return (kept + daily, expected + grouped)
        }
    }

    @Test func `rollups follow every insert, replacement, price change and deletion exactly`() throws {
        let database = try IngestionTests.syncedDatabase()
        // Several events per bucket, some without a model, across bucket edges.
        var records = try (0..<60).map { index in
            try IngestionTests.record("e\(index)", model: index % 5 == 0 ? nil : "claude-opus-5",
                                      at: Int64(index) * 200, output: Int64(index))
        }
        try database.ingest(records, issues: [], provider: .claudeCode)
        // A more complete snapshot of an event replaces it, in a new bucket.
        records = [try IngestionTests.record("e3", at: 50_000, output: 1_000)]
        try database.ingest(records, issues: [], provider: .claudeCode)
        #expect(try Self.rollups(database).kept == Self.rollups(database).expected)

        let windows = try database.pricing.apply(PricingStoreTests.manifest([
            ("claude-opus-5", "1970-01-01T00:00:00Z", "20")]))
        #expect(try database.pricing.reprice(windows) > 0)
        #expect(try Self.rollups(database).kept == Self.rollups(database).expected)

        try database.usage.deleteEvents(before: Timestamp(epochSeconds: 5_000))
        let (kept, expected) = try Self.rollups(database)
        #expect(kept == expected && !kept.isEmpty)

        try database.write { try $0.execute(sql: "UPDATE usage_rollups SET events = 99") }
        try database.rebuildRollups()
        #expect(try Self.rollups(database).kept == Self.rollups(database).expected)
    }
}
