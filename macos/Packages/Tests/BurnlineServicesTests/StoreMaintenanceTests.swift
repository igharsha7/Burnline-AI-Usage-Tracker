//
//  StoreMaintenanceTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineServices
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import Testing

/// The daily pass compacts by the user's detail window, and only by it.
struct StoreMaintenanceTests {
    static let now = Timestamp(epochSeconds: 1_793_491_200)

    func database(eventsDaysAgo days: [Int64]) throws -> BurnlineDatabase {
        let database = try emptyDatabase()
        try database.ingest(records(daysAgo: days), issues: [], provider: .claudeCode)
        return database
    }

    func emptyDatabase() throws -> BurnlineDatabase {
        try BurnlineDatabase.open(
            at: StoreLocation(directory: TestDirectory.make("Maintenance")),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")),
            clock: ManualClock(Self.now))
    }

    func records(daysAgo days: [Int64]) throws -> [IncomingUsage] {
        try days.enumerated().map { index, days in
            IncomingUsage(sourceEventID: "e\(index)", sessionSourceID: "s", project: nil, rawModel: "claude-opus-5",
                          timestamp: Self.now.adding(seconds: -days * 86_400), tokens: try TokenCounts(output: 10),
                          sourceType: "test", file: "/a.jsonl", schemaVersion: nil, offset: 0)
        }
    }

    @Test func `EC-D7 the launch pass on a new store does not drop the first import's old history`() throws {
        let database = try emptyDatabase()
        let maintenance = StoreMaintenance(database: database, retention: .halfYear, clock: ManualClock(Self.now))
        maintenance.pass()
        let history = try records(daysAgo: [1, 60, 300, 800])
        #expect(try database.ingest(history, issues: [], provider: .claudeCode).eventsWritten == 4)
        let window = TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: .max))
        let lifetime = try database.usage.totals(in: window)
        #expect(lifetime.events == 4)

        // The next pass compacts it into the rollups; a re-read then adds nothing.
        maintenance.pass()
        #expect(try database.usage.count() == 2)
        #expect(try database.ingest(history, issues: [], provider: .claudeCode).eventsWritten == 0)
        #expect(try database.usage.totals(in: window) == lifetime)
    }

    @Test @MainActor
    func `EC-D8 maintenance started by the app does not compact on the UI thread`() async throws {
        let database = try database(eventsDaysAgo: [800, 1])
        let maintenance = StoreMaintenance(database: database, retention: .halfYear, clock: MaintenanceThreadClock())
        let task = Task { await maintenance.run() }
        task.cancel()
        await task.value
        #expect(try database.usage.count() == 1)
    }

    @Test(arguments: [(DetailRetention.ninetyDays, 2), (.halfYear, 3), (.year, 4), (.forever, 5)])
    func `history older than the window is compacted, and lifetime totals stay`(
        retention: DetailRetention, kept: Int) throws {
        let database = try database(eventsDaysAgo: [1, 60, 120, 300, 800])
        let window = TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: .max))
        let lifetime = try database.usage.totals(in: window)
        StoreMaintenance(database: database, retention: retention, clock: ManualClock(Self.now)).pass()
        #expect(try database.usage.count() == kept)
        #expect(try database.usage.totals(in: window) == lifetime)
    }

    @Test func `EC-D5 a shrunk detail window compacts at once, a widened one changes nothing`() async throws {
        let database = try database(eventsDaysAgo: [1, 60, 120, 300, 800])
        let maintenance = StoreMaintenance(database: database, retention: .forever, clock: ManualClock(Self.now))
        await maintenance.change(to: .year)
        #expect(try database.usage.count() == 4 && maintenance.retention == .year)
        await maintenance.change(to: .ninetyDays)
        #expect(try database.usage.count() == 2)
        // Compacted detail does not come back; widening only stops compacting.
        await maintenance.change(to: .forever)
        #expect(try database.usage.count() == 2 && maintenance.retention == .forever)
    }

    @Test func `a stored setting maps to its window, and an unknown one to the default`() {
        #expect(DetailRetention(days: 0) == .forever)
        #expect(DetailRetention(days: 365) == .year)
        #expect(DetailRetention(days: 42) == .default && DetailRetention.default == .halfYear)
    }
}

/// Reading the cutoff happens synchronously inside the compaction pass.
private struct MaintenanceThreadClock: WallClock {
    var now: Timestamp {
        #expect(!Thread.isMainThread)
        return StoreMaintenanceTests.now
    }
}
