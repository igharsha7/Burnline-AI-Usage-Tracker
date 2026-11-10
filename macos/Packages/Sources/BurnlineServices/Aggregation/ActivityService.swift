//
//  ActivityService.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import Foundation

/// Every tracked day at once, with what it adds up to: streaks, lifetime
/// totals and the achievements earned.
public struct ActivitySnapshot: Equatable, Sendable {
    /// Every day from the one tracking began through today, oldest first.
    public let days: [ActivityDay]
    public let streaks: Streaks
    /// Every achievement stored, oldest first.
    public let achievements: [Achievement]
    public let lifetime: UsageTotals
    /// Every medal there is, for the shelves.
    public let catalogue: [AchievementBadge]
    /// The next medal on each habit ladder, closest first.
    public let progress: [AchievementProgress]
    public let records: PersonalRecords?
    /// This month's challenge, once there is a month before it.
    public let challenge: MonthlyChallenge?
    /// Fresh achievements whose arrival has not been played yet, oldest first.
    public let uncelebrated: [Achievement]

    public init(days: [ActivityDay], streaks: Streaks, achievements: [Achievement], lifetime: UsageTotals,
                catalogue: [AchievementBadge] = AchievementBadge.catalogue(providers: ProviderKey.trackable),
                progress: [AchievementProgress] = [], records: PersonalRecords? = nil,
                challenge: MonthlyChallenge? = nil, uncelebrated: [Achievement] = []) {
        self.days = days
        self.streaks = streaks
        self.achievements = achievements
        self.lifetime = lifetime
        self.catalogue = catalogue
        self.progress = progress
        self.records = records
        self.challenge = challenge
        self.uncelebrated = uncelebrated
    }

    public static let empty = ActivitySnapshot(days: [], streaks: Streaks(days: []), achievements: [], lifetime: .zero)
}

/// The activity page's figures, read from the rollups so compacted history
/// counts. Reading them also awards any achievement the history has earned
/// and the store does not hold yet, so a backfill is awarded retroactively,
/// dated where its usage happened.
public struct ActivityService: Sendable {
    let database: BurnlineDatabase
    let aggregation: AggregationService
    let calendar: LocalCalendar
    let clock: any WallClock
    let appVersion: String?

    public init(database: BurnlineDatabase, aggregation: AggregationService, calendar: LocalCalendar,
                clock: any WallClock = SystemClock(),
                appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) {
        self.database = database
        self.aggregation = aggregation
        self.calendar = calendar
        self.clock = clock
        self.appVersion = appVersion
    }

    public func snapshot() throws(StoreError) -> ActivitySnapshot {
        let now = clock.now
        guard let (days, lifetime, history) = try history(now: now) else {
            return ActivitySnapshot(days: [], streaks: Streaks(days: []), achievements: try database.achievements.all(),
                                    lifetime: .zero, uncelebrated: try fresh(now: now))
        }
        try database.achievements.award(Achievement.earned(history), at: now)
        let achievements = try database.achievements.all()
        let catalogue = AchievementBadge.catalogue(providers: ProviderKey.trackable,
                                                   revealedThrough: calendar.day(containing: now).year)
        return ActivitySnapshot(days: days, streaks: Streaks(days: days), achievements: achievements,
                                lifetime: lifetime, catalogue: catalogue,
                                progress: AchievementProgress.next(history, earned: achievements, catalogue: catalogue),
                                records: PersonalRecords(history), challenge: MonthlyChallenge.current(history),
                                uncelebrated: try fresh(now: now))
    }

    /// Awards whatever the history has earned and the store does not hold
    /// yet, without reading the rest of a snapshot.
    public func award() throws(StoreError) {
        let now = clock.now
        guard let (_, _, history) = try history(now: now) else { return }
        try database.achievements.award(Achievement.earned(history), at: now)
    }

    /// Judges the history now and returns every medal added since
    /// `moment`, however long ago it was earned: what importing a
    /// provider's history found, for setup and Add Provider to show.
    public func found(since moment: Timestamp) throws(StoreError) -> [Achievement] {
        try award()
        return try database.achievements.added(since: moment)
    }

    /// How many fresh medals wait to play their arrival, for the sidebar's
    /// badge. One small query; nothing is awarded.
    public func uncelebratedCount() throws(StoreError) -> Int {
        try fresh(now: clock.now).count
    }

    /// Marks the arrivals that just played, leaving anything earned while
    /// they were on screen for the next arrival.
    public func celebrate(_ achievements: [Achievement]) throws(StoreError) {
        try database.achievements.celebrate(achievements, at: clock.now)
    }

    /// Fresh medals still on the shelves: a medal the catalogue has since
    /// retired has nothing to show, so it never arrives.
    private func fresh(now: Timestamp) throws(StoreError) -> [Achievement] {
        let catalogue = AchievementBadge.catalogue(providers: ProviderKey.trackable)
        return try database.achievements.uncelebrated().filter { achievement in
            achievement.isFresh(at: now) && catalogue.contains { $0.matches(achievement) }
        }
    }

    /// Every tracked day, the lifetime total, and the history achievements
    /// are judged on; nil before anything is tracked.
    private func history(now: Timestamp) throws(StoreError) -> ([ActivityDay], UsageTotals, AchievementHistory)? {
        guard let start = try aggregation.trackingStart() else { return nil }
        let today = calendar.window(for: calendar.day(containing: now))
        let series = try aggregation.aggregate(.custom(TimeWindow(start: start, end: today.end)), width: .day,
                                               grouping: .provider)
        let windows = series.buckets.map(\.window)
        let sessions = try database.aggregation.sessionCounts(in: windows)
        let quarterHours = try database.aggregation.activeQuarterHours(in: windows)
        var lifetime = UsageTotals.zero
        var days: [ActivityDay] = []
        for ((bucket, sessions), quarterHours) in zip(zip(series.buckets, sessions), quarterHours) {
            var providers: [ProviderKey: UsageTotals] = [:]
            for case (.provider(let provider), let totals) in bucket.groups { providers[provider] = totals }
            days.append(ActivityDay(day: calendar.day(containing: bucket.window.start), window: bucket.window,
                                    totals: bucket.total, sessions: sessions, providers: providers,
                                    activeQuarterHours: quarterHours))
            do { lifetime = try lifetime.adding(bucket.total) } catch { throw .sqlite("a total overflowed: \(error)") }
        }
        let firstUses = try database.aggregation.firstUses()
        let cycles = try database.quota.cycles()
        let history = AchievementHistory(
            days: days, sessions: try database.sessions.records(), modelFirstUses: firstUses.models,
            projectFirstUses: firstUses.projects,
            weeklyCycles: cycles.filter { QuotaWindowKind(quotaKey: $0.key) == .weekly },
            fiveHourCycles: cycles.filter { QuotaWindowKind(quotaKey: $0.key) == .fiveHour },
            projectTokens: try database.aggregation.projectTokens(in: windows),
            modelsPerDay: try database.aggregation.modelCounts(in: windows),
            calendar: calendar, now: now, appVersion: appVersion)
        return (days, lifetime, history)
    }
}
