//
//  StatusModelTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineProviders
@testable import BurnlineServices
import BurnlineStore
import BurnlineTestSupport
@testable import BurnlineUI
import Foundation
import Testing

/// A quota reader that answers one weekly window at its current percentage.
final class FixedQuota: QuotaReader, @unchecked Sendable {
    // @unchecked: `percent` is only touched under `lock`.
    private let lock = NSLock()
    private var percent: Double
    let provider: ProviderKey
    let clock: ManualClock

    init(provider: ProviderKey, clock: ManualClock, percentUsed: Double) {
        self.provider = provider
        self.clock = clock
        percent = percentUsed
    }

    var percentUsed: Double {
        get { lock.withLock { percent } }
        set { lock.withLock { percent = newValue } }
    }

    func read() async throws(QuotaReadError) -> QuotaReading {
        QuotaReading(provider: provider, observedAt: clock.now, source: "test", scope: .account, plan: nil,
                     windows: [QuotaWindowReading(key: "weekly", name: "Weekly", percentUsed: percentUsed,
                                                  resetAt: clock.now.adding(seconds: 86_400), windowSeconds: 604_800)],
                     bankedResets: nil)
    }
}

/// What the menu bar shows once connected to the services, and how it follows
/// the changes they push.
struct StatusModelTests {
    /// 2 November 2026, 12:00 UTC.
    static let now = Timestamp(epochSeconds: 1_793_620_800)
    static let utc = LocalCalendar(timeZone: .gmt, firstWeekday: .monday)
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    struct Fixture {
        let clock = ManualClock(StatusModelTests.now)
        let sleeper = ControlledSleep()
        let model: StatusModel
        let feed = ChangeFeed()
        let database: BurnlineDatabase
        let quota: QuotaActor
        let readers: [ProviderKey: FixedQuota]

        /// Today's usage: `outputs` events of that many output tokens, a minute apart.
        init(outputs: [Int64], quota: [ProviderKey: Double] = [:], pushFirst: ProviderQuotaState? = nil) throws {
            let clock = clock
            model = StatusModel(clock: clock, sleep: sleeper.sleep)
            database = try BurnlineDatabase.open(
                at: StoreLocation(directory: TestDirectory.make("StatusModel")),
                schema: Schema(directory: StatusModelTests.repositoryRoot.appending(path: "shared/schema")),
                clock: clock)
            let records = try outputs.enumerated().map { index, output in
                IncomingUsage(sourceEventID: "e\(index)", sessionSourceID: "s", project: nil, rawModel: "gpt-5.5",
                              timestamp: StatusModelTests.now.adding(seconds: -60 * Int64(index + 1)),
                              tokens: try TokenCounts(output: output), sourceType: "test", file: "/a.jsonl",
                              schemaVersion: nil, offset: 0)
            }
            try database.ingest(records, issues: [], provider: .codex)
            let status = StatusService(aggregation: AggregationService(database: database, calendar: StatusModelTests.utc,
                                                                       clock: clock),
                                       calendar: StatusModelTests.utc, clock: clock)
            let feed = feed
            readers = Dictionary(uniqueKeysWithValues: quota.map {
                ($0.key, FixedQuota(provider: $0.key, clock: clock, percentUsed: $0.value))
            })
            let actor = QuotaActor(database: database, readers: Array(readers.values), clock: clock,
                                   onStateChange: { feed.send(.quota($0)) })
            self.quota = actor
            model.connect(status: status, quota: actor, changes: feed, calendar: StatusModelTests.utc)
            // Pushed at once, so it lands while the first load is still reading.
            if let pushFirst { feed.send(.quota(pushFirst)) }
        }
    }

    @Test func `once connected, refreshing shows today's usage and every provider's limits`() async throws {
        let fixture = try Fixture(outputs: [1_000, 2_000], quota: [.codex: 40, .claudeCode: 70])
        await fixture.model.refresh()

        #expect(fixture.model.today?.tokens == 3_000)
        #expect(await eventually { fixture.model.quotas.count == 2 })
        // Always in the same order, whichever answered first.
        #expect(fixture.model.quotas.map(\.provider) == [.codex, .claudeCode])
        #expect(fixture.model.quotas.last?.windows.first?.percentageUsed == 70)
    }

    @Test func `a fresh read of one provider updates its limits and leaves the other's`() async throws {
        let fixture = try Fixture(outputs: [], quota: [.codex: 40, .claudeCode: 70])
        await fixture.model.refresh()
        #expect(await eventually { fixture.model.quotas.count == 2 })

        fixture.readers[.codex]?.percentUsed = 90
        await fixture.quota.refresh(.codex)

        #expect(await eventually { fixture.model.quotas.first?.windows.first?.percentageUsed == 90 })
        #expect(fixture.model.quotas.last?.windows.first?.percentageUsed == 70)
    }

    @Test func `EC-D1 a failure to save is shown at once, and clears when saving recovers`() async throws {
        let fixture = try Fixture(outputs: [])
        fixture.feed.send(.storage(.diskFull))
        #expect(await eventually { fixture.model.storeFailure == .diskFull })

        fixture.feed.send(.storage(nil))
        #expect(await eventually { fixture.model.storeFailure == nil })
        #expect(!fixture.model.failedToStart)
    }

