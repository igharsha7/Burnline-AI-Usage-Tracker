//
//  PricingUpdaterTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineServices
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import GRDB
import Testing

/// The bundled-then-fetched pricing flow, with the network replaced.
struct PricingUpdaterTests {
    let root = TestDirectory.make("PricingUpdater")
    var cacheFile: URL { root.appending(path: "pricing.json") }
    /// 2026-10-31. A fetched cache is dated by this clock, not the real one.
    let clock = ManualClock(Timestamp(epochSeconds: 1_793_450_000))

    static func manifest(_ outputs: [(String, String)]) -> Data {
        let versions = outputs.map { from, output in
            """
            {"provider":"claude_code","model":"claude-opus-5","validFrom":"\(from)","tier":"standard",\
            "source":"litellm","confidence":"exact","perMillion":{"input":"1","output":"\(output)"}}
            """
        }
        return Data(#"{"schemaVersion":1,"versions":[\#(versions.joined(separator: ","))]}"#.utf8)
    }

    static let bundled = manifest([("1970-01-01T00:00:00Z", "20")])
    /// Bundled plus a cut to $10 from 1 November 2026.
    static let extended = manifest([("1970-01-01T00:00:00Z", "20"), ("2026-11-01T00:00:00Z", "10")])

    func database() throws -> BurnlineDatabase {
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: root.appending(path: "db")),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")),
            clock: clock)
        // One event before the price cut and one after.
        try database.ingest([Self.record("oct", at: 1_793_000_000), Self.record("nov", at: 1_794_000_000)],
                            issues: [], provider: .claudeCode)
        return database
    }

    static func record(_ id: String, at seconds: Int64) throws -> IncomingUsage {
        IncomingUsage(sourceEventID: id, sessionSourceID: "s", project: nil, rawModel: "claude-opus-5",
                      timestamp: Timestamp(epochSeconds: seconds), tokens: try TokenCounts(output: 1_000_000),
                      sourceType: "test", file: "/a.jsonl", schemaVersion: nil, offset: 0)
    }

    func updater(_ database: BurnlineDatabase, enabled: Bool = true,
                 fetch: @escaping PricingUpdater.Fetch) throws -> PricingUpdater {
        PricingUpdater(database: database, bundled: try PricingManifest.decode(Self.bundled), cacheFile: cacheFile,
                       enabled: enabled, clock: clock, fetch: fetch)
    }

    static func costs(_ database: BurnlineDatabase) throws -> [Nanodollars?] {
        try database.usage.events(in: TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: .max))).map(\.cost.amount)
    }

    @Test func `EC-R4 a launch retries pricing committed before an interrupted recalculation`() async throws {
        do {
            let database = try database()
            // The manifest committed, but the process stopped before updating any events.
            try database.pricing.apply(PricingManifest.decode(Self.bundled))
            #expect(try Self.costs(database) == [nil, nil])
        }
        let database = try database()
        let restarted = try updater(database) { _ in throw URLError(.notConnectedToInternet) }
        try await restarted.applyLocal()
        #expect(try Self.costs(database) == [Nanodollars(decimalString: "20"), Nanodollars(decimalString: "20")])
    }

    @Test func `EC-R4 a failed later recalculation batch is retried without new prices`() async throws {
        let database = try database()
        try database.ingest((0..<5_001).map { try Self.record("batch-\($0)", at: 1_795_000_000 + Int64($0)) },
                            issues: [], provider: .claudeCode)
        try database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_reprice BEFORE UPDATE OF cost_nanos ON usage_events
                WHEN OLD.source_event_id = 'batch-5000'
                BEGIN SELECT RAISE(ABORT, 'simulated recalculation failure'); END
                """)
        }
        let updater = try updater(database) { _ in Data() }
        await #expect(throws: StoreError.self) { try await updater.applyLocal() }
        let afterFailure = try Self.costs(database)
        #expect(afterFailure.prefix(5_000).allSatisfy { $0 == Nanodollars(decimalString: "20") })
        #expect(afterFailure.last == .some(nil))
        try database.write { try $0.execute(sql: "DROP TRIGGER reject_reprice") }
        #expect(try await updater.applyLocal() == 5_003)
        #expect(try Self.costs(database).allSatisfy { $0 == Nanodollars(decimalString: "20") })
        #expect(try await updater.applyLocal() == 0)
    }

    @Test func `the bundled prices price history already stored`() async throws {
        let database = try database()
        #expect(try Self.costs(database) == [nil, nil])
        try await updater(database) { _ in Data() }.applyLocal()
        #expect(try Self.costs(database) == [Nanodollars(decimalString: "20"), Nanodollars(decimalString: "20")])
    }

    @Test func `a fetched price change re-prices only the events after it, and is cached`() async throws {
        let database = try database()
        let updater = try updater(database) { _ in Self.extended }
        try await updater.applyLocal()
        #expect(await updater.refresh() == .updated(versions: 1, repriced: 1))
        #expect(try Self.costs(database) == [Nanodollars(decimalString: "20"), Nanodollars(decimalString: "10")])
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
        // Fetched a moment ago, so no second request today.
        #expect(await updater.refresh() == .fresh)
    }

    @Test func `the cached copy is applied at the next launch without the network`() async throws {
        let database = try database()
        try await updater(database) { _ in Self.extended }.refresh()
        let offline = try updater(database) { _ in throw URLError(.notConnectedToInternet) }
        try await offline.applyLocal()
        #expect(try Self.costs(database).last == Nanodollars(decimalString: "10"))
    }

    @Test func `EC-R9 a fetched manifest that rewrites a recorded price is refused`() async throws {
        let database = try database()
        let updater = try updater(database) { _ in Self.manifest([("1970-01-01T00:00:00Z", "5")]) }
        try await updater.applyLocal()
        guard case .failed = await updater.refresh() else {
            Issue.record("a rewritten history must be refused")
            return
        }
        #expect(try Self.costs(database) == [Nanodollars(decimalString: "20"), Nanodollars(decimalString: "20")])
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test func `Check Now fetches within the day, and switching off stops it`() async throws {
        let database = try database()
        let updater = try updater(database) { _ in Self.extended }
        try await updater.applyLocal()
        #expect(await updater.refresh() == .updated(versions: 1, repriced: 1))
        #expect(await updater.refresh(force: true) == .unchanged)
        #expect(await updater.info().fetchedAt != nil)
        await updater.setEnabled(false)
        #expect(await updater.refresh(force: true) == .disabled)
    }

    @Test func `switched off, it never touches the network`() async throws {
        let updater = try updater(database(), enabled: false) { _ in
            Issue.record("the network was used while switched off")
            return Self.extended
        }
        #expect(await updater.refresh() == .disabled)
    }

    @Test func `a failed download keeps the prices already known`() async throws {
        let database = try database()
        let updater = try updater(database) { _ in throw URLError(.timedOut) }
        try await updater.applyLocal()
        guard case .failed = await updater.refresh() else {
            Issue.record("a failed download is reported")
            return
        }
        #expect(try Self.costs(database).allSatisfy { $0 == Nanodollars(decimalString: "20") })
    }

    @Test func `a fetched copy stays fresh for a day, across a restart, and not a second longer`() async throws {
        let database = try database()
        let flaky = FlakyFetch(failures: 0)
        let first = try updater(database) { try flaky.fetch($0) }
        try await first.applyLocal()
        #expect(await first.refresh() == .updated(versions: 1, repriced: 1))

        // A new updater, as after a relaunch, judges the same cached copy.
        let relaunched = try updater(database) { try flaky.fetch($0) }
        clock.advance(seconds: PricingUpdater.refreshInterval - 1)
        #expect(await relaunched.refresh() == .fresh)
        #expect(flaky.fetches == 1)

        clock.advance(seconds: 1)
        #expect(await relaunched.refresh() == .unchanged)
        #expect(flaky.fetches == 2)
    }

    @Test func `a cached copy dated after now, as when the clock went back, is fetched again`() async throws {
        let database = try database()
        let flaky = FlakyFetch(failures: 0)
        let updater = try updater(database) { try flaky.fetch($0) }
        try await updater.applyLocal()
        #expect(await updater.refresh() == .updated(versions: 1, repriced: 1))

        clock.advance(seconds: -60)

        #expect(await updater.refresh() == .unchanged)
        #expect(flaky.fetches == 2)
    }

    /// Counts fetches; the first `failures` throw, the rest answer `extended`.
    final class FlakyFetch: @unchecked Sendable {
        // @unchecked: `count` is only touched under `lock`.
        private let lock = NSLock()
        private var count = 0
        let failures: Int
        init(failures: Int) { self.failures = failures }
        var fetches: Int { lock.withLock { count } }
        func fetch(_ url: URL) throws -> Data {
            let attempt = lock.withLock { count += 1; return count }
            if attempt <= failures { throw URLError(.notConnectedToInternet) }
            return PricingUpdaterTests.extended
        }
    }

    @Test func `the daily loop fetches at once and again each day, and a failed download does not stop it`() async throws {
        let database = try database()
        let flaky = FlakyFetch(failures: 1)
        let updater = try updater(database) { try flaky.fetch($0) }
        let clock = clock
        let stepper = SteppingClock(sleeps: 2) { clock.advance(seconds: $0.components.seconds) }

        await updater.run(clock: stepper)

        #expect(flaky.fetches == 3)
        #expect(stepper.waits == Array(repeating: .seconds(PricingUpdater.refreshInterval), count: 3))
        #expect(try Self.costs(database) == [Nanodollars(decimalString: "20"), Nanodollars(decimalString: "10")])
    }
}
