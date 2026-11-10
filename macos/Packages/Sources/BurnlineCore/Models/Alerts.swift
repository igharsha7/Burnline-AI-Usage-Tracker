//
//  Alerts.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// The `notification_events.notification_type` column.
public enum AlertKind: String, Sendable, CaseIterable, Codable {
    /// A window crossed one of the warning thresholds.
    case threshold
    /// A window reached 100%.
    case limitReached = "limit_reached"
    /// A window that had reached its limit reset, as a fresh read confirmed.
    case availableAgain = "available_again"
    /// The provider reset a window's usage itself, with no banked reset spent.
    case providerReset = "provider_reset"
    /// At the current pace a window runs out before it resets.
    case burnRate = "burn_rate"
    /// A held banked reset will expire soon, unused.
    case bankedResetExpiring = "banked_reset_expiring"
    /// A window is at or near its limit while a banked reset is held: the
    /// one combination the banked-reset ledger exists to catch.
    case bankedResetUseful = "banked_reset_useful"
    case dailySpend = "daily_spend"
    case weeklySpend = "weekly_spend"
    /// Lifetime usage crossed one of the comparison corpus's milestones.
    case milestone
}

/// What deduplication keys on. `cycleToken` names the window, day or week an
/// alert belongs to; for a quota it is the window's cycle token, never its
/// reset time, because a banked reset moves the reset time and keying on it
/// would hold back the re-armed alert.
public struct AlertKey: Hashable, Sendable {
    /// Nil for spend, which covers every provider.
    public let provider: ProviderKey?
    public let quotaKey: String?
    public let kind: AlertKind
    public let threshold: Double?
    public let cycleToken: String

    public init(provider: ProviderKey?, quotaKey: String?, kind: AlertKind, threshold: Double?,
                cycleToken: String) {
        self.provider = provider
        self.quotaKey = quotaKey
        self.kind = kind
        self.threshold = threshold
        self.cycleToken = cycleToken
    }
}

/// One notification, decided and worded.
public struct QuotaAlert: Hashable, Sendable {
    public let key: AlertKey
    public let title: String
    public let body: String
    /// Recorded as fired but not shown: a 75% alert when the same read also
    /// crosses 90%, or a threshold alert a banked-reset alert speaks for.
    public let silent: Bool
    public init(key: AlertKey, title: String, body: String, silent: Bool) {
        self.key = key
        self.title = title
        self.body = body
        self.silent = silent
    }
}

/// What a quota window measures, for choosing its alert thresholds. Plans
/// differ in which they have: Codex Pro and Claude's Ultra plan have no
/// 5-hour window, Claude Max does, so the settings show only the kinds a
/// provider reports (`ProviderQuotaState.windowKinds`).
public enum QuotaWindowKind: String, Hashable, Sendable, Codable, CaseIterable {
    case fiveHour = "five_hour"
    /// Weekly windows, including a model's own weekly limit.
    case weekly
    /// Anything else: a free plan's monthly window, extra usage, a credit limit.
    case other

    /// From a quota key: `five_hour`, `weekly`, `seven_day_opus`, or a
    /// model limit's `<id>.five_hour`.
    public init(quotaKey: String) {
        let kind = quotaKey.split(separator: ".").last.map(String.init) ?? quotaKey
        if kind == "five_hour" { self = .fiveHour }
        else if kind == "weekly" || kind.hasPrefix("seven_day") { self = .weekly }
        else { self = .other }
    }
}

extension QuotaSnapshot {
    public var windowKind: QuotaWindowKind { QuotaWindowKind(quotaKey: key) }
}

extension ProviderQuotaState {
    /// The kinds of window this account has, in the order first reported.
    public var windowKinds: [QuotaWindowKind] {
        windows.map(\.windowKind).reduce(into: []) { kinds, kind in if !kinds.contains(kind) { kinds.append(kind) } }
    }
}

