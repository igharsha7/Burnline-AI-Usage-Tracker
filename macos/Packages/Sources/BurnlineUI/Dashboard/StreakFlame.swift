//
//  StreakFlame.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import SwiftUI

/// The flat flame's four colours, as 0xRRGGBB: its body, the shaded right
/// edge, the inner flame and that flame's hot core.
struct FlameColours: Hashable {
    let body: UInt32
    let shade: UInt32
    let inner: UInt32
    let core: UInt32

    /// Before the first tier, and while today has no usage yet.
    static let unlit = FlameColours(body: 0x7A7A80, shade: 0x60606A, inner: 0xAAAAB0, core: 0xD6D6DA)
}

/// How the streak's flame looks at a tier. The shape stays the same at every
/// tier; size, side tongues, colour and what surrounds it change.
struct FlameLook: Equatable {
    var size: Double
    /// Side tongues, from none to two.
    var licks: Double
    var colours: FlameColours
    var isMajor = false
    var embers = 0
    var sparkle = false
    /// Heat waves above the tip.
    var haze = false
    /// Streaks rushing past, for the rocket tiers.
    var thrust: Double = 0
    /// A rayed disc behind the flame, for the star tiers.
    var sun: Double = 0
    var rays = 0
    var shock = false
    var beams = false
    /// Hues that cycle, for the last tier.
    var prism = false

    /// One per tier, in the order of `StreakTier.all`.
    static let tiers: [FlameLook] = [
        FlameLook(size: 0.44, licks: 0, colours: FlameColours(body: 0xFF9600, shade: 0xEC7A00, inner: 0xFFC800, core: 0xFFF3B8)),
        FlameLook(size: 0.56, licks: 1, colours: FlameColours(body: 0xFF8C00, shade: 0xE86E00, inner: 0xFFC400, core: 0xFFF0A8),
                  embers: 2),
        FlameLook(size: 0.66, licks: 2, colours: FlameColours(body: 0xFF7D00, shade: 0xE45F00, inner: 0xFFBE00, core: 0xFFEB9C),
                  embers: 4),
        FlameLook(size: 0.8, licks: 2, colours: FlameColours(body: 0xFF5C1F, shade: 0xDC3D10, inner: 0xFFAB00, core: 0xFFE27A),
                  isMajor: true, embers: 7, sparkle: true),
        FlameLook(size: 0.84, licks: 2, colours: FlameColours(body: 0xFF6A1A, shade: 0xE2480A, inner: 0xFFC21A, core: 0xFFF3B0),
                  embers: 8, haze: true),
        FlameLook(size: 0.88, licks: 2, colours: FlameColours(body: 0xFF8C1A, shade: 0xE86A00, inner: 0xFFD84A, core: 0xFFFBE0),
                  embers: 10, sparkle: true, haze: true),
        FlameLook(size: 0.88, licks: 2, colours: FlameColours(body: 0x2B7BFF, shade: 0x1A52DC, inner: 0x6CC4FF, core: 0xE4F6FF),
                  isMajor: true, embers: 10, sparkle: true),
        FlameLook(size: 0.92, licks: 2, colours: FlameColours(body: 0x4A62FF, shade: 0x3040D6, inner: 0x8FB4FF, core: 0xEEF3FF),
                  embers: 12, thrust: 1),
        FlameLook(size: 0.96, licks: 2, colours: FlameColours(body: 0x7A4DFF, shade: 0x5830DE, inner: 0xA9B6FF, core: 0xFFFFFF),
                  embers: 14, thrust: 1.6),
        FlameLook(size: 0.9, licks: 2, colours: FlameColours(body: 0xFF9A1A, shade: 0xEC7200, inner: 0xFFD24A, core: 0xFFF6C8),
                  embers: 12, sun: 1, rays: 10),
        FlameLook(size: 0.96, licks: 2, colours: FlameColours(body: 0xF2432E, shade: 0xC8281A, inner: 0xFF8A4A, core: 0xFFD8B8),
                  embers: 14, sun: 1.25, rays: 12),
        FlameLook(size: 0.96, licks: 2, colours: FlameColours(body: 0x9B4DFF, shade: 0x7230DE, inner: 0xD6A8FF, core: 0xFFFFFF),
                  isMajor: true, embers: 18, sparkle: true, sun: 1, rays: 16, shock: true),
        FlameLook(size: 0.9, licks: 2, colours: FlameColours(body: 0x26B8FF, shade: 0x0C8CDE, inner: 0x9FE4FF, core: 0xFFFFFF),
                  embers: 14, sun: 0.8, rays: 8, beams: true),
        FlameLook(size: 1, licks: 2, colours: FlameColours(body: 0xFF4FA0, shade: 0xDE2C7E, inner: 0xFFC870, core: 0xFFFFFF),
                  embers: 22, sparkle: true, sun: 1, rays: 20, shock: true, prism: true),
    ]

