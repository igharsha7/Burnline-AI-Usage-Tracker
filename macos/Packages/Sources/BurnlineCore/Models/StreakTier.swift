//
//  StreakTier.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// The named stops along a streak. Each one changes how the streak's flame
/// looks; the three majors change it most. They mark how long a run has
/// lasted and are never targets: nothing is lost by stopping short of one.
public struct StreakTier: Equatable, Sendable {
    /// The streak length, in days, that reaches this tier.
    public let days: Int
    public let name: String
    /// One line of the story at this tier.
    public let line: String
    public let isMajor: Bool

    public static let all: [StreakTier] = [
        StreakTier(days: 1, name: "Pilot Light", line: "A spark in the dark."),
        StreakTier(days: 7, name: "Hot Reload", line: "It caught. Keep feeding it."),
        StreakTier(days: 14, name: "Campfire", line: "Warm enough to stay up late."),
        StreakTier(days: 30, name: "Bonfire", line: "The whole camp can see it now.", isMajor: true),
        StreakTier(days: 60, name: "Thermal Throttling", line: "Things are getting toasty."),
        StreakTier(days: 80, name: "The Forge", line: "You are shaping something real."),
        StreakTier(days: 100, name: "Blue Flame", line: "Hotter than orange. Much hotter.", isMajor: true),
        StreakTier(days: 150, name: "Afterburner", line: "Full throttle."),
        StreakTier(days: 200, name: "Rocket Fuel", line: "Liftoff."),
        StreakTier(days: 300, name: "Solar Flare", line: "Close enough to touch the sun."),
        StreakTier(days: 400, name: "Red Giant", line: "It keeps growing."),
        StreakTier(days: 500, name: "Supernova", line: "Everything lights up at once.", isMajor: true),
        StreakTier(days: 600, name: "Pulsar", line: "Steady, blinding, on the beat."),
        StreakTier(days: 700, name: "Big Bang", line: "A new universe, made of streaks."),
    ]

    init(days: Int, name: String, line: String, isMajor: Bool = false) {
        self.days = days
        self.name = name
        self.line = line
        self.isMajor = isMajor
    }
}

/// Where a streak of some length stands among the tiers: the tier reached,
/// the next one, and the span between them that the streak is crossing.
///
/// The span always starts at or below the streak and ends above it, so a
/// ring drawn from it is never full: reaching a tier starts the next span
/// empty. Past the last tier the spans are laps of `lapLength` days.
public struct StreakProgress: Equatable, Sendable {
    public static let lapLength = 100

    public let days: Int
    /// The index in `StreakTier.all` of the tier reached; nil before the first.
    public let tierIndex: Int?
    public let next: StreakTier?
    public let spanStart: Int
    public let spanEnd: Int

    public init(days: Int) {
        let tiers = StreakTier.all
        self.days = days
        tierIndex = tiers.lastIndex { $0.days <= days }
        next = tiers.first { $0.days > days }
        if let next {
            spanStart = tierIndex.map { tiers[$0].days } ?? 0
            spanEnd = next.days
        } else {
            let last = tiers[tiers.count - 1].days
            spanStart = last + (days - last) / Self.lapLength * Self.lapLength
            spanEnd = spanStart + Self.lapLength
        }
    }

    public var tier: StreakTier? { tierIndex.map { StreakTier.all[$0] } }

    public var daysToNext: Int? { next.map { $0.days - days } }

    /// The lap under way past the last tier, from 1; nil before it.
    public var lap: Int? {
        guard next == nil else { return nil }
        return (spanStart - StreakTier.all[StreakTier.all.count - 1].days) / Self.lapLength + 1
    }

    /// How far through its span the streak is, from 0 up to but never 1.
    public var fraction: Double { Double(days - spanStart) / Double(spanEnd - spanStart) }
}
