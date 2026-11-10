//
//  MenuBarTitle.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import Foundation

/// What the menu-bar item shows beside its icon. Today's cost by default.
public enum MenuBarTitleMode: String, CaseIterable, Identifiable, Sendable {
    case iconOnly = "icon"
    case todayCost = "cost"
    case todayTokens = "tokens"
    case highestQuota
    case providerQuotas

    public static let storageKey = "menuBarTitle"
    public static let `default` = MenuBarTitleMode.todayCost

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly: "Icon Only"
        case .todayCost: "Today's Cost"
        case .todayTokens: "Today's Tokens"
        case .highestQuota: "Highest Quota"
        case .providerQuotas: "Each Provider's Quota"
        }
    }

    /// The title text, or nil for the icon alone. Quota modes take each
    /// provider's fullest window.
    func text(today: TodayStatus?, quotas: [ProviderQuotaState], locale: Locale = .current) -> String? {
        let fullest = quotas.compactMap { state in
            state.windows.compactMap(\.percentageUsed).max().map { (state.provider, $0) }
        }
        switch self {
        case .iconOnly: return nil
        case .todayCost: return today.map { Format.cost($0.cost, locale: locale) }
        case .todayTokens: return today.map { Format.tokens($0.tokens) }
        case .highestQuota: return fullest.map(\.1).max().map(Format.percent)
        case .providerQuotas:
            guard !fullest.isEmpty else { return nil }
            return fullest.map { "\(Self.letter($0.0))\(Int($0.1.rounded()))" }.joined(separator: " ")
        }
    }

    /// Each provider's letter: C for Codex, A for Anthropic's Claude, Cu for Cursor.
    static func letter(_ provider: ProviderKey) -> String {
        switch provider {
        case .codex: "C"
        case .claudeCode: "A"
        case .cursor: "Cu"
        }
    }
}
