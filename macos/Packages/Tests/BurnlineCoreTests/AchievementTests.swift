//
//  AchievementTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import Testing

/// The achievement catalogue and how each kind is earned.
struct AchievementTests {
    static let calendar = ActivityTests.calendar
    /// Monday 5 October 2026, the first full week of `days`.
    static let monday = calendar.window(for: LocalDay(year: 2026, month: 10, day: 5)).start

    /// Consecutive days from 1 October 2026, each with these tokens and
    /// the hour a streak asks for when it has any.
    static func days(_ tokens: [TokenCounts]) -> [ActivityDay] {
        let first = calendar.window(for: LocalDay(year: 2026, month: 10, day: 1)).start
        return tokens.enumerated().map { index, tokens in
            let window = calendar.window(for: calendar.day(containing: first.adding(seconds: Int64(index) * 86_400)))
            let used = tokens.processed > 0
            let totals = used ? UsageTotals(events: 1, tokens: tokens, cost: Nanodollars(raw: 0), unpricedEvents: 0,
                                            cacheSavings: CacheSavings()) : .zero
            return ActivityDay(day: calendar.day(containing: window.start), window: window, totals: totals,
                               sessions: used ? 1 : 0, providers: used ? [.claudeCode: totals] : [:],
                               activeQuarterHours: used ? StreakRule.baseQuarterHours : 0)
        }
    }

    static func history(_ days: [ActivityDay], sessions: [AchievementHistory.Session] = [],
                        cycles: [AchievementHistory.QuotaCycle] = [], models: [Timestamp] = [],
                        now: Timestamp? = nil, version: String? = nil) -> AchievementHistory {
        AchievementHistory(days: days, sessions: sessions, modelFirstUses: models, weeklyCycles: cycles,
                           calendar: calendar, now: now ?? days.last?.window.end ?? monday, appVersion: version)
    }

    /// A weekly window ending `weeks` weeks after the first Monday, at `peak`%.
    static func cycle(_ weeks: Int64, _ peak: Double, provider: ProviderKey = .codex) -> AchievementHistory.QuotaCycle {
        let end = monday.adding(seconds: weeks * 7 * 86_400)
        return AchievementHistory.QuotaCycle(provider: provider, key: "weekly", start: end.adding(seconds: -7 * 86_400),
                                             end: end, peak: peak, isConfirmedClosed: true)
    }

    // MARK: Catalogue

    @Test func `every kind has a medal, and every earned achievement belongs to exactly one`() throws {
        let catalogue = AchievementBadge.catalogue(providers: ProviderKey.trackable)
        #expect(Set(catalogue.map(\.kind)) == Set(AchievementKind.allCases))
        #expect(Set(catalogue.map(\.id)).count == catalogue.count)
        let start = Self.monday.adding(seconds: 3_600)
        let sessions = (0..<12).map { AchievementHistory.Session(startedAt: start.adding(seconds: Int64($0) * 600),
                                                                 endedAt: start.adding(seconds: 5 * 3_600),
                                                                 provider: .claudeCode) }
        let earned = Achievement.earned(Self.history(try ActivityTests.days(Array(repeating: 200_000, count: 40)),
                                                     sessions: sessions, cycles: [Self.cycle(1, 80), Self.cycle(2, 60)],
                                                     version: "0.1.0"))
        #expect(!earned.isEmpty)
        for achievement in earned {
            #expect(catalogue.count { $0.matches(achievement) } == 1, "\(achievement.kind) \(achievement.tier)")
        }
    }

