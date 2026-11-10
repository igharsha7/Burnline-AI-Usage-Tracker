//
//  QuotaReading.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// One window as a provider reported it, before Burnline compares it with
/// what it saw last. Reset detection turns it into a `QuotaSnapshot`.
public struct QuotaWindowReading: Hashable, Sendable {
    /// Stable within a provider: `five_hour`, `weekly`, `seven_day_opus`…
    public let key: String
    public let name: String
    /// 0 to 100, as the provider reports it.
    public let percentUsed: Double
    public let resetAt: Timestamp?
    /// How long the window runs, when the provider says. A window's start is
    /// its reset time less this.
    public let windowSeconds: Int64?

    public init(key: String, name: String, percentUsed: Double, resetAt: Timestamp?, windowSeconds: Int64?) {
        self.key = key
        self.name = name
        self.percentUsed = percentUsed
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
    }
}

/// Everything one read of a provider's quota returned.
public struct QuotaReading: Sendable {
    public let provider: ProviderKey
    public let observedAt: Timestamp
    /// Where it came from, such as `codex_app_server`; stored with each
    /// snapshot so a figure can be traced to its source.
    public let source: String
    /// Every figure is the account's, across every surface the provider
    /// offers, not this Mac's alone.
    public let scope: QuotaScope
    public let plan: String?
    public let windows: [QuotaWindowReading]
    /// Banked resets the provider reported, or nil when this source cannot
    /// see them. Nil is not "none": it leaves what is known untouched.
    public let bankedResets: [BankedReset]?

    public init(provider: ProviderKey, observedAt: Timestamp, source: String, scope: QuotaScope, plan: String?,
                windows: [QuotaWindowReading], bankedResets: [BankedReset]?) {
        self.provider = provider
        self.observedAt = observedAt
        self.source = source
        self.scope = scope
        self.plan = plan
        self.windows = windows
        self.bankedResets = bankedResets
    }
}

/// The default alert levels, as percentages used. Each quota keeps its own
/// notification state against them.
public enum QuotaThresholds {
    public static let warning = 75.0
    public static let critical = 90.0
    public static let exhausted = 100.0
}

extension QuotaStatus {
    /// The status a percentage used falls in. Staleness and a pending reset
    /// are judged when the figure is shown, not stored with it.
    public init(percentUsed: Double) {
        switch percentUsed {
        case QuotaThresholds.exhausted...: self = .exhausted
        case QuotaThresholds.critical...: self = .critical
        case QuotaThresholds.warning...: self = .warning
        default: self = .healthy
        }
    }
}
