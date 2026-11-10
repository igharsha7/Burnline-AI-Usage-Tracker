//
//  ScreenBurst.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import SwiftUI

/// The end of onboarding: when the fuse burns out, the window bursts with
/// light from where it ended, a shockwave and a shower of sparks cross the
/// screen, and the flash fades to reveal the dashboard beneath. Drawn over
/// the dashboard so it carries across the change from onboarding; it never
/// takes a click, and calls `done` when the last spark has gone. Every spark's
/// flight comes from its index, not chance.
struct ScreenBurst: View {
    /// When the fuse burnt out.
    let start: Date
    /// Where on the window the fuse ended.
    let origin: UnitPoint
    let done: () -> Void

    /// The flash swells for `swell` seconds, holds white-hot for `hold`, then
    /// fades over `fade`; sparks fly for `flight`.
    static let swell = 0.22
    static let hold = 0.12
    static let fade = 0.75
    static let flight = 1.3
    static let sparks = 72
    /// Frames a second, while it lasts.
    static let frameRate = 60.0

    static var length: Double { max(swell + hold + fade, flight) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.frameRate)) { timeline in
            let time = timeline.date.timeIntervalSince(start)
            Canvas { context, size in draw(in: &context, size: size, time: time) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .seconds(Self.length))
            done()
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let centre = CGPoint(x: size.width * origin.x, y: size.height * origin.y)
        // Far enough to cover the farthest corner.
        let reach = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height),
                     CGPoint(x: size.width, y: size.height)]
            .map { hypot($0.x - centre.x, $0.y - centre.y) }.max() ?? 0

        // The flash: light swelling out from the fuse's end until it fills the
        // window, white-hot at its heart, then fading to show what is beneath.
        let swelling = min(1, time / Self.swell)
        let fading = max(0, (time - Self.swell - Self.hold) / Self.fade)
        let strength = (1 - fading) * (1 - fading)
        if strength > 0 {
            let radius = reach * 1.15 * (0.08 + 0.92 * (1 - pow(1 - swelling, 3)))
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .radialGradient(Gradient(stops: [
                             .init(color: Color(red: 1, green: 0.97, blue: 0.9).opacity(strength), location: 0),
                             .init(color: Color(red: 1, green: 0.82, blue: 0.5).opacity(strength), location: 0.25),
                             .init(color: Palette.ember.opacity(strength * 0.95), location: 0.6),
                             .init(color: Palette.critical.opacity(strength * 0.6), location: 0.85),
                             .init(color: Palette.critical.opacity(0), location: 1),
                         ]), center: centre, startRadius: 0, endRadius: max(radius, 1)))
        }

        // The shockwave: a bright ring running out ahead of the light.
        let wave = time / (Self.swell + Self.hold + Self.fade * 0.6)
        if wave < 1 {
            let radius = reach * 1.2 * (1 - pow(1 - wave, 2))
            context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)),
                           with: .color(Color(red: 1, green: 0.9, blue: 0.7).opacity(0.7 * (1 - wave))),
                           lineWidth: 2 + 10 * (1 - wave))
        }

        // Sparks thrown across the window, cooling and falling as they fly.
        let age = time / Self.flight
        guard age < 1 else { return }
        for index in 0..<Self.sparks {
            let seed = Double(index)
            // Mostly up and away from the corner the fuse ended in.
            let angle = -.pi * (0.05 + 0.9 * (seed + 0.5) / Double(Self.sparks)) - .pi * 0.1 * sin(seed * 3.7)
            let speed = reach * (0.55 + 0.6 * abs(sin(seed * 12.9898)))
            let spark = { (age: Double) -> CGPoint in
                CGPoint(x: centre.x + cos(angle) * speed * age,
                        y: centre.y + sin(angle) * speed * age + 380 * age * age)
            }
            let trail = Path { path in
                path.move(to: spark(max(0, age - 0.05)))
                path.addLine(to: spark(age))
            }
            context.stroke(trail, with: .color(OnboardingFuse.color(at: age).opacity(1 - age)),
                           style: StrokeStyle(lineWidth: 3.5 * (1 - age * 0.7), lineCap: .round))
        }
    }
}
