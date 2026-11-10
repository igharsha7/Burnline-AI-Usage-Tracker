//
//  FuseBar.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import SwiftUI

/// Burnline's quota bar, the burn line itself: the used share burned in the
/// provider's colour, brightening toward an ember at the point reached, the
/// rest a quiet fuse, and a tick where an even pace would be.
///
/// Colour is never the only signal: wherever it appears, the percentage is
/// written beside it.
struct FuseBar: View {
    /// Used, from 0 to 1.
    let fraction: Double
    /// How far through the window time has gone, from 0 to 1.
    let pace: Double?
    let color: Color
    /// At or past the critical threshold the burn runs at full strength.
    let critical: Bool
    var height: CGFloat = 8

    /// How far the line is drawn: it burns up to `fraction` as it arrives,
    /// and follows a new reading with the same spring.
    @State private var burned: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrames) private var stillFrames

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let target = max(0, min(1, fraction))
            let used = stillFrames ? target : burned ?? 0
            let ember = height + 2
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.12))
                    .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
                    .frame(height: height)
                if used > 0 {
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(critical ? 0.7 : 0.3), color.opacity(critical ? 1 : 0.78)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, used * width), height: height)
                }
                if let pace {
                    Capsule().fill(Palette.textPrimary.opacity(0.85))
                        .frame(width: 2, height: height + 8)
                        .offset(x: pace * width - 1)
                }
                // The ember marks how far the line has burned, in the line's
                // own colour so it never reads as another provider's; a full
                // or untouched line has no burning point.
                if target > 0, target < 1 {
                    // Less its 2-point ring, so the dot itself sits on the line's end.
                    Ember(color: critical ? Palette.critical : color, size: ember)
                        .offset(x: min(max(used * width - ember / 2, 0), width - ember) - 2)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 8)
        .accessibilityHidden(true)
        .onAppear { burn(to: fraction, animation: Motion.reveal) }
        .onChange(of: fraction) { burn(to: fraction, animation: Motion.standard) }
    }

    private func burn(to fraction: Double, animation: Animation) {
        let target = max(0, min(1, fraction))
        if reduceMotion { burned = target } else { withAnimation(animation) { burned = target } }
    }
}
