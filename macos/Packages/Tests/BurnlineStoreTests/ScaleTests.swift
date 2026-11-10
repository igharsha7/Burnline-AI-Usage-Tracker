//
//  ScaleTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineStore
import Foundation
import GRDB
import Testing

/// The storage phase's measurements, on a synthetic history of
/// `BURNLINE_SCALE_EVENTS` events (one million by default). Slow, so opt-in,
/// and measured in release. The database is removed with the run's scratch
/// folder unless `BURNLINE_SCALE_KEEP` is set; ten million events take about
/// 2.5 GB.
///
///     BURNLINE_SCALE=1 BURNLINE_SCALE_EVENTS=10000000 swift test -c release --filter ScaleTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_SCALE"] != nil), .serialized)
struct ScaleTests {
    static let events = ProcessInfo.processInfo.environment["BURNLINE_SCALE_EVENTS"].flatMap(Int.init) ?? 1_000_000

    /// The queries the dashboard and menu bar are built on, each with the index
    /// it is expected to use.
    static let queries: [(name: String, sql: String)] = [
        ("lifetime totals by provider", """
            SELECT provider_id, count(*), sum(input_tokens), sum(cached_input_tokens), sum(output_tokens),
                   sum(cost_nanos), sum(cost_nanos IS NULL) FROM usage_events GROUP BY provider_id
            """),
        ("last 24 hours by provider", """
            SELECT provider_id, sum(output_tokens), sum(cost_nanos) FROM usage_events
            WHERE timestamp >= :end - 86400 AND timestamp < :end GROUP BY provider_id
            """),
        ("one provider, last 7 days", """
            SELECT sum(output_tokens), sum(cost_nanos) FROM usage_events
            WHERE provider_id = 1 AND timestamp >= :end - 604800 AND timestamp < :end
            """),
        ("daily buckets, last 365 days, UTC+5:30", """
            SELECT (timestamp + 19800) / 86400 AS day, sum(output_tokens), sum(cost_nanos), sum(cost_nanos IS NULL)
            FROM usage_events WHERE timestamp >= :end - 31536000 AND timestamp < :end GROUP BY day
            """),
        ("by model, last 30 days", """
            SELECT model_id, sum(output_tokens), sum(cost_nanos) FROM usage_events
            WHERE timestamp >= :end - 2592000 AND timestamp < :end GROUP BY model_id
            """),
        ("by project, last 90 days", """
            SELECT project_id, sum(output_tokens), sum(cost_nanos) FROM usage_events
            WHERE timestamp >= :end - 7776000 AND timestamp < :end GROUP BY project_id
            """),
        ("one project, lifetime", """
            SELECT count(*), sum(cost_nanos) FROM usage_events WHERE project_id = 1
            """),
        ("rollups: lifetime totals by provider", """
            SELECT provider_id, sum(events), sum(input_tokens), sum(cached_input_tokens), sum(output_tokens),
                   sum(cost_nanos), sum(unpriced_events) FROM usage_rollups GROUP BY provider_id
            """),
        ("rollups: daily buckets, last 365 days, UTC+5:30", """
            SELECT (bucket * 900 + 19800) / 86400 AS day, sum(output_tokens), sum(cost_nanos), sum(unpriced_events)
            FROM usage_rollups WHERE bucket >= (:end - 31536000) / 900 AND bucket < :end / 900 GROUP BY day
            """),
        ("rollups: by model, lifetime", """
            SELECT model_id, sum(output_tokens), sum(cost_nanos) FROM usage_rollups GROUP BY model_id
            """),
        ("rollups: one project, lifetime", """
            SELECT sum(events), sum(cost_nanos) FROM usage_rollups WHERE project_id = 1
            """),
        ("one session's events", "SELECT * FROM usage_events WHERE session_id = 1 ORDER BY timestamp"),
        ("re-price window for one model", """
            SELECT id FROM usage_events WHERE (timestamp, id) > (:end - 2592000, 0) AND timestamp < :end
              AND model_id = 1 ORDER BY timestamp, id LIMIT 5000
            """),
    ]

    /// Storage targets at ten million events, set from what was measured, less
    /// run-to-run variation. Inserts slow and deleted space returns only in part
    /// at ten million events because the dedup index is keyed by Claude
    /// Code's random message ids; SQLite keeps enforcing uniqueness instead
    /// of a hashed key in application code.
    static let maximumBytesPerEvent = 300
    static let minimumReclaimed = 0.8

    /// The aggregation phase's interactive budget: a range preset's chart
    /// and its breakdown, warm, in less than this.
    static let interactiveBudget = Duration.milliseconds(100)
    static let presets: [RangePreset] = [.today, .last7Days, .last30Days, .last90Days, .yearToDate, .lastYear, .all]

    static func minimumInsertRate(at events: Int) -> Double {
        events >= 10_000_000 ? 20_000 : 50_000
    }

