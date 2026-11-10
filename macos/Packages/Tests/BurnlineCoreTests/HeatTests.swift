//
//  HeatTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Testing

struct HeatTests {
    static func dollars(_ value: Int64) -> Nanodollars { Nanodollars(raw: value * Nanodollars.perDollar) }

    /// Five-minute stretches costing $1 to $100: $12 to $1,200 an hour.
    static let history = (1...100).map { Int64($0) * Nanodollars.perDollar }

    @Test func `the scale comes from this history's own busy stretches`() {
        let scale = HeatScale(spanCosts: Self.history)
        #expect(scale.typical == Self.dollars(50 * 12))
        #expect(scale.busy == Self.dollars(75 * 12))
        #expect(scale.peak == Self.dollars(95 * 12))
    }

    @Test func `too little history keeps the starting scale`() {
        #expect(HeatScale(spanCosts: Array(Self.history.prefix(HeatScale.fewest - 1))) == .starting)
        #expect(HeatScale(spanCosts: []) == .starting)
    }

    @Test func `heat climbs a third at each point and stops at a peak`() {
        let scale = HeatScale(typical: Self.dollars(10), busy: Self.dollars(20), peak: Self.dollars(40))
        #expect(scale.heat(costPerHour: .zero) == 0)
        #expect(scale.heat(costPerHour: Self.dollars(5)) == 1.0 / 6)
        #expect(scale.heat(costPerHour: Self.dollars(10)) == 1.0 / 3)
        #expect(scale.heat(costPerHour: Self.dollars(30)) == 5.0 / 6)
        #expect(scale.heat(costPerHour: Self.dollars(40)) == 1)
        #expect(scale.heat(costPerHour: Self.dollars(400)) == 1)
    }

    @Test func `a flat history still gives a usable scale`() {
        let scale = HeatScale(spanCosts: Array(repeating: Nanodollars.perDollar, count: 40))
        #expect(scale.heat(costPerHour: Self.dollars(12)) == 1)
        #expect(scale.heat(costPerHour: Self.dollars(6)) == 1.0 / 6)
    }

    @Test func `the stages split heat where the scale's points are`() {
        #expect(HeatStage(heat: 0) == .idle)
        #expect(HeatStage(heat: 0.2) == .warm)
        #expect(HeatStage(heat: 0.7) == .hot)
        #expect(HeatStage(heat: 1) == .blazing)
    }
}
