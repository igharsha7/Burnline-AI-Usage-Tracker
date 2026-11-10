//
//  FireFlame.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import Lottie
import SwiftUI

/// Google's animated Noto fire (see the README beside it), recoloured for a
/// tier. Every gradient stop is turned by the hue between the fire's own
/// orange and the tier's body colour, with saturation and brightness scaled
/// the same way, so a violet tier is a violet fire that keeps its pale core,
/// and the unlit flame is a grey one.
enum FireAnimation {
    /// The fire's body colour as drawn, the orange every tier is measured from.
    static let sourceBody: UInt32 = 0xFF8016

    private static let source: [String: Any]? = Bundle.module.url(forResource: "fire", withExtension: "json",
                                                                   subdirectory: "Animations")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    private static var cache: [FlameColours: LottieAnimation] = [:]

    /// The fire in `colours`, or nil if the bundled file cannot be read.
    static func animation(_ colours: FlameColours) -> LottieAnimation? {
        if let cached = cache[colours] { return cached }
        guard let source else { return nil }
        let turn = Turn(from: sourceBody, to: colours.body)
        guard let data = try? JSONSerialization.data(withJSONObject: recolour(source, turn)),
              let animation = try? LottieAnimation.from(data: data) else { return nil }
        cache[colours] = animation
        return animation
    }

    /// The change from one colour to another in hue, saturation and brightness.
    struct Turn {
        let hue: Double, saturation: Double, brightness: Double

        init(from: UInt32, to: UInt32) {
            let a = Self.hsb(from), b = Self.hsb(to)
            hue = b.h - a.h
            saturation = a.s > 0 ? b.s / a.s : 1
            brightness = a.b > 0 ? b.b / a.b : 1
        }

        /// `rgb`, components in 0...1, turned.
        func apply(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
            let colour = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            let h = (colour.hueComponent + hue + 1).truncatingRemainder(dividingBy: 1)
            let turned = NSColor(hue: h, saturation: min(1, colour.saturationComponent * saturation),
                                 brightness: min(1, colour.brightnessComponent * brightness), alpha: 1)
                .usingColorSpace(.sRGB)!
            return (turned.redComponent, turned.greenComponent, turned.blueComponent)
        }

        private static func hsb(_ rgb: UInt32) -> (h: Double, s: Double, b: Double) {
            let colour = NSColor(srgbRed: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255,
                                 blue: Double(rgb & 0xFF) / 255, alpha: 1)
            return (colour.hueComponent, colour.saturationComponent, colour.brightnessComponent)
        }
    }

    /// The animation with every gradient's colour stops turned. A gradient is
    /// `{"p": stops, "k": {"k": [offset, r, g, b, …, alpha stops…]}}`, or
    /// keyframes whose `s` holds that array; the alpha stops after the colour
    /// stops are left alone.
    private static func recolour(_ value: Any, _ turn: Turn) -> Any {
        if let array = value as? [Any] { return array.map { recolour($0, turn) } }
        guard var object = value as? [String: Any] else { return value }
        if var gradient = object["g"] as? [String: Any], let stops = gradient["p"] as? Int,
           var property = gradient["k"] as? [String: Any] {
            let turnStops = { (values: [Double]) in
                var values = values
                for stop in 0..<stops where stop * 4 + 3 < values.count {
                    let at = stop * 4
                    (values[at + 1], values[at + 2], values[at + 3]) = turn.apply(values[at + 1], values[at + 2], values[at + 3])
                }
                return values
            }
            if let values = property["k"] as? [Double] {
                property["k"] = turnStops(values)
            } else if let frames = property["k"] as? [[String: Any]] {
                property["k"] = frames.map { frame in
                    var frame = frame
                    for key in ["s", "e"] { if let values = frame[key] as? [Double] { frame[key] = turnStops(values) } }
                    return frame
                }
            }
            gradient["k"] = property
            object["g"] = gradient
        }
        for (key, child) in object where key != "g" { object[key] = recolour(child, turn) }
        return object
    }
}

