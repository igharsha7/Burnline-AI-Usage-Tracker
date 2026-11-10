//
//  Palette.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import SwiftUI

/// The design tokens from the architecture document. Burnline is dark
/// only, so each token is one colour, with a brighter one for Increase
/// Contrast. Colour is never the only signal: every bar also carries its
/// percentage in text.
enum Palette {
    static let background = token(0x0A0A0A)
    static let surface = token(0x121212)
    static let control = token(0x262626)
    static let controlTrack = token(0x262626)
    /// Something switched off or not yet had, such as an empty freeze slot:
    /// dim, but never lost against the card.
    static let inactive = token(0x4A4A4A, contrast: 0x6E6E6E)
    /// The lit top edge of a card, where light catches the surface.
    static let rim = token(0x2C2C2C)
    static let separator = token(0x3B3B3B, contrast: 0x6A6A6A)
    static let textPrimary = token(0xF5F5F5, contrast: 0xFFFFFF)
    /// A step from the reference's grey, so caption-sized text keeps
    /// 4.5:1 on every surface and control fill; `PaletteTests` holds them to it.
    static let textSecondary = token(0x8E8E8E, contrast: 0xB0B0B0)
    /// Warnings, such as a window running out before its reset. Quota and
    /// health run calm, then warning, then critical.
    static let warning = token(0xF0A040, contrast: 0xFFC070)
    /// A limit reached or nearly so: a deep red ember.
    static let critical = token(0xF2553D, contrast: 0xFF8070)
    /// Something live and well, such as a session under way.
    static let positive = token(0x5BC98A, contrast: 0x86E0AB)

    /// A record, such as the longest streak: gold, as the medals have it,
    /// and never a provider's colour.
    static let record = token(0xE8C35A, contrast: 0xF5D884)

    /// Burnline's own colour: the ember at the tip of a burn line. Used
    /// sparingly, for "now" and for the point a quota has burned to.
    static let ember = token(0xFF8A4C, contrast: 0xFFAA77)

    /// A streak freeze held: ice, the one cold colour beside the flame.
    static let ice = token(0x6CC4FF, contrast: 0x9AD8FF)

    static let accentClaude = token(0xCC7C5E, contrast: 0xE89A7C)
    /// A cool silver rather than the reference's white, which was the
    /// colour of text, so a Codex line never reads as a label.
    static let accentCodex = token(0xB8C4D0, contrast: 0xD6DEE6)
    static let accentCursor = token(0x5E9BCC, contrast: 0x8CBDE6)

    /// Token types, each its own hue and none a provider's, so a mix reads at
    /// a glance and never looks like a provider split.
    static let tokenCacheRead = token(0x45B5A8, contrast: 0x6FD3C6)
    static let tokenInput = token(0x9D8CF7, contrast: 0xBCAFFF)
    /// Chartreuse, not amber, so amber only ever means a warning.
    static let tokenCacheWrite = token(0xA8CF5A, contrast: 0xC4E585)
    static let tokenOutput = token(0xEE6E9A, contrast: 0xFF95B8)

    static func accent(_ provider: ProviderKey) -> Color {
        switch provider {
        case .claudeCode: accentClaude
        case .codex: accentCodex
        case .cursor: accentCursor
        }
    }

    /// Each provider's line pattern, for when the user asks to differentiate
    /// without colour: solid, dashed, dotted. Empty is solid.
    static func dash(_ provider: ProviderKey) -> [CGFloat] {
        switch provider {
        case .codex: []
        case .claudeCode: [6, 3]
        case .cursor: [1.5, 3]
        }
    }

    /// A colour, and its brighter variant under Increase Contrast. The
    /// system setting is read as well as the appearance, since a
    /// high-contrast appearance does not always say so.
    private static func token(_ hex: UInt32, contrast: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let increased = appearance.bestMatch(from: [.darkAqua, .accessibilityHighContrastDarkAqua])
                == .accessibilityHighContrastDarkAqua
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let value = increased ? contrast ?? hex : hex
            return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}
