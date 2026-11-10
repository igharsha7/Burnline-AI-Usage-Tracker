//
//  ActivityTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import Testing

/// Streaks, the heatmap's scale and achievements, computed from days alone.
struct ActivityTests {
    static let calendar = LocalCalendar(timeZone: TimeZone(identifier: "UTC")!, firstWeekday: .monday)

    /// Consecutive days from 1 October 2026, each with this many tokens; zero
    /// is a day without usage. A day with usage has the hour a streak asks for
    /// unless `quarterHours` says otherwise.
    static func days(_ tokens: [Int64], providers: [[ProviderKey]] = [], quarterHours: [Int] = []) throws -> [ActivityDay] {
        let first = calendar.window(for: LocalDay(year: 2026, month: 10, day: 1)).start
        return try tokens.enumerated().map { index, tokens in
            let window = calendar.window(for: calendar.day(containing: first.adding(seconds: Int64(index) * 86_400)))
            let totals = tokens == 0 ? UsageTotals.zero
                : UsageTotals(events: 1, tokens: try TokenCounts(output: tokens), cost: Nanodollars(raw: 0),
                              unpricedEvents: 0, cacheSavings: CacheSavings())
            let used = index < providers.count ? providers[index] : (tokens == 0 ? [] : [.claudeCode])
            return ActivityDay(day: calendar.day(containing: window.start), window: window, totals: totals,
                               sessions: tokens == 0 ? 0 : 1,
                               providers: Dictionary(uniqueKeysWithValues: used.map { ($0, totals) }),
                               activeQuarterHours: index < quarterHours.count ? quarterHours[index]
                                   : tokens == 0 ? 0 : StreakRule.baseQuarterHours)
        }
    }

    /// What `days` and `sessions` have earned, judged as of the end of the
    /// last day.
    static func earned(_ days: [ActivityDay], sessions: [AchievementHistory.Session] = []) -> [Achievement] {
        Achievement.earned(AchievementHistory(days: days, sessions: sessions, calendar: calendar,
                                              now: days.last?.window.end ?? Timestamp(epochSeconds: 1_800_000_000)))
    }

    @Test func `a streak survives a today without usage yet, but not a whole empty day`() throws {
        #expect(Streaks(days: try Self.days([5, 5, 5, 0])).current == 3)
        #expect(Streaks(days: try Self.days([5, 5, 5, 5])).current == 4)
        #expect(Streaks(days: try Self.days([5, 5, 0, 0])).current == 0)
        #expect(Streaks(days: try Self.days([])).current == 0)
    }

    @Test func `the longest streak is the latest of the longest runs`() throws {
        let streaks = Streaks(days: try Self.days([5, 5, 0, 5, 5, 0, 5]))
        #expect(streaks.longest == 2)
        #expect(streaks.longestEnded == LocalDay(year: 2026, month: 10, day: 5))
        #expect(streaks.current == 1)
    }

