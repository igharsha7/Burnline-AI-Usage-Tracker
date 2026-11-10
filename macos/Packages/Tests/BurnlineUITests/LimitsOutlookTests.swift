//
//  LimitsOutlookTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

@testable import BurnlineUI
import Testing

/// How the Limits page sums up a provider's windows.
struct LimitsOutlookTests {
    static func outlook(_ name: String = "Weekly", used: Double, elapsed: Double?, lead: Int64? = nil) -> WindowOutlook {
        WindowOutlook(name: name, used: used, elapsed: elapsed, lead: lead)
    }

    @Test func `each window stands by its use against the time gone`() {
        #expect(Self.outlook(used: 100, elapsed: 0.2).standing == .reached)
        #expect(Self.outlook(used: 40, elapsed: 0.2, lead: 600).standing == .runsOut)
        #expect(Self.outlook(used: 1, elapsed: 0.5).standing == .idle)
        #expect(Self.outlook(used: 50, elapsed: 0.3).standing == .ahead)
        #expect(Self.outlook(used: 35, elapsed: 0.3).standing == .onPace)
        #expect(Self.outlook(used: 10, elapsed: 0.6).standing == .under)
        #expect(Self.outlook(used: 30, elapsed: nil).standing == .onPace)
    }

    @Test func `the headline speaks of the most pressing window`() {
        let calm = Self.outlook("5-hour", used: 10, elapsed: 0.6)
        #expect(WindowOutlook.headline([calm]) == "Comfortably under pace")
        let ahead = Self.outlook(used: 50, elapsed: 0.3)
        #expect(WindowOutlook.headline([calm, ahead]) == "Running ahead on the weekly limit")
        #expect(WindowOutlook.focus([calm, ahead]) == 1)
        let out = Self.outlook("5-hour", used: 60, elapsed: 0.4, lead: 2 * 3_600)
        #expect(WindowOutlook.headline([out, ahead]) == "5-hour runs out 2h early")
        #expect(WindowOutlook.headline([out, Self.outlook(used: 100, elapsed: 0.9)]) == "Weekly limit reached")
        #expect(WindowOutlook.headline([]) == nil)
    }
}
