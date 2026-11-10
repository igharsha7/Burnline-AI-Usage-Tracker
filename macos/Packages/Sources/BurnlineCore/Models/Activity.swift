//
//  Activity.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// One local day of usage, as the heatmap, streaks and achievements read it.
public struct ActivityDay: Equatable, Sendable {
    public let day: LocalDay
    public let window: TimeWindow
    public let totals: UsageTotals
    /// Sessions active at some point in the day.
    public let sessions: Int
    public let providers: [ProviderKey: UsageTotals]
    /// Quarter hours of the day with any usage, the measure a streak day is
    /// held to.
    public let activeQuarterHours: Int

    public init(day: LocalDay, window: TimeWindow, totals: UsageTotals, sessions: Int,
                providers: [ProviderKey: UsageTotals], activeQuarterHours: Int) {
        self.day = day
        self.window = window
        self.totals = totals
        self.sessions = sessions
        self.providers = providers
        self.activeQuarterHours = activeQuarterHours
    }

    /// A day with at least one usage event, as active days are defined.
    public var isActive: Bool { totals.events > 0 }
}

/// What a streak asks of a day, and the freezes that carry it over a missed
/// one. A day counts once it has an hour of usage, in quarter hours that need
/// not be consecutive; every 90 days of a streak asks for a quarter hour
/// more, up to two hours, and a broken streak starts again at an hour. Each
/// week of counted days earns a freeze, two at most, and a freeze covers a
/// whole day that fell short without adding to the streak. Freezes belong to
/// their streak and go when it breaks. Today is never covered or broken:
/// until it is over it waits.
public enum StreakRule {
    public static let quarterHourMinutes = 15
    /// An hour.
    public static let baseQuarterHours = 4
    /// Two hours.
    public static let maximumQuarterHours = 8
    /// Days of a streak that add a quarter hour to what a day asks.
    public static let rampDays = 90
    /// Counted days that earn a freeze.
    public static let freezeEvery = 7
    public static let maximumFreezes = 2

    /// The quarter hours a day asks for when the streak has counted `length`
    /// days before it.
    public static func required(afterDays length: Int) -> Int {
        min(maximumQuarterHours, baseQuarterHours + length / rampDays)
    }

    /// What became of a day.
    public enum Outcome: Equatable, Sendable {
        /// It met the bar; the streak's length through it.
        case counted(Int)
        /// It fell short and a freeze covered it.
        case frozen
        /// It fell short with no freeze, or with no streak to keep.
        case missed
        /// Today, short of the bar so far.
        case waiting
    }

    public struct Step: Equatable, Sendable {
        public let day: ActivityDay
        public let outcome: Outcome
        /// The quarter hours this day asked for.
        public let required: Int
        /// Freezes held after this day.
        public let freezes: Int
    }

    /// Every day's outcome, in order. `days` is consecutive and ends today.
    public static func walk(_ days: [ActivityDay]) -> [Step] {
        var length = 0, freezes = 0
        return days.indices.map { index in
            let day = days[index], required = required(afterDays: length)
            let outcome: Outcome
            if day.activeQuarterHours >= required {
                length += 1
                if length.isMultiple(of: freezeEvery) { freezes = min(maximumFreezes, freezes + 1) }
                outcome = .counted(length)
            } else if index == days.count - 1 {
                outcome = .waiting
            } else if length > 0, freezes > 0 {
                freezes -= 1
                outcome = .frozen
            } else {
                length = 0
                freezes = 0
                outcome = .missed
            }
            return Step(day: day, outcome: outcome, required: required, freezes: freezes)
        }
    }
}

/// Runs of counted days under `StreakRule`. An unfinished today does not end
/// the current streak; it waits on the day's hour.
public struct Streaks: Equatable, Sendable {
    public let current: Int
    public let longest: Int
    /// The last day of the longest streak; the latest one on a tie.
    public let longestEnded: LocalDay?
    /// The longest streak; the latest one on a tie.
    public let best: StreakRun?
    /// Every streak, oldest first. The last is the current one while
    /// `current` is above zero.
    public let runs: [StreakRun]
    /// Whether today has met its bar yet. Until it does, the current streak
    /// stands on yesterday and waits.
    public let todayCounts: Bool
    /// Today's active quarter hours, and what today asks for.
    public let todayQuarterHours: Int
    public let todayRequired: Int
    /// Freezes the current streak holds.
    public let freezes: Int
    /// Counted days this month and this year.
    public let countedThisMonth: Int
    public let countedThisYear: Int

    /// `days` is every tracked day, oldest first and ending today.
    public init(days: [ActivityDay]) {
        let steps = StreakRule.walk(days)
        var runs: [StreakRun] = []
        var open: StreakRun?
        for step in steps {
            switch step.outcome {
            case .counted(let length):
                open = StreakRun(start: open?.start ?? step.day.day, end: step.day.day, length: length,
                                 frozen: open?.frozen ?? [])
            case .frozen:
                open = open.map { StreakRun(start: $0.start, end: $0.end, length: $0.length, frozen: $0.frozen + [step.day.day]) }
            case .missed:
                if let run = open { runs.append(run) }
                open = nil
            case .waiting:
                break
            }
        }
        if let open { runs.append(open) }
        let best = runs.reduce(nil) { best, run in run.length >= (best?.length ?? 1) ? run : best } as StreakRun?
        let today = days.last?.day
        let counted = steps.filter { if case .counted = $0.outcome { true } else { false } }.map(\.day.day)
        current = open?.length ?? 0
        longest = best?.length ?? 0
        longestEnded = best?.end
        self.best = best
        self.runs = runs
        todayCounts = steps.last.map { if case .counted = $0.outcome { true } else { false } } ?? false
        todayQuarterHours = days.last?.activeQuarterHours ?? 0
        todayRequired = steps.last?.required ?? StreakRule.baseQuarterHours
        freezes = open == nil ? 0 : steps.last?.freezes ?? 0
        countedThisMonth = counted.count { $0.year == today?.year && $0.month == today?.month }
        countedThisYear = counted.count { $0.year == today?.year }
    }
}

/// One unbroken run of counted days, first and last day included. `length`
/// counts only the counted days; `frozen` holds the days a freeze covered.
public struct StreakRun: Equatable, Sendable {
    public let start: LocalDay
    public let end: LocalDay
    public let length: Int
    public let frozen: [LocalDay]

    public init(start: LocalDay, end: LocalDay, length: Int, frozen: [LocalDay] = []) {
        self.start = start
        self.end = end
        self.length = length
        self.frozen = frozen
    }
}

/// The heatmap's intensity levels, derived from the visible range rather
/// than fixed thresholds, so a light user and a heavy one both see a
/// gradient. A day's level is its rank among the range's distinct
/// non-zero values: the busiest day is always the top level, and zero is
/// always level 0.
public struct HeatmapScale: Sendable {
    /// Levels above zero.
    public static let levels = 4

    private let sorted: [Double]

    public init(values: some Sequence<Double>) {
        sorted = Array(Set(values.filter { $0 > 0 })).sorted()
    }

    /// 0 for no usage, then 1 through `levels`.
    public func level(for value: Double) -> Int {
        guard value > 0, !sorted.isEmpty else { return 0 }
        // The number of distinct values above this one, as a share of all.
        let above = sorted.count - sorted.partitioningIndex { $0 >= value } - 1
        let level = Self.levels - above * Self.levels / sorted.count
        return min(max(level, 1), Self.levels)
    }
}

private extension Array where Element == Double {
    /// The first index whose element satisfies `predicate`, on an array
    /// partitioned by it.
    func partitioningIndex(where predicate: (Double) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
