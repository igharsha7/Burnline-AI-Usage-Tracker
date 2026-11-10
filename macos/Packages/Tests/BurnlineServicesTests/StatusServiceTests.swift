//
//  StatusServiceTests.swift
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

/// Today's totals and live activity, as the menu bar reads them.
struct StatusServiceTests {
    /// 2 November 2026, 12:00 UTC.
    static let now = Timestamp(epochSeconds: 1_793_620_800)
    static let utc = LocalCalendar(timeZone: .gmt, firstWeekday: .monday)

    /// Events `secondsAgo` before now, each with 1,000 output tokens.
    static func service(_ events: [(ProviderKey, Int64)], cachedInput: Int64 = 0) throws -> StatusService {
        let clock = ManualClock(now)
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: TestDirectory.make("Status")),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")),
            clock: clock)
        for (provider, group) in Dictionary(grouping: events.enumerated(), by: { $0.element.0 }) {
            let records = try group.map { index, event in
                IncomingUsage(sourceEventID: "e\(index)", sessionSourceID: "s", project: ProjectCandidate(
                                  identity: .gitRemote("github.com/me/burnline"), displayName: "burnline", path: "/b"),
                              rawModel: provider == .codex ? "gpt-5.5" : "claude-opus-5",
                              timestamp: now.adding(seconds: -event.1), tokens: try TokenCounts(cachedInput: cachedInput, output: 1_000),
                              sourceType: "test", file: "/a.jsonl", schemaVersion: nil, offset: 0)
            }
            try database.ingest(records, issues: [], provider: provider)
        }
        return StatusService(aggregation: AggregationService(database: database, calendar: utc, clock: clock),
                             calendar: utc, clock: clock)
    }

    @Test func `today counts only today, and says when it ends`() async throws {
        let service = try Self.service([(.codex, 60), (.claudeCode, 3_600), (.codex, 13 * 3_600)])
        let today = try #require(await service.today())
        #expect(today.tokens == 2_000)
        #expect(today.endsAt == Self.now.adding(seconds: 12 * 3_600))
    }

    @Test func `the provider used last is live, at its pace over five minutes`() async throws {
        let service = try Self.service([(.claudeCode, 200), (.codex, 30), (.codex, 90), (.codex, 400)])
        let live = try #require(await service.live())
        #expect(live.provider == .codex && live.model != nil && live.project == "Burnline")
        // Two events in the last five minutes: 2,000 tokens over five minutes.
        #expect(live.tokensPerMinute == 400)
        #expect(live.endsAt == Self.now.adding(seconds: -30 + StatusService.liveWindow))
    }

    @Test func `the new-token rate leaves out cache re-reads`() async throws {
        let service = try Self.service([(.claudeCode, 30)], cachedInput: 99_000)
        let live = try #require(await service.live())
        // 100,000 processed over five minutes, of which 1,000 were new.
        #expect(live.tokensPerMinute == 20_000)
        #expect(live.newTokensPerMinute == 200)
    }

    @Test func `every session used within the live window is active, across providers`() async throws {
        let service = try Self.service([(.claudeCode, 30), (.codex, 90), (.codex, 200)])
        let live = try #require(await service.live())
        #expect(Set(live.sessions.compactMap(\.provider)) == [.claudeCode, .codex])
        #expect(live.sessions.allSatisfy { $0.name == "Burnline" })
    }

    @Test func `nothing is live once usage stops for two minutes`() async throws {
        let service = try Self.service([(.codex, 121)])
        #expect(await service.live() == nil)
    }
}

/// Every subscriber hears every change, and one that stops listening is let go.
struct ChangeFeedTests {
    @Test func `each subscriber gets each change`() async {
        let feed = ChangeFeed()
        let first = feed.changes(), second = feed.changes()
        feed.send(.usage(.codex))
        for stream in [first, second] {
            guard case .usage(.codex) = await within({ await stream.first { _ in true } }) else {
                Issue.record("a subscriber missed the change")
                return
            }
        }
    }
}