/// Which alerts the user wants. Saved as JSON by the app; the settings
/// interface edits it.
public struct AlertSettings: Hashable, Sendable {
    /// Usage percentages that alert, for each provider and kind of window.
    /// A pair not listed uses `defaultThresholds`; an empty list is off.
    public var thresholds: [Target: [Double]]
    /// The alert at 100%.
    public var limitReached: Bool
    public var availableAgain: Bool
    /// A provider resetting usage itself, with no banked reset spent.
    public var providerResets: Bool
    public var burnRate: Bool
    public var bankedResets: Bool
    /// Equivalent cost at API prices that alerts once a day or week. Nil is off.
    public var dailySpend: Nanodollars?
    public var weeklySpend: Nanodollars?
    /// Lifetime usage crossing a milestone: a million tokens, a billion.
    public var milestones: Bool
    /// A medal earned.
    public var achievements: Bool

    public struct Target: Hashable, Sendable {
        public let provider: ProviderKey
        public let kind: QuotaWindowKind

        public init(_ provider: ProviderKey, _ kind: QuotaWindowKind) {
            self.provider = provider
            self.kind = kind
        }
    }

    /// The percentages the settings offer for each window.
    public static let thresholdChoices: [Double] = [50, 75, 90, 95]
    public static let defaultThresholds: [Double] = [QuotaThresholds.warning, QuotaThresholds.critical]

    public init(thresholds: [Target: [Double]] = [:], limitReached: Bool = true, availableAgain: Bool = true,
                providerResets: Bool = true, burnRate: Bool = true, bankedResets: Bool = true,
                dailySpend: Nanodollars? = nil, weeklySpend: Nanodollars? = nil, milestones: Bool = true,
                achievements: Bool = true) {
        self.thresholds = thresholds
        self.limitReached = limitReached
        self.availableAgain = availableAgain
        self.providerResets = providerResets
        self.burnRate = burnRate
        self.bankedResets = bankedResets
        self.dailySpend = dailySpend
        self.weeklySpend = weeklySpend
        self.milestones = milestones
        self.achievements = achievements
    }

    /// The percentages that alert for a provider's kind of window, lowest
    /// first, the limit included when it is on.
    public func thresholds(for provider: ProviderKey, _ kind: QuotaWindowKind) -> [Double] {
        let chosen = (thresholds[Target(provider, kind)] ?? Self.defaultThresholds)
            .filter { $0 > 0 && $0 < QuotaThresholds.exhausted }
        return Array(Set(chosen + (limitReached ? [QuotaThresholds.exhausted] : []))).sorted()
    }

    /// A threshold alert re-arms within a window once usage falls this far
    /// below it, so a correction and a second climb alert again.
    public static let hysteresis = 5.0
    /// Burn-rate warnings wait until a window is this full: early in a window
    /// one burst projects an exhaustion that rarely happens.
    public static let burnRateFloor = 50.0
    /// A projected exhaustion this close to the reset is not worth a warning.
    public static let burnRateMinimumLead: Int64 = 10 * 60
    /// How long before a banked reset expires the reminder comes.
    public static let bankedResetReminder: Int64 = 12 * 3_600
    /// A provider's reset of a window used less than this is not worth saying.
    public static let providerResetFloor = 25.0
}

extension AlertSettings: Codable {
    private struct Rule: Codable {
        let provider: ProviderKey
        let kind: QuotaWindowKind
        let percents: [Double]
    }

    private enum CodingKeys: String, CodingKey {
        case thresholds, limitReached, availableAgain, providerResets, burnRate, bankedResets
        case dailySpendNanos, weeklySpendNanos, milestones, achievements
    }

