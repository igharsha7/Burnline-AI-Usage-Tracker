//
//  ProviderStatus.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// Whether a provider's data can be read on this machine. Not installed is a
/// state to show, not an error to report.
public enum ProviderDetection: Hashable, Sendable {
    case installed(dataDirectory: URL)
    case notInstalled
    /// Installed or not, its usage cannot be measured locally, with the reason
    /// shown to the user. Cursor today: it keeps no token data on the machine.
    case unavailable(reason: String)
}

/// How a provider is doing, as the interface shows it. One provider failing
/// never changes another's health.
public enum ProviderHealth: Hashable, Sendable {
    case healthy(lastImport: Timestamp)
    /// Data is still shown, but the last attempt to read more failed.
    case degraded(reason: String, since: Timestamp)
    case notInstalled
    case unavailable(reason: String)
}
