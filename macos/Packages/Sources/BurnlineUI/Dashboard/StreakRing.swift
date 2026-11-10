//
//  StreakRing.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import SwiftUI

/// The streak's ring, open at the bottom. The thick arc is the span to the
/// next tier: it fills as the streak grows and starts empty at each tier, so
/// it is never stuck full. The hairline outside it is the whole road to the
/// last tier, on a square-root scale so the early tiers have room, notched
/// at every tier and starred at the best streak.
///
/// Drawn for a 280-point square and scaled to the space given. `fraction`
/// animates, and the dot at the arc's end travels along it.
struct StreakRing: View, Animatable {
    var fraction: Double
    let progress: StreakProgress
    let best: Int
    let colour: Color

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    private static let start = 135.0, sweep = 270.0

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height), unit = side / 280
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let point = { (radius: Double, degrees: Double) in
                CGPoint(x: centre.x + radius * unit * cos(degrees * .pi / 180),
                        y: centre.y + radius * unit * sin(degrees * .pi / 180))
            }
            let arc = { (radius: Double, share: Double) in
                Path { path in
                    let end = Self.start + Self.sweep * share
                    path.move(to: point(radius, Self.start))
                    for degrees in stride(from: Self.start, through: end, by: 1) { path.addLine(to: point(radius, degrees)) }
                    path.addLine(to: point(radius, end))
                }
            }
            let angle = { (share: Double) in Self.start + Self.sweep * share }

            // The road to the last tier.
            let road = StrokeStyle(lineWidth: 2 * unit, lineCap: .round)
            context.stroke(arc(128, 1), with: .color(Palette.controlTrack), style: road)
            context.stroke(arc(128, Self.journey(progress.days)), with: .color(Palette.textSecondary), style: road)
            for (tier, look) in zip(StreakTier.all, FlameLook.tiers) {
                let at = angle(Self.journey(tier.days))
                var notch = Path()
                notch.move(to: point(124, at))
                notch.addLine(to: point(tier.isMajor ? 136 : 132, at))
                context.stroke(notch, with: .color(progress.days >= tier.days ? Color(rgb: look.colours.body) : Palette.separator),
                               style: StrokeStyle(lineWidth: (tier.isMajor ? 2.5 : 1.5) * unit, lineCap: .round))
            }
            // Once the whole road is behind the best streak, it needs no star on it.
            if best > 0, best < StreakTier.all[StreakTier.all.count - 1].days {
                context.draw(Text("★").font(.system(size: 11 * unit)).foregroundStyle(StreakCard.record),
                             at: point(141, angle(Self.journey(best))))
            }

            // This tier's span, with a tick per day, five, ten or fifty.
            let track = StrokeStyle(lineWidth: 12 * unit, lineCap: .round)
            context.stroke(arc(112, 1), with: .color(Palette.controlTrack), style: track)
            if fraction > 0.001 { context.stroke(arc(112, fraction), with: .color(colour), style: track) }
            let span = progress.spanEnd - progress.spanStart
            let step = span <= 14 ? 1 : span <= 40 ? 5 : span <= 120 ? 10 : 50
            for day in stride(from: step, to: span, by: step) {
                let at = angle(Double(day) / Double(span))
                var tick = Path()
                tick.move(to: point(106, at))
                tick.addLine(to: point(118, at))
                context.stroke(tick, with: .color(Palette.surface), lineWidth: 1.5 * unit)
            }
            let bestShare = Double(best - progress.spanStart) / Double(span)
            if progress.days < best, bestShare > 0, bestShare < 1 {
                let at = point(112, angle(bestShare))
                context.fill(FlamePainter.circle(at.x, at.y, 4 * unit), with: .color(Palette.surface))
                context.stroke(FlamePainter.circle(at.x, at.y, 4 * unit), with: .color(StreakCard.record), lineWidth: 2 * unit)
            }
            let head = point(112, angle(max(0.0001, fraction)))
            context.fill(FlamePainter.circle(head.x, head.y, 5.5 * unit), with: .color(.white))
            context.stroke(FlamePainter.circle(head.x, head.y, 5.5 * unit), with: .color(colour), lineWidth: 2 * unit)

            let first = point(112, Self.start), last = point(112, Self.start + Self.sweep)
            for (value, style, at) in [(progress.spanStart, Palette.textSecondary.opacity(0.7),
                                        CGPoint(x: first.x - 4 * unit, y: first.y + 20 * unit)),
                                       (progress.spanEnd, Palette.textSecondary, CGPoint(x: last.x + 4 * unit, y: last.y + 20 * unit))] {
                context.draw(Text("\(value)").font(.system(size: 11 * unit).monospacedDigit()).foregroundStyle(style), at: at)
            }
        }
        .accessibilityHidden(true)
    }

    /// The share of the road to the last tier that `days` covers.
    static func journey(_ days: Int) -> Double {
        let last = StreakTier.all[StreakTier.all.count - 1].days
        return (Double(min(max(days, 0), last)) / Double(last)).squareRoot()
    }
}
