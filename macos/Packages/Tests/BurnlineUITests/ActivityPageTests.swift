//
//  ActivityPageTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
@testable import BurnlineUI
import Foundation
import Testing

/// How the heatmap lays tracked days out in weeks.
struct ActivityPageTests {
    /// Monday 2 November 2026 in India.
    static let now = DashboardTests.now
    static let calendar = DashboardTests.india

    /// The last `count` days, each with one event.
    static func tracked(_ count: Int) -> [ActivityDay] {
        calendar.days(endingWith: now, count: count).map { day in
            ActivityDay(day: day, window: calendar.window(for: day),
                        totals: UsageTotals(events: 1, tokens: .zero, cost: Nanodollars(raw: 0), unpricedEvents: 0,
                                            cacheSavings: CacheSavings()),
                        sessions: 1, providers: [:], activeQuarterHours: StreakRule.baseQuarterHours)
        }
    }

    @Test func `closing an arrival celebrates only medals reached in its queue`() {
        let medals = ["10", "100", "1000"].map {
            Achievement(kind: .sessions, tier: $0, value: 1, awardedAt: Self.now)
        }
        var progress = MedalArrivalProgress(achievements: medals)
        #expect(progress.current == medals[0])
        #expect(progress.shown == [medals[0]])
        progress.advance()
        #expect(progress.current == medals[1])
        #expect(progress.shown == Array(medals.prefix(2)))
        progress.advance()
        progress.advance()
        #expect(progress.current == medals[2] && !progress.more)
        #expect(progress.shown == medals)
        let empty = MedalArrivalProgress(achievements: [])
        #expect(empty.current == nil && empty.shown.isEmpty && !empty.more)
    }

    @Test func `weeks start on the user's first weekday and end with today's`() {
        let grid = HeatmapGrid(days: Self.tracked(10), range: .threeMonths, calendar: Self.calendar, now: Self.now)
        // 91 days from Tuesday 4 August, after one blank Monday.
        #expect(grid.weeks.count == 14)
        #expect(grid.weeks.allSatisfy { $0.count == 7 })
        #expect(grid.weeks[0][0] == nil)
        #expect(grid.weeks[0][1]?.day == LocalDay(year: 2026, month: 8, day: 4))
        #expect(grid.weeks[13][0]?.day == LocalDay(year: 2026, month: 11, day: 2))
        #expect(grid.weeks[13][1...].allSatisfy { $0 == nil })
    }

    @Test func `EC-U2 days before tracking began are drawn apart from tracked ones`() {
        let grid = HeatmapGrid(days: Self.tracked(10), range: .threeMonths, calendar: Self.calendar, now: Self.now)
        let cells = grid.weeks.joined().compactMap { $0 }
        #expect(cells.count == 91)
        #expect(cells.filter { if case .tracked = $0 { true } else { false } }.count == 10)
        #expect(grid.tracked.count == 10)
        if case .untracked = cells[80] {} else { Issue.record("the eleventh day back is before tracking") }
    }

    @Test func `a day splits between providers by the measure shown, and sessions split by events`() throws {
        let day = try #require(Self.tracked(1).first)
        let split = ActivityDay(day: day.day, window: day.window,
                                totals: try DashboardTests.totals(events: 4, tokens: 400, dollars: 4), sessions: 2,
                                providers: [.codex: try DashboardTests.totals(events: 3, tokens: 100, dollars: 3),
                                            .claudeCode: try DashboardTests.totals(events: 1, tokens: 300, dollars: 1),
                                            .cursor: try DashboardTests.totals(events: 0, tokens: 0, dollars: 0)],
                                activeQuarterHours: 6)
        let tokens = HeatmapMetric.tokens.parts(split)
        #expect(tokens.map(\.provider) == [.claudeCode, .codex])
        #expect(tokens.map(\.share) == [0.75, 0.25])
        #expect(HeatmapMetric.sessions.parts(split).map(\.provider) == [.codex, .claudeCode])
        #expect(HeatmapMetric.cost.parts(Self.tracked(1)[0]).isEmpty)
    }

    @Test func `all time spans exactly the tracked days`() {
        let grid = HeatmapGrid(days: Self.tracked(30), range: .all, calendar: Self.calendar, now: Self.now)
        #expect(grid.weeks.joined().compactMap { $0 }.count == 30)
    }