/// The dial's flame: the Noto fire in the tier's colours, at the tier's size,
/// with the tier's sun, rays, embers and sparkles drawn around it and a
/// spring on a new tier. It holds still under Reduce Motion and while the
/// window is inactive. The painted `StreakFlame` stands in if the fire cannot
/// load, and in rendered frames: Lottie's offscreen renderer drops the track
/// mattes the fire is cut out with.
struct FireFlame: View {
    let look: FlameLook
    var lit = true
    var popAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrames) private var stillFrames
    @Environment(\.controlActiveState) private var activeState

    /// Where the fire sits in its own square: its base this far down, and
    /// this tall, so it stands where the painted flame stands.
    private static let base = 0.94, height = 0.88

    var body: some View {
        let colours = lit ? look.colours : .unlit
        if !stillFrames, let animation = FireAnimation.animation(colours) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || activeState == .inactive)) { context in
                let t = reduceMotion ? 0.4 : context.date.timeIntervalSinceReferenceDate
                let popAge = reduceMotion ? nil : popAt.map { context.date.timeIntervalSince($0) }
                GeometryReader { proxy in
                    let s = min(proxy.size.width, proxy.size.height)
                    ZStack {
                        surroundings(.behind, t: t, popAge: popAge)
                        fire(animation, colours: colours, side: s, t: t, popAge: popAge)
                        surroundings(.front, t: t, popAge: popAge)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .accessibilityHidden(true)
        } else {
            StreakFlame(look: look, lit: lit, popAt: popAt)
        }
    }

    private func surroundings(_ parts: FlamePainter.Parts, t: Double, popAge: Double?) -> some View {
        Canvas { context, size in
            FlamePainter(look: look, lit: lit).draw(in: context, side: min(size.width, size.height), t: t, popAge: popAge,
                                                    parts: parts)
        }
    }

    /// The fire, scaled to the painted flame's height for this tier and stood
    /// on its base, squashed and stretched by the new-tier spring.
    @ViewBuilder
    private func fire(_ animation: LottieAnimation, colours: FlameColours, side s: Double, t: Double,
                      popAge: Double?) -> some View {
        let square = s * 0.66 * look.size / Self.height
        let spring = popAge.map { $0 >= 0 && $0 < 1.6 ? exp(-$0 * 4.2) * cos($0 * 15) : 0 } ?? 0
        Group {
            if reduceMotion {
                LottieView(animation: animation).resizable().paused(at: .progress(0))
            } else if activeState == .inactive {
                LottieView(animation: animation).resizable().paused(at: .currentFrame)
            } else {
                LottieView(animation: animation).resizable().looping()
            }
        }
        .frame(width: square, height: square)
        .id(colours)
        .scaleEffect(x: 1 - 0.16 * spring, y: 1 + 0.26 * spring, anchor: UnitPoint(x: 0.5, y: Self.base))
        .hueRotation(.degrees(lit && look.prism ? (t * 50).truncatingRemainder(dividingBy: 360) : 0))
        .position(x: s / 2, y: s * 0.86 - square * (Self.base - 0.5))
    }
}

/// The fire alone, filling its square in a tier's colours, for the tier road
/// and the hover cards, where every tier is drawn at one size. It plays
/// unless `animated` is false or Reduce Motion is on. The painted flame
/// stands in where the fire cannot load, and in rendered frames.
struct FireIcon: View {
    let look: FlameLook
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrames) private var stillFrames
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Group {
            if !stillFrames, let animation = FireAnimation.animation(look.colours) {
                if animated, !reduceMotion, activeState != .inactive {
                    LottieView(animation: animation).resizable().looping()
                } else {
                    LottieView(animation: animation).resizable().paused(at: .progress(0))
                }
            } else {
                // The painted flame stands smaller in its square; this brings
                // it to the fire's height.
                StreakFlame(look: look, animated: false).scaleEffect(0.88 / (0.66 * look.size), anchor: .bottom)
            }
        }
        .id(look.colours)
        .accessibilityHidden(true)
    }
}
