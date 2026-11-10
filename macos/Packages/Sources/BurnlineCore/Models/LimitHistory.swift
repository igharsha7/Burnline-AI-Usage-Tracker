//
//  LimitHistory.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// One quota window's story for the Limits page: how the open window has
/// filled since it began, how full the windows before it got, and the usage
/// this Mac sent in it. Built from recorded observations only, so it shows
/// what was seen, never an interpolation between sightings.
public struct LimitHistory: Sendable, Equatable {
    public struct Reading: Sendable, Equatable {
        public let at: Timestamp
        public let percent: Double

        public init(at: Timestamp, percent: Double) {
            self.at = at
            self.percent = percent
        }
    }

    /// The open window's readings, oldest first.
    public let readings: [Reading]
    /// Windows before it, oldest first, at most `pastLimit`.
    public let past: [AchievementHistory.QuotaCycle]
    /// What this Mac sent to the provider since the window began; nil when
    /// it could not be read.
    public let usage: UsageTotals?

    /// Past windows kept: enough to see a habit, few enough to read at once.
    public static let pastLimit = 12

    public init(readings: [Reading], past: [AchievementHistory.QuotaCycle], usage: UsageTotals? = nil) {
        self.readings = readings
        self.past = past
        self.usage = usage
    }

    /// `window`'s history from every observation of its quota and every
    /// cycle recorded: readings from its start on, and the cycles of the same
    /// quota that ended by then.
    public init(window: QuotaSnapshot, observations: [QuotaSnapshot], cycles: [AchievementHistory.QuotaCycle],
                usage: UsageTotals? = nil) {
        let start = window.windowStartedAt ?? window.observedAt
        readings = observations
            .filter { $0.key == window.key && $0.observedAt >= start }
            .compactMap { snapshot in snapshot.percentageUsed.map { Reading(at: snapshot.observedAt, percent: $0) } }
            .sorted { $0.at < $1.at }
        past = Array(cycles
            .filter { $0.provider == window.provider && $0.key == window.key && $0.end <= start }
            .sorted { $0.end < $1.end }
            .suffix(Self.pastLimit))
        self.usage = usage
    }

    /// Past windows that reached their limit, ending within `seconds` of `now`.
    public func capped(within seconds: Int64, now: Timestamp) -> Int {
        past.filter { $0.peak >= 100 && now.seconds(since: $0.end) <= seconds }.count
    }

    /// The mean of past windows' peaks; nil before any closed.
    public var averagePeak: Double? {
        past.isEmpty ? nil : past.map(\.peak).reduce(0, +) / Double(past.count)
    }
}
