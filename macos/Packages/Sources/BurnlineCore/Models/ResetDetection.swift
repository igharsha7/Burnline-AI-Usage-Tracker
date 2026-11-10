//
//  ResetDetection.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// Something about a quota that the provider has confirmed, for notifications
/// to act on. Only a fresh reading confirms anything: local time passing an
/// old reset time never does.
public enum QuotaEvent: Hashable, Sendable {
    /// A new window began. Unless `cause` is `.scheduled` it began before the
    /// old window was due to end, and its start is a discontinuity
    /// that burn rate must not average across.
    case windowReset(provider: ProviderKey, key: String, cycleToken: String?, cause: ResetCause)
    /// The provider moved the reset time within the same window.
    /// Countdowns follow the new time; nothing re-arms.
    case resetTimeMoved(provider: ProviderKey, key: String, from: Timestamp, to: Timestamp)
    /// A banked reset changed status: newly seen, consumed, expired, or gone
    /// from view without a reason.
    case bankedResetChanged(BankedReset)
}

/// An early reset awaiting its banked-reset explanation. Stored through the
/// grace period so restarting does not lose the reset or its before figure.
public struct PendingQuotaReset: Sendable {
    public let provider: ProviderKey
    public let key: String
    public let cycleToken: String?
    public let before: QuotaSnapshot?
    public let seenAt: Timestamp

    public init(provider: ProviderKey, key: String, cycleToken: String?, before: QuotaSnapshot?, seenAt: Timestamp) {
        self.provider = provider
        self.key = key
        self.cycleToken = cycleToken
        self.before = before
        self.seenAt = seenAt
    }
}

/// Why a window reset.
public enum ResetCause: String, Hashable, Sendable {
    /// The window ran its course.
    case scheduled
    /// The user spent a banked reset: one left the provider's list, or was
    /// marked spent, in the same read.
    case bankedReset = "banked_reset"
    /// The provider reset usage itself, as Codex and Claude sometimes do for
    /// everyone: the window ended early and no banked reset was spent.
    case provider
    /// The window ended early, and the source cannot see banked resets to
    /// say why.
    case early
}

/// Turns a provider's reading into a snapshot that continues the window it
/// belongs to, and says when a window has reset.
///
/// A reset is confirmed when the reset time advances: if the old window had
/// already ended, it was the scheduled reset; if not, usage must also have
/// fallen, which is what spending a banked reset looks like. An advance with
/// usage still rising is the provider moving the time, not a reset. A fall of
/// `resetDrop` points or more with the reset time unchanged, or with none
/// reported, is a reset too: a provider resetting everyone's usage can leave
/// the reset time where it was. Early resets are reported as `.early`; the
/// caller, which sees the banked resets, says which kind they were.
public enum ResetDetector {
    /// How far a reset time may drift within one window. Providers round and
    /// re-derive it; a real reset moves it by hours.
    public static let advanceTolerance: Int64 = 15 * 60
    /// A fall in usage this large within one window is a reset, not rounding.
    public static let resetDrop = 20.0

