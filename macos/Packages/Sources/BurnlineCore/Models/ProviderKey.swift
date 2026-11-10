//
//  ProviderKey.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// The providers Burnline knows. Raw values are the `providers.key` column.
public enum ProviderKey: String, Sendable, CaseIterable, Codable {
    case codex
    case claudeCode = "claude_code"
    case cursor

    /// The `providers.display_name` column, and the name the interface shows.
    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        }
    }

    /// The providers Burnline can track today, in the order it offers them.
    /// Cursor keeps no usage on the Mac, so it waits behind its adapter.
    public static let trackable: [ProviderKey] = [.claudeCode, .codex]
}