    @Test func `new usage pushed after connecting reaches today's figure`() async throws {
        let fixture = try Fixture(outputs: [1_000])
        await fixture.model.refresh()
        #expect(fixture.model.today?.tokens == 1_000)

        try fixture.database.ingest([IncomingUsage(
            sourceEventID: "later", sessionSourceID: "s", project: nil, rawModel: "gpt-5.5",
            timestamp: Self.now.adding(seconds: -5), tokens: try TokenCounts(output: 500), sourceType: "test",
            file: "/a.jsonl", schemaVersion: nil, offset: 0)], issues: [], provider: .codex)
        fixture.feed.send(.usage(.codex))

        #expect(await eventually { fixture.model.today?.tokens == 1_500 })
    }

    @Test func `a quota pushed while the first load reads is kept, not replaced by the stored one`() async throws {
        let pushed = ProviderQuotaState(provider: .codex, plan: "pro", windows: [], bankedResets: [], health: .ok,
                                        lastSuccess: Self.now)
        let fixture = try Fixture(outputs: [], quota: [.codex: 40, .claudeCode: 70], pushFirst: pushed)

        // The load has landed once Claude Code, which nothing pushed, appears.
        #expect(await eventually { fixture.model.quotas.map(\.provider) == [.codex, .claudeCode] })
        #expect(fixture.model.quotas.first?.plan == "pro")
    }

    @Test(.timeLimit(.minutes(1)))
    func `today starts over at midnight, used or not`() async throws {
        let fixture = try Fixture(outputs: [])
        // Ten minutes ago, so nothing is live and no expiry timer runs.
        try fixture.database.ingest([IncomingUsage(
            sourceEventID: "morning", sessionSourceID: "s", project: nil, rawModel: "gpt-5.5",
            timestamp: Self.now.adding(seconds: -600), tokens: try TokenCounts(output: 1_000), sourceType: "test",
            file: "/a.jsonl", schemaVersion: nil, offset: 0)], issues: [], provider: .codex)
        fixture.feed.send(.usage(.codex))
        #expect(await eventually { fixture.model.today?.tokens == 1_000 })
        #expect(fixture.model.live == nil)
        // Noon UTC, so midnight is twelve hours away.
        let untilMidnight = Duration.seconds(12 * 3_600)
        // Started before today loaded, the timer first waits a minute and looks again.
        #expect(await eventually {
            fixture.sleeper.release(.seconds(60))
            return fixture.sleeper.isWaiting(untilMidnight)
        })

        fixture.clock.advance(seconds: 12 * 3_600)
        fixture.sleeper.release(untilMidnight)

        #expect(await eventually { fixture.model.today?.tokens == 0 })
        #expect(fixture.model.today?.endsAt == Self.now.adding(seconds: 36 * 3_600))
    }

    @Test(.timeLimit(.minutes(1)))
    func `live usage ends when nothing more arrives, though no change says so`() async throws {
        let fixture = try Fixture(outputs: [])
        // Seven seconds ago, so live's end is a wait no other timer asks for:
        // the midnight timer may first wait a minute.
        try fixture.database.ingest([IncomingUsage(
            sourceEventID: "recent", sessionSourceID: "s", project: nil, rawModel: "gpt-5.5",
            timestamp: Self.now.adding(seconds: -7), tokens: try TokenCounts(output: 1_000), sourceType: "test",
            file: "/a.jsonl", schemaVersion: nil, offset: 0)], issues: [], provider: .codex)
        fixture.feed.send(.usage(.codex))
        #expect(await eventually { fixture.model.live != nil })
        let endsAt = try #require(fixture.model.live?.endsAt)
        let wait = endsAt.seconds(since: Self.now)
        #expect(wait == StatusService.liveWindow - 7)
        #expect(await eventually { fixture.sleeper.isWaiting(.seconds(wait)) })

        fixture.clock.advance(seconds: wait + 1)
        // A load that read live just before the clock moved can finish just
        // after, replacing the released expiry with one at the one-second
        // minimum, since live's end has passed. End both until live ends.
        #expect(await eventually {
            fixture.sleeper.release(.seconds(wait))
            fixture.sleeper.release(.seconds(1))
            return fixture.model.live == nil
        })
        #expect(fixture.model.heat == 0)
    }

    @Test func `EC-D2 a database that never opened is shown as failed to start`() {
        let model = StatusModel(clock: ManualClock(Self.now))
        model.fail(.corrupt)
        #expect(model.failedToStart && model.storeFailure == .corrupt)
    }

    @Test func `nothing live means no heat, whatever the scale`() {
        let model = StatusModel(clock: ManualClock(Self.now))
        model.show(today: nil, quotas: [], live: nil, heatScale: HeatScale(
            typical: Nanodollars(raw: 1), busy: Nanodollars(raw: 2), peak: Nanodollars(raw: 3)))
        #expect(model.heat == 0)
    }
}
