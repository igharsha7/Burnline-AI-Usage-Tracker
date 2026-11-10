//
//  ResetDetectionTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Testing

/// Reset detection, banked-reset bookkeeping and quota freshness: the rules
/// the rest of the app relies on being right.
struct ResetDetectionTests {
    static let hour: Int64 = 3_600
    static let fiveHours: Int64 = 5 * hour
    /// 2:00 PM, with the window due to reset at 5:00 PM.
    static let now = Timestamp(epochSeconds: 1_793_541_600)
    static let scheduledReset = now.adding(seconds: 3 * hour)

    static func reading(_ percent: Double, resetAt: Timestamp?, at observed: Timestamp = now,
                        resets: [BankedReset]? = nil) -> QuotaReading {
        QuotaReading(provider: .codex, observedAt: observed, source: "test", scope: .account, plan: "plus",
                     windows: [QuotaWindowReading(key: "five_hour", name: "5-hour", percentUsed: percent,
                                                  resetAt: resetAt, windowSeconds: fiveHours)],
                     bankedResets: resets)
    }

    static func detect(_ reading: QuotaReading, after previous: QuotaSnapshot?) -> (QuotaSnapshot, QuotaEvent?) {
        ResetDetector.snapshot(of: reading.windows[0], in: reading, after: previous)
    }

    static let before = detect(reading(94, resetAt: scheduledReset, at: now.adding(seconds: -600)), after: nil).0

    @Test func `the first reading starts its window from the reset time`() {
        #expect(Self.before.windowStartedAt == Self.scheduledReset.adding(seconds: -Self.fiveHours))
        #expect(Self.before.status == .critical && Self.before.scope == .account)
    }

    @Test func `EC-Q1 a banked reset mid-window is a confirmed early reset`() {
        // Spent at 2:00 PM: the window empties and a new one runs to 7:00 PM.
        let (after, event) = Self.detect(Self.reading(0, resetAt: Self.now.adding(seconds: Self.fiveHours)),
                                         after: Self.before)
        #expect(after.windowStartedAt == Self.now)
        #expect(after.cycleToken != Self.before.cycleToken)
        #expect(event == .windowReset(provider: .codex, key: "five_hour", cycleToken: after.cycleToken, cause: .early))
    }

    @Test func `a scheduled reset is confirmed even when usage has already climbed again`() {
        let later = Self.scheduledReset.adding(seconds: 2 * Self.hour)
        let (after, event) = Self.detect(
            Self.reading(97, resetAt: Self.scheduledReset.adding(seconds: Self.fiveHours), at: later), after: Self.before)
        #expect(after.windowStartedAt == Self.scheduledReset)
        #expect(event == .windowReset(provider: .codex, key: "five_hour", cycleToken: after.cycleToken, cause: .scheduled))
    }

    @Test func `a provider's reset with the reset time unchanged starts a new window`() {
        // Usage for everyone set back to zero, the window's end left alone.
        let (after, event) = Self.detect(Self.reading(0, resetAt: Self.scheduledReset), after: Self.before)
        #expect(after.windowStartedAt == Self.now && after.cycleToken != Self.before.cycleToken)
        #expect(event == .windowReset(provider: .codex, key: "five_hour", cycleToken: after.cycleToken, cause: .early))

        // When the old reset time comes, the window resets as scheduled.
        let next = Self.detect(Self.reading(5, resetAt: Self.scheduledReset.adding(seconds: Self.fiveHours),
                                            at: Self.scheduledReset.adding(seconds: 60)), after: after)
        guard case .windowReset(_, _, _, .scheduled) = next.1 else { Issue.record("\(String(describing: next.1))"); return }
    }

    @Test func `a fall seen before the new reset time is one reset, not two`() {
        let late = Self.scheduledReset.adding(seconds: 60)
        let (dropped, first) = Self.detect(Self.reading(0, resetAt: Self.scheduledReset, at: late), after: Self.before)
        guard case .windowReset(_, _, _, .scheduled) = first else { Issue.record("\(String(describing: first))"); return }
        let (confirmed, second) = Self.detect(
            Self.reading(1, resetAt: Self.scheduledReset.adding(seconds: Self.fiveHours), at: late.adding(seconds: 300)),
            after: dropped)
        #expect(second == nil && confirmed.cycleToken == dropped.cycleToken)
    }

    @Test func `a small fall within the window is rounding, not a reset`() {
        let (after, event) = Self.detect(Self.reading(90, resetAt: Self.scheduledReset), after: Self.before)
        #expect(event == nil && after.cycleToken == Self.before.cycleToken)
    }