    /// The look for a streak's tier; before the first tier, the first look, unlit.
    static func at(_ tierIndex: Int?) -> FlameLook {
        guard let tierIndex else {
            var look = tiers[0]
            look.colours = .unlit
            return look
        }
        return tiers[tierIndex]
    }
}

extension Color {
    /// An sRGB colour from 0xRRGGBB.
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: opacity)
    }
}

/// A fixed pseudo-random number in 0..<1 for a tuple of integers, so particles
/// scatter the same way in every frame and every run, and no test meets chance.
func scatter(_ a: Int, _ b: Int = 0, _ c: Int = 0, _ d: Int = 0) -> Double {
    var x = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
    for part in [b, c, d] { x = (x ^ UInt64(bitPattern: Int64(part))) &* 0xBF58_476D_1CE4_E5B9 ^ (x >> 31) }
    x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
    x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
    x ^= x >> 31
    return Double(x >> 11) / Double(UInt64(1) << 53)
}

/// Draws the flat flame into a square: a round belly with a tip that leans
/// right, side tongues, a shaded right edge, a yellow inner flame and a pale
/// core. It breathes, and springs after `popAge` seconds since a new tier.
/// The same look, time and age always draw the same frame. `parts` leaves
/// out the flame itself where the fire animation stands in for it.
struct FlamePainter {
    let look: FlameLook
    let lit: Bool

    struct Parts: OptionSet {
        let rawValue: Int
        /// The sun, shock rings and beams.
        static let behind = Parts(rawValue: 1)
        static let flame = Parts(rawValue: 2)
        /// Thrust, haze, embers, sparkles and the new-tier burst.
        static let front = Parts(rawValue: 4)
        static let all: Parts = [.behind, .flame, .front]
    }

    func draw(in context: GraphicsContext, side s: Double, t: Double, popAge: Double?, parts: Parts = .all) {
        let colours = lit ? look.colours : .unlit
        let hue = lit && look.prism ? (t * 50).truncatingRemainder(dividingBy: 360) : 0
        let body = Self.colour(colours.body, shiftedBy: hue), shade = Self.colour(colours.shade, shiftedBy: hue)
        let inner = Self.colour(colours.inner, shiftedBy: hue * 0.6), core = Color(rgb: colours.core)
        let cx = s / 2, base = s * 0.86, w = s * 0.2 * look.size, h = s * 0.66 * look.size, mid = base - h * 0.5

        if lit, parts.contains(.behind) { behind(context, s: s, cx: cx, mid: mid, t: t, inner: inner, core: core) }
        if parts.contains(.flame) { drawFlame(context, s: s, cx: cx, base: base, w: w, h: h, t: t, popAge: popAge,
                                              body: body, shade: shade, inner: inner, core: core) }
        if lit, parts.contains(.front) {
            front(context, s: s, cx: cx, base: base, w: w, h: h, mid: mid, t: t, body: body, inner: inner, core: core,
                  small: s < 60)
            if let popAge { burst(context, s: s, age: popAge, body: body, inner: inner) }
        }
    }