    @Test func `the climb's curve is smooth but never dips, and ends where the stack stands`() {
        // A stair: quiet days, then a busy one. Screen y falls as the stack rises.
        let stair = (0..<30).map { CGPoint(x: CGFloat($0) * 10, y: 200 - CGFloat($0 / 5) * 30) }
        let points = ClimbCurve.thinned(stair, spacing: 18)
        #expect(points.first == stair.first && points.last == stair.last)
        #expect(zip(points, points.dropFirst()).allSatisfy { $1.x - $0.x >= 9 })
        let curve = ClimbCurve.monotone(through: points)
        var heights: [CGFloat] = []
        for step in 0...200 {
            if let point = curve.trimmedPath(from: 0, to: CGFloat(step) / 200).currentPoint { heights.append(point.y) }
        }
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $1 <= $0 + 0.01 })
        #expect(curve.currentPoint == stair.last)
    }

    @Test func `a shelf opens on the eight medals around where the climb stands`() {
        let badges = AchievementBadge.catalogue(providers: [.claudeCode]).filter { $0.kind == .landmark }
        let ids = { (slice: ArraySlice<AchievementBadge>) in slice.map(\.tier) }
        // Twelve earned: the latest four, then the next four.
        let middle = AchievementShelf.window(badges, shown: 8) { badges.firstIndex(of: $0)! < 12 }
        #expect(ids(middle) == badges[8..<16].map(\.tier))
        // Nothing earned yet: the first eight; everything earned: the last eight.
        #expect(ids(AchievementShelf.window(badges, shown: 8) { _ in false }) == badges.prefix(8).map(\.tier))
        #expect(ids(AchievementShelf.window(badges, shown: 8) { _ in true }) == badges.suffix(8).map(\.tier))
        // A short shelf shows everything.
        #expect(AchievementShelf.window(Array(badges.prefix(5)), shown: 8) { _ in true }.count == 5)
    }

    @Test func `the climb's figure is said in every countable thing, categories taking turns, each with a line`() throws {
        let corpus = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "shared/corpus/comparisons.json")
        let engine = ComparisonEngine(corpus: try ComparisonCorpus.load(from: corpus))
        // About 1,200 m of paper.
        let ways = ReelFigure.all(tokens: 7_800_000_000, meters: 1_200, engine: engine)
        #expect(ways.first?.unit == "of printed paper")
        #expect(ways.count > 15)
        // Each thing once, and each with a line.
        #expect(Set(ways.map(\.unit)).count == ways.count)
        #expect(ways.dropFirst(2).allSatisfy { $0.quip != nil })
        // Nothing said as less than one of it.
        #expect(!ways.contains { $0.figure.hasPrefix("0") })
        // Without comparisons, only the height.
        #expect(ReelFigure.all(tokens: 7_800_000_000, meters: 1_200, engine: nil).count == 1)
    }

    @Test func `interleaving takes each group in turn`() {
        let items = ["a1", "a2", "a3", "b1", "c1", "c2"]
        #expect(ReelFigure.interleaved(items) { String($0.prefix(1)) } == ["a1", "b1", "c1", "a2", "c2", "a3"])
    }

    @Test func `found medals show the finest first, one from each category before a second from any`() {
        let catalogue = AchievementBadge.catalogue(providers: ProviderKey.trackable)
        let day = Self.now
        // Every volume rung, and the first sessions.
        let volume = catalogue.filter { $0.category == .volume }.compactMap { badge in
            badge.tier.map { Achievement(kind: badge.kind, tier: $0, value: Int64($0) ?? 0, awardedAt: day) }
        }
        let firsts = ProviderKey.trackable.map {
            Achievement(kind: .firstSession, tier: $0.rawValue, provider: $0, value: 0, awardedAt: day)
        }
        let picked = FoundMedals.significant(volume + firsts, count: 3)
        #expect(picked.count == 3)
        // The finest volume medal leads, and the second category gets a place.
        #expect(picked[0].badge.metal == volume.compactMap { a in catalogue.first { $0.matches(a) }?.metal }.max())
        #expect(Set(picked.map(\.badge.category)).count >= 2)
        #expect(Set(picked.map(\.badge.id)).count == picked.count)
        #expect(FoundMedals.significant([], count: 3).isEmpty)
    }
}
