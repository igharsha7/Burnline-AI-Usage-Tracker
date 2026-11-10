//
//  BurnRateTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import Testing

struct BurnRateTests {
    /// 2 November 2026, 12:00 UTC.
    static let now = Timestamp(epochSeconds: 1_793_620_800)
    static let windowStart = now.adding(seconds: -2 * 3_600)

    /// A 5-hour window's figure `minutesAgo` before now.
    static func point(_ minutesAgo: Int64, _ percent: Double, start: Timestamp? = windowStart,
                      reset: Timestamp? = now.adding(seconds: 6 * 3_600)) -> QuotaSnapshot {
        QuotaSnapshot(provider: .codex, key: "five_hour", name: "5-hour", scope: .account,
                      observedAt: now.adding(seconds: -minutesAgo * 60), used: nil, remaining: nil, limit: nil,
                      unit: "percent", percentageUsed: percent, windowStartedAt: start, resetAt: reset,
                      status: QuotaStatus(percentUsed: percent), source: "test")
    }

    @Test func `a steady climb gives its rate and when the window runs out`() throws {
        // One point every five minutes for half an hour: 12% an hour.
        let points = (0...6).map { Self.point(Int64(30 - $0 * 5), 40 + Double($0)) }
        let rate = try BurnRateEstimator.estimate(points, at: Self.now).get()
        #expect(abs(rate.percentPerHour - 12) < 0.001)
        // 54 points left at 12 an hour is four and a half hours, an hour and a
        // half before the reset.
        let exhaustion = try #require(rate.projectedExhaustion)
        #expect(abs(exhaustion.seconds(since: Self.now) - 16_200) <= 1)
        #expect(abs((rate.exhaustionLead ?? 0) - 5_400) <= 1)
    }

    @Test func `a window that resets before it would run out projects nothing`() throws {
        let points = (0...6).map { Self.point(Int64(30 - $0 * 5), 40 + Double($0), reset: Self.now.adding(seconds: 3_600)) }
        let rate = try BurnRateEstimator.estimate(points, at: Self.now).get()
        #expect(rate.percentPerHour > 0 && rate.projectedExhaustion == nil && rate.exhaustionLead == nil)
    }

    @Test(arguments: [true, false])
    func `EC-Q1 a banked reset's drop is discarded, never averaged into a negative rate`(knownStart: Bool) throws {
        // 80% to 94% in the old window, then a banked reset and a new window
        // climbing from 0%, with or without a reported window start.
        let newStart: Timestamp? = knownStart ? Self.now.adding(seconds: -20 * 60) : nil
        let old: Timestamp? = knownStart ? Self.windowStart : nil
        let before = [Self.point(50, 80, start: old), Self.point(40, 85, start: old), Self.point(30, 94, start: old)]
        let after = [Self.point(20, 0, start: newStart), Self.point(10, 2, start: newStart), Self.point(0, 4, start: newStart)]
        let rate = try BurnRateEstimator.estimate(before + after, at: Self.now).get()
        #expect(abs(rate.percentPerHour - 12) < 0.001)

        // Just after the drop there is too little of the new window to say.
        #expect(BurnRateEstimator.estimate(before + [Self.point(25, 0, start: newStart)], at: Self.now)
            == .failure(.notEnoughData))
    }

    @Test func `EC-Q3 a stale figure gives no rate`() {
        let points = [Self.point(60, 40), Self.point(31, 45)]
        #expect(BurnRateEstimator.estimate(points, at: Self.now) == .failure(.stale))
    }

    @Test func `too little observed gives no rate`() {
        #expect(BurnRateEstimator.estimate([], at: Self.now) == .failure(.notEnoughData))
        #expect(BurnRateEstimator.estimate([Self.point(0, 40, start: nil)], at: Self.now) == .failure(.notEnoughData))
        #expect(BurnRateEstimator.estimate([Self.point(5, 40, start: nil), Self.point(0, 41, start: nil)], at: Self.now)
            == .failure(.notEnoughData))
    }

    @Test func `an idle window with no known start has a zero rate and no projection`() throws {
        let points = [Self.point(30, 50, start: nil), Self.point(0, 50, start: nil)]
        let rate = try BurnRateEstimator.estimate(points, at: Self.now).get()
        #expect(rate.percentPerHour == 0 && rate.basis == .recent && rate.projectedExhaustion == nil)
    }

    @Test func `a pause does not hide a window on course to run out`() throws {
        // A week's window, 33 hours in and 49% used, idle for the last hour:
        // about 1.5% an hour, so the rest runs out some four days early.
        let start = Self.now.adding(seconds: -33 * 3_600), reset = start.adding(seconds: 7 * 86_400)
        let points = [Self.point(50, 49, start: start, reset: reset), Self.point(0, 49, start: start, reset: reset)]
        let rate = try BurnRateEstimator.estimate(points, at: Self.now).get()
        #expect(rate.basis == .window)
        #expect(abs(rate.percentPerHour - 49.0 / 33) < 0.001)
        let lead = try #require(rate.exhaustionLead)
        #expect(lead > 4 * 86_400 && lead < 5 * 86_400)
    }

    @Test func `one fresh reading projects from the window's average`() throws {
        // Two hours into a window at 40%: 20% an hour, out in three hours,
        // three hours before the reset. Right after a relaunch there is no
        // recent history to fit.
        let rate = try BurnRateEstimator.estimate([Self.point(0, 40)], at: Self.now).get()
        #expect(rate.basis == .window && abs(rate.percentPerHour - 20) < 0.001)
        #expect(abs((rate.exhaustionLead ?? 0) - 3 * 3_600) <= 1)
    }

    @Test func `the average waits until a tenth of the window has passed`() {
        // Twenty minutes into a week, 5% looks like a runaway; it is too early to say.
        let start = Self.now.adding(seconds: -20 * 60), reset = start.adding(seconds: 7 * 86_400)
        #expect(BurnRateEstimator.estimate([Self.point(0, 5, start: start, reset: reset)], at: Self.now)
            == .failure(.notEnoughData))
    }

    @Test func `usage now outweighs the window's average while it is active`() throws {
        // Fast earlier in the window, slower now: the rate is today's.
        let points = (0...6).map { Self.point(Int64(30 - $0 * 5), 80 + Double($0) * 0.5) }
        let rate = try BurnRateEstimator.estimate(points, at: Self.now).get()
        #expect(rate.basis == .recent && abs(rate.percentPerHour - 6) < 0.001)
    }

    @Test func `a small fall is rounding: the rate is zero, never negative`() throws {
        let points = [Self.point(30, 50, start: nil), Self.point(0, 49, start: nil)]
        let rate = try BurnRateEstimator.estimate(points, at: Self.now).get()
        #expect(rate.percentPerHour == 0)
    }

    @Test func `one short burst moves the rate without dominating it`() throws {
        // Flat for 55 minutes, then five points in the last five: 60% an hour
        // if the last interval alone were taken.
        let points = (0...11).map { Self.point(Int64(60 - $0 * 5), 40) } + [Self.point(0, 45)]
        let rate = try BurnRateEstimator.estimate(points, at: Self.now).get()
        #expect(rate.percentPerHour > 0 && rate.percentPerHour < 20)
    }

    @Test func `points older than the lookback are left out`() throws {
        // A fast climb two hours ago, flat since.
        let points = [Self.point(130, 10, start: nil), Self.point(120, 40, start: nil), Self.point(45, 40, start: nil),
                      Self.point(0, 40, start: nil)]
        let rate = try BurnRateEstimator.estimate(points, at: Self.now).get()
        #expect(rate.percentPerHour == 0)
    }
}

