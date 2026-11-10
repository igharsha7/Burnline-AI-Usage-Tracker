//
//  TimeTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import Testing

/// Fixed instants, written as UTC so no test depends on the machine's zone.
enum Instant {
    static func utc(_ iso: String) -> Timestamp {
        Timestamp(try! Date(iso, strategy: .iso8601))!
    }
}

struct LocalCalendarTests {
    static let newYork = LocalCalendar(timeZone: TimeZone(identifier: "America/New_York")!,
                                       firstWeekday: .sunday)
    static let hour: Int64 = 3_600

    @Test func `EC-T1 the spring-forward day is 23 hours`() {
        let window = Self.newYork.window(for: LocalDay(year: 2026, month: 3, day: 8))
        #expect(window.durationSeconds == 23 * Self.hour)
    }

    @Test func `EC-T1 the fall-back day is 25 hours`() {
        let window = Self.newYork.window(for: LocalDay(year: 2026, month: 11, day: 1))
        #expect(window.durationSeconds == 25 * Self.hour)
    }

    @Test func `an ordinary day is 24 hours`() {
        let window = Self.newYork.window(for: LocalDay(year: 2026, month: 6, day: 15))
        #expect(window.durationSeconds == 24 * Self.hour)
    }

    @Test func `EC-T1 the repeated 1am after fall-back still belongs to that day`() {
        // 01:30 EST, the second 1:30 of the night.
        let instant = Instant.utc("2026-11-01T06:30:00Z")
        #expect(Self.newYork.day(containing: instant) == LocalDay(year: 2026, month: 11, day: 1))
        #expect(Self.newYork.window(for: LocalDay(year: 2026, month: 11, day: 1)).contains(instant))
    }

    @Test func `EC-T1 a day whose midnight does not exist still has a window`() {
        // Chile moves its clocks forward at midnight, so 6 September 2026
        // begins at 01:00 and is 23 hours long.
        let santiago = LocalCalendar(timeZone: TimeZone(identifier: "America/Santiago")!,
                                     firstWeekday: .monday)
        let window = santiago.window(for: LocalDay(year: 2026, month: 9, day: 6))
        #expect(window.durationSeconds == 23 * Self.hour)
        #expect(santiago.day(containing: window.start) == LocalDay(year: 2026, month: 9, day: 6))
    }

    @Test func `consecutive day windows tile with no gap or overlap`() {
        let days = Self.newYork.days(endingWith: Instant.utc("2026-11-05T12:00:00Z"), count: 10)
        let windows = days.map(Self.newYork.window(for:))
        for (earlier, later) in zip(windows, windows.dropFirst()) {
            #expect(earlier.end == later.start)
        }
    }

    @Test func `EC-T2 a time zone change moves the bucket, not the timestamp`() {
        let instant = Instant.utc("2026-10-31T20:00:00Z")
        let utc = LocalCalendar(timeZone: TimeZone(identifier: "UTC")!, firstWeekday: .sunday)
        let kolkata = LocalCalendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!, firstWeekday: .sunday)

        #expect(utc.day(containing: instant) == LocalDay(year: 2026, month: 10, day: 31))
        #expect(kolkata.day(containing: instant) == LocalDay(year: 2026, month: 11, day: 1))
        #expect(instant == Instant.utc("2026-10-31T20:00:00Z"))
    }

    @Test func `EC-T4 the week starts on the configured weekday`() {
        let sunday = Instant.utc("2026-11-01T17:00:00Z")   // Sunday noon in New York
        let zone = TimeZone(identifier: "America/New_York")!
        let sundayFirst = LocalCalendar(timeZone: zone, firstWeekday: .sunday).week(containing: sunday)
        let mondayFirst = LocalCalendar(timeZone: zone, firstWeekday: .monday).week(containing: sunday)

        #expect(Self.newYork.day(containing: sundayFirst.start) == LocalDay(year: 2026, month: 11, day: 1))
        #expect(Self.newYork.day(containing: mondayFirst.start) == LocalDay(year: 2026, month: 10, day: 26))
        #expect(sundayFirst.contains(sunday) && mondayFirst.contains(sunday))
    }

    @Test func `the ledger range is the last ten days, oldest first, across a DST change`() {
        let days = Self.newYork.days(endingWith: Instant.utc("2026-11-05T12:00:00Z"), count: 10)
        #expect(days.count == 10)
        #expect(days.first == LocalDay(year: 2026, month: 10, day: 27))
        #expect(days.last == LocalDay(year: 2026, month: 11, day: 5))
        #expect(days == days.sorted() && Set(days).count == 10)
    }

    /// Samoa crossed the date line at the end of 29 December 2011 and never had
    /// a 30 December.
    static let apia = LocalCalendar(timeZone: TimeZone(identifier: "Pacific/Apia")!, firstWeekday: .friday)

    @Test func `EC-T1 a skipped date has an empty window and does not alias the next day`() {
        let skipped = Self.apia.window(for: LocalDay(year: 2011, month: 12, day: 30))
        let next = Self.apia.window(for: LocalDay(year: 2011, month: 12, day: 31))
        #expect(skipped.durationSeconds == 0)
        #expect(next.durationSeconds == 24 * Self.hour)
        #expect(skipped != next)
    }

    @Test func `EC-T4 a week around a skipped date still contains its instant`() {
        // Saturday 31 December 2011 in Apia; the week should start on the
        // Friday, which did not exist, so it starts on the Saturday instead.
        let instant = Timestamp(epochSeconds: 1_325_282_400)
        let week = Self.apia.week(containing: instant)
        #expect(week.contains(instant))
        #expect(Self.apia.day(containing: week.start) == LocalDay(year: 2011, month: 12, day: 31))
        #expect(week.durationSeconds == 6 * 24 * Self.hour)
    }

    @Test func `the ledger range never lists a skipped date`() {
        let days = Self.apia.days(endingWith: Timestamp(epochSeconds: 1_325_282_400), count: 3)
        #expect(days == [LocalDay(year: 2011, month: 12, day: 28),
                         LocalDay(year: 2011, month: 12, day: 29),
                         LocalDay(year: 2011, month: 12, day: 31)])
    }

    @Test(arguments: Weekday.allCases)
    func `EC-T4 an ordinary week is seven days and contains its instant`(first: Weekday) {
        let calendar = LocalCalendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!, firstWeekday: first)
        let instant = Instant.utc("2026-10-28T09:00:00Z")
        let week = calendar.week(containing: instant)
        #expect(week.contains(instant))
        #expect(week.durationSeconds == 7 * 24 * Self.hour)
        #expect(calendar.calendar.component(.weekday, from: week.start.date) == first.rawValue)
    }

    @Test func `an empty range is empty`() {
        #expect(Self.newYork.days(endingWith: Instant.utc("2026-11-05T12:00:00Z"), count: 0).isEmpty)
    }
}