    /// Every field is optional, so settings saved by an older build keep
    /// their choices and take defaults for what is new.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AlertSettings()
        let rules = try c.decodeIfPresent([Rule].self, forKey: .thresholds) ?? []
        self.init(
            thresholds: Dictionary(rules.map { (Target($0.provider, $0.kind), $0.percents) },
                                   uniquingKeysWith: { _, last in last }),
            limitReached: try c.decodeIfPresent(Bool.self, forKey: .limitReached) ?? defaults.limitReached,
            availableAgain: try c.decodeIfPresent(Bool.self, forKey: .availableAgain) ?? defaults.availableAgain,
            providerResets: try c.decodeIfPresent(Bool.self, forKey: .providerResets) ?? defaults.providerResets,
            burnRate: try c.decodeIfPresent(Bool.self, forKey: .burnRate) ?? defaults.burnRate,
            bankedResets: try c.decodeIfPresent(Bool.self, forKey: .bankedResets) ?? defaults.bankedResets,
            dailySpend: try c.decodeIfPresent(Int64.self, forKey: .dailySpendNanos).map(Nanodollars.init(raw:)),
            weeklySpend: try c.decodeIfPresent(Int64.self, forKey: .weeklySpendNanos).map(Nanodollars.init(raw:)),
            milestones: try c.decodeIfPresent(Bool.self, forKey: .milestones) ?? defaults.milestones,
            achievements: try c.decodeIfPresent(Bool.self, forKey: .achievements) ?? defaults.achievements)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let rules = thresholds.map { Rule(provider: $0.key.provider, kind: $0.key.kind, percents: $0.value) }
            .sorted { ($0.provider.rawValue, $0.kind.rawValue) < ($1.provider.rawValue, $1.kind.rawValue) }
        try c.encode(rules, forKey: .thresholds)
        try c.encode(limitReached, forKey: .limitReached)
        try c.encode(availableAgain, forKey: .availableAgain)
        try c.encode(providerResets, forKey: .providerResets)
        try c.encode(burnRate, forKey: .burnRate)
        try c.encode(bankedResets, forKey: .bankedResets)
        try c.encode(milestones, forKey: .milestones)
        try c.encode(achievements, forKey: .achievements)
        try c.encodeIfPresent(dailySpend?.raw, forKey: .dailySpendNanos)
        try c.encodeIfPresent(weeklySpend?.raw, forKey: .weeklySpendNanos)
    }
}

/// Decides which alerts a fresh quota reading or a usage sync calls for, and
/// words them. Pure: the caller keeps `fired`, the set of alerts already
/// sent, and records what is returned.
///
/// Only fresh figures alert. A window whose figure is stale, or whose reset
/// time has passed without a read confirming the reset, alerts nothing. Each
/// quota has its own state.
public struct AlertPlanner: Sendable {
    public let settings: AlertSettings
    public let calendar: LocalCalendar
    public let locale: Locale

    public init(settings: AlertSettings, calendar: LocalCalendar, locale: Locale = .current) {
        self.settings = settings
        self.calendar = calendar
        self.locale = locale
    }

