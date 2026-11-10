//
//  QuotaState.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// Whether a provider's quota could be read last time it was asked.
public enum QuotaHealth: Hashable, Sendable {
    case ok
    /// The last read failed. What was read before is still shown, marked
    /// stale; an expired login lands here too.
    case degraded(reason: String, since: Timestamp)
    /// Nothing can be read on this Mac, such as when the tool is not
    /// installed or the account has no subscription limits.
    case unavailable(reason: String)
}

/// One provider's quota as the interface shows it.
public struct ProviderQuotaState: Sendable {
    public let provider: ProviderKey
    public let plan: String?
    public let windows: [QuotaSnapshot]
    /// Soonest expiry first. Held ones are the ones to show.
    public let bankedResets: [BankedReset]
    public let health: QuotaHealth
    /// When a read last succeeded.
    public let lastSuccess: Timestamp?
    /// Each window's burn rate by key, or why there is none.
    public let burnRates: [String: Result<BurnRate, BurnRateGap>]

    public init(provider: ProviderKey, plan: String?, windows: [QuotaSnapshot], bankedResets: [BankedReset],
                health: QuotaHealth, lastSuccess: Timestamp?,
                burnRates: [String: Result<BurnRate, BurnRateGap>] = [:]) {
        self.provider = provider
        self.plan = plan
        self.windows = windows
        self.bankedResets = bankedResets
        self.health = health
        self.lastSuccess = lastSuccess
        self.burnRates = burnRates
    }

    /// A figure older than this is stale even if nothing failed, as after
    /// sleep, until the next read replaces it.
    public static let staleAfter: Int64 = 30 * 60

    /// Stale figures are shown with their age, never replaced by zero.
    public func isStale(at now: Timestamp) -> Bool {
        if case .degraded = health { return true }
        guard let lastSuccess else { return true }
        return now.seconds(since: lastSuccess) > Self.staleAfter
    }

    /// Seconds since the figures were read, for "Last updated 18 min ago".
    public func age(at now: Timestamp) -> Int64? {
        lastSuccess.map { max(0, now.seconds(since: $0)) }
    }

    /// Held banked resets, soonest expiry first.
    public var heldResets: [BankedReset] { bankedResets.filter { $0.status == .held } }

    /// Banked resets the provider stopped reporting without saying they were
    /// spent: unconfirmed, never assumed consumed.
    public var unconfirmedResets: Int { bankedResets.count { $0.status == .unknown } }

    /// Whether every window counts the whole account's use, from any device
    /// or app, rather than this Mac's alone.
    public var isAccountWide: Bool { !windows.isEmpty && windows.allSatisfy { $0.scope == .account } }
}

extension QuotaSnapshot {
    /// The status to show at `now`. Once the reset time passes, the window
    /// is waiting for the provider to confirm the reset, never assumed to
    /// have one.
    public func status(at now: Timestamp) -> QuotaStatus {
        if let resetAt, resetAt <= now { return .resetPending }
        return status
    }
}
