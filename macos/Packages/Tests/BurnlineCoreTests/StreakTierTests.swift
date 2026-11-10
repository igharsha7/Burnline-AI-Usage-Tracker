//
//  StreakTierTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Testing

/// The tiers a streak passes, and the span its ring fills.
struct StreakTierTests {
    @Test func `the tiers rise, and the majors are 30, 100 and 500 days`() {
        let days = StreakTier.all.map(\.days)
        #expect(days == days.sorted() && Set(days).count == days.count)
        #expect(StreakTier.all.filter(\.isMajor).map(\.days) == [30, 100, 500])
    }

    @Test func `the ring fills toward the next tier and starts empty on reaching it`() {
        let none = StreakProgress(days: 0)
        #expect(none.tierIndex == nil && none.next?.days == 1 && none.fraction == 0)

        let six = StreakProgress(days: 6)
        #expect(six.tier?.name == "Pilot Light" && six.daysToNext == 1)
        #expect(six.spanStart == 1 && six.spanEnd == 7)

        let seven = StreakProgress(days: 7)
        #expect(seven.tier?.name == "Hot Reload" && seven.fraction == 0)

        for days in 0...900 {
            let progress = StreakProgress(days: days)
            #expect(progress.fraction >= 0 && progress.fraction < 1, "\(days) days")
        }
    }

    @Test func `past the last tier the ring laps every hundred days`() {
        let reached = StreakProgress(days: 700)
        #expect(reached.next == nil && reached.lap == 1 && reached.spanStart == 700 && reached.spanEnd == 800)
        let later = StreakProgress(days: 845)
        #expect(later.lap == 2 && later.spanStart == 800 && later.fraction == 0.45)
        #expect(StreakProgress(days: 699).lap == nil)
    }
}
