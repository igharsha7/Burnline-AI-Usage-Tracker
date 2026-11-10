//
//  ActivityServiceTests.swift
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

/// The activity page's figures from a real store, and achievements awarded
/// once, where the history earned them.
struct ActivityServiceTests {
    static let now = AggregationServiceTests.now
    static let calendar = AggregationServiceTests.india

    static func open() throws -> BurnlineDatabase {
        try BurnlineDatabase.open(
            at: StoreLocation(directory: TestDirectory.make("Activity")),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")),
            clock: ManualClock(now))
    }

    /// Events of `tokens` output tokens at these days ago, one session
    /// each: one event in each of `quarterHours` quarter hours, counting back
    /// from a minute before that time of day.
    static func ingest(_ database: BurnlineDatabase, daysAgo: [Int64], tokens: Int64 = 10,
                       provider: ProviderKey = .claudeCode, quarterHours: Int64 = 1) throws {
        let records = try daysAgo.flatMap { ago in
            try (0..<quarterHours).map { quarter in
                IncomingUsage(sourceEventID: "\(provider)-\(ago)-\(quarter)", sessionSourceID: "\(provider)-s\(ago)",
                              project: nil, rawModel: "claude-opus-5",
                              timestamp: now.adding(seconds: -ago * 86_400 - 60 - quarter * 900),
                              tokens: try TokenCounts(output: tokens), sourceType: "test", file: "/a.jsonl",
                              schemaVersion: nil, offset: 0)
            }
        }
        try database.ingest(records, issues: [], provider: provider)
    }

    static func service(_ database: BurnlineDatabase, at now: Timestamp = now) -> ActivityService {
        let clock = ManualClock(now)
        return ActivityService(database: database,
                               aggregation: AggregationService(database: database, calendar: calendar, clock: clock),
                               calendar: calendar, clock: clock)
    }

    @Test func `every day from tracking start through today, with sessions and providers`() throws {
        let database = try Self.open()
        try Self.ingest(database, daysAgo: [0, 1, 3], quarterHours: 4)
        try Self.ingest(database, daysAgo: [1], provider: .codex)
        let snapshot = try Self.service(database).snapshot()
        #expect(snapshot.days.count == 4)
        #expect(snapshot.days.map(\.isActive) == [true, false, true, true])
        #expect(snapshot.days.map(\.sessions) == [1, 0, 2, 1])
        #expect(Set(snapshot.days[2].providers.keys) == [.claudeCode, .codex])
        #expect(snapshot.days.last?.day == Self.calendar.day(containing: Self.now))
        #expect(snapshot.streaks.current == 2)
        #expect(snapshot.lifetime.events == 13)
    }

    @Test func `a day's active quarter hours count each quarter hour once, across providers`() throws {
        let database = try Self.open()
        try Self.ingest(database, daysAgo: [0], quarterHours: 3)
        // Codex in the same quarter hours, and one more.
        try Self.ingest(database, daysAgo: [0], provider: .codex, quarterHours: 4)
        try Self.ingest(database, daysAgo: [1], quarterHours: 2)
        let snapshot = try Self.service(database).snapshot()
        #expect(snapshot.days.map(\.activeQuarterHours) == [2, 4])
        #expect(snapshot.streaks.current == 1 && snapshot.streaks.todayCounts)
    }

    @Test func `nothing tracked yet is an empty snapshot`() throws {
        let snapshot = try Self.service(try Self.open()).snapshot()
        #expect(snapshot.days.isEmpty && snapshot.achievements.isEmpty && snapshot.streaks.longest == 0)
    }

    @Test func `a backfill awards past achievements with stable timestamps`() throws {
        let database = try Self.open()
        try Self.ingest(database, daysAgo: [0, 1], tokens: 30_000_000)
        let first = try Self.service(database).snapshot().achievements
        let fiftyMillion = try #require(first.first { $0.kind == .lifetimeTokens && $0.tier == "50000000" })
        #expect(fiftyMillion.awardedAt == Self.calendar.window(for: Self.calendar.day(containing: Self.now)).start)

        // Reading again changes nothing.
        #expect(try Self.service(database).snapshot().achievements == first)

        // Older history arrives: what it earned on its own is dated in the
        // past, and what was already awarded keeps its date.
        try Self.ingest(database, daysAgo: [30], provider: .codex)
        try Self.ingest(database, daysAgo: [40, 41], tokens: 6_000_000)
        let after = try Self.service(database).snapshot().achievements
        #expect(after.first { $0.kind == .lifetimeTokens && $0.tier == "50000000" } == fiftyMillion)
        let codex = try #require(after.first { $0.kind == .firstSession && $0.provider == .codex })
        #expect(codex.awardedAt < fiftyMillion.awardedAt)
        #expect(after.map(\.awardedAt) == after.map(\.awardedAt).sorted())
    }

    @Test func `new medals wait for their arrival, and a backfill's old ones join quietly`() throws {
        let database = try Self.open()
        // 1M tokens forty days ago; 50M and 100M today.
        try Self.ingest(database, daysAgo: [40, 41], tokens: 6_000_000)
        try Self.ingest(database, daysAgo: [0], tokens: 90_000_000)
        let snapshot = try Self.service(database).snapshot()
        #expect(snapshot.uncelebrated.contains { $0.kind == .lifetimeTokens && $0.tier == "100000000" })
        #expect(!snapshot.uncelebrated.contains { $0.kind == .lifetimeTokens && $0.tier == "1000000" })
        #expect(try Self.service(database).uncelebratedCount() == snapshot.uncelebrated.count)
        try Self.service(database).celebrate(snapshot.uncelebrated)
        #expect(try Self.service(database).snapshot().uncelebrated.isEmpty)
        #expect(try Self.service(database).uncelebratedCount() == 0)
    }

    @Test func `adding a provider finds the medals its history earned, however old, and nothing from before`() throws {
        let database = try Self.open()
        try Self.ingest(database, daysAgo: [0, 1], tokens: 30_000_000)
        let before = try Self.service(database).snapshot().achievements
        // An hour later, Codex is added and brings a month-old session.
        let added = Self.now.adding(seconds: 3_600)
        try Self.ingest(database, daysAgo: [30], provider: .codex)
        let found = try Self.service(database, at: added).found(since: added)
        #expect(found.contains { $0.kind == .firstSession && $0.provider == .codex })
        #expect(found.allSatisfy { !before.contains($0) })
        // Asking again finds the same, and nothing is awarded twice.
        #expect(try Self.service(database, at: added).found(since: added) == found)
    }
}
