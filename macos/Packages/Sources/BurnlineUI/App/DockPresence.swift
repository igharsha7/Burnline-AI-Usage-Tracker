//
//  DockPresence.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit

/// Whether Burnline shows in the Dock. It is a regular app with a Dock icon
/// by default and offers an optional menu-bar-only mode, so the
/// bundle does not set `LSUIElement`; the policy is switched at runtime instead.
public enum DockPresence {
    public static let menuBarOnlyKey = "menuBarOnly"

    public static var isMenuBarOnly: Bool {
        UserDefaults.standard.bool(forKey: menuBarOnlyKey)
    }

    public static func apply(menuBarOnly: Bool) {
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        // Leaving the Dock drops focus; returning to it should not leave the
        // app sitting in the background.
        if !menuBarOnly { NSApp.activate() }
    }
}