struct CountdownTests {
    @Test func `compact countdowns keep the two largest units`() {
        #expect(Countdown.compact(30) == "under a minute")
        #expect(Countdown.compact(52 * 60) == "52m")
        #expect(Countdown.compact(2 * 3_600 + 48 * 60 + 59) == "2h 48m")
        #expect(Countdown.compact(3 * 3_600) == "3h")
        #expect(Countdown.compact(86_400 + 4 * 3_600 + 10 * 60) == "1d 4h")
    }

    @Test func `a countdown changes text hourly in days, each minute below, and at zero`() {
        #expect(Countdown.nextChange(remaining: 4 * 86_400 + 18 * 3_600 + 125) == 126)
        #expect(Countdown.nextChange(remaining: 86_400) == 1)
        #expect(Countdown.nextChange(remaining: 2 * 3_600 + 48 * 60 + 30) == 31)
        #expect(Countdown.nextChange(remaining: 60) == 1)
        #expect(Countdown.nextChange(remaining: 42) == 42)
        #expect(Countdown.nextChange(remaining: 0) == nil)
        // Each redraw lands where the text has changed.
        for remaining: Int64 in [61, 3_599, 86_399, 90_000, 400_000] {
            let wait = Countdown.nextChange(remaining: remaining)!
            #expect(Countdown.compact(remaining - wait) != Countdown.compact(remaining))
            #expect(Countdown.compact(remaining - wait + 1) == Countdown.compact(remaining))
        }
    }

    @Test func `spoken durations read as a sentence`() {
        #expect(Countdown.spoken(60) == "1 minute")
        #expect(Countdown.spoken(48 * 60) == "48 minutes")
        #expect(Countdown.spoken(2 * 3_600 + 10 * 60) == "2 hours 10 minutes")
        #expect(Countdown.spoken(9 * 3_600 + 20 * 60) == "9 hours")
        #expect(Countdown.spoken(3 * 86_400) == "3 days")
    }

    @Test func `a moment names its day only when it is not today`() {
        let calendar = LocalCalendar(timeZone: .gmt, firstWeekday: .monday)
        let locale = Locale(identifier: "en_US")
        let now = BurnRateTests.now
        #expect(Countdown.moment(now.adding(seconds: 5 * 3_600), now: now, calendar: calendar, locale: locale).plain
            == "5:00 PM")
        #expect(Countdown.moment(now.adding(seconds: 21 * 3_600), now: now, calendar: calendar, locale: locale).plain
            == "9:00 AM tomorrow")
        #expect(Countdown.moment(now.adding(seconds: 3 * 86_400), now: now, calendar: calendar, locale: locale).plain
            == "Thu 12:00 PM")
        #expect(Countdown.moment(now.adding(seconds: 10 * 86_400), now: now, calendar: calendar, locale: locale).plain
            == "Nov 12 at 12:00 PM")
    }
}

extension String {
    /// Foundation sets a time's AM and PM apart with a narrow no-break space.
    var plain: String { replacingOccurrences(of: "\u{202F}", with: " ") }
}
