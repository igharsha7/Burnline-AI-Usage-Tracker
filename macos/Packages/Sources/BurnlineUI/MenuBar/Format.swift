//
//  Format.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// Figures as the menu bar and the dashboard write them.
enum Format {
    /// "842", "12.4K", "18.6M", "1.2B".
    static func tokens(_ count: Int64) -> String {
        let value = Double(count)
        func scaled(_ divisor: Double, _ unit: String) -> String {
            let text = String(format: "%.1f", value / divisor)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        switch abs(value) {
        case ..<1_000: return "\(count)"
        case ..<999_950: return scaled(1_000, "K")
        case ..<999_950_000: return scaled(1_000_000, "M")
        default: return scaled(1_000_000_000, "B")
        }
    }

    /// "$12.84", "$1,240.00", in the user's locale.
    static func cost(_ amount: Nanodollars, locale: Locale = .current) -> String {
        currency(locale).string(from: amount.decimalDollars as NSDecimalNumber) ?? "$\(amount.decimalDollars)"
    }

    /// Formatters are costly to make and every table cell asks for one, so
    /// one is kept per locale.
    private static var currencyFormatters: [String: NumberFormatter] = [:]

    private static func currency(_ locale: Locale) -> NumberFormatter {
        if let formatter = currencyFormatters[locale.identifier] { return formatter }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = locale
        currencyFormatters[locale.identifier] = formatter
        return formatter
    }

    /// "842", "44.4K", "1.54M", "135M", "5.98B": up to three significant
    /// figures, as the dashboard's figures read, without trailing zeros.
    static func figure(_ count: Int64) -> String {
        let units: [(Double, String)] = [(1, ""), (1e3, "K"), (1e6, "M"), (1e9, "B"), (1e12, "T")]
        let value = Double(count)
        guard abs(value) >= 1_000 else { return "\(count)" }
        for (index, (divisor, unit)) in units.enumerated().dropFirst() {
            let scaled = value / divisor
            let decimals = abs(scaled) < 10 ? 2 : abs(scaled) < 100 ? 1 : 0
            let text = String(format: "%.\(decimals)f", scaled)
            // 999.6K rounds to 1000K, which reads as the next unit.
            if abs(Double(text) ?? 0) >= 1_000, index < units.count - 1 { continue }
            // "7K", not "7.00K".
            let trimmed = text.contains(".") ? String(text.reversed().drop { $0 == "0" }.drop { $0 == "." }.reversed()) : text
            return trimmed + unit
        }
        return "\(count)"
    }

    /// "78%".
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "26.3%", "<0.1%", "0%": a share of a whole, from a fraction.
    static func share(_ fraction: Double) -> String {
        if fraction <= 0 { return "0%" }
        if fraction < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", fraction * 100)
    }

    /// An axis label: "$150", "$2.50", "300M".
    static func axisCost(_ dollars: Double) -> String {
        dollars == 0 ? "0" : dollars < 10 && dollars.rounded() != dollars
            ? String(format: "$%.2f", dollars) : "$" + figure(Int64(dollars.rounded()))
    }

    /// Claude's quota covers the whole account, so it is named for it.
    static func quotaLabel(_ provider: ProviderKey) -> String {
        provider == .claudeCode ? "Claude" : provider.displayName
    }
}
