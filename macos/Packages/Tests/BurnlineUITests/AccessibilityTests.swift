//
//  AccessibilityTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
@testable import BurnlineUI
import SwiftUI
import Testing

/// Contrast of the real colour tokens on the surfaces the dashboard draws
/// them on, measured as WCAG 2 defines it. Burnline is dark only; the
/// Increase Contrast values cannot be resolved outside a running app with
/// the setting on, so the plain ones are held to the line here.
@MainActor
struct AccessibilityTests {
    static let surfaces = [("background", Palette.background), ("surface", Palette.surface),
                           ("control", Palette.control)]

    static func luminance(_ color: Color) -> Double {
        var result = 0.0
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { value in
                value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            result = 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        return result
    }

    static func contrast(_ a: Color, _ b: Color) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static let text = ["primary": Palette.textPrimary, "secondary": Palette.textSecondary, "warning": Palette.warning]

    @Test(arguments: ["primary", "secondary", "warning"])
    func `text keeps 4.5 to 1 on every surface`(_ token: String) {
        for (surface, colour) in Self.surfaces {
            let ratio = Self.contrast(Self.text[token]!, colour)
            #expect(ratio >= 4.5, "\(token) on \(surface): \(ratio)")
        }
    }

    @Test(arguments: ProviderKey.allCases)
    func `provider colours keep 3 to 1, as chart lines and dots must`(_ provider: ProviderKey) {
        for (surface, colour) in Self.surfaces {
            let ratio = Self.contrast(Palette.accent(provider), colour)
            #expect(ratio >= 3, "\(provider) on \(surface): \(ratio)")
        }
    }

    @Test(arguments: TokenKind.allCases)
    func `token kind colours keep 3 to 1, as the mix bar's segments must`(_ kind: TokenKind) {
        for (surface, colour) in Self.surfaces {
            let ratio = Self.contrast(kind.color, colour)
            #expect(ratio >= 3, "\(kind.name) on \(surface): \(ratio)")
        }
    }
}