    /// Alerts for one provider's fresh reading. `previous` holds each
    /// window's figure from before the reading.
    public func quotaAlerts(previous: [String: QuotaSnapshot], state: ProviderQuotaState, events: [QuotaEvent],
                            burnRates: [String: BurnRate], now: Timestamp,
                            fired: inout Set<AlertKey>) -> [QuotaAlert] {
        guard !state.isStale(at: now) else { return [] }
        var alerts: [QuotaAlert] = []
        let label = Self.label(state.provider, scope: state.windows.first?.scope)
        let held = settings.bankedResets
            ? state.heldResets.filter { $0.expiresAt.map { $0 > now } ?? true }
            : []

        for event in events {
            guard case .windowReset(_, let key, _, let cause) = event,
                  let before = previous[key]?.percentageUsed,
                  let window = state.windows.first(where: { $0.key == key }),
                  now.seconds(since: window.observedAt) <= ProviderQuotaState.staleAfter else { continue }
            let name = Self.lowered(window.name)
            let blocked = before >= QuotaThresholds.exhausted
            func alert(_ kind: AlertKind, _ title: String, _ body: String) {
                let alertKey = AlertKey(provider: state.provider, quotaKey: key, kind: kind, threshold: nil,
                                        cycleToken: Self.cycle(of: window))
                guard fired.insert(alertKey).inserted else { return }
                alerts.append(QuotaAlert(key: alertKey, title: title, body: body, silent: false))
            }
            if cause == .provider, settings.providerResets, before >= AlertSettings.providerResetFloor {
                // Said in place of available again: it explains why.
                alert(.providerReset, "\(Self.company(state.provider)) reset your \(label) \(name) usage",
                      (blocked ? "You can use \(label) again. " : "")
                          + "The window is back to \(Int(window.percentageUsed ?? 0))% early, "
                          + "and no banked reset was spent.")
            } else if blocked, settings.availableAgain {
                alert(.availableAgain, "\(label) is available again", "Your \(name) allowance has reset.")
            }
        }

        for window in state.windows {
            guard let percent = window.percentageUsed,
                  now.seconds(since: window.observedAt) <= ProviderQuotaState.staleAfter,
                  window.resetAt.map({ $0 > now }) ?? true else { continue }
            let cycle = Self.cycle(of: window)
            func key(_ kind: AlertKind, _ threshold: Double? = nil) -> AlertKey {
                AlertKey(provider: state.provider, quotaKey: window.key, kind: kind, threshold: threshold,
                         cycleToken: cycle)
            }
            let name = Self.lowered(window.name)
            let thresholds = settings.thresholds(for: state.provider, window.windowKind)
            for threshold in thresholds where percent < threshold - AlertSettings.hysteresis {
                fired.remove(key(Self.kind(threshold), threshold))
            }

            var spokenFor = false
            if !held.isEmpty, percent >= QuotaThresholds.critical, fired.insert(key(.bankedResetUseful)).inserted {
                let reached = percent >= QuotaThresholds.exhausted
                alerts.append(QuotaAlert(
                    key: key(.bankedResetUseful),
                    title: "\(label) \(name) limit \(reached ? "reached" : "nearly reached")",
                    body: heldSentence(held, now: now), silent: false))
                spokenFor = true
            }

            let crossed = thresholds.filter { percent >= $0 && !fired.contains(key(Self.kind($0), $0)) }
            for threshold in crossed {
                let alertKey = key(Self.kind(threshold), threshold)
                fired.insert(alertKey)
                let (title, body): (String, String)
                if threshold >= QuotaThresholds.exhausted {
                    title = "\(label) usage limit reached"
                    body = window.resetAt.map {
                        "Your \(name) window is expected to reset \(at($0, now: now))."
                    } ?? "Your \(name) window has no reset time yet."
                } else {
                    title = "\(label) \(name) usage reached \(Int(threshold))%"
                    body = window.resetAt.map { "Resets in \(Countdown.compact($0.seconds(since: now)))." } ?? ""
                }
                alerts.append(QuotaAlert(key: alertKey, title: title, body: body,
                                         silent: spokenFor || threshold != crossed.last))
            }

            if settings.burnRate, percent >= AlertSettings.burnRateFloor, percent < QuotaThresholds.exhausted,
               let lead = burnRates[window.key]?.exhaustionLead, lead >= AlertSettings.burnRateMinimumLead,
               fired.insert(key(.burnRate)).inserted {
                // A pace drawn from the whole window is not a rise happening now.
                let recent = burnRates[window.key]?.basis != .window
                alerts.append(QuotaAlert(
                    key: key(.burnRate),
                    title: recent ? "\(label) usage is rising quickly" : "\(label) usage is on pace to run out",
                    body: (recent ? "At the current rate" : "At this window's pace so far")
                        + ", your \(name) allowance may run out about \(Countdown.spoken(lead)) before reset.",
                    silent: false))
            }
        }

        // One reminder per expiry: Claude grants several resets that end together.
        for (expiry, resets) in Dictionary(grouping: held.filter { $0.expiresAt != nil }, by: { $0.expiresAt! })
            .sorted(by: { $0.key < $1.key }) {
            let left = expiry.seconds(since: now)
            guard left > 0, left <= AlertSettings.bankedResetReminder else { continue }
            let alertKey = AlertKey(provider: state.provider, quotaKey: nil, kind: .bankedResetExpiring,
                                    threshold: nil, cycleToken: "expires:\(expiry.epochSeconds)")
            guard fired.insert(alertKey).inserted else { continue }
            let what = resets.count == 1 ? "Your banked \(label) reset expires"
                : "Your \(resets.count) banked \(label) resets expire"
            alerts.append(QuotaAlert(key: alertKey, title: "\(what) in \(Countdown.compact(left))",
                                     body: "Unused, \(resets.count == 1 ? "it is" : "they are") lost \(at(expiry, now: now)).",
                                     silent: false))
        }
        return alerts
    }