    public static func snapshot(of window: QuotaWindowReading, in reading: QuotaReading,
                                after previous: QuotaSnapshot?) -> (QuotaSnapshot, QuotaEvent?) {
        let derivedStart = window.resetAt.flatMap { reset in window.windowSeconds.map { reset.adding(seconds: -$0) } }
        var start = previous?.windowStartedAt ?? derivedStart
        var event: QuotaEvent?

        let used = previous?.percentageUsed ?? 0
        let dropped = previous != nil && used - window.percentUsed >= resetDrop
        if let previous, let old = previous.resetAt, let new = window.resetAt,
           new > old.adding(seconds: advanceTolerance) || new < old.adding(seconds: -advanceTolerance) {
            if new > old.adding(seconds: advanceTolerance) {
                let due = old <= reading.observedAt
                if let restarted = previous.windowStartedAt, restarted >= old {
                    // The fall was seen first and already began this window;
                    // the new reset time only confirms it.
                } else if due || window.percentUsed < used {
                    // A scheduled window began when the old one ended.
                    start = derivedStart ?? (due ? old : reading.observedAt)
                    event = .windowReset(provider: reading.provider, key: window.key,
                                         cycleToken: start.map { cycleToken(reading.provider, window.key, $0) },
                                         cause: due ? .scheduled : .early)
                } else {
                    event = .resetTimeMoved(provider: reading.provider, key: window.key, from: old, to: new)
                }
            } else {
                event = .resetTimeMoved(provider: reading.provider, key: window.key, from: old, to: new)
            }
        } else if dropped {
            // The window started over where it stood. Past the old reset time
            // it is the scheduled reset, seen before its new reset time is.
            start = reading.observedAt
            let due = previous?.resetAt.map { $0 <= reading.observedAt } ?? false
            event = .windowReset(provider: reading.provider, key: window.key,
                                 cycleToken: cycleToken(reading.provider, window.key, reading.observedAt),
                                 cause: due ? .scheduled : .early)
        }

        let snapshot = QuotaSnapshot(
            provider: reading.provider, key: window.key, name: window.name, scope: reading.scope,
            observedAt: reading.observedAt, used: nil, remaining: nil, limit: nil, unit: "percent",
            percentageUsed: window.percentUsed, windowStartedAt: start, resetAt: window.resetAt,
            status: QuotaStatus(percentUsed: window.percentUsed), source: reading.source)
        return (snapshot, event)
    }

    /// The same text `QuotaSnapshot.cycleToken` produces.
    static func cycleToken(_ provider: ProviderKey, _ key: String, _ start: Timestamp) -> String {
        "\(provider.rawValue):\(key):\(start.epochSeconds)"
    }
}

/// Keeps the record of banked resets in step with what a provider reports.
///
/// The provider's word decides: a reset it calls redeemed is consumed, one it
/// still lists is held. One that disappears is expired if its expiry has
/// passed, and otherwise of unknown status, never assumed consumed.
public enum BankedResetLedger {
    /// The rows to save: those that are new or whose status or expiry changed.
    /// `observed` nil means the source cannot see banked resets, so nothing
    /// changes.
    public static func reconcile(stored: [BankedReset], observed: [BankedReset]?,
                                 at now: Timestamp) -> [BankedReset] {
        guard let observed else { return [] }
        let known = Dictionary(stored.map { ($0.sourceResetID, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [BankedReset] = []
        for reset in observed {
            let previous = known[reset.sourceResetID]
            let consumedAt = reset.status == .consumed ? (previous?.consumedAt ?? reset.consumedAt ?? now) : nil
            let current = reset.with(status: reset.status, consumedAt: consumedAt,
                                     grantedAt: reset.grantedAt ?? previous?.grantedAt)
            if previous.map({ !$0.sameState(as: current) }) ?? true { changes.append(current) }
        }
        let seen = Set(observed.map(\.sourceResetID))
        for reset in stored where !seen.contains(reset.sourceResetID) && reset.status == .held {
            let expired = reset.expiresAt.map { $0 <= now } ?? false
            changes.append(reset.with(status: expired ? .expired : .unknown, consumedAt: nil,
                                      observedAt: now))
        }
        return changes
    }
}

extension BankedReset {
    func with(status: BankedResetStatus, consumedAt: Timestamp?, grantedAt: Timestamp? = nil,
              observedAt: Timestamp? = nil) -> BankedReset {
        BankedReset(provider: provider, sourceResetID: sourceResetID, appliesToQuotaKey: appliesToQuotaKey,
                    grantedAt: grantedAt ?? self.grantedAt, expiresAt: expiresAt, consumedAt: consumedAt,
                    status: status, source: source, observedAt: observedAt ?? self.observedAt)
    }

    /// Equal apart from when it was last seen.
    func sameState(as other: BankedReset) -> Bool {
        status == other.status && expiresAt == other.expiresAt && appliesToQuotaKey == other.appliesToQuotaKey
            && consumedAt == other.consumedAt
    }
}