    @Test func `each streak is kept with its first and last day`() throws {
        let streaks = Streaks(days: try Self.days([5, 5, 0, 0, 5, 0, 5, 5, 0]))
        let day = { LocalDay(year: 2026, month: 10, day: $0) }
        #expect(streaks.runs == [StreakRun(start: day(1), end: day(2), length: 2),
                                 StreakRun(start: day(5), end: day(5), length: 1),
                                 StreakRun(start: day(7), end: day(8), length: 2)])
        #expect(streaks.best == streaks.runs.last)
        #expect(!streaks.todayCounts && streaks.current == 2)
        #expect(Streaks(days: try Self.days([0, 0])).best == nil)
    }

    @Test func `counted days count this month and this year only`() throws {
        // 1 October through 2 November: today is in November.
        let streaks = Streaks(days: try Self.days(Array(repeating: 5, count: 33)))
        #expect(streaks.countedThisMonth == 2)
        #expect(streaks.countedThisYear == 33)
    }

    /// Days with these quarter hours of usage each, the last being today.
    static func worked(_ quarterHours: [Int]) throws -> [ActivityDay] {
        try days(quarterHours.map { $0 == 0 ? 0 : 5 }, quarterHours: quarterHours)
    }

    @Test func `a day counts once it has an hour of usage, and a short one breaks the streak`() throws {
        let streaks = Streaks(days: try Self.worked([4, 4, 3, 4, 4]))
        #expect(streaks.current == 2)
        #expect(streaks.runs.map(\.length) == [2, 2])
    }

    @Test func `today short of its hour waits, and says how far it has come`() throws {
        let streaks = Streaks(days: try Self.worked([4, 4, 4, 2]))
        #expect(streaks.current == 3 && !streaks.todayCounts)
        #expect(streaks.todayQuarterHours == 2 && streaks.todayRequired == 4)
    }

    @Test func `every ninety days a streak asks for a quarter hour more, and a break starts again at an hour`() {
        #expect(StreakRule.required(afterDays: 0) == 4)
        #expect(StreakRule.required(afterDays: 89) == 4)
        #expect(StreakRule.required(afterDays: 90) == 5)
        #expect(StreakRule.required(afterDays: 1_000) == StreakRule.maximumQuarterHours)
    }

    @Test func `the ninety-first day needs five quarter hours`() throws {
        let streaks = Streaks(days: try Self.worked(Array(repeating: 4, count: 90) + [4, 0]))
        // Day 91 had only an hour; the streak's freezes carry it, so it neither
        // counts nor breaks.
        #expect(streaks.current == 90)
        #expect(streaks.runs.last?.frozen.count == 1)
        let met = Streaks(days: try Self.worked(Array(repeating: 4, count: 90) + [5, 0]))
        #expect(met.current == 91)
    }

    @Test func `a week of counted days earns a freeze, which covers one short day without adding to the streak`() throws {
        let streaks = Streaks(days: try Self.worked(Array(repeating: 4, count: 7) + [0, 4, 4]))
        #expect(streaks.current == 9)
        #expect(streaks.runs.count == 1)
        #expect(streaks.runs[0].frozen == [LocalDay(year: 2026, month: 10, day: 8)])
        #expect(streaks.freezes == 0)
    }

    @Test func `without a freeze a short day ends the streak, and freezes go with it`() throws {
        let short = Streaks(days: try Self.worked([4, 4, 4, 4, 4, 4, 0, 4]))
        #expect(short.current == 1 && short.runs.map(\.length) == [6, 1])
        // Fourteen days earn two freezes; a third short day in a row ends it.
        let spent = Streaks(days: try Self.worked(Array(repeating: 4, count: 14) + [0, 0, 0, 4]))
        #expect(spent.runs.map(\.length) == [14, 1])
        #expect(spent.freezes == 0)
    }

    @Test func `freezes stop at two`() throws {
        let streaks = Streaks(days: try Self.worked(Array(repeating: 4, count: 28) + [0]))
        #expect(streaks.freezes == StreakRule.maximumFreezes)
    }

    @Test func `a streak achievement waits for the counted days, not just days with usage`() throws {
        let earned = Self.earned(try Self.worked(Array(repeating: 2, count: 10)))
        #expect(!earned.contains { $0.kind == .streak })
        let counted = Self.earned(try Self.worked(Array(repeating: 4, count: 7) + [0]))
        #expect(counted.contains { $0.kind == .streak && $0.value == 7 })
    }

    @Test func `EC-U5 a brand-new user still sees a gradient`() {
        let one = HeatmapScale(values: [0, 0, 40])
        #expect(one.level(for: 40) == HeatmapScale.levels)
        #expect(one.level(for: 0) == 0)

        let three = HeatmapScale(values: [10, 20, 30])
        #expect([10, 20, 30].map { three.level(for: $0) } == [2, 3, 4])
    }

    @Test func `EC-U5 the scale follows the range's own distribution, not fixed thresholds`() {
        // A light user and a heavy one get the same levels for the same shape.
        let light = HeatmapScale(values: [1, 2, 3, 4, 5, 6, 7, 8])
        let heavy = HeatmapScale(values: [1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 8_000])
        #expect((1...8).map { light.level(for: Double($0)) } == (1...8).map { heavy.level(for: Double($0) * 1_000) })
        #expect((1...8).map { light.level(for: Double($0)) } == [1, 1, 2, 2, 3, 3, 4, 4])
    }

    @Test func `achievements are dated where the history met them`() throws {
        let days = try Self.days([600_000, 500_000, 0, 50_000_000],
                                 providers: [[.claudeCode], [.claudeCode, .codex]])
        let earned = Self.earned(days)
        let tokens = earned.filter { $0.kind == .lifetimeTokens }
        #expect(tokens.map(\.tier) == ["1000000", "50000000"])
        #expect(tokens.map(\.awardedAt) == [days[1].window.start, days[3].window.start])
        #expect(earned.filter { $0.kind == .providersInADay }.map(\.awardedAt) == [days[1].window.start])
    }

    @Test func `a streak achievement is dated on the day the streak reached it`() throws {
        let days = try Self.days(Array(repeating: 5, count: 3) + [0] + Array(repeating: 5, count: 8))
        let streak = Self.earned(days).filter { $0.kind == .streak }
        // The first run reached three days; the second, seven.
        #expect(streak.map(\.tier) == ["3", "7"])
        #expect(streak.map(\.awardedAt) == [days[2].window.start, days[10].window.start])
    }

    @Test func `sessions are counted by when they started`() throws {
        let start = Timestamp(epochSeconds: 1_790_000_000)
        let sessions = (0..<12).map { AchievementHistory.Session(startedAt: start.adding(seconds: Int64(11 - $0) * 60),
                                                                 endedAt: nil,
                                                                 provider: $0 == 11 ? ProviderKey.codex : .claudeCode) }
        let earned = Self.earned([], sessions: sessions)
        #expect(earned.first { $0.kind == .sessions }?.awardedAt == start.adding(seconds: 9 * 60))
        #expect(earned.first { $0.kind == .firstSession && $0.provider == .codex }?.awardedAt == start)
        #expect(earned.first { $0.kind == .firstSession && $0.provider == .claudeCode }?.awardedAt
                    == start.adding(seconds: 60))
        #expect(!earned.contains { $0.kind == .firstSession && $0.provider == .cursor })
    }

    @Test func `a day with three providers also counts as two`() throws {
        let days = try Self.days([5], providers: [[.claudeCode, .codex, .cursor]])
        let counts = Self.earned(days).filter { $0.kind == .providersInADay }
        #expect(counts.map(\.tier) == ["2", "3"])
    }
}
