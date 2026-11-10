//
//  ModelTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Testing

struct PricingVersionTests {
    static func version(from: Int64, until: Int64?) -> PricingVersion {
        PricingVersion(id: 1, modelID: 1, validFrom: Timestamp(epochSeconds: from),
                       validUntil: until.map(Timestamp.init(epochSeconds:)),
                       rates: TokenRates(), source: "test", confidence: .exact)
    }

    @Test func `validity includes the start and excludes the end`() {
        let version = Self.version(from: 100, until: 200)
        #expect(!version.applies(at: Timestamp(epochSeconds: 99)))
        #expect(version.applies(at: Timestamp(epochSeconds: 100)))
        #expect(version.applies(at: Timestamp(epochSeconds: 199)))
        #expect(!version.applies(at: Timestamp(epochSeconds: 200)))
    }

    @Test func `the current version has no end`() {
        #expect(Self.version(from: 100, until: nil).applies(at: Timestamp(epochSeconds: .max)))
    }

    @Test func `an unpriced event has no amount and says why`() {
        let cost = CostAttribution.unpriced(.nonModel)
        #expect(cost.amount == nil)
        #expect(cost != .unpriced(.unknownModel))
    }
}

struct QuotaTests {
    static func snapshot(windowStart: Int64?, resetAt: Int64?) -> QuotaSnapshot {
        QuotaSnapshot(provider: .codex, key: "five_hour", name: "5-hour", scope: .account,
                      observedAt: Timestamp(epochSeconds: 0), used: nil, remaining: nil, limit: nil,
                      unit: nil, percentageUsed: 40, windowStartedAt: windowStart.map(Timestamp.init(epochSeconds:)),
                      resetAt: resetAt.map(Timestamp.init(epochSeconds:)), status: .healthy, source: "test")
    }

    @Test func `EC-Q2 the cycle token ignores a moved reset time`() {
        let before = Self.snapshot(windowStart: 1_000, resetAt: 19_000)
        let resetMoved = Self.snapshot(windowStart: 1_000, resetAt: 5_000)
        #expect(before.cycleToken == resetMoved.cycleToken)
    }

    @Test func `EC-Q1 a banked reset starts a new cycle`() {
        let before = Self.snapshot(windowStart: 1_000, resetAt: 19_000)
        let afterBankedReset = Self.snapshot(windowStart: 7_200, resetAt: 25_200)
        #expect(before.cycleToken != afterBankedReset.cycleToken)
    }

    @Test func `no window start means no cycle token`() {
        #expect(Self.snapshot(windowStart: nil, resetAt: 19_000).cycleToken == nil)
    }
}

struct BankedResetTests {
    static func reset(status: BankedResetStatus, expiresAt: Int64?) -> BankedReset {
        BankedReset(provider: .codex, sourceResetID: "r1", appliesToQuotaKey: "weekly",
                    grantedAt: nil, expiresAt: expiresAt.map(Timestamp.init(epochSeconds:)), consumedAt: nil,
                    status: status, source: "test", observedAt: Timestamp(epochSeconds: 0))
    }

    @Test func `a held reset counts down to its expiry`() {
        let reset = Self.reset(status: .held, expiresAt: 10_000)
        #expect(reset.secondsUntilExpiry(at: Timestamp(epochSeconds: 6_400)) == 3_600)
    }

    @Test func `EC-Q6 a passed expiry reads zero rather than assuming the reset is gone`() {
        let reset = Self.reset(status: .held, expiresAt: 10_000)
        #expect(reset.secondsUntilExpiry(at: Timestamp(epochSeconds: 20_000)) == 0)
    }

    @Test(arguments: [BankedResetStatus.consumed, .expired, .unknown])
    func `only a held reset has a countdown`(status: BankedResetStatus) {
        #expect(Self.reset(status: status, expiresAt: 10_000)
            .secondsUntilExpiry(at: Timestamp(epochSeconds: 0)) == nil)
    }
}

struct SecretStringTests {
    static let token = "sk-live-do-not-print"

    @Test func `a secret never prints its value`() {
        let secret = SecretString(Self.token)
        var dumped = ""
        dump(secret, to: &dumped)

        for rendering in [secret.description, secret.debugDescription, "\(secret)",
                          String(describing: secret), String(reflecting: secret), dumped] {
            #expect(!rendering.contains(Self.token), "leaked through: \(rendering)")
        }
    }

    @Test func `the value is available inside a single use`() {
        let secret = SecretString(Self.token)
        #expect(secret.withValue { $0 } == Self.token)
        #expect(!secret.isEmpty)
        #expect(SecretString("").isEmpty)
    }
}
