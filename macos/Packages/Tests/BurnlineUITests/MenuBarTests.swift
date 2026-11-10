//
//  MenuBarTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
@testable import BurnlineServices
@testable import BurnlineUI
import Foundation
import SwiftUI
import Testing

/// The menu-bar title in each of its modes, and the figures it writes.
struct MenuBarTests {
    /// 2 November 2026, 12:00 UTC.
    static let now = Timestamp(epochSeconds: 1_793_620_800)
    static let usLocale = Locale(identifier: "en_US")

    static let today = TodayStatus(tokens: 18_600_000, cost: Nanodollars(raw: 12_840_000_000), costCoverage: 1,
                                   endsAt: now.adding(seconds: 12 * 3_600))

    static func window(_ provider: ProviderKey, _ key: String, _ name: String, _ percent: Double,
                       resetIn: Int64, length: Int64) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, key: key, name: name, scope: .account, observedAt: now, used: nil,
                      remaining: nil, limit: nil, unit: "percent", percentageUsed: percent,
                      windowStartedAt: now.adding(seconds: resetIn - length), resetAt: now.adding(seconds: resetIn),
                      status: QuotaStatus(percentUsed: percent), source: "test")
    }

    static let quotas = [
        ProviderQuotaState(
            provider: .codex, plan: "plus",
            windows: [window(.codex, "five_hour", "5-hour", 78, resetIn: 6_180, length: 18_000),
                      window(.codex, "weekly", "Weekly", 61, resetIn: 412_000, length: 604_800)],
            bankedResets: [BankedReset(provider: .codex, sourceResetID: "rc_1", appliesToQuotaKey: "codex",
                                       grantedAt: nil, expiresAt: now.adding(seconds: 75_600), consumedAt: nil,
                                       status: .held, source: "test", observedAt: now)],
            health: .ok, lastSuccess: now,
            burnRates: ["five_hour": .success(BurnRate(percentPerHour: 18, percentUsed: 78, observedAt: now,
                                                       resetAt: now.adding(seconds: 6_180),
                                                       projectedExhaustion: now.adding(seconds: 4_400)))]),
        ProviderQuotaState(
            provider: .claudeCode, plan: "max",
            windows: [window(.claudeCode, "five_hour", "5-hour", 71, resetIn: 7_680, length: 18_000),
                      window(.claudeCode, "seven_day", "Weekly", 53, resetIn: 300_000, length: 604_800)],
            bankedResets: [], health: .ok, lastSuccess: now),
    ]

    @Test(arguments: [
        (MenuBarTitleMode.iconOnly, nil), (.todayCost, "$12.84"), (.todayTokens, "18.6M"),
        (.highestQuota, "78%"), (.providerQuotas, "C78 A71"),
    ] as [(MenuBarTitleMode, String?)])
    func `every title mode writes its figure`(mode: MenuBarTitleMode, expected: String?) {
        #expect(mode.text(today: Self.today, quotas: Self.quotas, locale: Self.usLocale) == expected)
    }

    @Test func `a title waits for figures rather than showing zero`() {
        for mode in MenuBarTitleMode.allCases {
            #expect(mode.text(today: nil, quotas: [], locale: Self.usLocale) == nil)
        }
    }

    @Test func `token counts shorten to one decimal`() {
        #expect(Format.tokens(842) == "842")
        #expect(Format.tokens(12_400) == "12.4K")
        #expect(Format.tokens(1_000_000) == "1M")
        #expect(Format.tokens(999_999) == "1M")
        #expect(Format.tokens(18_640_000) == "18.6M")
        #expect(Format.tokens(1_200_000_000) == "1.2B")
    }

    @Test func `EC-U3 a partly priced cost says how much is priced`() {
        #expect(TodayHeader.costNote(1) == "Equivalent cost at API prices")
        #expect(TodayHeader.costNote(0.926) == "Equivalent cost · 92% of events priced")
    }

    @Test func `a provider with nothing to show has no section`() {
        let model = StatusModel()
        let missing = ProviderQuotaState(provider: .cursor, plan: nil, windows: [], bankedResets: [],
                                         health: .unavailable(reason: "Cursor is not installed."), lastSuccess: nil)
        model.show(today: Self.today, quotas: Self.quotas + [missing], live: nil)
        #expect(model.visibleQuotas.map(\.provider) == [.codex, .claudeCode])
    }

    @Test func `EC-U7 very long session, project and model names truncate instead of growing the popover`() throws {
        func height(naming name: String) throws -> CGFloat {
            let live = LiveActivity(provider: .codex, model: name, project: name,
                                    tokensPerMinute: 1_000, costPerMinute: Nanodollars(raw: 1_000),
                                    endsAt: Self.now.adding(seconds: 60), newTokensPerMinute: 1_000,
                                    sessions: [ActiveSession(id: 1, name: name, provider: .codex,
                                                             costPerHour: Nanodollars(dollars: 1))])
            let model = StatusModel()
            model.show(today: Self.today, quotas: Self.quotas, live: live)
            let renderer = ImageRenderer(content: PopoverView(model: model).environment(\.stillFrames, true))
            renderer.scale = 1
            let image = try #require(renderer.nsImage)
            #expect(image.size.width == PopoverView.width)
            return image.size.height
        }
        let long = String(repeating: "an-extremely-long-repository-name-", count: 8)
        #expect(try height(naming: long) == height(naming: "api"))
    }

    /// Renders the popover to a PNG for looking at, when asked:
    /// BURNLINE_RENDER=/path/to/popover.png swift test --filter MenuBarTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_RENDER"] != nil))
    func `render the popover`() throws {
        let live = LiveActivity(provider: .codex, model: "gpt-5.5", project: "burnline",
                                tokensPerMinute: 1_420_000, costPerMinute: Nanodollars(raw: 830_000_000),
                                endsAt: Self.now.adding(seconds: 60), newTokensPerMinute: 14_200,
                                sessions: [ActiveSession(id: 1, name: "Burnline AI Usage Tracker", provider: .claudeCode,
                                                         costPerHour: Nanodollars(dollars: 18.4)),
                                           ActiveSession(id: 2, name: "portfolio-site", provider: .codex,
                                                         costPerHour: Nanodollars(dollars: 2.1))])
        let cursor = ProviderQuotaState(
            provider: .cursor, plan: "pro",
            windows: [Self.window(.cursor, "monthly", "Monthly", 34, resetIn: 1_200_000, length: 2_592_000)],
            bankedResets: [], health: .ok, lastSuccess: Self.now)
        // Two providers get full cards; three fold into compact rows.
        // Idle, then live at a busy pace and at a peak for this history.
        let scale = HeatScale(typical: Nanodollars(raw: 5 * Nanodollars.perDollar),
                              busy: Nanodollars(raw: 10 * Nanodollars.perDollar),
                              peak: Nanodollars(raw: 20 * Nanodollars.perDollar))
        let renders: [(String, [ProviderQuotaState], LiveActivity?, HeatScale)] = [
            ("-idle", Self.quotas, nil, .starting), ("", Self.quotas, live, .starting),
            ("-peak", Self.quotas, live, scale), ("-three", Self.quotas + [cursor], live, .starting),
        ]
        for (name, quotas, live, scale) in renders {
            let model = StatusModel()
            model.show(today: Self.today, quotas: quotas, live: live, heatScale: scale)
            let renderer = ImageRenderer(content: PopoverView(model: model)
                .environment(\.colorScheme, .dark).environment(\.stillFrames, true))
            renderer.scale = 2
            let tiff = try #require(renderer.nsImage?.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            let path = ProcessInfo.processInfo.environment["BURNLINE_RENDER"]!
                .replacingOccurrences(of: ".png", with: "\(name).png")
            try data.write(to: URL(filePath: path))
        }
    }
}
