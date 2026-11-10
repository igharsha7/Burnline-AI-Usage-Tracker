//
//  MonthlyChallenge.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// One month's challenge, from a fixed schedule that starts in September
/// 2026. Every challenge rewards rest, restraint or craft, never more usage,
/// and each month's medal is set in its birthstone.
public struct MonthlyChallenge: Hashable, Sendable {
    public enum Kind: Int64, Sendable, CaseIterable {
        case underTheLimit = 1, cacheKeeper, showingUp, lightsOut, newGround, steadyWeeks, deepFocus,
             betterCache, weekendsOff, spreadOut, rested, fullRoster, oneThingWell, calmLimits

        public var title: String {
            switch self {
            case .underTheLimit: "Under the Limit"
            case .cacheKeeper: "Cache Keeper"
            case .showingUp: "Showing Up"
            case .lightsOut: "Lights Out"
            case .newGround: "New Ground"
            case .steadyWeeks: "Steady Weeks"
            case .deepFocus: "Deep Focus"
            case .betterCache: "Better Cache"
            case .weekendsOff: "Weekends Off"
            case .spreadOut: "Spread Out"
            case .rested: "Rested"
            case .fullRoster: "Full Roster"
            case .oneThingWell: "One Thing Well"
            case .calmLimits: "Calm Limits"
            }
        }

        public var summary: String {
            let percent = { (share: Double) in "\(Int((share * 100).rounded()))%" }
            return switch self {
            case .underTheLimit: "Close every weekly window this month without reaching its limit."
            case .cacheKeeper: "Serve \(percent(MonthlyChallenge.cacheKeeperShare)) of the month's input from the cache."
            case .showingUp: "Be active on \(MonthlyChallenge.showingUpDays) days this month."
            case .lightsOut: "Start no sessions between midnight and 5 a.m. all month."
            case .newGround: "Try a model you have never used before."
            case .steadyWeeks: "Keep every weekly window this month under \(Int(MonthlyChallenge.steadyWeeksCeiling))%."
            case .deepFocus: "Hold \(MonthlyChallenge.deepFocusSessions) sessions of an hour or more."
            case .betterCache: "Serve more of your input from the cache than last month."
            case .weekendsOff: "Take \(MonthlyChallenge.weekendsOffDays) weekend days off entirely."
            case .spreadOut: "Be active in every week that starts this month."
            case .rested: "Take at least one day off in every full week of the month."
            case .fullRoster: "Use every provider you track on the same day, \(MonthlyChallenge.fullRosterDays) times."
            case .oneThingWell: "Spend \(percent(MonthlyChallenge.oneThingWellShare)) of the month's tokens in one project."
            case .calmLimits: "Keep every 5-hour window this month at or under \(Int(MonthlyChallenge.calmLimitsCeiling))%."
            }
        }

        /// Whether it counts toward a target, so a bar can show it, rather
        /// than holding or breaking.
        public var isCounted: Bool {
            [.cacheKeeper, .showingUp, .deepFocus, .betterCache, .weekendsOff, .fullRoster, .oneThingWell]
                .contains(self)
        }
    }

    public let year: Int
    public let month: Int
    public let kind: Kind
    /// Where a counted challenge stands, a count or a share of one.
    public let current: Double?
    /// What a counted challenge asks for; nil when there is nothing to beat.
    public let target: Double?
    /// Whether the month so far meets it. Judged on the whole month once it
    /// is over.
    public let onTrack: Bool

    public var tier: String { Self.tier(year, month) }
    public var summary: String { kind.summary }

    public static let cacheKeeperShare = 0.7
    public static let showingUpDays = 15
    public static let steadyWeeksCeiling = 80.0
    public static let deepFocusSessions = 10
    public static let deepFocusSeconds: Int64 = 3_600
    public static let weekendsOffDays = 4
    public static let fullRosterDays = 10
    public static let oneThingWellShare = 0.8
    public static let calmLimitsCeiling = 90.0
    /// A month needs this many active days before resting or caching in it
    /// means anything: an idle month rests by default.
    public static let minimumActiveDays = 5
    /// Sessions starting before this hour count as late.
    public static let lateHour = 5

