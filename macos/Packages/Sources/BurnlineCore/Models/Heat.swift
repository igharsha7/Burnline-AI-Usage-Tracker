//
//  Heat.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// How hard usage is burning right now, judged against this person's own
/// history rather than fixed figures: what is hot for one is idle for
/// another. Measured in equivalent cost an hour, which follows real work
/// and compares fairly across providers, where processed tokens are mostly
/// cache re-reads.
///
/// The scale is three points from the history's busy stretches: the
/// typical one (the median), a busy one (the 75th percentile) and a peak
/// (the 95th). Heat climbs from 0 to 1 across them.
public struct HeatScale: Sendable, Equatable {
    public let typical: Nanodollars
    public let busy: Nanodollars
    public let peak: Nanodollars

    /// The stretch the history is cut into, and the present measured over.
    public static let span: Int64 = 5 * 60
    /// How far back the history is read.
    public static let lookback: Int64 = 30 * 86_400
    /// Fewer busy stretches than this say too little; the default holds.
    public static let fewest = 24
    /// Until there is enough history: a scale for moderate agent use.
    public static let starting = HeatScale(typical: Nanodollars(raw: 5 * Nanodollars.perDollar),
                                           busy: Nanodollars(raw: 15 * Nanodollars.perDollar),
                                           peak: Nanodollars(raw: 40 * Nanodollars.perDollar))

    public init(typical: Nanodollars, busy: Nanodollars, peak: Nanodollars) {
        self.typical = typical
        self.busy = max(busy, typical)
        self.peak = max(peak, self.busy)
    }

    /// The scale from the costs of busy stretches `span` seconds long, or
    /// the starting one when they are too few to say anything.
    public init(spanCosts: [Int64], span: Int64 = HeatScale.span) {
        let perHour = spanCosts.filter { $0 > 0 }.map { $0 * (3_600 / span) }.sorted()
        guard perHour.count >= Self.fewest else {
            self = Self.starting
            return
        }
        func percentile(_ p: Double) -> Nanodollars {
            Nanodollars(raw: perHour[min(perHour.count - 1, Int(Double(perHour.count - 1) * p))])
        }
        self.init(typical: percentile(0.5), busy: percentile(0.75), peak: percentile(0.95))
    }

    /// 0 with nothing burning, a third at a typical pace, two thirds when
    /// busy, 1 at a peak and beyond.
    public func heat(costPerHour: Nanodollars) -> Double {
        let value = Double(costPerHour.raw)
        guard value > 0 else { return 0 }
        let points = [0, Double(typical.raw), Double(busy.raw), Double(peak.raw)]
        for index in 1..<points.count where value < points[index] {
            let low = points[index - 1], high = points[index]
            let within = high > low ? (value - low) / (high - low) : 1
            return (Double(index - 1) + within) / Double(points.count - 1)
        }
        return 1
    }
}

/// Heat said in steps, for the menu-bar flame, which changes only when the
/// step does.
public enum HeatStage: Int, Sendable, Comparable, CaseIterable {
    case idle, warm, hot, blazing

    public init(heat: Double) {
        switch heat {
        case ..<0.000_001: self = .idle
        case ..<(2.0 / 3): self = .warm
        case ..<1: self = .hot
        default: self = .blazing
        }
    }

    public static func < (a: HeatStage, b: HeatStage) -> Bool { a.rawValue < b.rawValue }
}