struct TimestampTests {
    @Test(arguments: [(1_999, 1), (1_000, 1), (0, 0), (-1, -1), (-1_000, -1), (-1_001, -2)]
          as [(Int64, Int64)])
    func `milliseconds floor to the containing second`(milliseconds: Int64, seconds: Int64) {
        #expect(Timestamp(epochMilliseconds: milliseconds).epochSeconds == seconds)
    }

    @Test func `a date with a fraction floors rather than rounds`() {
        #expect(Timestamp(Date(timeIntervalSince1970: 10.9))?.epochSeconds == 10)
        #expect(Timestamp(Date(timeIntervalSince1970: -0.5))?.epochSeconds == -1)
    }

    @Test func `a date beyond whole epoch seconds is refused rather than trapping`() {
        #expect(Timestamp(Date(timeIntervalSince1970: 9_223_372_036_854_775_808)) == nil)
        #expect(Timestamp(Timestamp(epochSeconds: .max).date) == nil)
        #expect(Timestamp(Date(timeIntervalSince1970: .nan)) == nil)
    }

    @Test func `windows include their start and exclude their end`() {
        let window = TimeWindow(start: Timestamp(epochSeconds: 100), end: Timestamp(epochSeconds: 200))
        #expect(window.contains(Timestamp(epochSeconds: 100)))
        #expect(window.contains(Timestamp(epochSeconds: 199)))
        #expect(!window.contains(Timestamp(epochSeconds: 200)))
    }

    @Test func `EC-T3 a timestamp from the future is kept, clamped for placement, and flagged`() {
        let now = Timestamp(epochSeconds: 1_000_000)
        let ahead = now.adding(seconds: 3_600)
        let checked = CheckedTimestamp(ahead, now: now)

        #expect(checked.recorded == ahead)
        #expect(checked.effective == now)
        #expect(checked.isFromFuture)
    }

    @Test func `EC-T3 ordinary drift and past timestamps pass through untouched`() {
        let now = Timestamp(epochSeconds: 1_000_000)
        for instant in [now.adding(seconds: CheckedTimestamp.futureTolerance), now, now.adding(seconds: -86_400)] {
            let checked = CheckedTimestamp(instant, now: now)
            #expect(checked.effective == instant && !checked.isFromFuture)
        }
    }

    @Test func `EC-T3 a corrupt far-future timestamp is flagged without overflowing`() {
        let checked = CheckedTimestamp(Timestamp(epochSeconds: .max), now: Timestamp(epochSeconds: -1))
        #expect(checked.isFromFuture)
        #expect(checked.effective == Timestamp(epochSeconds: -1))
        #expect(checked.recorded == Timestamp(epochSeconds: .max))
    }

    @Test func `a manual clock moves only when told`() {
        let clock = ManualClock(Timestamp(epochSeconds: 50))
        #expect(clock.now == Timestamp(epochSeconds: 50))
        clock.advance(seconds: 10)
        #expect(clock.now == Timestamp(epochSeconds: 60))
        clock.set(Timestamp(epochSeconds: 5))
        #expect(clock.now == Timestamp(epochSeconds: 5))
    }
}
