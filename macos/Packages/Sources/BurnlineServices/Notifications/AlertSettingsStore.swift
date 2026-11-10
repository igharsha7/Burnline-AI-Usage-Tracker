//
//  AlertSettingsStore.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// The user's alert choices, kept in the app's preferences as JSON. Read at
/// launch; the settings interface saves through it, then hands the new
/// settings to `NotificationService.update(settings:)`.
public struct AlertSettingsStore: Sendable {
    let suiteName: String?
    public static let key = "alertSettings"

    /// `suiteName` nil is the app's own preferences.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// The saved settings, or the defaults when none were saved or they
    /// cannot be read.
    public func load() -> AlertSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(AlertSettings.self, from: data) else { return AlertSettings() }
        return settings
    }

    public func save(_ settings: AlertSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
