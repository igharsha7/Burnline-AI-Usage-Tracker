//
//  HeatGlow.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import SwiftUI

/// The popover's burn: ember light rising from its top edge and along its
/// rim, as strong as the work going on now. Nothing at all when nothing is
/// live. It flickers only while its window is on screen and burning, so a
/// closed popover or an idle one costs no frames; under Reduce Motion it
/// holds still. The menu bar keeps its window alive while hidden, so being
/// on screen is read from the window itself.
struct HeatGlow: View {
    /// From 0 to 1, as `HeatScale` gives it.
    let heat: Double

    /// Frames a second the flicker asks for: a slow flame needs few.
    static let framesPerSecond = 30.0
    /// How far the flicker swings the glow at full heat.
    static let flickerDepth = 0.18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrames) private var stillFrames
    @State private var onScreen = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.framesPerSecond,
                                paused: heat == 0 || reduceMotion || stillFrames || !onScreen)) { context in
            let strength = heat * flicker(at: context.date)
            ZStack {
                // Heat rising from the top edge, reaching further down the
                // hotter the burn, and reddening at its source at a peak.
                EllipticalGradient(colors: [(heat >= 1 ? Palette.critical : Palette.ember).opacity(0.34 * strength),
                                            Palette.ember.opacity(0.08 * strength), .clear],
                                   center: .top, startRadiusFraction: 0, endRadiusFraction: 0.3 + 0.7 * heat)
                // The rim, brightest at the top where the heat gathers.
                Rectangle()
                    .strokeBorder(LinearGradient(colors: [Palette.ember.opacity(0.95 * strength),
                                                          Palette.ember.opacity(0.35 * strength),
                                                          Palette.ember.opacity(0.12 * strength)],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1 + 2 * heat)
                    .blur(radius: 1 + heat)
            }
        }
        .animation(.smooth(duration: 1.2), value: heat)
        .background(OnScreen(visible: $onScreen))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Three slow waves out of step, so the flicker never repeats visibly;
    /// it swings further the hotter the burn.
    private func flicker(at date: Date) -> Double {
        guard !(reduceMotion || stillFrames) else { return 1 }
        let t = date.timeIntervalSinceReferenceDate
        let wave = (sin(t * 2.3) + 0.6 * sin(t * 3.7 + 1.3) + 0.3 * sin(t * 7.1 + 0.4)) / 1.9
        return 1 + Self.flickerDepth * heat * wave
    }
}

/// Whether the window holding this view is on screen, from its occlusion
/// state, which changes as the menu bar shows and hides the popover.
private struct OnScreen: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Watcher {
        let watcher = Watcher()
        watcher.report = { visible = $0 }
        return watcher
    }

    func updateNSView(_ nsView: Watcher, context: Context) {}

    final class Watcher: NSView {
        var report: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return report(false) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportState() }
            }
            reportState()
        }

        private func reportState() {
            report(window?.occlusionState.contains(.visible) == true)
        }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
