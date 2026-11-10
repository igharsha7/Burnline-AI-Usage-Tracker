//
//  PreferenceBackup.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineServices
import Foundation

/// Burnline's preferences as a backup carries them: every setting the user
/// chose, and nothing secret, since Burnline keeps no credential.
public enum PreferenceBackup {
    static let keys = [
        SettingsModel.pricingUpdatesKey, SettingsModel.detailRetentionKey, SettingsModel.historyRetentionKey,
        SettingsModel.weekStartKey, SettingsModel.onboardedKey, SettingsModel.nameKey, SettingsModel.trackedKey, AlertSettingsStore.key,
        ActivityPreferences.showAchievementsKey, ActivityPreferences.showComparisonsKey,
        ActivityPreferences.comparisonToneKey, MenuBarTitleMode.storageKey, DockPresence.menuBarOnlyKey,
        DashboardModel.rangeKey, DashboardModel.filtersKey,
    ]

    /// The preferences set in `defaults`, as a property list.
    public static func export(from defaults: UserDefaults = .standard) -> Data {
        var values: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        return (try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)) ?? Data()
    }

    /// Sets the preferences a backup carried. Keys this build does not know
    /// are ignored, and those the backup lacks are left as they are.
    public static func apply(_ data: Data, to defaults: UserDefaults = .standard) {
        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return
        }
        for key in keys {
            if let value = values[key] { defaults.set(value, forKey: key) }
        }
    }
}
