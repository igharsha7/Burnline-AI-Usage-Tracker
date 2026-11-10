//
//  QuotaActor.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineProviders
import BurnlineStore
import Foundation

/// Live quota state for every provider: read on a conservative schedule,
/// recorded as history, and checked for resets.
///
/// A reset is reported only when a fresh read confirms it: refresh first,
/// confirm second, notify third. Notifications act on `onUpdate`. A read that
/// fails leaves the last figures in place, marked stale with their age, never
/// zero. One provider failing never touches another's state, and each quota
/// is tracked on its own, so simultaneous resets are separate events.
public actor QuotaActor {
    let database: BurnlineDatabase
    let readers: [any QuotaReader]
    /// The providers chosen for tracking; quota is read for no other, so an
    /// untracked tool's credentials are never touched.
    public private(set) var tracked: Set<ProviderKey>
    let clock: any WallClock
    let power: any PowerSource

    /// Called after every successful read, before `refresh` returns. A failed
    /// read calls nothing, so stale figures never alert.
    let onUpdate: @Sendable (QuotaUpdate) async -> Void
    /// Called with the provider's state after every read, failed or not,
    /// for the interface.
    let onStateChange: @Sendable (ProviderQuotaState) async -> Void

    private var records: [ProviderKey: Record] = [:]
    private var inFlight: Set<ProviderKey> = []

    /// A snapshot is recorded when anything about it changes, and at least
    /// this often while unchanged, so history shows the quiet hours too.
    static let unchangedRecordInterval: Int64 = 3_600

    private struct Record {
        /// The newest snapshot of each window, as shown.
        var current: [String: QuotaSnapshot] = [:]
        /// The last snapshot of each window written to the database.
        var recorded: [String: QuotaSnapshot] = [:]
        var resets: [String: BankedReset] = [:]
        var plan: String?
        var health = QuotaHealth.ok
        var lastAttempt: Timestamp?
        var lastSuccess: Timestamp?
        var failures = 0
        var lastUsage: Timestamp?
        var burnRates: [String: Result<BurnRate, BurnRateGap>] = [:]
        /// Early resets not yet explained, by quota key.
        var pending: [String: PendingQuotaReset] = [:]
    }

    /// How long an early reset waits for a banked reset to show as spent:
    /// two reads while the provider is in use.
    static let explanationGrace: Int64 = 10 * 60

    public init(database: BurnlineDatabase, readers: [any QuotaReader],
                tracked: Set<ProviderKey> = Set(ProviderKey.allCases), clock: any WallClock = SystemClock(),
                power: any PowerSource = SystemPowerSource(),
                onUpdate: @escaping @Sendable (QuotaUpdate) async -> Void = { _ in },
                onStateChange: @escaping @Sendable (ProviderQuotaState) async -> Void = { _ in }) {
        self.database = database
        self.readers = readers
        self.tracked = tracked
        self.clock = clock
        self.power = power
        self.onUpdate = onUpdate
        self.onStateChange = onStateChange
    }

    // MARK: Reading

    /// The readers of tracked providers.
    private var trackedReaders: [any QuotaReader] { readers.filter { tracked.contains($0.provider) } }

    /// Each of `state`'s windows with its readings so far and the windows
    /// before it, for the Limits page. Reads the store only, so it never
    /// waits on a quota read in progress.
    public nonisolated func history(of state: ProviderQuotaState) -> [String: LimitHistory] {
        let cycles = (try? database.quota.cycles()) ?? []
        var history: [String: LimitHistory] = [:]
        for window in state.windows {
            let start = window.windowStartedAt ?? window.observedAt
            let observations = (try? database.quota.history(provider: state.provider, key: window.key, since: start)) ?? []
            history[window.key] = LimitHistory(window: window, observations: observations, cycles: cycles)
        }
        return history
    }

    /// Starts reading `provider`'s quota, with a read now.
    public func track(_ provider: ProviderKey) async {
        guard tracked.insert(provider).inserted else { return }
        await refresh(provider)
    }

    /// Reads `provider` now, unless a read of it is already under way or it
    /// is not tracked.
    @discardableResult
    public func refresh(_ provider: ProviderKey) async -> ProviderQuotaState {
        guard tracked.contains(provider), let reader = readers.first(where: { $0.provider == provider }) else {
            return state(of: provider)
        }
        guard inFlight.insert(provider).inserted else { return state(of: provider) }
        defer { inFlight.remove(provider) }
        loadIfNeeded(provider)
        records[provider]?.lastAttempt = clock.now
        do {
            let reading = try await reader.read()
            if records[provider]?.lastSuccess.map({ reading.observedAt >= $0 }) ?? true {
                await onUpdate(apply(reading))
            } else {
                fail(provider, .unreachable("the available quota reading is older than the last observation"))
            }
        } catch {
            fail(provider, error)
        }
        let state = state(of: provider)
        await onStateChange(state)
        return state
    }

    /// Reads every provider now, as after waking from sleep, when stale
    /// figures must be refreshed before any reset is judged.
    public func refreshAll() async {
        for reader in trackedReaders { await refresh(reader.provider) }
    }

    /// Reads every provider whose next read is due.
    public func refreshDue() async {
        let now = clock.now
        for reader in trackedReaders where nextRefresh(reader.provider) <= now { await refresh(reader.provider) }
    }

    /// New usage was imported for `provider`: while it is in use, its quota
    /// is read more often.
    public func noteUsage(_ provider: ProviderKey) {
        loadIfNeeded(provider)
        records[provider]?.lastUsage = clock.now
    }

    /// Reads on schedule until the calling task is cancelled.
    public func run<C: Clock<Duration>>(clock sleeper: C = ContinuousClock()) async {
        repeat {
            await refreshDue()
            let now = clock.now
            let soonest = trackedReaders.map { nextRefresh($0.provider) }.min() ?? now.adding(seconds: QuotaSchedule.idleInterval)
            let wait = min(max(soonest.seconds(since: now), Self.minimumWait), QuotaSchedule.idleInterval)
            guard (try? await sleeper.sleep(for: .seconds(wait))) != nil else { return }
        } while !Task.isCancelled
    }

    static let minimumWait: Int64 = 5

    func nextRefresh(_ provider: ProviderKey) -> Timestamp {
        loadIfNeeded(provider)
        let record = records[provider] ?? Record()
        let now = clock.now
        return QuotaSchedule.next(.init(
            lastAttempt: record.lastAttempt, consecutiveFailures: record.failures, lastUsage: record.lastUsage,
            nearLimit: record.current.values.contains { ($0.percentageUsed ?? 0) >= QuotaThresholds.critical },
            onBattery: power.onBattery,
            // A reset is still pending until its grace has passed, so a read
            // just after it keeps the confirmation deadline.
            nextReset: record.current.values.compactMap(\.resetAt)
                .filter { $0.adding(seconds: QuotaSchedule.resetGrace) > (record.lastAttempt ?? now) }.min()),
            now: now)
    }

    // MARK: State

    public func state(of provider: ProviderKey) -> ProviderQuotaState {
        loadIfNeeded(provider)
        let record = records[provider] ?? Record()
        let now = clock.now
        return ProviderQuotaState(
            provider: provider, plan: record.plan,
            windows: record.current.values.sorted { $0.key < $1.key },
            bankedResets: record.resets.values.sorted {
                ($0.expiresAt?.epochSeconds ?? .max, $0.sourceResetID) < ($1.expiresAt?.epochSeconds ?? .max, $1.sourceResetID)
            },
            health: record.health, lastSuccess: record.lastSuccess,
            burnRates: record.burnRates.mapValues { rate in
                // A rate goes stale with the figure it came from.
                rate.flatMap { now.seconds(since: $0.observedAt) <= ProviderQuotaState.staleAfter
                    ? .success($0) : .failure(.stale) }
            })
    }

    public func states() -> [ProviderQuotaState] { trackedReaders.map { state(of: $0.provider) } }

    // MARK: Applying a reading

    private func apply(_ reading: QuotaReading) -> QuotaUpdate {
        let provider = reading.provider
        var record = records[provider] ?? Record()
        let previous = record.current
        var current: [String: QuotaSnapshot] = [:]
        var events: [QuotaEvent] = []
        for window in reading.windows {
            let (snapshot, event) = ResetDetector.snapshot(of: window, in: reading, after: record.current[window.key])
            current[window.key] = snapshot
            if let event { events.append(event) }
            if Self.worthRecording(snapshot, after: record.recorded[window.key]) {
                // History is a convenience; a failed write must not lose the live figure.
                if (try? database.quota.append(snapshot)) != nil { record.recorded[window.key] = snapshot }
            }
        }
        record.current = current
        record.burnRates = current.mapValues { burnRate(of: $0) }

        let changes = BankedResetLedger.reconcile(stored: Array(record.resets.values), observed: reading.bankedResets,
                                                  at: reading.observedAt)
        // A held reset spent, or gone without expiring, in this same read.
        let spent = changes.contains { reset in
            (reset.status == .consumed || reset.status == .unknown)
                && record.resets[reset.sourceResetID]?.status == .held
        }
        for reset in changes {
            try? database.quota.save(reset)
            record.resets[reset.sourceResetID] = reset
            events.append(.bankedResetChanged(reset))
        }
        // The detector cannot tell a banked reset from the provider's own;
        // the banked resets can, when this source sees them. One spent now
        // explains every early reset waiting; without one, a reset waits out
        // the grace before it is called the provider's.
        var before = previous
        func explain(_ waiting: PendingQuotaReset, as cause: ResetCause) {
            events.append(.windowReset(provider: waiting.provider, key: waiting.key, cycleToken: waiting.cycleToken,
                                       cause: cause))
            before[waiting.key] = waiting.before
            record.pending[waiting.key] = nil
            try? database.quota.removePending(provider: provider, key: waiting.key)
        }
        let sees = reading.bankedResets != nil
        let fresh = events.compactMap { event -> PendingQuotaReset? in
            guard case .windowReset(let provider, let key, let token, .early) = event else { return nil }
            return PendingQuotaReset(provider: provider, key: key, cycleToken: token, before: previous[key],
                                seenAt: reading.observedAt)
        }
        events.removeAll { if case .windowReset(_, _, _, .early) = $0 { sees } else { false } }
        for waiting in record.pending.values.sorted(by: { $0.key < $1.key }) {
            // An explanation belongs to the cycle that dropped. A later
            // reset must keep its own before figure and notification state.
            if let window = current[waiting.key], window.cycleToken != waiting.cycleToken {
                record.pending[waiting.key] = nil
                try? database.quota.removePending(provider: provider, key: waiting.key)
                continue
            }
            if sees, spent { explain(waiting, as: .bankedReset) }
            else if reading.observedAt.seconds(since: waiting.seenAt) >= Self.explanationGrace
                || fresh.contains(where: { $0.key == waiting.key }) {
                explain(waiting, as: sees ? .provider : .early)
            }
        }
        if sees {
            for waiting in fresh {
                if spent { explain(waiting, as: .bankedReset) } else {
                    record.pending[waiting.key] = waiting
                    try? database.quota.savePending(waiting)
                }
            }
        }

        record.plan = reading.plan ?? record.plan
        record.health = .ok
        record.lastSuccess = reading.observedAt
        record.failures = 0
        records[provider] = record
        return QuotaUpdate(previous: before, state: state(of: provider), events: events)
    }

    /// The window's rate from its recorded history and its newest figure.
    private func burnRate(of snapshot: QuotaSnapshot) -> Result<BurnRate, BurnRateGap> {
        let since = snapshot.observedAt.adding(seconds: -BurnRateEstimator.lookback)
        var points = (try? database.quota.history(provider: snapshot.provider, key: snapshot.key, since: since)) ?? []
        if points.last?.observedAt != snapshot.observedAt { points.append(snapshot) }
        return BurnRateEstimator.estimate(points, at: clock.now)
    }

    private func fail(_ provider: ProviderKey, _ error: QuotaReadError) {
        var record = records[provider] ?? Record()
        record.failures += 1
        switch error {
        case .notInstalled, .unsupported:
            record.health = .unavailable(reason: error.reason)
        default:
            let since = if case .degraded(_, let since) = record.health { since } else { clock.now }
            record.health = .degraded(reason: error.reason, since: since)
        }
        records[provider] = record
    }

    static func worthRecording(_ snapshot: QuotaSnapshot, after previous: QuotaSnapshot?) -> Bool {
        guard let previous else { return true }
        return snapshot.percentageUsed != previous.percentageUsed || snapshot.resetAt != previous.resetAt
            || snapshot.windowStartedAt != previous.windowStartedAt || snapshot.status != previous.status
            || snapshot.name != previous.name
            || snapshot.observedAt.seconds(since: previous.observedAt) >= unchangedRecordInterval
    }

    /// Picks up where the last run left off: the last recorded figure of
    /// each window, shown as stale until a read confirms it, and the banked
    /// resets known so far.
    private func loadIfNeeded(_ provider: ProviderKey) {
        guard records[provider] == nil else { return }
        var record = Record()
        let latest = (try? database.quota.latest(provider: provider)) ?? []
        for snapshot in latest {
            record.current[snapshot.key] = snapshot
            record.recorded[snapshot.key] = snapshot
        }
        for reset in (try? database.quota.bankedResets(for: provider)) ?? [] {
            record.resets[reset.sourceResetID] = reset
        }
        for pending in (try? database.quota.pendingResets(provider: provider)) ?? [] {
            record.pending[pending.key] = pending
        }
        // Figures from an earlier run are as old as they are.
        record.lastSuccess = latest.map(\.observedAt).max()
        records[provider] = record
    }
}

/// What one successful read changed, for notifications.
public struct QuotaUpdate: Sendable {
    /// Each window's figure from before the read, by key; for a reset
    /// explained only now, its figure from before that reset.
    public let previous: [String: QuotaSnapshot]
    public let state: ProviderQuotaState
    /// Confirmed resets, moved reset times and banked-reset changes.
    public let events: [QuotaEvent]
}
