//
//  MoneyTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Testing

struct MoneyTests {
    static let fifteenDollars = Nanodollars(decimalString: "15")!

    @Test func `EC-R6 a billion tokens at $15 per million costs $15,000 without overflow`() throws {
        let tokens: Int64 = 1_000_000_000
        // The naive product is what the contracts warn about.
        #expect(tokens.multipliedReportingOverflow(by: Self.fifteenDollars.raw).overflow)

        let cost = try Nanodollars.cost(tokens: tokens, ratePerMillionTokens: Self.fifteenDollars)
        #expect(cost == Nanodollars(decimalString: "15000"))
    }

    @Test func `EC-R6 a cost too large for 64 bits throws instead of wrapping`() {
        #expect(throws: MoneyError.overflow) {
            try Nanodollars.cost(tokens: .max, ratePerMillionTokens: Self.fifteenDollars)
        }
    }

    @Test func `the largest token count still prices at a tiny rate`() throws {
        // 9_223_372_036_854_775_807 / 10⁶ = 9_223_372_036_854.775807, rounds up.
        let cost = try Nanodollars.cost(tokens: .max, ratePerMillionTokens: Nanodollars(raw: 1))
        #expect(cost.raw == 9_223_372_036_855)
    }

    /// A rate of one nanodollar per million tokens makes the exact result
    /// tokens / 10⁶, so each case lands precisely on the rounding rule.
    @Test(arguments: [
        (400_000, 0),     // 0.4 → down
        (500_000, 0),     // 0.5 → nearest even, 0
        (600_000, 1),     // 0.6 → up
        (1_500_000, 2),   // 1.5 → nearest even, 2
        (2_500_000, 2),   // 2.5 → nearest even, 2
        (3_500_000, 4),   // 3.5 → nearest even, 4
    ] as [(Int64, Int64)])
    func `cost rounds half to even`(tokens: Int64, expected: Int64) throws {
        let cost = try Nanodollars.cost(tokens: tokens, ratePerMillionTokens: Nanodollars(raw: 1))
        #expect(cost.raw == expected)
    }

    @Test func `negative tokens or rates are rejected`() {
        #expect(throws: MoneyError.negativeInput) {
            try Nanodollars.cost(tokens: -1, ratePerMillionTokens: Self.fifteenDollars)
        }
        #expect(throws: MoneyError.negativeInput) {
            try Nanodollars.cost(tokens: 1, ratePerMillionTokens: Nanodollars(raw: -1))
        }
    }

    @Test(arguments: [
        ("15", 15_000_000_000),
        ("0.30", 300_000_000),
        ("3.000000001", 3_000_000_001),
        ("-1.5", -1_500_000_000),
        ("0", 0),
    ] as [(String, Int64)])
    func `decimal prices parse exactly`(text: String, raw: Int64) {
        #expect(Nanodollars(decimalString: text)?.raw == raw)
    }

    @Test(arguments: ["", "abc", "1.", ".5", "1e3", "1,000", " 1", "1.0000000001", "99999999999"])
    func `malformed or unrepresentable prices are refused`(text: String) {
        #expect(Nanodollars(decimalString: text) == nil)
    }

    @Test func `addition reports overflow`() throws {
        #expect(try Nanodollars(raw: 2).adding(Nanodollars(raw: 3)) == Nanodollars(raw: 5))
        #expect(throws: MoneyError.overflow) {
            try Nanodollars(raw: .max).adding(Nanodollars(raw: 1))
        }
    }
}

struct TokenCountsTests {
    @Test func `processed counts cached reads but not reasoning or cache writes`() throws {
        let tokens = try TokenCounts(input: 100, cachedInput: 50, cacheWrite: 999, output: 20, reasoning: 7)
        #expect(tokens.processed == 170)
    }

    @Test func `negative counts are rejected by name`() {
        #expect(throws: TokenCountError.negative(field: "output")) {
            try TokenCounts(input: 1, output: -1)
        }
    }

    @Test func `EC-R6 a processed total past 64 bits is rejected`() {
        #expect(throws: TokenCountError.overflow) {
            try TokenCounts(input: .max, output: 1)
        }
    }
}
