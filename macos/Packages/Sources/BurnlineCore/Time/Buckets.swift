//
//  Buckets.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// How wide a chart's buckets are. Minutes and quarter hours are fixed
/// lengths; hours and longer follow the user's calendar, so a day bucket on a
/// daylight-saving change is 23 or 25 hours long.
public enum BucketWidth: String, Sendable, CaseIterable, Comparable {
    case minute, quarterHour, hour, day, week, month

    /// The width for a range, so a chart has between a few dozen and a few
    /// hundred points: up to 6 hours by minute, 48 hours by hour, 90 days by
    /// day, two years by week, longer by month.
    public static func automatic(for window: TimeWindow) -> BucketWidth {
        switch window.durationSeconds {
        case ...(6 * 3_600): .minute
        case ...(48 * 3_600): .hour
        case ...(90 * 86_400): .day
        case ...(731 * 86_400): .week
        default: .month
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// The ranges the dashboard offers.
public enum RangePreset: Hashable, Sendable {
    case today, last7Days, last30Days, last90Days, yearToDate, lastYear, all
    case custom(TimeWindow)
}

extension LocalCalendar {
    /// The buckets of `width` that cover `window`, oldest first. The first
    /// and last may reach outside it, as a day bucket does for a range that
    /// starts at noon; each is a real interval of the calendar.
    public func buckets(_ width: BucketWidth, covering window: TimeWindow) -> [TimeWindow] {
        guard window.start < window.end else { return [] }
        var buckets: [TimeWindow] = []
        var current = bucket(width, containing: window.start)
        while current.start < window.end {
            buckets.append(current)
            current = bucket(width, containing: current.end)
        }
        return buckets
    }

    /// The bucket of `width` that contains `instant`.
    public func bucket(_ width: BucketWidth, containing instant: Timestamp) -> TimeWindow {
        switch width {
        case .minute: return fixed(60, containing: instant)
        case .quarterHour: return fixed(900, containing: instant)
        case .hour:
            // Foundation's hour follows the zone, so in India an hour starts at
            // half past the UTC hour, and a repeated hour is its own bucket.
            let interval = calendar.dateInterval(of: .hour, for: instant.date)!
            // Foundation can span both occurrences of a half-hour clock change.
            // Split at the transition so adjacent hours never overlap.
            if let transition = calendar.timeZone.nextDaylightSavingTimeTransition(
                after: interval.start.addingTimeInterval(-1)), transition < interval.end {
                return stampedInterval(DateInterval(
                    start: transition <= instant.date ? max(interval.start, transition) : interval.start,
                    end: transition > instant.date ? transition : interval.end))
            }
            return stampedInterval(interval)
        case .day: return window(for: day(containing: instant))
        case .week: return week(containing: instant)
        case .month: return month(containing: instant)
        }
    }

    /// The calendar month containing `instant`, from the start of its first
    /// day to the start of the next month's.
    public func month(containing instant: Timestamp) -> TimeWindow {
        let day = day(containing: instant)
        let next = day.month == 12 ? LocalDay(year: day.year + 1, month: 1, day: 1)
                                   : LocalDay(year: day.year, month: day.month + 1, day: 1)
        return TimeWindow(start: window(for: LocalDay(year: day.year, month: day.month, day: 1)).start,
                          end: window(for: next).start)
    }

    /// The span a preset covers at `now`, ending with the end of today. `all`
    /// starts with the day of `earliest`, the oldest instant tracked.
    public func window(for preset: RangePreset, now: Timestamp, earliest: Timestamp?) -> TimeWindow {
        let today = window(for: day(containing: now))
        func lastDays(_ count: Int) -> TimeWindow {
            TimeWindow(start: window(for: days(endingWith: now, count: count)[0]).start, end: today.end)
        }
        switch preset {
        case .today: return today
        case .last7Days: return lastDays(7)
        case .last30Days: return lastDays(30)
        case .last90Days: return lastDays(90)
        case .lastYear: return lastDays(365)
        case .yearToDate:
            let year = day(containing: now).year
            return TimeWindow(start: window(for: LocalDay(year: year, month: 1, day: 1)).start, end: today.end)
        case .all:
            let first = earliest.map { window(for: day(containing: $0)).start } ?? today.start
            return TimeWindow(start: min(first, today.start), end: today.end)
        case .custom(let window): return window
        }
    }

    /// The span just before `window`, for comparing with the previous period,
    /// up to the same point in it: `through` is where `window` stops counting,
    /// its end by default.
    ///
    /// A window of whole local days steps back that many days at the same
    /// clock time, so a 25-hour day before a daylight-saving change does not
    /// pull an hour of the wrong day in. Any other window steps back
    /// its length.
    public func previous(_ window: TimeWindow, through: Timestamp? = nil) -> TimeWindow {
        let through = through ?? window.end
        guard let days = wholeDays(window) else {
            return TimeWindow(start: window.start.adding(seconds: -window.durationSeconds),
                              end: through.adding(seconds: -window.durationSeconds))
        }
        func back(_ instant: Timestamp) -> Timestamp {
            calendar.date(byAdding: .day, value: -days, to: instant.date).flatMap(Timestamp.init) ?? instant
        }
        return TimeWindow(start: back(window.start), end: back(through))
    }

    /// How many local days `window` spans, when it starts and ends at local midnight.
    private func wholeDays(_ window: TimeWindow) -> Int? {
        let start = window.start.date, end = window.end.date
        guard calendar.startOfDay(for: start) == start, calendar.startOfDay(for: end) == end,
              let days = calendar.dateComponents([.day], from: start, to: end).day, days > 0 else { return nil }
        return days
    }

    private func fixed(_ seconds: Int64, containing instant: Timestamp) -> TimeWindow {
        let remainder = ((instant.epochSeconds % seconds) + seconds) % seconds
        let start = instant.adding(seconds: -remainder)
        return TimeWindow(start: start, end: start.adding(seconds: seconds))
    }

    private func stampedInterval(_ interval: DateInterval) -> TimeWindow {
        TimeWindow(start: Timestamp(interval.start)!, end: Timestamp(interval.end)!)
    }
}
