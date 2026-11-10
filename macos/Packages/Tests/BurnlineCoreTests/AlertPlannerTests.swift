//
//  AlertPlannerTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import Testing

struct AlertPlannerTests {
    /// 2 November 2026, 12:00 UTC; the 5-hour window resets at 17:00.
    static let now = BurnRateTests.now
    static let start = now.adding(seconds: -2 * 3_600)
    static let reset = now.adding(seconds: 5 * 3_600)
    static let planner = AlertPlanner(settings: AlertSettings(),
                                      calendar: LocalCalendar(timeZone: .gmt, firstWeekday: .monday),
                                      locale: Locale(identifier: "en_US"))

    static func window(_ percent: Double, provider: ProviderKey = .codex, at time: Timestamp = now,
                       start: Timestamp? = start, reset: Timestamp? = reset) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, key: "five_hour", name: "5-hour", scope: .account, observedAt: time,
                      used: nil, remaining: nil, limit: nil, unit: "percent", percentageUsed: percent,
                      windowStartedAt: start, resetAt: reset, status: QuotaStatus(percentUsed: percent),
                      source: "test")
    }

    static func held(_ id: String, provider: ProviderKey = .codex, expires: Timestamp) -> BankedReset {
        BankedReset(provider: provider, sourceResetID: id, appliesToQuotaKey: provider == .codex ? "codex" : "claude",
                    grantedAt: nil, expiresAt: expires, consumedAt: nil, status: .held, source: "test",
                    observedAt: now)
    }

    static func alerts(_ windows: [QuotaSnapshot], previous: [QuotaSnapshot] = [], resets: [BankedReset] = [],
                       events: [QuotaEvent] = [], rates: [String: BurnRate] = [:], at time: Timestamp = now,
                       planner: AlertPlanner = planner, fired: inout Set<AlertKey>) -> [QuotaAlert] {
        let state = ProviderQuotaState(provider: windows.first?.provider ?? .codex, plan: nil, windows: windows,
                                       bankedResets: resets, health: .ok, lastSuccess: time)
        return planner.quotaAlerts(previous: Dictionary(uniqueKeysWithValues: previous.map { ($0.key, $0) }),
                                   state: state, events: events, burnRates: rates, now: time, fired: &fired)
    }

    static func shown(_ alerts: [QuotaAlert]) -> [String] { alerts.filter { !$0.silent }.map(\.title) }

    @Test func `a threshold alerts once, saying when the window resets`() {
        var fired: Set<AlertKey> = []
        let first = Self.alerts([Self.window(76)], fired: &fired)
        #expect(Self.shown(first) == ["Codex 5-hour usage reached 75%"])
        #expect(first.first?.body == "Resets in 5h.")
        #expect(Self.alerts([Self.window(78)], fired: &fired).isEmpty)
    }

    @Test func `a jump past two thresholds shows only the higher, and records both`() {
        var fired: Set<AlertKey> = []
        let alerts = Self.alerts([Self.window(92)], fired: &fired)
        #expect(alerts.map(\.key.threshold) == [75, 90])
        #expect(Self.shown(alerts) == ["Codex 5-hour usage reached 90%"])
        #expect(Self.alerts([Self.window(93)], fired: &fired).isEmpty)
    }

    @Test func `the limit alert says when the window is expected to reset`() {
        var fired: Set<AlertKey> = []
        let alerts = Self.alerts([Self.window(100)], fired: &fired)
        let limit = alerts.first { !$0.silent }
        #expect(limit?.key.kind == .limitReached && limit?.title == "Codex usage limit reached")
        #expect(limit?.body.plain == "Your 5-hour window is expected to reset at 5:00 PM.")
    }

    @Test func `a fired 90% alert re-arms after a scheduled reset and after a banked one`() {
        var fired: Set<AlertKey> = []
        _ = Self.alerts([Self.window(91)], fired: &fired)
        // The scheduled reset: a new window starting at the old reset time.
        let next = Self.window(91, at: Self.reset.adding(seconds: 4 * 3_600), start: Self.reset,
                               reset: Self.reset.adding(seconds: 5 * 3_600))
        #expect(Self.shown(Self.alerts([next], at: next.observedAt, fired: &fired)) == ["Codex 5-hour usage reached 90%"])
        // A banked reset mid-window: a new window starting when it was spent.
        let spent = next.observedAt.adding(seconds: 600)
        let banked = Self.window(91, at: spent.adding(seconds: 3_600), start: spent,
                                 reset: spent.adding(seconds: 5 * 3_600))
        #expect(Self.shown(Self.alerts([banked], at: banked.observedAt, fired: &fired))
            == ["Codex 5-hour usage reached 90%"])
    }

    @Test func `EC-Q2 a moved reset time within the same window does not re-arm`() {
        var fired: Set<AlertKey> = []
        _ = Self.alerts([Self.window(91)], fired: &fired)
        let moved = Self.window(92, reset: Self.reset.adding(seconds: 2 * 3_600))
        #expect(Self.alerts([moved], fired: &fired).isEmpty)
    }

    @Test func `usage falling well below a threshold re-arms it within the window`() {
        var fired: Set<AlertKey> = []
        _ = Self.alerts([Self.window(91)], fired: &fired)
        // 87 is within the hysteresis: still armed off.
        _ = Self.alerts([Self.window(87)], fired: &fired)
        #expect(Self.alerts([Self.window(91)], fired: &fired).isEmpty)
        _ = Self.alerts([Self.window(84)], fired: &fired)
        #expect(Self.shown(Self.alerts([Self.window(90)], fired: &fired)) == ["Codex 5-hour usage reached 90%"])
    }

    @Test func `EC-Q3 a stale figure never alerts`() {
        var fired: Set<AlertKey> = []
        let old = Self.window(100, at: Self.now.adding(seconds: -31 * 60))
        #expect(Self.alerts([old], fired: &fired).isEmpty && fired.isEmpty)
    }

    @Test func `EC-Q3 stale reset events and banked reminders never alert`() {
        var fired: Set<AlertKey> = []
        let old = Self.now.adding(seconds: -ProviderQuotaState.staleAfter - 1)
        let window = Self.window(0, at: old, start: old)
        let event = QuotaEvent.windowReset(provider: .codex, key: window.key,
                                          cycleToken: window.cycleToken, cause: .scheduled)
        let state = ProviderQuotaState(provider: .codex, plan: nil, windows: [window],
                                       bankedResets: [Self.held("old", expires: Self.now.adding(seconds: 600))],
                                       health: .ok, lastSuccess: old)
        let alerts = Self.planner.quotaAlerts(previous: [window.key: Self.window(100)], state: state,
                                              events: [event], burnRates: [:], now: Self.now, fired: &fired)
        #expect(alerts.isEmpty && fired.isEmpty)
    }

    @Test func `EC-T6 a window past its reset time waits for the reset to be confirmed`() {
        var fired: Set<AlertKey> = []
        let pending = Self.window(100, reset: Self.now.adding(seconds: -60))
        #expect(Self.alerts([pending], fired: &fired).isEmpty)
    }

    @Test func `a window that hit its limit says when it is available again`() {
        var fired: Set<AlertKey> = []
        let fresh = Self.window(0, start: Self.now, reset: Self.now.adding(seconds: 5 * 3_600))
        let event = QuotaEvent.windowReset(provider: .codex, key: "five_hour", cycleToken: fresh.cycleToken, cause: .scheduled)
        let alerts = Self.alerts([fresh], previous: [Self.window(100)], events: [event], fired: &fired)
        #expect(Self.shown(alerts) == ["Codex is available again"])
        #expect(alerts.first?.body == "Your 5-hour allowance has reset.")

        // A reset from 80% was never blocking anything.
        var others: Set<AlertKey> = []
        #expect(Self.alerts([fresh], previous: [Self.window(80)], events: [event], fired: &others).isEmpty)
    }

    @Test func `EC-Q1 a banked reset's 94% to 0% drop raises no spurious alert`() {
        var fired: Set<AlertKey> = []
        _ = Self.alerts([Self.window(94)], fired: &fired)
        let spent = Self.now.adding(seconds: 300)
        let fresh = Self.window(0, at: spent, start: spent, reset: spent.adding(seconds: 5 * 3_600))
        let event = QuotaEvent.windowReset(provider: .codex, key: "five_hour", cycleToken: fresh.cycleToken, cause: .bankedReset)
        #expect(Self.alerts([fresh], previous: [Self.window(94)], events: [event], at: spent, fired: &fired).isEmpty)
    }

    static func rate(lead: Int64, percent: Double, basis: BurnRate.Basis = .recent) -> BurnRate {
        BurnRate(percentPerHour: 20, basis: basis, percentUsed: percent, observedAt: now, resetAt: reset,
                 projectedExhaustion: reset.adding(seconds: -lead))
    }

    @Test func `a pace drawn from the whole window says so, not that usage is rising`() {
        var fired: Set<AlertKey> = []
        let alerts = Self.alerts([Self.window(72)],
                                 rates: ["five_hour": Self.rate(lead: 48 * 60, percent: 72, basis: .window)], fired: &fired)
        let warning = alerts.first { $0.key.kind == .burnRate }
        #expect(warning?.title == "Codex usage is on pace to run out")
        #expect(warning?.body
            == "At this window's pace so far, your 5-hour allowance may run out about 48 minutes before reset.")
    }

    @Test func `a pace that runs out before the reset warns once a window`() {
        var fired: Set<AlertKey> = []
        let alerts = Self.alerts([Self.window(72)], rates: ["five_hour": Self.rate(lead: 48 * 60, percent: 72)],
                                 fired: &fired)
        let warning = alerts.first { $0.key.kind == .burnRate }
        #expect(warning?.title == "Codex usage is rising quickly")
        #expect(warning?.body == "At the current rate, your 5-hour allowance may run out about 48 minutes before reset.")
        #expect(Self.alerts([Self.window(73)], rates: ["five_hour": Self.rate(lead: 50 * 60, percent: 73)],
                            fired: &fired).isEmpty)
    }

    @Test func `no pace warning early in a window or for a near miss`() {
        var fired: Set<AlertKey> = []
        #expect(Self.alerts([Self.window(40)], rates: ["five_hour": Self.rate(lead: 3_600, percent: 40)],
                            fired: &fired).isEmpty)
        #expect(Self.alerts([Self.window(60)], rates: ["five_hour": Self.rate(lead: 5 * 60, percent: 60)],
                            fired: &fired).isEmpty)
    }

    @Test func `a held banked reset near the limit is said, in place of the threshold`() {
        var fired: Set<AlertKey> = []
        let tomorrow = Timestamp(epochSeconds: 1_793_696_400)
        let alerts = Self.alerts([Self.window(92)], resets: [Self.held("r1", expires: tomorrow)], fired: &fired)
        #expect(Self.shown(alerts) == ["Codex 5-hour limit nearly reached"])
        #expect(alerts.first { !$0.silent }?.body.plain == "You have a banked reset available until 9:00 AM tomorrow.")
        // The 90% alert is recorded, so it does not follow at the next read.
        #expect(Self.alerts([Self.window(93)], resets: [Self.held("r1", expires: tomorrow)], fired: &fired).isEmpty)
    }

    @Test func `resets expiring together are one reminder, sent once`() {
        var fired: Set<AlertKey> = []
        let soon = Self.now.adding(seconds: 11 * 3_600)
        let resets = [Self.held("g#1", provider: .claudeCode, expires: soon),
                      Self.held("g#2", provider: .claudeCode, expires: soon),
                      Self.held("later", provider: .claudeCode, expires: Self.now.adding(seconds: 2 * 86_400))]
        let window = Self.window(10, provider: .claudeCode)
        let alerts = Self.alerts([window], resets: resets, fired: &fired)
        #expect(Self.shown(alerts) == ["Your 2 banked Claude resets expire in 11h"])
        #expect(alerts.first?.body.plain == "Unused, they are lost at 11:00 PM.")
        #expect(Self.alerts([window], resets: resets, fired: &fired).isEmpty)
    }

    @Test func `EC-Q5 Claude's quota is named for the account`() {
        var fired: Set<AlertKey> = []
        #expect(Self.shown(Self.alerts([Self.window(76, provider: .claudeCode)], fired: &fired))
            == ["Claude 5-hour usage reached 75%"])
    }

    @Test func `EC-Q7 each quota keeps its own state`() {
        var fired: Set<AlertKey> = []
        let weekly = QuotaSnapshot(provider: .codex, key: "weekly", name: "Weekly", scope: .account,
                                   observedAt: Self.now, used: nil, remaining: nil, limit: nil, unit: "percent",
                                   percentageUsed: 91, windowStartedAt: Self.start, resetAt: Self.reset,
                                   status: .critical, source: "test")
        let alerts = Self.alerts([Self.window(91), weekly], fired: &fired)
        #expect(Self.shown(alerts) == ["Codex 5-hour usage reached 90%", "Codex weekly usage reached 90%"])
    }

    @Test func `switched-off alerts stay quiet`() {
        var fired: Set<AlertKey> = []
        let quiet = AlertPlanner(settings: AlertSettings(thresholds: [.init(.codex, .fiveHour): []], limitReached: false,
                                                         burnRate: false, bankedResets: false),
                                 calendar: Self.planner.calendar)
        #expect(Self.alerts([Self.window(100)], resets: [Self.held("r", expires: Self.now.adding(seconds: 60))],
                            rates: ["five_hour": Self.rate(lead: 3_600, percent: 100)], planner: quiet,
                            fired: &fired).isEmpty)
    }

    @Test func `a spend limit alerts once a day and again the next`() {
        let planner = AlertPlanner(settings: AlertSettings(dailySpend: Nanodollars(raw: 20 * Nanodollars.perDollar)),
                                   calendar: Self.planner.calendar, locale: Locale(identifier: "en_US"))
        var fired: Set<AlertKey> = []
        let spent = Nanodollars(raw: 21_400_000_000)
        let first = planner.spendAlerts(day: spent, week: spent, now: Self.now, fired: &fired)
        #expect(first.map(\.title) == ["Today's equivalent cost passed $20.00"])
        #expect(first.first?.body == "$21.40 so far at API prices." && first.first?.key.provider == nil)
        #expect(planner.spendAlerts(day: spent, week: spent, now: Self.now.adding(seconds: 3_600), fired: &fired).isEmpty)
        #expect(planner.spendAlerts(day: spent, week: spent, now: Self.now.adding(seconds: 86_400), fired: &fired)
            .count == 1)
        #expect(planner.spendAlerts(day: Nanodollars(raw: 1), week: spent, now: Self.now.adding(seconds: 2 * 86_400),
                                    fired: &fired).isEmpty)
    }

    // MARK: Provider resets

    static func providerReset(from before: Double) -> (QuotaSnapshot, QuotaSnapshot, QuotaEvent) {
        let fresh = window(0, start: now, reset: reset)
        return (window(before), fresh,
                .windowReset(provider: .codex, key: "five_hour", cycleToken: fresh.cycleToken, cause: .provider))
    }

    @Test func `a provider's own reset is said, naming who reset it`() {
        var fired: Set<AlertKey> = []
        let (before, fresh, event) = Self.providerReset(from: 60)
        let alerts = Self.alerts([fresh], previous: [before], events: [event], fired: &fired)
        #expect(Self.shown(alerts) == ["OpenAI reset your Codex 5-hour usage"])
        #expect(alerts.first?.body == "The window is back to 0% early, and no banked reset was spent.")
        #expect(Self.alerts([fresh], previous: [before], events: [event], fired: &fired).isEmpty)
    }

    @Test func `a provider's reset from the limit is said once, in place of available again`() {
        var fired: Set<AlertKey> = []
        let (before, fresh, event) = Self.providerReset(from: 100)
        let alerts = Self.alerts([fresh], previous: [before], events: [event], fired: &fired)
        #expect(alerts.map(\.key.kind) == [.providerReset])
        #expect(alerts.first?.body.hasPrefix("You can use Codex again.") == true)
    }

    @Test func `a provider's reset of a barely used window says nothing`() {
        var fired: Set<AlertKey> = []
        let (before, fresh, event) = Self.providerReset(from: 10)
        #expect(Self.alerts([fresh], previous: [before], events: [event], fired: &fired).isEmpty)
    }

    // MARK: Choosing thresholds

    @Test func `each kind of window alerts at its own chosen percentages`() {
        let settings = AlertSettings(thresholds: [.init(.codex, .fiveHour): [50, 95], .init(.codex, .weekly): [90]])
        #expect(settings.thresholds(for: .codex, .fiveHour) == [50, 95, 100])
        #expect(settings.thresholds(for: .codex, .weekly) == [90, 100])
        // A window not chosen for keeps the defaults.
        #expect(settings.thresholds(for: .claudeCode, .fiveHour) == [75, 90, 100])

        let planner = AlertPlanner(settings: settings, calendar: Self.planner.calendar, locale: Self.planner.locale)
        var fired: Set<AlertKey> = []
        #expect(Self.shown(Self.alerts([Self.window(52)], planner: planner, fired: &fired))
            == ["Codex 5-hour usage reached 50%"])
        #expect(Self.alerts([Self.window(91)], planner: planner, fired: &fired).isEmpty)
        #expect(Self.shown(Self.alerts([Self.window(96)], planner: planner, fired: &fired))
            == ["Codex 5-hour usage reached 95%"])
    }

    @Test func `the limit alert can be switched off on its own`() {
        let settings = AlertSettings(limitReached: false)
        #expect(settings.thresholds(for: .codex, .weekly) == [75, 90])
    }

    @Test func `window kinds follow the quota keys, so a plan's settings show only its windows`() {
        #expect(QuotaWindowKind(quotaKey: "five_hour") == .fiveHour)
        #expect(QuotaWindowKind(quotaKey: "premium.five_hour") == .fiveHour)
        #expect(QuotaWindowKind(quotaKey: "weekly") == .weekly)
        #expect(QuotaWindowKind(quotaKey: "seven_day_opus") == .weekly)
        #expect(QuotaWindowKind(quotaKey: "monthly") == .other)
        // A plan with no 5-hour window, such as Codex Pro or Claude Ultra.
        let weekly = QuotaSnapshot(provider: .codex, key: "weekly", name: "Weekly", scope: .account,
                                   observedAt: Self.now, used: nil, remaining: nil, limit: nil, unit: "percent",
                                   percentageUsed: 10, windowStartedAt: nil, resetAt: nil, status: .healthy,
                                   source: "test")
        let state = ProviderQuotaState(provider: .codex, plan: "pro", windows: [weekly], bankedResets: [],
                                       health: .ok, lastSuccess: Self.now)
        #expect(state.windowKinds == [.weekly])
    }

    @Test func `settings survive saving, and older saved settings take new defaults`() throws {
        let settings = AlertSettings(thresholds: [.init(.claudeCode, .weekly): [50, 75, 90, 95]], providerResets: false,
                                     dailySpend: Nanodollars(raw: 20 * Nanodollars.perDollar))
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AlertSettings.self, from: data) == settings)
        let older = try JSONDecoder().decode(AlertSettings.self, from: Data(#"{"burnRate":false}"#.utf8))
        #expect(older == AlertSettings(burnRate: false))
    }
}