    @Test func `measure footprint, insert rate, queries, and deletion`() async throws {
        let keep = ProcessInfo.processInfo.environment["BURNLINE_SCALE_KEEP"] != nil
        let fixture = try keep
            ? StoreFixture(keepingIn: FileManager.default.temporaryDirectory.appending(path: "BurnlineScale-\(UUID().uuidString)"))
            : StoreFixture()
        let database = try fixture.open()
        try database.models.sync(ModelAliasManifest.load(from: IngestionTests.manifestURL))
        try database.pricing.apply(PricingManifest.load(from: PricingStoreTests.shippedURL))

        let shape = SyntheticHistory.Shape(events: Self.events)
        var elapsed = Duration.zero
        var written = 0
        for batch in SyntheticHistory(shape: shape).batches() {
            let started = ContinuousClock.now
            written += try database.ingest(batch.records, issues: [], provider: batch.provider).eventsWritten
            elapsed += ContinuousClock.now - started
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("SCALE inserted \(written) events in \(elapsed): \(Int(Double(written) / seconds)) events/s")
        #expect(written == Self.events)

        try await database.pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let bytes = try FileManager.default.attributesOfItem(atPath: fixture.location.databaseFile.path)[.size] as! Int
        print("SCALE file \(bytes) bytes, \(bytes / written) bytes per event")
        try database.read { db in
            if let rows = try? Row.fetchAll(db, sql: """
                SELECT name, sum(pgsize) AS size FROM dbstat GROUP BY name ORDER BY size DESC LIMIT 12
                """) {
                for row in rows {
                    let size: Int = row["size"]
                    print("SCALE   \(row["name"] as String): \(size / written) bytes per event")
                }
            }
            let rollups = try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_rollups") ?? 0
            print("SCALE \(rollups) rollup rows, one per \(written / max(rollups, 1)) events")
            let end = shape.end.epochSeconds
            // Cold, then warm, then warm with the file memory-mapped.
            func time(_ sql: String) throws -> Duration {
                let started = ContinuousClock.now
                _ = try Row.fetchAll(db, sql: sql, arguments: ["end": end])
                return ContinuousClock.now - started
            }
            var timings: [(String, String, Duration, Duration)] = []
            for (name, sql) in Self.queries {
                let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: ["end": end])
                    .map { $0["detail"] as String }.joined(separator: " | ")
                timings.append((name, plan, try time(sql), try time(sql)))
            }
            try db.execute(sql: "PRAGMA mmap_size = 1073741824")
            for (name, plan, cold, warm) in timings {
                let mapped = try time(Self.queries.first { $0.name == name }!.sql)
                print("SCALE query \(name): cold \(cold), warm \(warm), mapped \(mapped) — \(plan)")
            }
        }

        // Every preset's chart by provider and its breakdown by model, as the
        // dashboard asks for them, on the user's calendar.
        let calendar = LocalCalendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!, firstWeekday: .monday)
        let earliest = try database.aggregation.earliest()
        var slowestPreset = Duration.zero
        for preset in Self.presets {
            let window = calendar.window(for: preset, now: shape.end.adding(seconds: -1), earliest: earliest)
            let width = max(BucketWidth.automatic(for: window), .quarterHour)
            let buckets = calendar.buckets(width, covering: window)
            func run() throws -> Duration {
                let started = ContinuousClock.now
                _ = try database.aggregation.series(buckets, grouping: .provider, filters: .none, from: .rollups)
                _ = try database.aggregation.breakdown(window, by: .model, filters: .none)
                return ContinuousClock.now - started
            }
            let cold = try run(), warm = try run()
            slowestPreset = max(slowestPreset, warm)
            print("SCALE preset \(preset): \(buckets.count) \(width) buckets, cold \(cold), warm \(warm)")
        }

        // Delete the oldest year while a day's history keeps arriving.
        let pages = { try database.read { try Int.fetchOne($0, sql: "PRAGMA page_count") ?? 0 } }
        let before = try pages()
        let cutoff = Timestamp(epochSeconds: shape.end.epochSeconds - Int64(shape.years - 1) * 365 * 86_400)
        let started = ContinuousClock.now
        async let deleted = Task.detached {
            let count = try database.usage.deleteEvents(before: cutoff)
            try database.reclaimSpace()
            return count
        }.value
        var slowest = Duration.zero
        let arriving = SyntheticHistory(shape: .init(events: 5_000, years: 1, seed: 11))
        for batch in arriving.batches() {
            let batchStarted = ContinuousClock.now
            try database.ingest(batch.records, issues: [], provider: batch.provider)
            slowest = max(slowest, ContinuousClock.now - batchStarted)
        }
        let removed = try await deleted
        try database.reclaimSpace()
        let reclaimed = Double(before - (try pages())) / (Double(removed) / Double(written) * Double(before))
        print("SCALE deleted \(removed) events and reclaimed \(Int(reclaimed * 100))% of their share of the file in "
              + "\(ContinuousClock.now - started); slowest concurrent batch \(slowest)")

        // Compact to the default detail window: lifetime figures unchanged,
        // the file down to about the window's events.
        let everything = TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: .max))
        let lifetime = try database.usage.totals(in: everything)
        let compactStarted = ContinuousClock.now
        let compacted = try database.compact(before: Timestamp(epochSeconds: shape.end.epochSeconds - 180 * 86_400))
        try await database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        let remaining = try database.usage.count()
        let compactBytes = try database.read { try Int.fetchOne($0, sql: """
            SELECT page_count * page_size FROM pragma_page_count, pragma_page_size
            """) ?? 0 }
        print("SCALE compacted \(compacted) events in \(ContinuousClock.now - compactStarted): "
              + "\(remaining) kept, file \(compactBytes) bytes")
        #expect(try database.usage.totals(in: everything) == lifetime)

        #expect(bytes / written <= Self.maximumBytesPerEvent)
        #expect(Double(written) / seconds >= Self.minimumInsertRate(at: written))
        #expect(reclaimed >= Self.minimumReclaimed)
        #expect(slowest < .seconds(1))
        #expect(slowestPreset < Self.interactiveBudget)
        if keep { print("SCALE database kept at \(fixture.location.databaseFile.path)") }
    }
}