    /// The schedule, by year and month. No challenge runs before it starts.
    public static let schedule: [String: Kind] = [
        "2026-09": .underTheLimit, "2026-10": .cacheKeeper, "2026-11": .showingUp, "2026-12": .lightsOut,
        "2027-01": .newGround, "2027-02": .steadyWeeks, "2027-03": .deepFocus, "2027-04": .betterCache,
        "2027-05": .weekendsOff, "2027-06": .spreadOut, "2027-07": .rested, "2027-08": .fullRoster,
        "2027-09": .oneThingWell, "2027-10": .calmLimits, "2027-11": .underTheLimit, "2027-12": .cacheKeeper,
        "2028-01": .showingUp, "2028-02": .lightsOut, "2028-03": .newGround, "2028-04": .steadyWeeks,
        "2028-05": .deepFocus, "2028-06": .betterCache, "2028-07": .weekendsOff, "2028-08": .spreadOut,
        "2028-09": .rested, "2028-10": .fullRoster, "2028-11": .oneThingWell, "2028-12": .calmLimits,
    ]

    /// Every scheduled month, earliest first, as `yyyy-MM`.
    public static var months: [String] { schedule.keys.sorted() }

    public static func tier(_ year: Int, _ month: Int) -> String { String(format: "%04d-%02d", year, month) }

