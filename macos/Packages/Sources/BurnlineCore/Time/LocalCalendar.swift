//
//  LocalCalendar.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// A calendar date in the user's time zone, used as a bucket key for the day
/// ledger and the heatmap. Carries no time zone of its own: which instants
/// belong to it depends on the `LocalCalendar` that resolves it.
public struct LocalDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// ISO 8601, `2026-10-31`.
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

public enum Weekday: Int, Sendable, CaseIterable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
}

/// Turns UTC timestamps into local calendar buckets.
///
/// Days come from the calendar, never from dividing epoch seconds by 86,400:
/// across a daylight-saving change a local day is 23 or 25 hours. Nothing is
/// cached, so a new time zone or week start takes effect by building a new
/// `LocalCalendar`; stored timestamps never change.
public struct LocalCalendar: Sendable {
    public let calendar: Calendar

    public init(timeZone: TimeZone, firstWeekday: Weekday) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = firstWeekday.rawValue
        self.calendar = calendar
    }

    public func day(containing instant: Timestamp) -> LocalDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant.date)
        return LocalDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Every instant that falls on `day`. Usually 24 hours long; 23 or 25 on a
    /// daylight-saving change. Empty for a date the zone skipped entirely, as
    /// Samoa skipped 30 December 2011 when it crossed the date line.
    public func window(for day: LocalDay) -> TimeWindow {
        let noon = self.noon(of: day)
        let start = stamp(calendar.startOfDay(for: noon))
        guard self.day(containing: start) == day else {
            // The requested date has no instants; the calendar rolled forward
            // to the next day that exists.
            return TimeWindow(start: start, end: start)
        }
        let nextNoon = calendar.date(byAdding: .day, value: 1, to: noon)!
        return TimeWindow(start: start, end: stamp(calendar.startOfDay(for: nextNoon)))
    }

    /// The week containing `instant`, beginning on the configured first weekday.
    ///
    /// Built by walking day boundaries rather than asking Foundation for a
    /// week interval: around a skipped date, Foundation returns the previous
    /// week, which does not contain the instant at all. A week here is the run
    /// of consecutive days whose position after the first weekday keeps
    /// increasing, so a week missing a day is simply shorter.
    public func week(containing instant: Timestamp) -> TimeWindow {
        var first = dayWindow(containing: instant)
        while true {
            let previous = dayWindow(containing: first.start.adding(seconds: -1))
            guard positionInWeek(previous.start) < positionInWeek(first.start) else { break }
            first = previous
        }
        var last = dayWindow(containing: instant)
        while true {
            let next = dayWindow(containing: last.end)
            guard positionInWeek(next.start) > positionInWeek(last.start) else { break }
            last = next
        }
        return TimeWindow(start: first.start, end: last.end)
    }

    /// The `count` days ending with the day containing `instant`, oldest first.
    /// This is the day ledger's range. Walks real day boundaries, so a skipped
    /// date is never listed.
    public func days(endingWith instant: Timestamp, count: Int) -> [LocalDay] {
        precondition(count >= 0, "a range cannot hold a negative number of days")
        var windows: [TimeWindow] = []
        var current = dayWindow(containing: instant)
        for _ in 0..<count {
            windows.append(current)
            current = dayWindow(containing: current.start.adding(seconds: -1))
        }
        return windows.reversed().map { day(containing: $0.start) }
    }

    /// The window of the day containing `instant`, which always exists.
    private func dayWindow(containing instant: Timestamp) -> TimeWindow {
        window(for: day(containing: instant))
    }

    /// Days after the configured first weekday: 0 for the first day of a week.
    private func positionInWeek(_ instant: Timestamp) -> Int {
        (calendar.component(.weekday, from: instant.date) - calendar.firstWeekday + 7) % 7
    }

    /// Midday anchors day arithmetic because midnight does not exist in zones
    /// that change their clocks at 00:00. Midday can be missing too, but only
    /// when the whole date is, which `window(for:)` checks.
    private func noon(of day: LocalDay) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
    }

    /// Dates here come from the calendar's own arithmetic on in-range
    /// timestamps, so they always convert back.
    private func stamp(_ date: Date) -> Timestamp {
        Timestamp(date)!
    }
}
