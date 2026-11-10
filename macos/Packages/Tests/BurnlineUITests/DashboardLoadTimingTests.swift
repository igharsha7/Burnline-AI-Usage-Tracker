//
//  DashboardLoadTimingTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import BurnlineStore
@testable import BurnlineUI
import Foundation
import Testing

/// How long the dashboard takes to read each range from a real database,
/// opened read-only beside a running app. Off by default; run with
///
///     BURNLINE_DASHBOARD_DB=/path/to/store/dir swift test -c release --filter DashboardLoadTimingTests
///
/// It prints timings and counts only. `BURNLINE_LAUNCH_DB`, a copy of a
/// store directory, also times what launch does on the main thread; it
/// opens that copy as the writer.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_DASHBOARD_DB"] != nil
                || ProcessInfo.processInfo.environment["BURNLINE_LAUNCH_DB"] != nil))
struct DashboardLoadTimingTests {
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_LAUNCH_DB"] != nil))
    func `time the launch steps`() throws {
        let location = StoreLocation(directory: URL(filePath: ProcessInfo.processInfo.environment["BURNLINE_LAUNCH_DB"]!))
        let pricing = Self.repositoryRoot.appending(path: "shared/pricing")
        var start = ContinuousClock.now
        func lap(_ step: String) {
            print("LAUNCH", step, (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))
            start = ContinuousClock.now
        }
        let database = try BurnlineDatabase.open(
            at: location, schema: Schema(directory: Self.repositoryRoot.appending(path: "shared/schema")),
            clock: SystemClock())
        lap("open and migrate")
        try database.models.sync(ModelAliasManifest.load(from: pricing.appending(path: "model_aliases.json")))
        lap("model aliases")
        _ = try PricingManifest.load(from: pricing.appending(path: "pricing.json"))
        lap("price history")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_DASHBOARD_DB"] != nil))
    func `time every range`() async throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["BURNLINE_DASHBOARD_DB"]!)
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: directory),
            schema: Schema(directory: Self.repositoryRoot.appending(path: "shared/schema")),
            clock: SystemClock(), mode: .readOnly)
        let calendar = LocalCalendar(timeZone: .current, firstWeekday: .monday)
        let service = AggregationService(database: database, calendar: calendar)
        for choice in RangeChoice.allCases {
            // Once to warm the page cache, then the median of five.
            _ = try await DashboardData.load(service, range: choice.preset, filters: .none, now: SystemClock().now)
            var samples: [Duration] = []
            var buckets = 0
            for _ in 0..<5 {
                let start = ContinuousClock.now
                let data = try await DashboardData.load(service, range: choice.preset, filters: .none,
                                                        now: SystemClock().now)
                samples.append(ContinuousClock.now - start)
                buckets = data.series.buckets.count
            }
            let median = samples.sorted()[2]
            print("LOAD", choice.spoken, "·", buckets, "buckets ·",
                  median.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_DASHBOARD_DB"] != nil))
    func `time every page over 30 days`() async throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["BURNLINE_DASHBOARD_DB"]!)
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: directory),
            schema: Schema(directory: Self.repositoryRoot.appending(path: "shared/schema")),
            clock: SystemClock(), mode: .readOnly)
        let service = AggregationService(database: database, calendar: LocalCalendar(timeZone: .current, firstWeekday: .monday))
        let catalog = CatalogService(database: database)
        let scopes: [Scope] = [.overview, .provider(.codex), .provider(.claudeCode), .projects, .sessions]
        for scope in scopes {
            for key in scope.breakdowns {
                let start = ContinuousClock.now
                _ = try service.breakdown(.last30Days, by: key, filters: scope.filters(.none))
                print("PART", scope, key, (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])))
            }
            let start = ContinuousClock.now
            _ = try await DashboardData.load(service, catalog: catalog, range: .last30Days, filters: scope.filters(.none),
                                             breakdowns: scope.breakdowns, ledger: scope.ledger, now: SystemClock().now)
            print("PAGE", scope, (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])))
        }
    }
}
