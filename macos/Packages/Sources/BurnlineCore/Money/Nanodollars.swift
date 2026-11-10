//
//  Nanodollars.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// USD held as integer nanodollars: dollars × 10⁹, in 64 bits, covering about
/// ±9.2 billion dollars.
///
/// Nothing here touches floating point. Prices enter through
/// `init?(decimalString:)`, which is exact, and costs come out of
/// `cost(tokens:ratePerMillionTokens:)`, which uses a 128-bit intermediate.
/// `ArchitectureTests` rejects any `Double` or `Float` in this folder.
public struct Nanodollars: Hashable, Comparable, Sendable {
    public static let perDollar: Int64 = 1_000_000_000
    public static let zero = Nanodollars(raw: 0)

    /// Rates are quoted per million tokens, as providers publish them.
    public static let tokensPerRateUnit: UInt64 = 1_000_000

    public let raw: Int64

    public init(raw: Int64) { self.raw = raw }

    /// Parses a plain decimal dollar amount such as `"15"`, `"0.30"` or
    /// `"-1.5"`. Returns nil for anything else, for more than nine fractional
    /// digits (which would need rounding), and for amounts out of range.
    public init?(decimalString: String) {
        guard let match = decimalString.wholeMatch(of: /(-)?([0-9]+)(?:\.([0-9]{1,9}))?/),
              let whole = Int64(match.2) else { return nil }
        let fractionDigits = match.3.map(String.init) ?? ""
        let paddedFraction = fractionDigits + String(repeating: "0", count: 9 - fractionDigits.count)
        guard let fraction = Int64(paddedFraction) else { return nil }

        let (scaled, overflowed) = whole.multipliedReportingOverflow(by: Self.perDollar)
        guard !overflowed else { return nil }
        let (magnitude, overflowedSum) = scaled.addingReportingOverflow(fraction)
        guard !overflowedSum else { return nil }
        self.raw = match.1 == nil ? magnitude : -magnitude
    }

    /// The amount in dollars, exactly. For display and export only.
    public var decimalDollars: Decimal { Decimal(raw) / Decimal(Self.perDollar) }

    public func adding(_ other: Nanodollars) throws(MoneyError) -> Nanodollars {
        let (sum, overflowed) = raw.addingReportingOverflow(other.raw)
        guard !overflowed else { throw .overflow }
        return Nanodollars(raw: sum)
    }

    public static func < (a: Self, b: Self) -> Bool { a.raw < b.raw }
}

public enum MoneyError: Error, Equatable, Sendable {
    case negativeInput
    case overflow
}

extension Nanodollars {
    /// `round_half_even(tokens × rate / 1_000_000)`, the cost formula from the
    /// contracts document.
    ///
    /// The product is formed in 128 bits because it routinely exceeds 64:
    /// 10⁹ tokens at $15 per million is 1.5 × 10¹⁹ before the division.
    /// Throws rather than wrapping when even the final cost cannot be
    /// represented.
    public static func cost(tokens: Int64,
                            ratePerMillionTokens rate: Nanodollars) throws(MoneyError) -> Nanodollars {
        guard tokens >= 0, rate.raw >= 0 else { throw .negativeInput }

        let product = UInt64(tokens).multipliedFullWidth(by: UInt64(rate.raw))
        // dividingFullWidth traps when the quotient needs more than 64 bits.
        guard product.high < tokensPerRateUnit else { throw .overflow }
        let (quotient, remainder) = tokensPerRateUnit.dividingFullWidth(product)

        guard quotient <= UInt64(Int64.max) else { throw .overflow }
        let twiceRemainder = remainder * 2
        let roundsUp = twiceRemainder > tokensPerRateUnit
            || (twiceRemainder == tokensPerRateUnit && quotient & 1 == 1)
        let rounded = roundsUp ? quotient + 1 : quotient
        guard rounded <= UInt64(Int64.max) else { throw .overflow }
        return Nanodollars(raw: Int64(rounded))
    }
}