/// The figures the menu bar judges against history: the heat scale, and what
/// this Mac sent a provider during a quota window.
struct StatusHistoryTests {
    static let now = StatusServiceTests.now
    /// Claude Opus output at $12 a million tokens: 1,000 tokens cost 0.012 dollars.
    static let prices = PricingUpdaterTests.manifest([("1970-01-01T00:00:00Z", "12")])

    /// Priced Claude Code events, each `secondsAgo` before now with `output` tokens.
    static func service(_ events: [(secondsAgo: Int64, output: Int64)]) throws -> StatusService {
        let clock = ManualClock(now)
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: TestDirectory.make("StatusHistory")),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")),
            clock: clock)
        try database.pricing.apply(PricingManifest.decode(prices))
        let records = try events.enumerated().map { index, event in
            IncomingUsage(sourceEventID: "e\(index)", sessionSourceID: "s", project: nil, rawModel: "claude-opus-5",
                          timestamp: now.adding(seconds: -event.secondsAgo), tokens: try TokenCounts(output: event.output),
                          sourceType: "test", file: "/a.jsonl", schemaVersion: nil, offset: 0)
        }
        try database.ingest(records, issues: [], provider: .claudeCode)
        return StatusService(aggregation: AggregationService(database: database, calendar: StatusServiceTests.utc,
                                                             clock: clock),
                             calendar: StatusServiceTests.utc, clock: clock)
    }

    /// `count` busy stretches an hour apart, starting `daysAgo` back.
    static func stretches(_ count: Int, daysAgo: Int64, output: Int64) -> [(secondsAgo: Int64, output: Int64)] {
        (0..<Int64(count)).map { (daysAgo * 86_400 + $0 * 3_600 + 60, output) }
    }

    @Test func `heat is judged on the last 30 days of this history alone`() async throws {
        // 24 recent stretches at 0.012 dollars each, and 24 far costlier ones
        // just past the lookback that must not raise the scale.
        let service = try Self.service(Self.stretches(24, daysAgo: 0, output: 1_000)
                                       + Self.stretches(24, daysAgo: 31, output: 100_000))
        let scale = await service.heatScale()
        // 0.012 dollars a five-minute stretch is 0.144 dollars an hour.
        let perHour = Nanodollars(raw: 144_000_000)
        #expect(scale == HeatScale(typical: perHour, busy: perHour, peak: perHour))
    }

    @Test func `too little history keeps the starting heat scale`() async throws {
        let service = try Self.service(Self.stretches(HeatScale.fewest - 1, daysAgo: 0, output: 1_000))
        #expect(await service.heatScale() == HeatScale.starting)
    }

    @Test func `usage during a window counts from its start until now`() async throws {
        let service = try Self.service([(7_200, 1_000), (1_800, 2_000), (60, 4_000)])
        let totals = try #require(await service.usage(of: .claudeCode, from: Self.now.adding(seconds: -3_600), until: nil))
        #expect(totals.tokens.output == 6_000)
    }

    @Test func `EC-T6 a window waiting for its reset counts nothing after the reset time`() async throws {
        let service = try Self.service([(1_800, 2_000), (60, 4_000)])
        let totals = try #require(await service.usage(of: .claudeCode, from: Self.now.adding(seconds: -3_600),
                                                      until: Self.now.adding(seconds: -600)))
        #expect(totals.tokens.output == 2_000)
    }

    @Test func `another provider's usage is never counted in a window`() async throws {
        let service = try Self.service([(60, 4_000)])
        let totals = try #require(await service.usage(of: .codex, from: Self.now.adding(seconds: -3_600), until: nil))
        #expect(totals.events == 0)
    }

    @Test func `a window that has not begun has no usage`() async throws {
        let service = try Self.service([(60, 4_000)])
        #expect(await service.usage(of: .claudeCode, from: Self.now.adding(seconds: 60), until: nil) == nil)
    }
}
