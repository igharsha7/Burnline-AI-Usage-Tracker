//
//  OnboardingStage.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import SwiftUI

/// The burn line along the foot of onboarding, and its map: a fuse burnt as
/// far as the user has come, its ember on the step they are on. The ember
/// throws sparks that cool from white-hot to red as they fly, crackles in a
/// burst every few seconds, trails smoke and lifts embers on the heat; the
/// burnt cord glows, and each step it has passed is a glowing bead, each
/// ahead an empty ring.
/// Every motion is worked out from the time, not chance, and all of it holds
/// still under Reduce Motion.
struct OnboardingFuse: View, Animatable {
    /// How far along the fuse the ember is, 0 to 1.
    var progress: Double
    let steps: [String]
    let current: Int

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sparks drawn at a time; each lives `sparkLife` seconds.
    private static let sparks = 18
    private static let sparkLife = 1.1
    /// A crackle: this many sparks thrown at once, every `crackleEvery`
    /// seconds, flying for `crackleLife`.
    private static let crackle = 12
    private static let crackleEvery = 2.6
    private static let crackleLife = 0.55
    /// Puffs of smoke in the air at a time, each rising for `smokeLife`.
    private static let smoke = 7
    private static let smokeLife = 2.4
    /// Embers lifted on the heat, drifting up and away, each for `driftLife`.
    private static let drifting = 7
    private static let driftLife = 3.2
    /// Frames a second: enough for sparks, light on a laptop.
    private static let frameRate = 30.0

    /// A spark's colour as it cools: white-hot, yellow, ember, then red.
    private static let cooling: [(age: Double, color: Color)] = [
        (0, Color(red: 1, green: 0.96, blue: 0.84)), (0.25, Color(red: 1, green: 0.82, blue: 0.48)),
        (0.6, Palette.ember), (1, Palette.critical),
    ]

    /// The fuse's own band, and how far above it sparks and smoke may rise:
    /// the drawing reaches over the content above rather than being cut off.
    private static let band: CGFloat = 84
    private static let headroom: CGFloat = 150

