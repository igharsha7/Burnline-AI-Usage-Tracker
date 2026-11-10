//
//  CompactionTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineStore
import Foundation
import GRDB
import Testing

/// History older than the detail window, compacted into its rollups: smaller,
/// and every lifetime and long-range figure unchanged.
struct CompactionTests {
    @Test func `EC-D10 alias repair leaves interrupted compaction history frozen`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([IngestionTests.record("old", model: "mystery", at: 900),
                             IngestionTests.record("recent", model: "mystery", at: 2700)],
                            issues: [], provider: .claudeCode)
        let oldWindow = TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: 1800))
        let frozen = try database.aggregation.series([oldWindow], grouping: .model, filters: .none, from: .rollups)
        try database.write { db in
            try db.execute(sql: "UPDATE compaction SET compacted_before = 1800")
            try db.execute(sql: """
                INSERT INTO model_aliases (provider_id, raw_model_name, model_id)
                SELECT provider_id, 'mystery', id FROM models WHERE canonical_name = 'claude-opus-5'
                """)
        }
        #expect(try database.remapModels() == 1)
        #expect(try database.aggregation.series([oldWindow], grouping: .model, filters: .none, from: .rollups) == frozen)
        try database.compact(before: oldWindow.end)
        #expect(try database.aggregation.series([oldWindow], grouping: .model, filters: .none, from: .rollups) == frozen)
        #expect(try database.check().isHealthy)
    }

    static let everything = IngestionTests.everything
    /// India's offset, which only 15-minute buckets divide exactly.
    static let offset: Int64 = 19_800

    /// A priced, two-year synthetic history.
    static func history(events: Int = 20_000) throws -> (StoreFixture, BurnlineDatabase, SyntheticHistory.Shape) {
        let fixture = try StoreFixture()
        let database = try fixture.open()
        try database.models.sync(ModelAliasManifest.load(from: IngestionTests.manifestURL))
        try database.pricing.apply(PricingManifest.load(from: PricingStoreTests.shippedURL))
        let shape = SyntheticHistory.Shape(events: events, years: 2, projects: 20)
        for batch in SyntheticHistory(shape: shape).batches() {
            try database.ingest(batch.records, issues: [], provider: batch.provider)
        }
        return (fixture, database, shape)
    }

    /// Totals for every local day in India across the history.
    static func dailyTotals(_ database: BurnlineDatabase, _ shape: SyntheticHistory.Shape) throws -> [UsageTotals] {
        let lastDay = (shape.end.epochSeconds + offset) / 86_400
        return try ((lastDay - Int64(shape.years) * 366)...lastDay).map { day in
            let start = day * 86_400 - offset
            return try database.usage.totals(in: TimeWindow(start: Timestamp(epochSeconds: start),
                                                            end: Timestamp(epochSeconds: start + 86_400)))
        }
    }

    @Test func `EC-D10 re-pricing leaves interrupted compaction history frozen`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([IngestionTests.record("old", at: 900), IngestionTests.record("recent", at: 2700)],
                            issues: [], provider: .claudeCode)
        let oldWindow = TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: 1800))
        let frozen = try database.usage.totals(in: oldWindow)
        // A crash just after advancing the boundary leaves old events pending deletion.
        try database.write { try $0.execute(sql: "UPDATE compaction SET compacted_before = 1800") }
        let affected = try database.pricing.apply(PricingStoreTests.manifest([
            ("claude-opus-5", "1970-01-01T00:00:00Z", "20")]))
        #expect(try database.pricing.reprice(affected) == 1)
        #expect(try database.usage.totals(in: oldWindow) == frozen)
        try database.compact(before: Timestamp(epochSeconds: 1800))
        #expect(try database.usage.totals(in: oldWindow) == frozen)
    }

    @Test func `EC-D10 compacting keeps every lifetime and daily total, cache savings included`() throws {
        let (_, database, shape) = try Self.history()
        let lifetime = try database.usage.totals(in: Self.everything)
        let days = try Self.dailyTotals(database, shape)
        let pages = { try database.read { try Int.fetchOne($0, sql: "PRAGMA page_count") ?? 0 } }
        let before = try pages()
        #expect(lifetime.events == 20_000 && lifetime.cacheSavings.saved.raw > 0)
        #expect(lifetime.cacheSavings.coverage == 1)

        let cutoff = Timestamp(epochSeconds: shape.end.epochSeconds - 180 * 86_400)
        let removed = try database.compact(before: cutoff)
        #expect(removed > 0 && removed < 20_000)
        #expect(try database.usage.count() == 20_000 - removed)
        #expect(try database.usage.totals(in: Self.everything) == lifetime)
        #expect(try Self.dailyTotals(database, shape) == days)
        #expect(try pages() < before)
    }

    @Test func `a large compaction repacks the file, a small one does not`() throws {
        let (_, database, shape) = try Self.history(events: 10_000)
        let freePages = { try database.read { try Int.fetchOne($0, sql: "PRAGMA freelist_count") ?? 0 } }
        let pages = { try database.read { try Int.fetchOne($0, sql: "PRAGMA page_count") ?? 0 } }
        // A day's worth: incremental reclaim only.
        let oneDay = try database.compact(before: Timestamp(epochSeconds: shape.end.epochSeconds - 700 * 86_400))
        #expect(oneDay > 0 && Double(oneDay) < BurnlineDatabase.vacuumShare * 10_000)
        let beforeLarge = try pages()

        let removed = try database.compact(before: Timestamp(epochSeconds: shape.end.epochSeconds - 180 * 86_400))
        #expect(Double(removed) >= BurnlineDatabase.vacuumShare * Double(10_000 - oneDay))
        let packed = try pages()
        #expect(packed < beforeLarge)
        #expect(try freePages() == 0)
        // Already packed: another rewrite finds nothing to recover.
        try database.vacuum()
        #expect(try pages() == packed)
        #expect(try database.read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") } == Vacuum.incremental)
    }

    @Test func `the cached savings stored per event are the pricer's`() throws {
        let (_, database, _) = try Self.history(events: 2_000)
        var expected = CacheSavings()
        for event in try database.usage.events(in: Self.everything) {
            guard case .priced(_, let versionID, _) = event.cost else { continue }
            let rates = try database.read { try PricingRepository.rates(ofVersion: versionID, in: $0) }
            try expected.add(event.tokens, rates: rates)
        }
        #expect(try database.usage.cacheSavings(in: Self.everything) == expected)
    }

    @Test func `EC-D11 compacted history is never imported twice`() throws {
        let database = try IngestionTests.syncedDatabase()
        let records = try (0..<10).map { try IngestionTests.record("e\($0)", at: Int64($0) * 1_000) }
        try database.ingest(records, issues: [], provider: .claudeCode)
        let lifetime = try database.usage.totals(in: Self.everything)

        try database.compact(before: Timestamp(epochSeconds: 5_400))
        // The same transcript read again, as after a lost source state.
        let again = try database.ingest(records, issues: [], provider: .claudeCode)
        #expect(again.eventsWritten == 0)
        #expect(try database.usage.totals(in: Self.everything) == lifetime)
        #expect(try database.usage.count() == 4)
    }

    @Test func `EC-D7 compacting a store with nothing older leaves the boundary, and the first import keeps it all`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.compact(before: Timestamp(epochSeconds: 90_000))
        #expect(try database.compactedBefore() == Timestamp(epochSeconds: 0))

        let records = try (0..<10).map { try IngestionTests.record("e\($0)", at: Int64($0) * 10_000) }
        #expect(try database.ingest(records, issues: [], provider: .claudeCode).eventsWritten == 10)
        let lifetime = try database.usage.totals(in: Self.everything)
        #expect(lifetime.events == 10)

        // The next pass compacts what the import brought in, totals unchanged.
        #expect(try database.compact(before: Timestamp(epochSeconds: 90_000)) == 9)
        #expect(try database.usage.totals(in: Self.everything) == lifetime)
        #expect(try database.check().isHealthy)
    }

    @Test func `EC-D11 the boundary stops at the newest compacted event, and later history still imports once`() throws {
        let database = try IngestionTests.syncedDatabase()
        let old = try (0..<3).map { try IngestionTests.record("old\($0)", at: Int64($0) * 1_000) }
        try database.ingest(old, issues: [], provider: .claudeCode)
        try database.compact(before: Timestamp(epochSeconds: 90_000))
        // The newest event before the cutoff is at 2,000, in the bucket ending 2,700.
        #expect(try database.compactedBefore() == Timestamp(epochSeconds: 2_700))

        // History in the gap was never stored, so it imports; the compacted part does not again.
        let gap = try IngestionTests.record("gap", at: 50_000)
        #expect(try database.ingest(old + [gap], issues: [], provider: .claudeCode).eventsWritten == 1)
        #expect(try database.usage.totals(in: Self.everything).events == 4)
        try database.compact(before: Timestamp(epochSeconds: 90_000))
        #expect(try database.compactedBefore() == Timestamp(epochSeconds: 50_400))
        #expect(try database.ingest(old + [gap], issues: [], provider: .claudeCode).eventsWritten == 0)
        #expect(try database.usage.totals(in: Self.everything).events == 4)
        #expect(try database.usage.count() == 0)
    }

    @Test func `EC-D7 a provider tracked after another's compaction keeps all its history, once`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([try IngestionTests.record("claude-old", at: 1_000),
                             try IngestionTests.record("claude-new", at: 80_000)], issues: [], provider: .claudeCode)
        try database.compact(before: Timestamp(epochSeconds: 50_000))
        #expect(try database.compactedBefore() == Timestamp(epochSeconds: 1_800))

        // Codex arrives later with history older than Claude Code's boundary.
        let codex = try (0..<3).map { index in
            IncomingUsage(sourceEventID: "codex\(index)", sessionSourceID: "c1", project: nil, rawModel: nil,
                          timestamp: Timestamp(epochSeconds: Int64(index) * 600), tokens: try TokenCounts(input: 1, output: 5),
                          sourceType: "test", file: "/c.jsonl", schemaVersion: nil, offset: 0)
        }
        #expect(try database.ingest(codex, issues: [], provider: .codex).eventsWritten == 3)
        let lifetime = try database.usage.totals(in: Self.everything)
        #expect(lifetime.events == 5)
        #expect(try database.check().isHealthy)

        // The next pass compacts it, totals unchanged, and a re-read adds nothing.
        try database.compact(before: Timestamp(epochSeconds: 50_000))
        #expect(try database.usage.totals(in: Self.everything) == lifetime)
        #expect(try database.ingest(codex, issues: [], provider: .codex).eventsWritten == 0)
        #expect(try database.usage.totals(in: Self.everything) == lifetime)
        #expect(try database.check().isHealthy)

        // Deleting Codex's usage frees its history to be imported again.
        try database.delete(.provider(.codex))
        #expect(try database.ingest(codex, issues: [], provider: .codex).eventsWritten == 3)
        #expect(try database.usage.totals(in: Self.everything) == lifetime)
    }

    @Test func `EC-D7 history found after compaction imports, except into a quarter hour already compacted`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([try IngestionTests.record("a", at: 1_000), try IngestionTests.record("b", at: 20_000),
                             try IngestionTests.record("recent", at: 80_000)], issues: [], provider: .claudeCode)
        try database.compact(before: Timestamp(epochSeconds: 50_000))
        #expect(try database.compactedBefore() == Timestamp(epochSeconds: 20_700))

        // A file read for the first time, as from another Mac: between the
        // compacted events it is new; beside one, it cannot be told from it.
        let found = [try IngestionTests.record("between", at: 10_000, file: "/b.jsonl"),
                     try IngestionTests.record("beside", at: 1_100, file: "/b.jsonl")]
        #expect(try database.ingest(found, issues: [], provider: .claudeCode).eventsWritten == 1)
        #expect(try database.usage.totals(in: Self.everything).events == 4)
        #expect(try database.check().isHealthy)
        // Read again before and after the next pass, it counts once.
        #expect(try database.ingest(found, issues: [], provider: .claudeCode).eventsWritten == 0)
        try database.compact(before: Timestamp(epochSeconds: 50_000))
        #expect(try database.ingest(found, issues: [], provider: .claudeCode).eventsWritten == 0)
        #expect(try database.usage.totals(in: Self.everything).events == 4)
        #expect(try database.check().isHealthy)
    }

    @Test func `EC-D11 a compacted reply crossing into the next quarter hour is not counted again`() throws {
        let database = try IngestionTests.syncedDatabase()
        // One reply, written over two lines either side of a quarter hour.
        let lines = [try IngestionTests.record("reply", at: 1_790, output: 10),
                     try IngestionTests.record("reply", at: 1_810, output: 12)]
        try database.ingest([lines[0]], issues: [], provider: .claudeCode)
        try database.compact(before: Timestamp(epochSeconds: 50_000))
        let lifetime = try database.usage.totals(in: Self.everything)
        #expect(lifetime.events == 1)

        #expect(try database.ingest(lines, issues: [], provider: .claudeCode).eventsWritten == 0)
        #expect(try database.admissible(lines, provider: .claudeCode).isEmpty)
        #expect(try database.usage.totals(in: Self.everything) == lifetime)
    }

    @Test func `the boundary falls on a bucket edge and never moves back`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([try IngestionTests.record("e", at: 1_000)], issues: [], provider: .claudeCode)
        try database.compact(before: Timestamp(epochSeconds: 2_000))
        #expect(try database.compactedBefore() == Timestamp(epochSeconds: 1_800))
        try database.compact(before: Timestamp(epochSeconds: 900))
        #expect(try database.compactedBefore() == Timestamp(epochSeconds: 1_800))
    }

    @Test func `events after the boundary keep their rollups exact`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest((0..<40).map { try IngestionTests.record("e\($0)", at: Int64($0) * 300) },
                            issues: [], provider: .claudeCode)
        try database.compact(before: Timestamp(epochSeconds: 4_500))
        // A fuller snapshot, a price, and a deletion, all after the boundary.
        try database.ingest([try IngestionTests.record("e30", at: 9_000, output: 500)], issues: [], provider: .claudeCode)
        try database.pricing.reprice(database.pricing.apply(PricingStoreTests.manifest([
            ("claude-opus-5", "1970-01-01T00:00:00Z", "20")])))
        try database.write { try $0.execute(sql: "DELETE FROM usage_events WHERE source_event_id = 'e35'") }
        let (kept, expected) = try StorageTests.rollups(database)
        #expect(kept == expected && !kept.isEmpty)
        // Compacted buckets stay out of a rebuild.
        let compacted = try database.usage.totals(in: TimeWindow(start: .init(epochSeconds: 0),
                                                                 end: .init(epochSeconds: 4_500)))
        try database.rebuildRollups()
        #expect(try database.usage.totals(in: TimeWindow(start: .init(epochSeconds: 0),
                                                         end: .init(epochSeconds: 4_500))) == compacted)
        #expect(compacted.events == 15)
    }

    @Test func `deleting history removes compacted totals too`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest((0..<20).map { try IngestionTests.record("e\($0)", at: Int64($0) * 900) },
                            issues: [], provider: .claudeCode)
        try database.compact(before: Timestamp(epochSeconds: 9_000))
        try database.usage.deleteEvents(before: Timestamp(epochSeconds: 13_500))
        #expect(try database.usage.totals(in: Self.everything).events == 5)
        let (kept, expected) = try StorageTests.rollups(database)
        #expect(kept == expected)
    }

    @Test func `a database from before compaction gets its cache savings filled`() throws {
        let fixture = try StoreFixture()
        do {
            let old = try fixture.open(schema: fixture.schema(through: 8))
            try old.models.sync(ModelAliasManifest.load(from: IngestionTests.manifestURL))
            try old.pricing.apply(PricingStoreTests.manifest([("claude-opus-5", "1970-01-01T00:00:00Z", "20")]))
            try old.write { db in
                let model = try Int64.fetchOne(db, sql: "SELECT id FROM models WHERE canonical_name = 'claude-opus-5'")
                let version = try Int64.fetchOne(db, sql: "SELECT id FROM pricing_versions")
                try db.execute(sql: """
                    INSERT INTO source_files (provider_id, source_type, path)
                    SELECT id, 't', '/a' FROM providers WHERE key = 'claude_code'
                    """)
                try db.execute(sql: """
                    INSERT INTO usage_events (provider_id, model_id, timestamp, input_tokens, cached_input_tokens,
                      output_tokens, pricing_version_id, cost_nanos, pricing_confidence, source_file_id,
                      source_event_id, created_at)
                    SELECT id, ?, 100, 1, 1000000, 1, ?, 0, 'exact', 1, 'old', 0 FROM providers WHERE key = 'claude_code'
                    """, arguments: [model, version])
            }
        }
        let upgraded = try fixture.open()
        let savings = try upgraded.usage.cacheSavings(in: Self.everything)
        // The test price has no cache rate of its own, so the saving is unknown.
        #expect(savings.cacheTokens == 1_000_000 && savings.coverage == 0)
        let (kept, expected) = try StorageTests.rollups(upgraded)
        #expect(kept == expected)
        #expect(try upgraded.usage.totals(in: Self.everything).cost.raw > 0)
    }
}
