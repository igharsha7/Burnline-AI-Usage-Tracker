//
//  StorePerformanceTests.swift
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

/// The store's share of the performance gate CI runs on every pull request:
/// a synthetic history of `BURNLINE_PERF_EVENTS` events (half a million by
/// default) written, measured, and every dashboard range read from it warm.
/// Off unless `BURNLINE_PERF` names a directory for the figures; run in
/// release:
///
///     BURNLINE_PERF=/tmp/perf swift test -c release --filter PerformanceTests
///
/// `ScaleTests` measures the same things at ten million events, by hand.
@Suite(.enabled(if: PerformanceReport.enabled), .serialized)
struct StorePerformanceTests {
    static let events = ProcessInfo.processInfo.environment["BURNLINE_PERF_EVENTS"].flatMap(Int.init) ?? 500_000

    /// How many warm runs each range gets; the fastest counts.
    static let runs = 5

    /// The slowest insert rate allowed: a floor against disaster, not the
    /// target. Measured near 50,000 a second on the reference Mac at this
    /// size, but from 19,700 to 27,200 on CI's shared runner for the same
    /// code, so the comparison with the base branch, measured in turns on
    /// the same runner, is what catches a real regression.
    static let minimumInsertRate = 10_000.0

    static let names: [RangePreset: String] = [
        .today: "today", .last7Days: "7 days", .last30Days: "30 days", .last90Days: "90 days",
        .yearToDate: "year to date", .lastYear: "12 months", .all: "all time",
    ]

    @Test func `the store stays small, fast to write, and interactive at every range`() throws {
        let fixture = try StoreFixture()
        let database = try fixture.open()
        try database.models.sync(ModelAliasManifest.load(from: IngestionTests.manifestURL))
        try database.pricing.apply(PricingManifest.load(from: PricingStoreTests.shippedURL))

        let shape = SyntheticHistory.Shape(events: Self.events)
        var writing = Duration.zero
        var written = 0
        for batch in SyntheticHistory(shape: shape).batches() {
            let started = ContinuousClock.now
            written += try database.ingest(batch.records, issues: [], provider: batch.provider).eventsWritten
            writing += ContinuousClock.now - started
        }
        #expect(written == Self.events)

        var report = PerformanceReport()
        let rate = Double(written) / (PerformanceReport.milliseconds(writing) / 1_000)
        report.record(.init(id: "insert-rate", title: "Insert rate", value: rate, unit: "events/s",
                            budget: Self.minimumInsertRate, better: .higher, doc: "storage"))

        try database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        let bytes = try FileManager.default.attributesOfItem(atPath: fixture.location.databaseFile.path)[.size] as! Int
        report.record(.init(id: "bytes-per-event", title: "Store size per event", value: Double(bytes / written),
                            unit: "bytes", budget: Double(ScaleTests.maximumBytesPerEvent), better: .lower,
                            doc: "storage"))

        // Each range's chart by provider and its breakdown by model, as the
        // dashboard loads them, on a calendar whose days are not UTC's.
        let calendar = LocalCalendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!, firstWeekday: .monday)
        let earliest = try database.aggregation.earliest()
        let budget = PerformanceReport.milliseconds(ScaleTests.interactiveBudget)
        for preset in ScaleTests.presets {
            let window = calendar.window(for: preset, now: shape.end.adding(seconds: -1), earliest: earliest)
            let width = max(BucketWidth.automatic(for: window), .quarterHour)
            let buckets = calendar.buckets(width, covering: window)
            let load = {
                _ = try database.aggregation.series(buckets, grouping: .provider, filters: .none, from: .rollups)
                _ = try database.aggregation.breakdown(window, by: .model, filters: .none)
            }
            try load()   // cold
            let warm = try PerformanceReport.fastest(of: Self.runs, load)
            report.record(.init(id: "range-\(preset)", title: "Dashboard, \(Self.names[preset] ?? "\(preset)"), warm",
                                value: PerformanceReport.milliseconds(warm), unit: "ms", budget: budget,
                                better: .lower, doc: "aggregation"))
        }

        try report.write(suite: "store")
        for metric in report.metrics {
            #expect(metric.withinBudget, "\(metric.title): \(metric.value) \(metric.unit), budget \(metric.budget)")
        }
    }
}