    /// Spend alerts after a usage sync. `day` and `week` are the local day's
    /// and week's equivalent cost so far; `now` decides which day and week.
    public func spendAlerts(day: Nanodollars, week: Nanodollars, now: Timestamp,
                            fired: inout Set<AlertKey>) -> [QuotaAlert] {
        var alerts: [QuotaAlert] = []
        func check(_ kind: AlertKind, _ total: Nanodollars, _ limit: Nanodollars?, _ cycle: String,
                   _ period: String) {
            guard let limit, total >= limit else { return }
            let key = AlertKey(provider: nil, quotaKey: nil, kind: kind,
                               threshold: Double(limit.raw), cycleToken: cycle)
            guard fired.insert(key).inserted else { return }
            alerts.append(QuotaAlert(key: key, title: "\(period) equivalent cost passed \(money(limit))",
                                     body: "\(money(total)) so far at API prices.", silent: false))
        }
        check(.dailySpend, day, settings.dailySpend, "day:\(calendar.day(containing: now))", "Today's")
        check(.weeklySpend, week, settings.weeklySpend,
              "week:\(calendar.day(containing: calendar.week(containing: now).start))", "This week's")
        return alerts
    }

    // MARK: Wording

    /// Claude's quota covers the whole account, not only Claude Code, so it
    /// is named for the account.
    static func label(_ provider: ProviderKey, scope: QuotaScope?) -> String {
        provider == .claudeCode && scope != .surface ? "Claude" : provider.displayName
    }

    /// Who resets a provider's usage.
    static func company(_ provider: ProviderKey) -> String {
        switch provider {
        case .codex: "OpenAI"
        case .claudeCode: "Anthropic"
        case .cursor: "Cursor"
        }
    }

    /// "Weekly · Opus" reads "weekly · Opus" mid-sentence.
    static func lowered(_ name: String) -> String {
        name.prefix(1).lowercased() + name.dropFirst()
    }

    static func kind(_ threshold: Double) -> AlertKind {
        threshold >= QuotaThresholds.exhausted ? .limitReached : .threshold
    }

    /// The window's cycle token, or, when the provider gives no window start,
    /// one token for the quota, which only the hysteresis re-arms.
    static func cycle(of window: QuotaSnapshot) -> String {
        window.cycleToken ?? "\(window.provider.rawValue):\(window.key):open"
    }

    private func at(_ instant: Timestamp, now: Timestamp) -> String {
        let moment = Countdown.moment(instant, now: now, calendar: calendar, locale: locale)
        return moment.first?.isNumber == true ? "at \(moment)" : "on \(moment)"
    }

    private func heldSentence(_ held: [BankedReset], now: Timestamp) -> String {
        let soonest = held.compactMap(\.expiresAt).min()
        let until = soonest.map { " until \(Countdown.moment($0, now: now, calendar: calendar, locale: locale))" } ?? ""
        return held.count == 1
            ? "You have a banked reset available\(until)."
            : "You have \(held.count) banked resets available\(soonest == nil ? "" : "; the first lasts\(until)")."
    }

    private func money(_ amount: Nanodollars) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = locale
        return formatter.string(from: amount.decimalDollars as NSDecimalNumber) ?? "$\(amount.decimalDollars)"
    }
}