    /// Where the ember has been lately, so what it throws stays where it
    /// was thrown when the ember moves on.
    @State private var trail = EmberTrail()

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 1 / Self.frameRate, paused: reduceMotion)) { timeline in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in draw(in: &context, size: size, time: time) }
            }
            .frame(height: Self.band + Self.headroom)
            .frame(height: Self.band, alignment: .bottom)
            .allowsHitTesting(false)
            HStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Text(step)
                        .font(.callout.weight(index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? Palette.textPrimary
                                         : index < current ? Palette.textSecondary : Palette.textSecondary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(steps.count): \(steps[current])")
    }

    /// The fuse's height at `x`: a slow wave, so it reads as a cord, low in
    /// its band with the headroom above.
    private func y(_ x: CGFloat, _ size: CGSize) -> CGFloat {
        size.height - Self.band * 0.38 + sin(x / size.width * .pi * 3) * 5
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        trail.record(progress, at: time)
        let tip = size.width * progress
        let ember = CGPoint(x: tip, y: y(tip, size))
        /// Where the ember was when something `age` through a `life` left it.
        func thrown(_ age: Double, _ life: Double) -> CGPoint {
            let x = size.width * trail.progress(at: time - age * life)
            return CGPoint(x: x, y: y(x, size))
        }
        func cord(from start: CGFloat, to end: CGFloat) -> Path {
            Path { path in
                path.move(to: CGPoint(x: start, y: y(start, size)))
                stride(from: start, through: end, by: 4).forEach { path.addLine(to: CGPoint(x: $0, y: y($0, size))) }
            }
        }
        let behind = Gradient(colors: [Palette.textSecondary.opacity(0.15), Palette.ember.opacity(0.25), Palette.ember])

        // Heat rising off the burnt cord, strongest near the ember.
        var heat = context
        heat.addFilter(.blur(radius: 7))
        heat.stroke(cord(from: 0, to: tip),
                    with: .linearGradient(Gradient(colors: [.clear, Palette.ember.opacity(0.12), Palette.ember.opacity(0.55)]),
                                          startPoint: .zero, endPoint: CGPoint(x: tip, y: 0)),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round))

        // Smoke curling up from just behind the ember, spreading as it fades.
        var smoke = context
        smoke.addFilter(.blur(radius: 7))
        for index in 0..<Self.smoke where tip > 0 {
            let seed = Double(index)
            let age = (time / Self.smokeLife + seed / Double(Self.smoke)).truncatingRemainder(dividingBy: 1)
            let origin = thrown(age, Self.smokeLife)
            let drift = sin(time * 0.9 + seed * 2.1) * 14 * age
            let point = CGPoint(x: origin.x - 6 + drift - 18 * age, y: origin.y - 8 - 90 * age)
            let radius = 3 + 14 * age
            smoke.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)),
                       with: .color(Palette.textSecondary.opacity(0.26 * (1 - age))))
        }

        // Embers lifted on the heat, swaying as they rise and fade.
        for index in 0..<Self.drifting where tip > 0 {
            let seed = Double(index)
            let age = (time / Self.driftLife + seed / Double(Self.drifting)).truncatingRemainder(dividingBy: 1)
            let sway = sin(time * 1.7 + seed * 3.3) * 8
            let origin = thrown(age, Self.driftLife)
            let point = CGPoint(x: origin.x - 30 * age * abs(sin(seed * 5.1)) + sway, y: origin.y - 6 - 100 * age)
            let radius = 1.6 * (1 - age * 0.5)
            let glow = radius * 3.5
            context.fill(Path(ellipseIn: CGRect(x: point.x - glow, y: point.y - glow, width: 2 * glow, height: 2 * glow)),
                         with: .radialGradient(Gradient(colors: [Palette.ember.opacity(0.35 * (1 - age)), .clear]),
                                               center: point, startRadius: 0, endRadius: glow))
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)),
                         with: .color(Self.color(at: 0.3 + age * 0.6).opacity(1 - age)))
        }

        // Ahead: unburnt cord. Behind: charred, glowing toward the ember.
        context.stroke(cord(from: tip, to: size.width), with: .color(Palette.textSecondary.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
        context.stroke(cord(from: 0, to: tip), with: .linearGradient(behind, startPoint: .zero, endPoint: CGPoint(x: tip, y: 0)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        // Each step's place: a glowing bead once burnt through, a ring ahead.
        for index in steps.indices {
            let x = size.width * (Double(index) + 0.5) / Double(steps.count)
            let centre = CGPoint(x: x, y: y(x, size))
            if x <= tip + 1 {
                let halo = 9.0
                context.fill(Path(ellipseIn: CGRect(x: x - halo, y: centre.y - halo, width: 2 * halo, height: 2 * halo)),
                             with: .radialGradient(Gradient(colors: [Palette.ember.opacity(0.4), Palette.ember.opacity(0)]),
                                                   center: centre, startRadius: 0, endRadius: halo))
                context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: centre.y - 3.5, width: 7, height: 7)), with: .color(Palette.ember))
            } else {
                context.stroke(Path(ellipseIn: CGRect(x: x - 3.5, y: centre.y - 3.5, width: 7, height: 7)),
                               with: .color(Palette.textSecondary.opacity(0.45)), lineWidth: 1.5)
            }
        }

        // Sparks, each on its own short arc, born in turn so a few are
        // always in the air, drawn as streaks along their flight.
        for index in 0..<Self.sparks {
            let seed = Double(index)
            let age = (time / Self.sparkLife + seed / Double(Self.sparks)).truncatingRemainder(dividingBy: 1)
            let angle = -.pi / 2 + sin(seed * 12.9898) * 1.1
            let speed = 40 + 28 * abs(sin(seed * 78.233))
            spark(in: &context, from: thrown(age, Self.sparkLife), angle: angle, speed: speed, age: age, size: 2.1)
        }

        // A crackle: a burst of fast sparks every few seconds, every way but down.
        let phase = time.truncatingRemainder(dividingBy: Self.crackleEvery)
        if phase < Self.crackleLife {
            let age = phase / Self.crackleLife
            let round = (time / Self.crackleEvery).rounded(.down)
            for index in 0..<Self.crackle {
                let seed = Double(index) + round * 7
                let angle = -.pi + .pi * (Double(index) + 0.5) / Double(Self.crackle) + sin(seed * 4.1) * 0.25
                spark(in: &context, from: thrown(age, Self.crackleLife), angle: angle,
                      speed: 70 + 30 * abs(sin(seed * 9.7)), age: age, size: 1.7)
            }
        }

        // The ember, flickering.
        let flicker = 1 + 0.08 * sin(time * 13) + 0.05 * sin(time * 7.3)
        let glow = 20 * flicker
        context.fill(Path(ellipseIn: CGRect(x: ember.x - glow, y: ember.y - glow, width: 2 * glow, height: 2 * glow)),
                     with: .radialGradient(Gradient(colors: [Palette.ember.opacity(0.6), Palette.ember.opacity(0)]),
                                           center: ember, startRadius: 0, endRadius: glow))
        context.fill(Path(ellipseIn: CGRect(x: ember.x - 4.5, y: ember.y - 4.5, width: 9, height: 9)),
                     with: .color(Self.color(at: 0)))
    }

    /// One spark `age` through its flight from `origin`: a short streak from
    /// where it just was, falling a little, shrinking and cooling as it goes.
    private func spark(in context: inout GraphicsContext, from origin: CGPoint, angle: Double, speed: Double,
                       age: Double, size: Double) {
        func position(_ age: Double) -> CGPoint {
            CGPoint(x: origin.x + cos(angle) * speed * age, y: origin.y + sin(angle) * speed * age + 26 * age * age)
        }
        let trail = Path { path in
            path.move(to: position(max(0, age - 0.08)))
            path.addLine(to: position(age))
        }
        context.stroke(trail, with: .color(Self.color(at: age).opacity(1 - age)),
                       style: StrokeStyle(lineWidth: 2 * size * (1 - age * 0.7), lineCap: .round))
    }

    /// The cooling colour `age` of the way through a spark's flight; the
    /// burst at the end of onboarding throws the same sparks.
    static func color(at age: Double) -> Color {
        guard let upper = cooling.firstIndex(where: { $0.age >= age }), upper > 0 else { return cooling[0].color }
        let low = cooling[upper - 1], high = cooling[upper]
        return (age - low.age) / (high.age - low.age) < 0.5 ? low.color : high.color
    }
}