    private func drawFlame(_ context: GraphicsContext, s: Double, cx: Double, base: Double, w: Double, h: Double, t: Double,
                           popAge: Double?, body: Color, shade: Color, inner: Color, core: Color) {

        // Squash and stretch about the base, with a spring after a new tier.
        let spring = popAge.map { $0 >= 0 && $0 < 1.6 ? exp(-$0 * 4.2) * cos($0 * 15) : 0 } ?? 0
        let beat = sin(t * 4.2)
        var flame = context
        flame.translateBy(x: cx, y: base)
        flame.scaleBy(x: 1 - 0.028 * beat - 0.16 * spring, y: 1 + 0.038 * beat + 0.26 * spring)
        flame.translateBy(x: -cx, y: -base)
        let sway = sin(t * 2.6) * w * 0.16 + sin(t * 6.3) * w * 0.05
        let outline = silhouette(cx: cx, base: base, w: w, h: h, sway: sway)
        flame.fill(outline, with: .color(shade))
        var lighted = flame
        lighted.clip(to: outline)
        lighted.translateBy(x: -w * 0.2, y: -w * 0.02)
        lighted.fill(outline, with: .color(body))
        let iw = w * 0.6, ih = h * 0.56 * (1 + 0.05 * sin(t * 7.1)), innerSway = sway * 0.5 + sin(t * 5.2) * iw * 0.1
        flame.fill(blob(x: cx + w * 0.04, y: base - w * 0.12, w: iw, h: ih, lean: iw * 0.14 + innerSway), with: .color(inner))
        flame.fill(blob(x: cx + w * 0.06, y: base - w * 0.22, w: iw * 0.5, h: ih * 0.46, lean: iw * 0.06 + innerSway * 0.5),
                   with: .color(core.opacity(0.95)))
        if s >= 60 {
            var glint = flame
            glint.translateBy(x: cx - w * 0.5, y: base - w * 1.45)
            glint.rotate(by: .radians(-0.42))
            glint.fill(Path(roundedRect: CGRect(x: -w * 0.07, y: -w * 0.24, width: w * 0.14, height: w * 0.48),
                            cornerRadius: w * 0.07), with: .color(.white.opacity(0.3)))
        }
    }

    /// One tongue: a round belly centred `w` above `y`, a tip `h` above `y`
    /// moved sideways by `lean`. Every tongue runs the same way round, so
    /// overlapping ones fill as one shape.
    private func blob(x: Double, y: Double, w: Double, h: Double, lean: Double) -> Path {
        var path = Path()
        add(&path, x: x, y: y, w: w, h: h, lean: lean)
        return path
    }

    private func add(_ path: inout Path, x: Double, y: Double, w: Double, h: Double, lean: Double) {
        let cy = y - w, tx = x + lean, ty = y - h, k = h - w, q = 0.5523 * w
        path.move(to: CGPoint(x: x + w, y: cy))
        path.addCurve(to: CGPoint(x: x, y: cy + w), control1: CGPoint(x: x + w, y: cy + q), control2: CGPoint(x: x + q, y: cy + w))
        path.addCurve(to: CGPoint(x: x - w, y: cy), control1: CGPoint(x: x - q, y: cy + w), control2: CGPoint(x: x - w, y: cy + q))
        path.addCurve(to: CGPoint(x: tx, y: ty), control1: CGPoint(x: x - w, y: cy - k * 0.5),
                      control2: CGPoint(x: tx - w * 0.5, y: ty + k * 0.32))
        path.addCurve(to: CGPoint(x: x + w, y: cy), control1: CGPoint(x: tx + w * 0.45, y: ty + k * 0.36),
                      control2: CGPoint(x: x + w, y: cy - k * 0.42))
        path.closeSubpath()
    }

    private func silhouette(cx: Double, base: Double, w: Double, h: Double, sway: Double) -> Path {
        var path = Path()
        add(&path, x: cx, y: base, w: w, h: h, lean: w * 0.16 + sway)
        let left = min(1, max(0, look.licks)), right = min(1, max(0, look.licks - 1))
        if left > 0 {
            add(&path, x: cx - w * 0.5, y: base - w * 0.62, w: w * 0.42 * left, h: h * 0.64 * left,
                lean: -w * 0.36 * left + sway * 0.6)
        }
        if right > 0 {
            add(&path, x: cx + w * 0.54, y: base - w * 0.56, w: w * 0.36 * right, h: h * 0.5 * right,
                lean: w * 0.32 * right + sway * 0.4)
        }
        return path
    }

