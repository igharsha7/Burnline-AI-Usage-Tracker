//
//  ReviewRenderTests.swift
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

/// Renders the degraded quota and menu-bar states that cannot be brought
/// about on demand against live providers, for the error-state review:
/// BURNLINE_REVIEW_DIR=/path swift test --filter ReviewRenderTests
///
/// The views count down from the real time, so the fixtures are set
/// around it; nothing here is asserted.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_REVIEW_DIR"] != nil))
struct ReviewRenderTests {
    static let directory = URL(filePath: ProcessInfo.processInfo.environment["BURNLINE_REVIEW_DIR"] ?? "/")
    static let now = SystemClock().now

    static func window(_ provider: ProviderKey, _ key: String, _ name: String, _ percent: Double, resetIn: Int64,
                       length: Int64, observedAgo: Int64 = 0) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, key: key, name: name, scope: .account,
                      observedAt: now.adding(seconds: -observedAgo), used: nil, remaining: nil, limit: nil,
                      unit: "percent", percentageUsed: percent, windowStartedAt: now.adding(seconds: resetIn - length),
                      resetAt: now.adding(seconds: resetIn), status: QuotaStatus(percentUsed: percent), source: "review")
    }

    static func reset(_ id: String, _ status: BankedResetStatus) -> BankedReset {
        BankedReset(provider: .codex, sourceResetID: id, appliesToQuotaKey: "codex", grantedAt: nil,
                    expiresAt: now.adding(seconds: 5 * 86_400), consumedAt: nil, status: status, source: "review",
                    observedAt: now)
    }

    /// Codex unreachable for two hours, its figures kept and aged, with a
    /// banked reset it stopped reporting; Claude's login expired, with a
    /// window past its reset waiting to be confirmed. Both account-wide.
    static let quotas = [
        ProviderQuotaState(
            provider: .codex, plan: "plus",
            windows: [window(.codex, "five_hour", "5-hour", 42, resetIn: 9_000, length: 18_000, observedAgo: 7_200),
                      window(.codex, "weekly", "Weekly", 65, resetIn: 190_000, length: 604_800, observedAgo: 7_200)],
            bankedResets: [reset("rc_1", .held), reset("rc_2", .held), reset("rc_3", .unknown)],
            health: .degraded(reason: "Codex stopped answering.", since: now.adding(seconds: -7_000)),
            lastSuccess: now.adding(seconds: -7_200)),
        ProviderQuotaState(
            provider: .claudeCode, plan: "pro",
            windows: [window(.claudeCode, "five_hour", "5-hour", 97, resetIn: -120, length: 18_000, observedAgo: 900),
                      window(.claudeCode, "seven_day", "Weekly", 26, resetIn: 560_000, length: 604_800,
                             observedAgo: 900)],
            bankedResets: [],
            health: .degraded(reason: "Claude Code is not signed in with a Claude account.",
                              since: now.adding(seconds: -900)),
            lastSuccess: now.adding(seconds: -900)),
    ]

    static let today = TodayStatus(tokens: 18_600_000, cost: Nanodollars(raw: 12_840_000_000), costCoverage: 0.93,
                                   endsAt: now.adding(seconds: 3_600))

    func write(_ view: some View, _ name: String, width: CGFloat) throws {
        let renderer = ImageRenderer(content: view.frame(width: width)
            .background(Palette.background)
            .environment(\.colorScheme, .dark).environment(\.stillFrames, true))
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try data.write(to: Self.directory.appending(path: "\(name).png"))
    }

    @Test func `degraded quota in the dashboard`() throws {
        let model = StatusModel()
        model.show(today: Self.today, quotas: Self.quotas, live: nil)
        try write(LimitsView(status: model).padding(24), "ec-q3-q4-q5-q6-t6-limits", width: 880)
    }

    @Test func `degraded quota in the popover`() throws {
        let model = StatusModel()
        model.show(today: Self.today, quotas: Self.quotas, live: nil)
        try write(PopoverView(model: model), "ec-q3-q4-t6-popover", width: 320)
    }

    @Test func `a full disk in the popover`() throws {
        let model = StatusModel()
        model.show(today: Self.today, quotas: [], live: nil, storeFailure: .diskFull)
        try write(PopoverView(model: model), "ec-d1-popover", width: 320)
    }

    @Test func `a database that did not open, in the popover`() throws {
        let model = StatusModel()
        model.fail(.corrupt)
        try write(PopoverView(model: model), "ec-d2-popover", width: 320)
    }

    @Test func `a provider no longer read, beside the history it kept`() throws {
        let codex = try DashboardTests.totals(events: 900, tokens: 840_000_000, dollars: 186)
        let claude = try DashboardTests.totals(events: 2_100, tokens: 1_700_000_000, dollars: 778)
        let whole = try DashboardTests.totals(events: 3_000, tokens: 2_540_000_000, dollars: 964)
        let spectrum = ProviderSpectrum(
            providers: [ProviderFigures(provider: .claudeCode, totals: claude, sessions: 20),
                        ProviderFigures(provider: .codex, totals: codex, sessions: 18)],
            metric: .cost, whole: whole, hidden: [],
            health: [.claudeCode: .healthy(lastImport: Self.now), .codex: .notInstalled], toggle: { _ in })
        try write(spectrum.padding(24), "ec-u4-provider-no-longer-read", width: 460)
    }
}