    @Test func `EC-Q2 a reset time that moves with usage still rising is not a reset`() {
        let moved = Self.scheduledReset.adding(seconds: Self.hour)
        let (after, event) = Self.detect(Self.reading(96, resetAt: moved), after: Self.before)
        #expect(after.windowStartedAt == Self.before.windowStartedAt && after.resetAt == moved)
        #expect(event == .resetTimeMoved(provider: .codex, key: "five_hour", from: Self.scheduledReset, to: moved))
    }

    @Test func `EC-Q2 drift within the tolerance keeps the window and says nothing`() {
        let (after, event) = Self.detect(Self.reading(95, resetAt: Self.scheduledReset.adding(seconds: 40)),
                                         after: Self.before)
        #expect(event == nil && after.cycleToken == Self.before.cycleToken)
    }

    @Test func `EC-T6 a countdown at zero is pending until the provider confirms`() {
        #expect(Self.before.status(at: Self.scheduledReset.adding(seconds: -1)) == .critical)
        #expect(Self.before.status(at: Self.scheduledReset) == .resetPending)
        // A read that still shows the old window confirms nothing.
        let (_, event) = Self.detect(Self.reading(94, resetAt: Self.scheduledReset, at: Self.scheduledReset),
                                     after: Self.before)
        #expect(event == nil)
    }

    @Test(arguments: [(0.0, QuotaStatus.healthy), (74.9, .healthy), (75, .warning), (90, .critical), (100, .exhausted)])
    func `a percentage falls in its alert band`(percent: Double, status: QuotaStatus) {
        #expect(QuotaStatus(percentUsed: percent) == status)
    }

    // MARK: Banked resets

    static func banked(_ id: String, _ status: BankedResetStatus, expires: Timestamp?) -> BankedReset {
        BankedReset(provider: .codex, sourceResetID: id, appliesToQuotaKey: "codex", grantedAt: nil, expiresAt: expires,
                    consumedAt: nil, status: status, source: "test", observedAt: now)
    }

    @Test func `a newly reported reset is recorded, and an unchanged one is not rewritten`() {
        let held = Self.banked("a", .held, expires: Self.now.adding(seconds: 86_400))
        #expect(BankedResetLedger.reconcile(stored: [], observed: [held], at: Self.now) == [held])
        #expect(BankedResetLedger.reconcile(stored: [held], observed: [held], at: Self.now).isEmpty)
    }

    @Test func `a reset the provider calls redeemed is consumed at the moment it was seen`() {
        let held = Self.banked("a", .held, expires: Self.now.adding(seconds: 86_400))
        let changes = BankedResetLedger.reconcile(stored: [held], observed: [Self.banked("a", .consumed, expires: held.expiresAt)],
                                                  at: Self.now)
        #expect(changes.map(\.status) == [.consumed] && changes.first?.consumedAt == Self.now)
    }

    @Test func `EC-Q6 a reset that vanishes before its expiry becomes unknown, never consumed`() {
        let held = Self.banked("a", .held, expires: Self.now.adding(seconds: 86_400))
        let changes = BankedResetLedger.reconcile(stored: [held], observed: [], at: Self.now)
        #expect(changes.map(\.status) == [.unknown] && changes.first?.consumedAt == nil)
    }

    @Test func `a reset that vanishes after its expiry has expired`() {
        let held = Self.banked("a", .held, expires: Self.now.adding(seconds: -60))
        #expect(BankedResetLedger.reconcile(stored: [held], observed: [], at: Self.now).map(\.status) == [.expired])
    }

    @Test func `a source that cannot see banked resets changes none of them`() {
        let held = Self.banked("a", .held, expires: nil)
        #expect(BankedResetLedger.reconcile(stored: [held], observed: nil, at: Self.now).isEmpty)
    }

    // MARK: Freshness

    static func state(health: QuotaHealth, lastSuccess: Timestamp?) -> ProviderQuotaState {
        ProviderQuotaState(provider: .codex, plan: nil, windows: [Self.before],
                           bankedResets: [Self.banked("b", .expired, expires: nil), Self.banked("a", .held, expires: nil)],
                           health: health, lastSuccess: lastSuccess)
    }

    @Test func `EC-Q3 after a failed read the last figures stay, stale, with their age`() {
        let read = Self.now.adding(seconds: -18 * 60)
        let state = Self.state(health: .degraded(reason: "offline", since: Self.now), lastSuccess: read)
        #expect(state.isStale(at: Self.now) && state.age(at: Self.now) == 18 * 60)
        #expect(state.windows.first?.percentageUsed == 94)
    }

    @Test func `figures go stale with time alone, as after sleep`() {
        let state = Self.state(health: .ok, lastSuccess: Self.now)
        #expect(!state.isStale(at: Self.now.adding(seconds: ProviderQuotaState.staleAfter)))
        #expect(state.isStale(at: Self.now.adding(seconds: ProviderQuotaState.staleAfter + 1)))
        #expect(state.heldResets.map(\.sourceResetID) == ["a"])
    }
}
