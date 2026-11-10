//
//  LimitHistoryTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Testing

/// The Limits page's history of one window: its readings and the windows before it.
struct LimitHistoryTests {
    static func snapshot(_ key: String = "five_hour", at seconds: Int64, percent: Double?,
                         start: Int64 = 10_000) -> QuotaSnapshot {
        QuotaSnapshot(provider: .codex, key: key, name: "5-hour", scope: .account,
                      observedAt: Timestamp(epochSeconds: seconds), used: nil, remaining: nil, limit: nil, unit: nil,
                      percentageUsed: percent, windowStartedAt: Timestamp(epochSeconds: start),
                      resetAt: Timestamp(epochSeconds: start + 18_000), status: .healthy, source: "test")
    }

    static func cycle(_ key: String = "five_hour", end: Int64, peak: Double,
                      provider: ProviderKey = .codex) -> AchievementHistory.QuotaCycle {
        AchievementHistory.QuotaCycle(provider: provider, key: key, start: Timestamp(epochSeconds: end - 18_000),
                                      end: Timestamp(epochSeconds: end), peak: peak, isConfirmedClosed: true)
    }

    @Test func `a window's readings start at its start, are its own, and are in order`() {
        let window = Self.snapshot(at: 12_000, percent: 30)
        let history = LimitHistory(window: window, observations: [
            Self.snapshot(at: 11_000, percent: 20), Self.snapshot(at: 9_000, percent: 90),
            Self.snapshot("weekly", at: 10_500, percent: 50), Self.snapshot(at: 10_200, percent: 5),
            Self.snapshot(at: 11_500, percent: nil),
        ], cycles: [])
        #expect(history.readings.map(\.percent) == [5, 20])
    }

    @Test func `earlier windows are this quota's, ended by the window's start, newest last and capped`() {
        let window = Self.snapshot(at: 12_000, percent: 30, start: 1_000_000)
        var cycles = (0..<20).map { Self.cycle(end: 900_000 - Int64($0) * 18_000, peak: Double($0)) }
        cycles.append(Self.cycle(end: 1_018_000, peak: 99))                       // the open window itself
        cycles.append(Self.cycle("weekly", end: 950_000, peak: 98))
        cycles.append(Self.cycle(end: 950_000, peak: 97, provider: .claudeCode))
        let history = LimitHistory(window: window, observations: [], cycles: cycles)
        #expect(history.past.count == LimitHistory.pastLimit)
        #expect(history.past.last?.peak == 0)
        #expect(history.past.map(\.end) == history.past.map(\.end).sorted())
    }

    @Test func `capped counts windows that reached the limit within the span, and the average peak`() {
        let now = Timestamp(epochSeconds: 100 * 86_400)
        let history = LimitHistory(readings: [], past: [
            Self.cycle(end: 10 * 86_400, peak: 100),          // too long ago
            Self.cycle(end: 90 * 86_400, peak: 100),
            Self.cycle(end: 95 * 86_400, peak: 40),
            Self.cycle(end: 99 * 86_400, peak: 112),
        ])
        #expect(history.capped(within: 30 * 86_400, now: now) == 2)
        #expect(history.averagePeak == 88)
        #expect(LimitHistory(readings: [], past: []).averagePeak == nil)
    }
}
