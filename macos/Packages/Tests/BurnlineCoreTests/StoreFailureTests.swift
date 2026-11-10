//
//  StoreFailureTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import Testing

/// The ways out the failure screen offers. A wrong one strands the user: a
/// retry that cannot work, or a restore that would discard a newer database.
struct StoreFailureTests {
    /// Every failure, with whether it offers a restore and whether a retry can work.
    static let waysOut: [(StoreFailure, restore: Bool, retry: Bool)] = [
        (.corrupt, true, false),
        (.migrationFailed(backup: URL(filePath: "/backup.sqlite")), true, true),
        (.migrationFailed(backup: nil), true, true),
        (.diskFull, false, true),
        (.anotherInstance, false, false),
        (.newerVersion(found: 20, supported: 14), false, false),
        (.other("database is locked"), false, true),
    ]

    @Test(arguments: waysOut)
    func `EC-D1 to EC-D6 each failure offers only the ways out that can work`(
        failure: StoreFailure, restore: Bool, retry: Bool) {
        #expect(failure.offersRestore == restore)
        #expect(failure.canRetry == retry)
    }

    @Test func `EC-D3 a failed migration names its backup only when one was taken`() {
        #expect(StoreFailure.migrationFailed(backup: URL(filePath: "/backup.sqlite")).explanation.contains("A copy was taken"))
        #expect(!StoreFailure.migrationFailed(backup: nil).explanation.contains("A copy was taken"))
    }

    @Test func `EC-D6 a newer database says which versions`() {
        let explanation = StoreFailure.newerVersion(found: 20, supported: 14).explanation
        #expect(explanation.contains("20") && explanation.contains("14"))
    }

    @Test func `EC-D1 a full disk promises nothing saved was lost`() {
        #expect(StoreFailure.diskFull.explanation.contains("Nothing already saved was lost"))
    }

    @Test func `an unknown failure passes SQLite's words through`() {
        #expect(StoreFailure.other("database is locked").cause == "database is locked")
        #expect(StoreFailure.other("database is locked").explanation.contains("database is locked"))
    }
}

/// How a provider's quota is labelled and counted for the interface.
struct QuotaStateTests {
    static func window(scope: QuotaScope) -> QuotaSnapshot {
        QuotaSnapshot(provider: .codex, key: "primary", name: "5-hour", scope: scope,
                      observedAt: Timestamp(epochSeconds: 0), used: nil, remaining: nil, limit: nil, unit: nil,
                      percentageUsed: 40, windowStartedAt: nil, resetAt: nil, status: .healthy, source: "test")
    }

    static func reset(_ id: String, _ status: BankedResetStatus) -> BankedReset {
        BankedReset(provider: .codex, sourceResetID: id, appliesToQuotaKey: "codex", grantedAt: nil,
                    expiresAt: nil, consumedAt: nil, status: status, source: "test",
                    observedAt: Timestamp(epochSeconds: 0))
    }

    static func state(windows: [QuotaSnapshot] = [], resets: [BankedReset] = []) -> ProviderQuotaState {
        ProviderQuotaState(provider: .codex, plan: nil, windows: windows, bankedResets: resets,
                           health: .ok, lastSuccess: Timestamp(epochSeconds: 0))
    }

    @Test func `EC-Q5 quota is account-wide only when every window is`() {
        #expect(Self.state(windows: [Self.window(scope: .account), Self.window(scope: .account)]).isAccountWide)
        #expect(!Self.state(windows: [Self.window(scope: .account), Self.window(scope: .surface)]).isAccountWide)
    }

    @Test func `EC-Q5 no windows is not labelled account-wide`() {
        #expect(!Self.state().isAccountWide)
    }

    @Test func `EC-Q6 resets that vanished unconfirmed are counted apart from held, spent and expired ones`() {
        let state = Self.state(resets: [Self.reset("a", .held), Self.reset("b", .unknown), Self.reset("c", .unknown),
                                        Self.reset("d", .consumed), Self.reset("e", .expired)])
        #expect(state.unconfirmedResets == 2)
        #expect(state.heldResets.map(\.sourceResetID) == ["a"])
    }
}
