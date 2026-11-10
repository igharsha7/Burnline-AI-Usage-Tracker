//
//  DataControlTests.swift
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

/// The user's control over Burnline's copy of their history: deleting part
/// or all of it, backing it up and restoring it, checking and repairing it,
/// and exporting it. Every figure that remains stays exact.
struct DataControlTests {
    @Test func `EC-R3 exports preserve negative cache savings exactly`() throws {
        let database = try StoreFixture().open()
        try database.usage.insert([StoreFixture.event("write")])
        for amount: Int64 in [-250_000_000, -1_250_000_000, .min] {
            try database.write { db in
                try db.execute(sql: "UPDATE usage_events SET cache_savings_nanos = ?", arguments: [amount])
            }
            for dataset: ExportDataset in [.events, .totals] {
                try database.exports.rows(dataset) { values in
                    let index = dataset == .events ? 12 : 13
                    guard case .text(let text) = values[index] else {
                        Issue.record("missing savings"); return
                    }
                    #expect(Decimal(string: text) == Nanodollars(raw: amount).decimalDollars)
                }
            }
        }
    }

    static let everything = IngestionTests.everything

    /// A priced history with its older half compacted, so every operation
    /// meets both events and compacted totals.
    static func history() throws -> (StoreFixture, BurnlineDatabase, SyntheticHistory.Shape) {
        let (fixture, database, shape) = try CompactionTests.history(events: 6_000)
        try database.compact(before: shape.end.adding(seconds: -Int64(shape.years) * 86_400 * 183))
        return (fixture, database, shape)
    }

    static func projectTotals(_ database: BurnlineDatabase) throws -> [GroupKey: UsageTotals] {
        try database.aggregation.series([everything], grouping: .project, filters: .none, from: .rollups)[0]
    }