/// Where the fuse's ember has been over the last few seconds, by time, so a
/// spark or puff can start from where the ember was when it was thrown. Kept
/// outside SwiftUI's state: it is written as frames are drawn, never read to
/// decide what to show.
final class EmberTrail {
    /// Longer than anything thrown lives.
    static let memory = 4.0
    private var points: [(time: Double, progress: Double)] = []

    func record(_ progress: Double, at time: Double) {
        if let last = points.last, last.time >= time { return }
        points.append((time, progress))
        points.removeAll { $0.time < time - Self.memory }
    }

    /// The ember's place at `time`: the last one recorded by then, or the
    /// oldest one remembered.
    func progress(at time: Double) -> Double {
        points.last { $0.time <= time }?.progress ?? points.first?.progress ?? 0
    }
}

/// The back of a gold medal with the name engraved as it is typed, swaying
/// gently, so the user sees where the name goes.
struct NamePreview: View {
    let name: String?
    @State private var sway = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MedalBack(form: .coin, metal: .gold, title: "Your First Medal",
                  date: "Today",
                  name: name ?? "Your Name", size: 230, mirrored: false)
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .modifier(Tilt(yaw: sway ? 14 : -14, pitch: sway ? 4 : -4))
            .animation(name == nil ? nil : .snappy, value: name)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { sway = true }
            }
            .accessibilityHidden(true)
    }
}

/// A notification as macOS shows it, for onboarding to show what is coming.
struct NotificationPreview: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: AboutView.icon).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.callout.weight(.semibold))
                    Spacer()
                    Text("now").font(.caption).foregroundStyle(Palette.textSecondary)
                }
                Text(message).font(.callout).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }
}