    /// "2026-11" as (2026, 11).
    public static func month(_ tier: String) -> (year: Int, month: Int)? {
        let parts = tier.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// This month's challenge and how it stands, or nil outside the schedule.
    public static func current(_ history: AchievementHistory) -> MonthlyChallenge? {
        let today = history.calendar.day(containing: history.now)
        return judge(year: today.year, month: today.month, history)
    }

    /// The challenges met in months already over.
    static func earned(_ history: AchievementHistory) -> [Achievement] {
        months.compactMap { tier in
            guard let (year, month) = month(tier), let end = monthWindow(year, month, history.calendar)?.end,
                  end <= history.now, let challenge = judge(year: year, month: month, history), challenge.onTrack
            else { return nil }
            return Achievement(kind: .monthly, tier: tier, value: challenge.kind.rawValue, awardedAt: end)
        }
    }

    /// How the month's challenge stands on what has happened in it so far.
    static func judge(year: Int, month: Int, _ history: AchievementHistory) -> MonthlyChallenge? {
        guard let kind = schedule[tier(year, month)],
              let window = monthWindow(year, month, history.calendar) else { return nil }
        let calendar = history.calendar
        let indices = history.days.indices.filter { history.days[$0].day.year == year && history.days[$0].day.month == month }
        let days = indices.map { history.days[$0] }
        guard !days.isEmpty else { return nil }
        let over = window.end <= history.now
        let active = days.count(where: \.isActive)
        let busy = active >= minimumActiveDays
        let inMonth = { (instant: Timestamp) in window.contains(instant) }
        let sessions = history.sessions.filter { inMonth($0.startedAt) }
        func windows(_ cycles: [AchievementHistory.QuotaCycle]) -> [AchievementHistory.QuotaCycle] {
            cycles.filter { inMonth($0.end) && (!over || $0.isConfirmedClosed) }
        }
        func held(_ cycles: [AchievementHistory.QuotaCycle], below ceiling: Double, inclusive: Bool = false) -> Bool {
            let kept = cycles.allSatisfy { inclusive ? $0.peak <= ceiling : $0.peak < ceiling }
            return kept && (!over || !cycles.isEmpty)
        }
        func counted(_ value: Double, _ target: Double, needsBusy: Bool = false) -> MonthlyChallenge {
            MonthlyChallenge(year: year, month: month, kind: kind, current: value, target: target,
                             onTrack: value >= target && (!needsBusy || busy))
        }
        func status(_ onTrack: Bool) -> MonthlyChallenge {
            MonthlyChallenge(year: year, month: month, kind: kind, current: nil, target: nil, onTrack: onTrack)
        }
        let rate = Achievement.cacheRate(days.map(\.totals.tokens))

        switch kind {
        case .underTheLimit:
            return status(held(windows(history.weeklyCycles), below: QuotaThresholds.exhausted))
        case .steadyWeeks:
            return status(held(windows(history.weeklyCycles), below: steadyWeeksCeiling))
        case .calmLimits:
            return status(held(windows(history.fiveHourCycles), below: calmLimitsCeiling, inclusive: true))
        case .cacheKeeper:
            return counted(rate ?? 0, cacheKeeperShare, needsBusy: true)
        case .showingUp:
            return counted(Double(active), Double(showingUpDays))
        case .lightsOut:
            let late = sessions.contains { calendar.calendar.component(.hour, from: $0.startedAt.date) < lateHour }
            return status(!late && busy)
        case .newGround:
            let hadHistory = history.days.first.map { $0.window.start < window.start } ?? false
            return status(hadHistory && history.modelFirstUses.contains(where: inMonth))
        case .deepFocus:
            let long = sessions.count { session in
                guard let end = session.endedAt else { return false }
                let length = end.seconds(since: session.startedAt)
                return length >= deepFocusSeconds && length <= Achievement.marathonCeiling
            }
            return counted(Double(long), Double(deepFocusSessions))
        case .betterCache:
            let (previousYear, previousMonth) = month == 1 ? (year - 1, 12) : (year, month - 1)
            let previous = history.days.filter { $0.day.year == previousYear && $0.day.month == previousMonth }
            let target = previous.count(where: \.isActive) >= minimumActiveDays
                ? Achievement.cacheRate(previous.map(\.totals.tokens)) : nil
            guard let target else {
                return MonthlyChallenge(year: year, month: month, kind: kind, current: rate, target: nil, onTrack: false)
            }
            return MonthlyChallenge(year: year, month: month, kind: kind, current: rate ?? 0, target: target,
                                    onTrack: busy && (rate ?? 0) > target)
        case .weekendsOff:
            let off = days.count { day in
                let weekday = calendar.calendar.component(.weekday, from: day.window.start.date)
                return [Weekday.saturday.rawValue, Weekday.sunday.rawValue].contains(weekday)
                    && !day.isActive && day.window.end <= history.now
            }
            return counted(Double(off), Double(weekendsOffDays), needsBusy: true)
        case .spreadOut:
            let weeks = Self.weeks(starting: window, days: history.days, calendar: calendar)
            let missed = weeks.contains { week in
                week.window.end <= history.now && !week.days.contains(where: \.isActive)
            }
            return status(!missed && active > 0)
        case .rested:
            let weeks = Self.weeks(starting: window, days: history.days, calendar: calendar)
                .filter { $0.window.end <= window.end }
            let unrested = weeks.contains { week in
                week.window.end <= history.now && week.days.allSatisfy(\.isActive)
            }
            return status(!unrested && busy)
        case .fullRoster:
            let tracked = Set(history.days.flatMap { day in day.providers.filter { $0.value.events > 0 }.keys })
            guard tracked.count >= 2 else { return counted(0, Double(fullRosterDays)) }
            let together = days.count { day in tracked.allSatisfy { (day.providers[$0]?.events ?? 0) > 0 } }
            return counted(Double(together), Double(fullRosterDays))
        case .oneThingWell:
            var byProject: [Int64: Int64] = [:]
            for index in indices where index < history.projectTokens.count {
                for (project, tokens) in history.projectTokens[index] { byProject[project, default: 0] += tokens }
            }
            let total = byProject.values.reduce(0, +)
            let share = total > 0 ? Double(byProject.values.max() ?? 0) / Double(total) : 0
            return counted(share, oneThingWellShare, needsBusy: true)
        }
    }

    /// The calendar weeks that begin in `month`, each with its tracked days.
    private static func weeks(starting month: TimeWindow, days: [ActivityDay], calendar: LocalCalendar)
        -> [(window: TimeWindow, days: [ActivityDay])] {
        var weeks: [TimeWindow: [ActivityDay]] = [:]
        for day in days {
            let week = calendar.week(containing: day.window.start)
            if month.contains(week.start) { weeks[week, default: []].append(day) }
        }
        return weeks.sorted { $0.key.start < $1.key.start }.map { ($0.key, $0.value) }
    }

    static func monthWindow(_ year: Int, _ month: Int, _ calendar: LocalCalendar) -> TimeWindow? {
        let (nextYear, nextMonth) = month == 12 ? (year + 1, 1) : (year, month + 1)
        guard let start = calendar.calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.calendar.date(from: DateComponents(year: nextYear, month: nextMonth, day: 1))
        else { return nil }
        return TimeWindow(start: Timestamp(epochSeconds: Int64(start.timeIntervalSince1970)),
                          end: Timestamp(epochSeconds: Int64(end.timeIntervalSince1970)))
    }
}