    @Test func `deleting a provider's history leaves the others untouched`() throws {
        let (_, database, shape) = try Self.history()
        let claude = try database.usage.totals(in: Self.everything, provider: .claudeCode)
        let claudeDays = try CompactionTests.dailyTotals(database, shape)
        #expect(try database.usage.totals(in: Self.everything, provider: .codex).events > 0)

        let report = try database.delete(.provider(.codex))
        #expect(report.events > 0 && report.sessions > 0)
        #expect(try database.usage.totals(in: Self.everything, provider: .codex) == .zero)
        #expect(try database.usage.totals(in: Self.everything, provider: .claudeCode) == claude)
        #expect(try database.usage.totals(in: Self.everything) == claude)
        // Every day now holds exactly its Claude Code usage.
        #expect(try CompactionTests.dailyTotals(database, shape).map(\.events).reduce(0, +) == claude.events)
        #expect(claudeDays.count == (try CompactionTests.dailyTotals(database, shape)).count)
        #expect(try database.check().isHealthy)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sessions WHERE provider_id = ?",
                                                    arguments: [database.providerID(.codex)]) } == 0)
    }

    @Test func `deleting a project removes it and what was merged into it, and nothing else`() throws {
        let (_, database, _) = try Self.history()
        let before = try Self.projectTotals(database)
        let (target, merged) = try database.read { db in
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM projects ORDER BY id LIMIT 2")
            return (ids[0], ids[1])
        }
        try database.projects.merge(merged, into: target)
        let total = try database.usage.totals(in: Self.everything)
        let gone = try before[.project(target)]!.adding(before[.project(merged)]!)

        try database.delete(.project(target))
        let after = try Self.projectTotals(database)
        #expect(after[.project(target)] == nil && after[.project(merged)] == nil)
        #expect(try database.usage.totals(in: Self.everything).events == total.events - gone.events)
        for (key, totals) in before where key != .project(target) && key != .project(merged) {
            #expect(after[key] == totals)
        }
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM projects WHERE id IN (?, ?)",
                                                    arguments: [target, merged]) } == 0)
        #expect(try database.check().isHealthy)
    }

    @Test func `deleting a range spanning compacted history empties it and keeps the rest exact`() throws {
        let (_, database, shape) = try Self.history()
        let boundary = try database.compactedBefore()
        let window = TimeWindow(start: boundary.adding(seconds: -40 * 86_400), end: boundary.adding(seconds: 40 * 86_400))
        let earlier = TimeWindow(start: Timestamp(epochSeconds: 0), end: window.start)
        let later = TimeWindow(start: window.end, end: shape.end.adding(seconds: 86_400))
        let (beforeEarlier, beforeLater) = (try database.usage.totals(in: earlier), try database.usage.totals(in: later))
        #expect(try database.usage.totals(in: window).events > 0)

        try database.delete(.range(window))
        #expect(try database.usage.totals(in: window) == .zero)
        #expect(try database.usage.totals(in: earlier) == beforeEarlier)
        #expect(try database.usage.totals(in: later) == beforeLater)
        #expect(try database.check().isHealthy)
    }

    @Test func `deleting everything leaves an empty store that can import again`() throws {
        let (_, database, _) = try Self.history()
        try database.delete(.everything)
        #expect(try database.usage.totals(in: Self.everything) == .zero)
        #expect(try database.compactedBefore() == Timestamp(epochSeconds: 0))
        let leftover = try database.read { db in
            try ["sessions", "projects", "usage_rollups", "daily_rollups", "achievements"].map {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)") ?? -1
            }
        }
        #expect(leftover == [0, 0, 0, 0, 0])
        // Pricing and models are reference data, not history.
        #expect(try database.pricing.count() > 0)
        try database.ingest([IngestionTests.record("again", at: 1_000)], issues: [], provider: .claudeCode)
        #expect(try database.usage.totals(in: Self.everything).events == 1)
    }

    @Test func `a backup restores into a clean profile and reproduces every total`() throws {
        let (fixture, database, shape) = try Self.history()
        let file = fixture.location.directory.appending(path: "backup.sqlite")
        try database.backup(to: file)
        let lifetime = try database.usage.totals(in: Self.everything)
        let days = try CompactionTests.dailyTotals(database, shape)
        let projects = try Self.projectTotals(database)
        let events = try database.usage.count()

        let clean = try StoreFixture()
        let inspection = try DatabaseBackups.stageRestore(file, in: clean.location, schema: StoreFixture.shippedSchema())
        #expect(inspection.events == events && inspection.schemaVersion == StoreFixture.shippedVersion)
        #expect(DatabaseBackups.hasStagedRestore(in: clean.location))
        let restored = try clean.open()
        #expect(!DatabaseBackups.hasStagedRestore(in: clean.location))
        #expect(try restored.usage.totals(in: Self.everything) == lifetime)
        #expect(try CompactionTests.dailyTotals(restored, shape) == days)
        #expect(try Self.projectTotals(restored) == projects)
        #expect(try restored.compactedBefore() == database.compactedBefore())
        #expect(try restored.check().isHealthy)
    }

    @Test func `restoring over a database moves the old one aside, never deletes it`() throws {
        let source = try StoreFixture()
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([IngestionTests.record("a", at: 1_000)], issues: [], provider: .claudeCode)
        let file = source.location.directory.appending(path: "backup.sqlite")
        try database.backup(to: file)

        let target = try StoreFixture()
        do {
            let current = try target.open()
            try current.ingest([IngestionTests.record("b", at: 1_000), IngestionTests.record("c", at: 2_000)],
                               issues: [], provider: .codex)
        }
        _ = try DatabaseBackups.stageRestore(file, in: target.location, schema: StoreFixture.shippedSchema())
        let restored = try target.open()
        #expect(try restored.usage.count() == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: target.location.directory.path)
        #expect(names.contains { $0.hasPrefix("burnline.sqlite.replaced-") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
    }

    @Test func `EC-D2 a file that is not a sound backup is refused and nothing is staged`() throws {
        let fixture = try StoreFixture()
        let junk = fixture.location.directory.appending(path: "junk.sqlite")
        try FileManager.default.createDirectory(at: fixture.location.directory, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: junk)
        #expect(storeError { _ = try DatabaseBackups.stageRestore(junk, in: fixture.location,
                                                                  schema: StoreFixture.shippedSchema()) } != nil)
        #expect(!DatabaseBackups.hasStagedRestore(in: fixture.location))
    }

    @Test func `a sound SQLite database that is not Burnline's is refused, and nothing is staged`() throws {
        let fixture = try StoreFixture()
        try FileManager.default.createDirectory(at: fixture.location.directory, withIntermediateDirectories: true)
        let other = fixture.location.directory.appending(path: "other.sqlite")
        try DatabaseQueue(path: other.path).write { try $0.execute(sql: "CREATE TABLE notes (body TEXT)") }

        let failure = storeError { _ = try DatabaseBackups.stageRestore(other, in: fixture.location,
                                                                        schema: StoreFixture.shippedSchema()) }
        guard case .sqlite("this is not a Burnline backup") = failure else {
            Issue.record("expected the not-a-backup refusal, got \(String(describing: failure))")
            return
        }
        #expect(!DatabaseBackups.hasStagedRestore(in: fixture.location))
    }

    @Test func `EC-D6 a backup from a newer Burnline is refused`() throws {
        let newer = try StoreFixture()
        let schema = try newer.schema(addingMigrations: ["CREATE TABLE later (id INTEGER);"])
        let database = try newer.open(schema: schema)
        let file = newer.location.directory.appending(path: "newer.sqlite")
        try database.backup(to: file)
        let target = try StoreFixture()
        guard case .newerSchema? = storeError({
            _ = try DatabaseBackups.stageRestore(file, in: target.location, schema: StoreFixture.shippedSchema())
        }) else {
            Issue.record("a newer backup must be refused")
            return
        }
        #expect(!DatabaseBackups.hasStagedRestore(in: target.location))
    }

    @Test func `the check finds totals that drifted, and rebuilding fixes them`() throws {
        let (_, database, _) = try Self.history()
        #expect(try database.check().isHealthy)
        try database.write { db in
            try db.execute(sql: """
                UPDATE usage_rollups SET output_tokens = output_tokens + 1
                WHERE bucket = (SELECT max(bucket) FROM usage_rollups)
                """)
        }
        let problems = try database.check().problems
        #expect(problems.contains { $0.contains("quarter-hour totals disagree with their events") })
        try database.rebuildRollups()
        #expect(try database.check().isHealthy)
    }

    @Test func `EC-M3 re-applying model names moves events to an alias learned later`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([IngestionTests.record("x", model: "claude-mystery-9", at: 1_000)], issues: [],
                            provider: .claudeCode)
        let opus = try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM models WHERE canonical_name = 'claude-opus-5'")!
        }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO model_aliases (provider_id, raw_model_name, model_id) VALUES (?, 'claude-mystery-9', ?)
                """, arguments: [database.providerID(.claudeCode), opus])
        }
        #expect(try database.remapModels() == 1)
        #expect(try database.read { try Int64.fetchOne($0, sql: "SELECT model_id FROM usage_events") } == opus)
        #expect(try database.remapModels() == 0)
        #expect(try database.check().isHealthy)
    }

    @Test func `exports stream every event and every total, money exact`() throws {
        let (_, database, _) = try Self.history()
        var costs: [String] = []
        let events = try database.exports.rows(.events) { values in
            #expect(values.count == ExportRepository.columns(.events).count)
            if case .text(let cost) = values[11] { costs.append(cost) }
        }
        #expect(events == (try database.usage.count()))
        #expect(costs.allSatisfy { $0.wholeMatch(of: /[0-9]+\.[0-9]{9}/) != nil })
        let rollups = try database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM usage_rollups") ?? 0 }
        var tokens: Int64 = 0
        #expect(try database.exports.rows(.totals) { values in
            if case .integer(let output) = values[9] { tokens += output }
        } == rollups)
        #expect(tokens == (try database.usage.totals(in: Self.everything)).tokens.output)
    }
}