    /// The sun's rays and disc, shock rings and pulsar beams.
    private func behind(_ context: GraphicsContext, s: Double, cx: Double, mid: Double, t: Double, inner: Color,
                        core: Color) {
        if look.sun > 0 {
            let radius = s * 0.3 * min(1.3, look.sun), strength = min(1, look.sun), count = max(1, look.rays)
            for index in 0..<count {
                var ray = context
                ray.translateBy(x: cx, y: mid)
                ray.rotate(by: .radians(t * 0.22 + 2 * .pi * Double(index + 1) / Double(count)))
                let length = radius * (1.26 + 0.07 * sin(t * 3 + Double(index) * 1.7))
                var path = Path()
                path.move(to: CGPoint(x: -radius * 0.13, y: -radius * 0.9))
                path.addLine(to: CGPoint(x: 0, y: -length))
                path.addLine(to: CGPoint(x: radius * 0.13, y: -radius * 0.9))
                path.closeSubpath()
                ray.fill(path, with: .color(inner.opacity(0.5 * strength)))
            }
            context.fill(Self.circle(cx, mid, radius), with: .color(inner.opacity(0.22 * strength)))
            context.fill(Self.circle(cx, mid, radius * 0.78), with: .color(inner.opacity(0.16 * strength)))
        }
        if look.shock {
            for ring in 0..<2 {
                let phase = (t * 0.45 + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1)
                context.stroke(Self.circle(cx, mid, s * (0.18 + phase * 0.3)), with: .color(inner.opacity((1 - phase) * 0.7)),
                               lineWidth: max(1.5, s * 0.014))
            }
        }
        if look.beams {
            var beams = context
            beams.translateBy(x: cx, y: mid)
            beams.rotate(by: .radians(t * 1.4))
            for direction in [1.0, -1.0] {
                var path = Path()
                path.move(to: CGPoint(x: -2, y: 0))
                path.addLine(to: CGPoint(x: -s * 0.07, y: direction * s * 0.5))
                path.addLine(to: CGPoint(x: s * 0.07, y: direction * s * 0.5))
                path.addLine(to: CGPoint(x: 2, y: 0))
                beams.fill(path, with: .linearGradient(Gradient(colors: [inner.opacity(0.55), inner.opacity(0)]),
                                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: direction * s * 0.5)))
            }
        }
    }

    /// Thrust streaks, heat haze, embers and sparkles.
    private func front(_ context: GraphicsContext, s: Double, cx: Double, base: Double, w: Double, h: Double, mid: Double,
                       t: Double, body: Color, inner: Color, core: Color, small: Bool) {
        let line = StrokeStyle(lineWidth: max(1.5, s * 0.014), lineCap: .round)
        if look.thrust > 0 {
            for index in 0..<6 {
                let phase = (t * 1.6 + Double(index) / 6).truncatingRemainder(dividingBy: 1)
                let x = cx + (index % 2 == 0 ? -1 : 1) * w * (1.35 + Double(index % 3) * 0.28), y = base - h * 0.95 + phase * h
                var path = Path()
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + h * 0.16 * min(1.6, look.thrust)))
                context.stroke(path, with: .color(inner.opacity(sin(phase * .pi) * 0.8)), style: line)
            }
        }
        guard !small else { return }
        if look.haze {
            for wave in 0..<2 {
                var path = Path()
                for x in stride(from: -w * 0.9, through: w * 0.9, by: 2) {
                    let point = CGPoint(x: cx + x, y: base - h - 8 - Double(wave) * 8 + sin(x * 0.25 + t * 6 + Double(wave) * 2) * 2.2)
                    if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(inner.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        for index in 0..<look.embers {
            let drift = scatter(index, 1) * 2 - 1, speed = 0.32 + scatter(index, 2) * 0.22, size = 0.5 + scatter(index, 3) * 0.5
            let age = (t * speed + scatter(index, 4)).truncatingRemainder(dividingBy: 1)
            let x = cx + drift * w * 1.1 + sin(t * 2 + Double(index)) * 3, y = base - h * 0.55 - age * s * 0.42
            context.fill(Self.circle(x, y, (1 - age) * 2.6 * size + 0.6),
                         with: .color((index % 3 == 0 ? body : inner).opacity(1 - age * 0.8)))
        }
        if look.sparkle {
            for index in 0..<5 {
                let angle = -Double.pi / 2 + Double(index - 2) * 0.62 + (scatter(index, 5) - 0.5) * 0.2
                let distance = 0.34 + scatter(index, 6) * 0.1, grow = max(0, sin(t * 2.2 + scatter(index, 7) * 7))
                guard grow > 0.05 else { continue }
                context.fill(Self.star(cx + cos(angle) * s * distance * 1.05, mid + sin(angle) * s * distance, s * 0.045 * grow),
                             with: .color(core.opacity(0.95)))
            }
        }
    }

    /// Confetti thrown out from the flame on a new tier, for three quarters of a second.
    private func burst(_ context: GraphicsContext, s: Double, age: Double, body: Color, inner: Color) {
        let life = 1 - age / 0.75
        guard age >= 0, life > 0 else { return }
        let frames = age * 60, scale = s / 180
        for index in 0..<(look.isMajor ? 26 : 14) {
            let angle = scatter(index, 11) * 2 * .pi, speed = (look.isMajor ? 2.4 : 1.7) + scatter(index, 12) * 1.6
            let x = s / 2 + cos(angle) * speed * frames * scale
            let y = s * 0.5 + ((sin(angle) * speed - 0.8) * frames + 0.025 * frames * frames) * scale
            context.fill(Self.circle(x, y, ((2 + scatter(index, 13) * 2.5) * life + 0.4) * scale),
                         with: .color((index % 2 == 0 ? body : inner).opacity(life)))
        }
    }

    static func circle(_ x: Double, _ y: Double, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    /// A four-pointed sparkle.
    static func star(_ x: Double, _ y: Double, _ r: Double) -> Path {
        var path = Path()
        let centre = CGPoint(x: x, y: y)
        path.move(to: CGPoint(x: x, y: y - r))
        path.addQuadCurve(to: CGPoint(x: x + r, y: y), control: centre)
        path.addQuadCurve(to: CGPoint(x: x, y: y + r), control: centre)
        path.addQuadCurve(to: CGPoint(x: x - r, y: y), control: centre)
        path.addQuadCurve(to: CGPoint(x: x, y: y - r), control: centre)
        return path
    }

    /// `rgb` with its hue turned by `degrees`.
    static func colour(_ rgb: UInt32, shiftedBy degrees: Double) -> Color {
        guard degrees != 0 else { return Color(rgb: rgb) }
        let colour = NSColor(srgbRed: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255,
                             blue: Double(rgb & 0xFF) / 255, alpha: 1)
        let hue = (colour.hueComponent + degrees / 360).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: colour.saturationComponent, brightness: colour.brightnessComponent)
    }
}

/// The streak's flame. It breathes while shown, and springs when `popAt`
/// marks a new tier; it holds still under Reduce Motion, while the window
/// is inactive, and in rendered frames. `animated: false` draws one frame,
/// for the small flames on the tier chips.
struct StreakFlame: View {
    let look: FlameLook
    var lit = true
    var animated = true
    var popAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrames) private var stillFrames
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Group {
            if !animated || reduceMotion || stillFrames {
                frame(t: 0.4, popAge: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: activeState == .inactive)) { context in
                    frame(t: context.date.timeIntervalSinceReferenceDate,
                          popAge: popAt.map { context.date.timeIntervalSince($0) })
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func frame(t: Double, popAge: Double?) -> some View {
        Canvas { context, size in
            FlamePainter(look: look, lit: lit).draw(in: context, side: min(size.width, size.height), t: t, popAge: popAge)
        }
    }
}