    @Test func `every ladder climbs the eighteen metals and grades, and tops out at ember III`() {
        let catalogue = AchievementBadge.catalogue(providers: ProviderKey.trackable)
        let ladders = Dictionary(grouping: catalogue.filter { $0.threshold != nil }, by: \.kind)
        for (kind, rungs) in ladders {
            let ordered = rungs.sorted { $0.threshold! < $1.threshold! }
            let positions = ordered.map { $0.metal.rawValue * Metal.grades + $0.grade! - 1 }
            // A ladder longer than the eighteen rungs shares some between neighbours.
            #expect(positions == positions.sorted(), "\(kind)")
            #expect(Set(positions).count == min(positions.count, Metal.rungs), "\(kind)")
            #expect(ordered.last?.metalName == "Ember III", "\(kind)")
        }
        // The token ladder has a rung for every metal and grade, 1M to 3T.
        let tokens = ladders[.lifetimeTokens]!.sorted { $0.threshold! < $1.threshold! }
        #expect(tokens.count == Metal.rungs)
        #expect(tokens.map(\.title).prefix(2) == ["1M Tokens", "50M Tokens"])
        #expect(tokens.first { $0.threshold == 1_500_000_000_000 }?.title == "1.5T Tokens")
        #expect(tokens.first { $0.threshold == 1_500_000_000_000 }?.metalName == "Diamond III")
        // Ember is a ladder's top rung, or a medal that cannot come again.
        #expect(Set(catalogue.filter { $0.metal == .ember && $0.threshold == nil }.map(\.kind))
                == [.alphaTester, .foundingYear])
    }

    @Test func `the catalogue holds over a hundred medals before the monthly ones`() {
        let catalogue = AchievementBadge.catalogue(providers: ProviderKey.trackable)
        #expect(catalogue.count { $0.kind != .monthly } >= 100)
        #expect(catalogue.count { $0.kind == .monthly } == MonthlyChallenge.schedule.count)
    }

    // MARK: Pacing

    @Test func `Steady Hand counts busy windows in a row, and a limit reached starts it again`() {
        let cycles = [Self.cycle(1, 60), Self.cycle(2, 20), Self.cycle(3, 100), Self.cycle(4, 55), Self.cycle(5, 70)]
        let earned = Achievement.earned(Self.history([], cycles: cycles, now: Self.monday.adding(seconds: 60 * 86_400)))
        let steady = earned.filter { $0.kind == .steadyHand }
        // The idle second window neither counts nor breaks; the third breaks.
        #expect(steady.map(\.tier) == ["2"])
        #expect(steady.first?.awardedAt == cycles[4].end)
    }

    @Test func `Under the Line is each window that passed 75% and closed short of the limit`() {
        let cycles = [Self.cycle(1, 80), Self.cycle(2, 100), Self.cycle(3, 74), Self.cycle(4, 99),
                      Self.cycle(9, 90)]
        let earned = Achievement.earned(Self.history([], cycles: cycles, now: Self.monday.adding(seconds: 40 * 86_400)))
        let under = earned.filter { $0.kind == .underTheLine }
        // The last window has not closed yet.
        #expect(under.map(\.value) == [80, 99])
    }

    // MARK: Weeks

    @Test func `a Perfect Week is a whole calendar week of counted days, judged once it is over`() throws {
        let full = try ActivityTests.days(Array(repeating: 5, count: 14))
        let perfect = Achievement.earned(Self.history(full)).filter { $0.kind == .perfectWeek }
        #expect(perfect.map(\.tier) == ["2026-10-05"])
        let gap = try ActivityTests.days(Array(repeating: 5, count: 6) + [0] + Array(repeating: 5, count: 7))
        #expect(!Achievement.earned(Self.history(gap)).contains { $0.kind == .perfectWeek })
    }

    @Test func `Hot Cache needs a busy week with over 90% of its input from the cache`() throws {
        let hot = try TokenCounts(input: 50_000, cachedInput: 950_000, output: 1_000)
        let cold = try TokenCounts(input: 500_000, cachedInput: 500_000, output: 1_000)
        let earned = Achievement.earned(Self.history(Self.days(Array(repeating: hot, count: 11)
                                                              + Array(repeating: cold, count: 7))))
        // The week tracking began in counts too, once over.
        #expect(earned.filter { $0.kind == .hotCache }.map(\.tier) == ["2026-09-28", "2026-10-05"])
        let light = try TokenCounts(input: 1, cachedInput: 99, output: 1)
        #expect(!Achievement.earned(Self.history(Self.days(Array(repeating: light, count: 14))))
            .contains { $0.kind == .hotCache })
    }

    // MARK: Sessions

    @Test func `Night Owl, Early Bird and Marathon come from when sessions start and how long they run`() {
        let day = Self.monday
        let sessions = [
            AchievementHistory.Session(startedAt: day.adding(seconds: 9 * 3_600), endedAt: day.adding(seconds: 14 * 3_600),
                                       provider: .codex),
            AchievementHistory.Session(startedAt: day.adding(seconds: 86_400 + 2 * 3_600), endedAt: nil, provider: .codex),
            AchievementHistory.Session(startedAt: day.adding(seconds: 2 * 86_400 + 6 * 3_600), endedAt: nil,
                                       provider: .codex),
        ]
        let earned = Achievement.earned(Self.history([], sessions: sessions, now: day.adding(seconds: 10 * 86_400)))
        #expect(earned.first { $0.kind == .nightOwl }?.awardedAt == sessions[1].startedAt)
        #expect(earned.first { $0.kind == .earlyBird }?.awardedAt == sessions[2].startedAt)
        #expect(earned.first { $0.kind == .marathon }?.awardedAt == day.adding(seconds: 13 * 3_600))
    }

    @Test func `a conversation resumed days later is not a marathon`() {
        let session = AchievementHistory.Session(startedAt: Self.monday.adding(seconds: 9 * 3_600),
                                                 endedAt: Self.monday.adding(seconds: 3 * 86_400), provider: .codex)
        let history = Self.history([], sessions: [session], now: Self.monday.adding(seconds: 10 * 86_400))
        #expect(!Achievement.earned(history).contains { $0.kind == .marathon })
        #expect(PersonalRecords(history).longestSession == nil)
    }

    @Test func `model medals are dated at the use of the model that reached them`() {
        let uses = (0..<6).map { Self.monday.adding(seconds: Int64($0) * 86_400) }
        let earned = Achievement.earned(Self.history([], models: uses, now: Self.monday.adding(seconds: 10 * 86_400)))
        #expect(earned.filter { $0.kind == .models }.map(\.awardedAt) == [uses[2], uses[5]])
    }

    // MARK: Monthly challenges

    @Test func `monthly challenges start in September 2026 and run to the end of 2028`() {
        #expect(MonthlyChallenge.months.first == "2026-09" && MonthlyChallenge.months.last == "2028-12")
        #expect(MonthlyChallenge.months.count == 28)
        // Each kind waits at least nine months before it comes round again.
        let kinds = MonthlyChallenge.months.map { MonthlyChallenge.schedule[$0]! }
        for (index, kind) in kinds.enumerated() {
            #expect(!kinds[(index + 1)..<min(kinds.count, index + 9)].contains(kind), "\(MonthlyChallenge.months[index])")
        }
        let catalogue = AchievementBadge.catalogue(providers: ProviderKey.trackable)
        #expect(catalogue.first { $0.tier == "2026-09" }?.stone == 9)
    }

    @Test func `October's Cache Keeper is judged on the whole month once it is over`() throws {
        let hot = try TokenCounts(input: 20_000, cachedInput: 80_000, output: 100)
        let cold = try TokenCounts(input: 80_000, cachedInput: 20_000, output: 100)
        let met = Achievement.earned(Self.history(Self.days(Array(repeating: hot, count: 33))))
        #expect(met.filter { $0.kind == .monthly }.map(\.tier) == ["2026-10"])
        #expect(met.first { $0.kind == .monthly }?.value == MonthlyChallenge.Kind.cacheKeeper.rawValue)
        let missed = Achievement.earned(Self.history(Self.days(Array(repeating: cold, count: 33))))
        #expect(!missed.contains { $0.kind == .monthly })
        // Mid-month it shows where the share stands against the target.
        let midMonth = try #require(MonthlyChallenge.current(Self.history(Self.days(Array(repeating: hot, count: 10)))))
        #expect(midMonth.kind == .cacheKeeper && midMonth.onTrack && midMonth.target == MonthlyChallenge.cacheKeeperShare)
    }

    @Test func `November's Showing Up counts active days, and an idle month earns nothing`() throws {
        let tokens: [Int64] = Array(repeating: 0, count: 31) + (0..<30).map { $0 < 15 ? 5 : 0 } + [5]
        let earned = Achievement.earned(Self.history(try ActivityTests.days(tokens)))
        #expect(earned.contains { $0.kind == .monthly && $0.tier == "2026-11" })
        let short = Array(repeating: Int64(0), count: 31) + (0..<30).map { $0 < 14 ? 5 : 0 } + [5]
        #expect(!Achievement.earned(Self.history(try ActivityTests.days(short))).contains { $0.kind == .monthly })
    }

    @Test func `December's Lights Out needs a busy month without a late start`() throws {
        let days = try ActivityTests.days(Array(repeating: 5, count: 93))
        let december = Self.calendar.window(for: LocalDay(year: 2026, month: 12, day: 10)).start
        let late = AchievementHistory.Session(startedAt: december.adding(seconds: 2 * 3_600), endedAt: nil, provider: .codex)
        let early = AchievementHistory.Session(startedAt: december.adding(seconds: 9 * 3_600), endedAt: nil, provider: .codex)
        let lightsOut = { (session: AchievementHistory.Session) in
            Achievement.earned(Self.history(days, sessions: [session])).contains { $0.tier == "2026-12" }
        }
        #expect(lightsOut(early))
        #expect(!lightsOut(late))
    }

    @Test(arguments: ["0.10.0", "0.11.0", "0.100.0"])
    func `later minor releases do not earn the first alpha medal`(version: String) throws {
        let history = Self.history(try ActivityTests.days([5]), version: version)
        #expect(!Achievement.earned(history).contains { $0.kind == .alphaTester })
    }

    // MARK: Progress, limited editions

    @Test func `progress is shown only for habit medals`() throws {
        let history = Self.history(try ActivityTests.days(Array(repeating: 50_000_000, count: 10)),
                                   cycles: [Self.cycle(1, 60)])
        let catalogue = AchievementBadge.catalogue(providers: ProviderKey.trackable)
        let progress = AchievementProgress.next(history, earned: Achievement.earned(history), catalogue: catalogue)
        #expect(!progress.isEmpty)
        #expect(progress.allSatisfy { $0.badge.category.isHabit }, "\(progress.map(\.badge.kind))")
        #expect(progress.first { $0.badge.kind == .streak }?.target == 14)
    }

    @Test func `cache savings progress sums fractional dollars before rounding`() throws {
        let savings = CacheSavings(saved: Nanodollars(raw: 600_000_000), coveredCacheTokens: 1, cacheTokens: 1)
        let days = Self.days(Array(repeating: try TokenCounts(input: 1), count: 20)).map { day in
            ActivityDay(day: day.day, window: day.window,
                        totals: UsageTotals(events: 1, tokens: day.totals.tokens, cost: .zero,
                                           unpricedEvents: 0, cacheSavings: savings),
                        sessions: day.sessions, providers: day.providers,
                        activeQuarterHours: day.activeQuarterHours)
        }
        let history = Self.history(days)
        let earned = Achievement.earned(history)
        let progress = AchievementProgress.next(
            history, earned: earned, catalogue: AchievementBadge.catalogue(providers: ProviderKey.trackable))
        #expect(earned.contains { $0.kind == .cacheSavings && $0.tier == "10" })
        #expect(progress.first { $0.badge.kind == .cacheSavings }?.current == 12)
    }

    @Test func `Founding Year goes to anyone active in 2026`() throws {
        let earned = Achievement.earned(Self.history(try ActivityTests.days([0, 5])))
        let founding = try #require(earned.first { $0.kind == .foundingYear })
        #expect(founding.tier == "2026" && founding.awardedAt == Self.calendar.window(for: LocalDay(year: 2026, month: 10, day: 2)).start)
    }

    // MARK: Explorer

    /// `history` with each day's tokens by project.
    static func history(_ days: [ActivityDay], projects: [[Int64: Int64]], models: [Int] = []) -> AchievementHistory {
        AchievementHistory(days: days, sessions: [], projectTokens: projects, modelsPerDay: models,
                           calendar: calendar, now: days.last?.window.end ?? monday)
    }

    @Test func `Deep Dive counts one project's tokens, not every project's together`() throws {
        let days = try ActivityTests.days(Array(repeating: 5, count: 4))
        let split: [[Int64: Int64]] = Array(repeating: [1: 20_000_000, 2: 20_000_000], count: 4)
        #expect(!Achievement.earned(Self.history(days, projects: split)).contains { $0.kind == .deepDive })
        let focused: [[Int64: Int64]] = Array(repeating: [1: 40_000_000], count: 4)
        let deep = Achievement.earned(Self.history(days, projects: focused)).filter { $0.kind == .deepDive }
        #expect(deep.map(\.tier) == ["100000000"])
        #expect(deep.first?.awardedAt == days[2].window.start)
    }

    @Test func `Project Hopper and Model Hopper count a single day`() throws {
        let days = try ActivityTests.days([5, 5])
        let projects: [[Int64: Int64]] = [Dictionary(uniqueKeysWithValues: (1...10).map { (Int64($0), 1) }), [1: 1]]
        let earned = Achievement.earned(Self.history(days, projects: projects, models: [2, 5]))
        #expect(earned.filter { $0.kind == .projectHopper }.map(\.tier) == ["5", "10"])
        #expect(earned.first { $0.kind == .modelHopper }?.awardedAt == days[1].window.start)
    }

    @Test func `Old Friend is one project worked in a year apart`() throws {
        let days = try ActivityTests.days(Array(repeating: 5, count: 367))
        var projects = Array(repeating: [Int64: Int64](), count: 367)
        projects[0] = [7: 1]
        projects[366] = [7: 1]
        let earned = Achievement.earned(Self.history(days, projects: projects))
        #expect(earned.first { $0.kind == .oldFriend }?.awardedAt == days[365].window.start
                || earned.first { $0.kind == .oldFriend }?.awardedAt == days[366].window.start)
    }

    @Test func `Comeback counts the days away before an active day`() throws {
        let tokens: [Int64] = [5] + Array(repeating: 0, count: 95) + [5]
        let earned = Achievement.earned(Self.history(try ActivityTests.days(tokens)))
        #expect(earned.filter { $0.kind == .comeback }.map(\.tier) == ["30", "90"])
        #expect(earned.first { $0.kind == .comeback }?.value == 95)
    }

    @Test func `Cache Master holds 90% for a busy week, then whole months running`() throws {
        let hot = try TokenCounts(input: 50_000, cachedInput: 950_000, output: 1_000)
        // October through December, judged in January.
        let earned = Achievement.earned(Self.history(Self.days(Array(repeating: hot, count: 93))))
        let master = earned.filter { $0.kind == .cacheMaster }
        #expect(master.map(\.tier) == ["7", "30", "90"])
        let decemberEnd = Self.calendar.window(for: LocalDay(year: 2027, month: 1, day: 1)).start
        #expect(master.last?.awardedAt == decemberEnd)
    }

    // MARK: Streaks, secrets, landmarks

    @Test func `Rest Day is a whole day off that a freeze carried`() throws {
        // A week earns a freeze; a short day spends it on Saved by a Freeze,
        // and only a day with no usage at all is a Rest Day.
        let short = try ActivityTests.days(Array(repeating: 5, count: 7) + [5, 5], quarterHours: Array(repeating: 4, count: 7) + [1, 4])
        let earned = Achievement.earned(Self.history(short))
        #expect(earned.contains { $0.kind == .freezeUsed })
        #expect(!earned.contains { $0.kind == .restDay })
        let off = try ActivityTests.days(Array(repeating: 5, count: 7) + [0, 5])
        #expect(Achievement.earned(Self.history(off)).first { $0.kind == .restDay }?.awardedAt == off[7].window.start)
    }

    @Test func `Midnight Crossing is a session running as the new year arrives`() {
        let newYear = Self.calendar.window(for: LocalDay(year: 2027, month: 1, day: 1)).start
        let across = AchievementHistory.Session(startedAt: newYear.adding(seconds: -1_800), endedAt: newYear.adding(seconds: 600),
                                                provider: .codex)
        let before = AchievementHistory.Session(startedAt: newYear.adding(seconds: -7_200), endedAt: newYear.adding(seconds: -60),
                                                provider: .codex)
        let earned = { (session: AchievementHistory.Session) in
            Achievement.earned(Self.history([], sessions: [session], now: newYear.adding(seconds: 86_400)))
        }
        #expect(earned(across).first { $0.kind == .midnightCrossing }?.awardedAt == newYear)
        #expect(!earned(before).contains { $0.kind == .midnightCrossing })
    }

    @Test func `the stack passes a landmark the day its tokens stand taller, and the climb flags that day`() throws {
        let pisa = try #require(Landmark.all.first)
        // 56 m of paper is about 364M tokens.
        #expect(pisa.tokens == PaperStack.tokens(meters: 56))
        #expect(abs(PaperStack.meters(tokens: pisa.tokens) - 56) < 0.001)
        let days = try ActivityTests.days(Array(repeating: pisa.tokens / 3 + 1, count: 4))
        let earned = Achievement.earned(Self.history(days))
        #expect(earned.first { $0.kind == .landmark }?.awardedAt == days[2].window.start)
        let climb = Climb(days: days)
        #expect(climb.passed["pisa"] == days[2].window.start)
        #expect(climb.next?.id == "liberty")
        #expect(climb.points.count == 4 && climb.points.last?.meters == climb.meters)
    }

    @Test func `the landmarks rise without a long gap, and what flies is above what stands`() {
        for (lower, higher) in zip(Landmark.all, Landmark.all.dropFirst()) {
            #expect(higher.meters > lower.meters)
            #expect(higher.meters / lower.meters <= 2.2, "\(lower.name) to \(higher.name)")
        }
        let firstFlying = Landmark.all.firstIndex { $0.silhouette.flies } ?? Landmark.all.endIndex
        let flying = Landmark.all[firstFlying...].map(\.silhouette.flies)
        #expect(!flying.contains(false))
    }

    @Test func `the pace over the last month says when the next landmark is reached`() throws {
        // A metre a day: 1 m of paper is 6.5M tokens.
        let days = try ActivityTests.days(Array(repeating: PaperStack.tokens(meters: 1), count: 40))
        let climb = Climb(days: days)
        let pace = try #require(climb.pace())
        #expect(abs(pace - 1) < 0.001)
        #expect(climb.lastPassed == nil && climb.next?.id == "pisa")
        let arrival = try #require(climb.arrival(pace: pace))
        let daysAway = Double(arrival.epochSeconds - days[39].window.start.epochSeconds) / 86_400
        #expect(abs(daysAway - (56 - climb.meters)) < 0.01)
        // Under a week of history gives no pace.
        #expect(Climb(days: Array(days.prefix(5))).pace() == nil)
    }

    @Test func `the climb as of a moment stands part way between its days, with only what was passed by then`() throws {
        let pisa = try #require(Landmark.all.first)
        let days = try ActivityTests.days(Array(repeating: pisa.tokens / 3 + 1, count: 4))
        let climb = Climb(days: days)
        let start = days[0].window.start
        // Before the first day, the climb stands at its first day.
        #expect(climb.asOf(start.adding(seconds: -86_400)) == climb.asOf(start))
        #expect(climb.asOf(start).points.count == 1)
        // Half way through the second day, half way between the first two heights.
        let midway = climb.asOf(start.adding(seconds: 86_400 + 43_200))
        #expect(abs(midway.meters - (climb.points[1].meters + climb.points[2].meters) / 2) < 0.001)
        #expect(midway.points.last?.meters == midway.meters)
        #expect(midway.passed.isEmpty && midway.next?.id == "pisa")
        // At the last day it is the whole climb.
        #expect(climb.asOf(days[3].window.start) == climb)
    }

    @Test func `a long history is thinned for drawing, keeping its last day`() throws {
        let days = try ActivityTests.days(Array(repeating: 1_000, count: 500))
        let climb = Climb(days: days, maximumPoints: 100)
        #expect(climb.points.count <= 101)
        #expect(climb.points.last?.at == days.last?.window.start)
    }

    @Test func `Alpha Tester belongs to the 0.1 releases, and the anniversary to a year of tracking`() throws {
        let days = try ActivityTests.days([5])
        #expect(Achievement.earned(Self.history(days, version: "0.1.0")).contains { $0.kind == .alphaTester })
        #expect(!Achievement.earned(Self.history(days, version: "0.2.0")).contains { $0.kind == .alphaTester })
        let later = Self.history(days, now: days[0].window.start.adding(seconds: 366 * 86_400))
        #expect(Achievement.earned(later).contains { $0.kind == .anniversary })
    }
}
