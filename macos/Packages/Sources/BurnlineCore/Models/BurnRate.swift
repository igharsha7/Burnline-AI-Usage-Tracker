//
//  BurnRate.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// How fast one quota window is being used, and when it would run out at that
/// pace. A projection, never a guarantee.
public struct BurnRate: Hashable, Sendable {
    /// What the rate was drawn from.
    public enum Basis: Hashable, Sendable {
        /// The last `BurnRateEstimator.lookback` of readings: usage now.
        case recent
        /// The whole window so far, used while recent usage is idle, so a
        /// pause does not hide a window that is on course to run out.
        case window
    }

    /// Percentage points of the window used per hour. Never negative: usage
    /// that falls within a window is a correction, not negative consumption.
    public let percentPerHour: Double
    public let basis: Basis
    public let percentUsed: Double
    /// The newest figure the rate is based on.
    public let observedAt: Timestamp
    public let resetAt: Timestamp?
    /// When the window reaches 100% at this rate. Nil when it will not before
    /// it resets, or within `BurnRateEstimator.horizon` when the reset time is
    /// unknown, or when nothing is being used.
    public let projectedExhaustion: Timestamp?

    public init(percentPerHour: Double, basis: Basis = .recent, percentUsed: Double, observedAt: Timestamp,
                resetAt: Timestamp?, projectedExhaustion: Timestamp?) {
        self.percentPerHour = percentPerHour
        self.basis = basis
        self.percentUsed = percentUsed
        self.observedAt = observedAt
        self.resetAt = resetAt
        self.projectedExhaustion = projectedExhaustion
    }

    /// How long before the reset the window runs out at this rate. Nil unless
    /// it is projected to run out first.
    public var exhaustionLead: Int64? {
        guard let projectedExhaustion, let resetAt else { return nil }
        return resetAt.seconds(since: projectedExhaustion)
    }
}

/// Why no rate is shown. The interface says so rather than forcing a number.
public enum BurnRateGap: Error, Hashable, Sendable {
    /// The newest figure is too old to describe the present.
    case stale
    /// Too little of the current window has been observed.
    case notEnoughData
}

/// Estimates a window's burn rate from its recent snapshots.
///
/// 1. Keep the current window only: points before a new window start, or
///    before an unexplained drop in usage, belong to a window that ended. A
///    banked reset's 94%-to-0% drop is therefore never averaged across.
/// 2. Keep the last `lookback` of it.
/// 3. Fit a line by least squares, each point weighted by its age with a
///    half-life of `halfLife`, so one short burst moves the rate without
///    dominating it.
/// 4. While that rate is idle, or there is too little of it to fit, take
///    the window's average instead: what it has used over the time since it
///    started, once `windowMinimumShare` of it has passed.
/// 5. Extrapolate to 100% and compare with the reset time.
public enum BurnRateEstimator {
    public static let lookback: Int64 = 60 * 60
    public static let halfLife: Double = 20 * 60
    /// The least span of observations a rate is drawn from.
    public static let minimumSpan: Int64 = 10 * 60
    /// A fall smaller than this is provider rounding, not a new window.
    public static let dropTolerance = 2.0
    /// Below this, usage is treated as idle and nothing is projected.
    public static let idleRate = 0.1
    /// How far ahead a window with no known reset time is projected.
    public static let horizon: Int64 = 31 * 86_400
    /// The share of a window that must have passed before its average is a
    /// pace: a few minutes in, one burst would read as a runaway.
    public static let windowMinimumShare = 0.1

    /// `points` are one window's snapshots in any order; the newest is taken
    /// as the present figure.
    public static func estimate(_ points: [QuotaSnapshot], at now: Timestamp) -> Result<BurnRate, BurnRateGap> {
        let sorted = points.filter { $0.percentageUsed != nil }.sorted { $0.observedAt < $1.observedAt }
        guard let latest = sorted.last, latest.percentageUsed != nil else { return .failure(.notEnoughData) }
        guard now.seconds(since: latest.observedAt) <= ProviderQuotaState.staleAfter else { return .failure(.stale) }

        let recent = recentRate(sorted, latest: latest)
        if let recent, recent >= idleRate { return .success(project(recent, .recent, from: latest)) }
        if let average = windowAverage(latest), average >= idleRate {
            return .success(project(average, .window, from: latest))
        }
        guard let recent else { return .failure(.notEnoughData) }
        return .success(project(recent, .recent, from: latest))
    }

    /// Percentage points an hour over the last `lookback` of the current
    /// window, or nil when too little of it was observed.
    private static func recentRate(_ sorted: [QuotaSnapshot], latest: QuotaSnapshot) -> Double? {
        var window = [latest]
        for point in sorted.dropLast().reversed() {
            guard latest.observedAt.seconds(since: point.observedAt) <= lookback else { break }
            let later = window[window.count - 1]
            if let start = point.windowStartedAt, let current = later.windowStartedAt, start != current { break }
            if point.percentageUsed! > later.percentageUsed! + dropTolerance { break }
            window.append(point)
        }
        guard window.count >= 2,
              latest.observedAt.seconds(since: window[window.count - 1].observedAt) >= minimumSpan else { return nil }

        // Seconds before the newest point, and their weights.
        let samples = window.map { point in
            let age = Double(latest.observedAt.seconds(since: point.observedAt))
            return (t: -age, p: point.percentageUsed!, w: pow(2, -age / halfLife))
        }
        let weight = samples.reduce(0) { $0 + $1.w }
        let meanT = samples.reduce(0) { $0 + $1.w * $1.t } / weight
        let meanP = samples.reduce(0) { $0 + $1.w * $1.p } / weight
        let spread = samples.reduce(0) { $0 + $1.w * ($1.t - meanT) * ($1.t - meanT) }
        guard spread > 0 else { return nil }
        let slope = samples.reduce(0) { $0 + $1.w * ($1.t - meanT) * ($1.p - meanP) } / spread
        return max(0, slope * 3_600)
    }

    /// Percentage points an hour since the window started, or nil when its
    /// start is unknown or too little of it has passed.
    private static func windowAverage(_ latest: QuotaSnapshot) -> Double? {
        guard let start = latest.windowStartedAt, let percent = latest.percentageUsed else { return nil }
        let elapsed = latest.observedAt.seconds(since: start)
        let least = latest.resetAt.map { Int64(Double($0.seconds(since: start)) * windowMinimumShare) } ?? minimumSpan
        guard elapsed > 0, elapsed >= max(least, minimumSpan) else { return nil }
        return percent / Double(elapsed) * 3_600
    }

    private static func project(_ rate: Double, _ basis: BurnRate.Basis, from latest: QuotaSnapshot) -> BurnRate {
        let percent = latest.percentageUsed!
        var exhaustion: Timestamp?
        if rate >= idleRate, percent < QuotaThresholds.exhausted {
            let seconds = (QuotaThresholds.exhausted - percent) / rate * 3_600
            let limit = latest.resetAt.map { $0.seconds(since: latest.observedAt) } ?? horizon
            if seconds < Double(limit) { exhaustion = latest.observedAt.adding(seconds: Int64(seconds.rounded())) }
        }
        return BurnRate(percentPerHour: rate, basis: basis, percentUsed: percent, observedAt: latest.observedAt,
                        resetAt: latest.resetAt, projectedExhaustion: exhaustion)
    }
}
