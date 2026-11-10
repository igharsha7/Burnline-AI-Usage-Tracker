//
//  Quota.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// The `quota_snapshots.status` column.
public enum QuotaStatus: String, Sendable, CaseIterable, Codable {
    case healthy, warning, critical, exhausted
    case resetPending = "reset_pending"
    case unavailable, stale, unknown
}

/// What a quota figure covers. Some providers report usage across the whole
/// account rather than for the one tool Burnline reads, and that must be
/// labelled rather than passed off as the tool's own.
public enum QuotaScope: String, Sendable, CaseIterable, Codable {
    case account
    case surface
}

/// One observation of a provider's quota. Quota state is a separate system from
/// usage history: token counts cannot reproduce a subscription allowance.
///
/// Usage amounts are plain numbers in the provider's own unit, not money, so
/// they are floating point like the schema's `REAL` columns.
public struct QuotaSnapshot: Hashable, Sendable {
    public let provider: ProviderKey
    public let key: String
    public let name: String
    public let scope: QuotaScope
    public let observedAt: Timestamp
    public let used: Double?
    public let remaining: Double?
    public let limit: Double?
    public let unit: String?
    public let percentageUsed: Double?
    public let windowStartedAt: Timestamp?
    /// When the provider says this window resets. It can move: a banked reset
    /// ends the window early.
    public let resetAt: Timestamp?
    public let status: QuotaStatus
    public let source: String

    public init(provider: ProviderKey, key: String, name: String, scope: QuotaScope,
                observedAt: Timestamp, used: Double?, remaining: Double?, limit: Double?,
                unit: String?, percentageUsed: Double?, windowStartedAt: Timestamp?,
                resetAt: Timestamp?, status: QuotaStatus, source: String) {
        self.provider = provider
        self.key = key
        self.name = name
        self.scope = scope
        self.observedAt = observedAt
        self.used = used
        self.remaining = remaining
        self.limit = limit
        self.unit = unit
        self.percentageUsed = percentageUsed
        self.windowStartedAt = windowStartedAt
        self.resetAt = resetAt
        self.status = status
        self.source = source
    }

    /// Identifies the window itself: quota identity plus window start.
    /// Notification deduplication keys on this rather than on `resetAt`,
    /// because a banked reset moves `resetAt` and keying on it would suppress
    /// the re-armed alert. Nil when the provider does not report a window
    /// start.
    public var cycleToken: String? {
        windowStartedAt.map { "\(provider.rawValue):\(key):\($0.epochSeconds)" }
    }
}

/// The `banked_resets.status` column. `unknown` is required: Burnline observes
/// rather than controls these, so a reset that disappears without an
/// observable transition is not guessed to be consumed.
public enum BankedResetStatus: String, Sendable, CaseIterable, Codable {
    case held, consumed, expired, unknown
}

/// A consumable that clears a usage window early.
///
/// It is not extra allowance: it does not raise a limit or add capacity. It
/// sets consumed usage back to zero and is spent doing so. Unused, it expires
/// and is lost. A window *resets*; a banked reset *expires*.
public struct BankedReset: Hashable, Sendable {
    public let provider: ProviderKey
    public let sourceResetID: String
    public let appliesToQuotaKey: String?
    public let grantedAt: Timestamp?
    public let expiresAt: Timestamp?
    public let consumedAt: Timestamp?
    public let status: BankedResetStatus
    public let source: String
    public let observedAt: Timestamp

    public init(provider: ProviderKey, sourceResetID: String, appliesToQuotaKey: String?,
                grantedAt: Timestamp?, expiresAt: Timestamp?, consumedAt: Timestamp?,
                status: BankedResetStatus, source: String, observedAt: Timestamp) {
        self.provider = provider
        self.sourceResetID = sourceResetID
        self.appliesToQuotaKey = appliesToQuotaKey
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
        self.status = status
        self.source = source
        self.observedAt = observedAt
    }

    /// Seconds left to use this reset, for the expiry countdown. Nil unless it
    /// is held and has a known expiry; zero once the expiry has passed but the
    /// provider has not yet confirmed it, since that is never assumed.
    public func secondsUntilExpiry(at now: Timestamp) -> Int64? {
        guard status == .held, let expiresAt else { return nil }
        return max(0, expiresAt.seconds(since: now))
    }
}
