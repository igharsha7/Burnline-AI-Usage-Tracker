//
//  BucketTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import Testing

/// Chart buckets and range presets, on calendars that make them hard.
struct BucketTests {
    static let newYork = LocalCalendarTests.newYork
    static let india = LocalCalendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!, firstWeekday: .monday)
    static let hour: Int64 = 3_600

    @Test func `EC-T1 a range across spring-forward has one bucket per local day`() {
        let range = TimeWindow(start: Instant.utc("2026-03-06T05:00:00Z"), end: Instant.utc("2026-03-10T04:00:00Z"))
        let days = Self.newYork.buckets(.day, covering: range)
        #expect(days.map(\.durationSeconds) == [24, 24, 23, 24].map { $0 * Self.hour })
        #expect(days.first?.start == range.start && days.last?.end == range.end)
    }

    @Test func `EC-T1 the fall-back day has 25 hour buckets, the repeated hour among them`() {
        let day = Self.newYork.window(for: LocalDay(year: 2026, month: 11, day: 1))
        let hours = Self.newYork.buckets(.hour, covering: day)
        #expect(hours.count == 25)
        #expect(hours.allSatisfy { $0.durationSeconds == Self.hour })
    }

    @Test(arguments: [LocalDay(year: 2026, month: 4, day: 5), LocalDay(year: 2026, month: 10, day: 4)])
    func `EC-T1 hour buckets tile a half-hour DST transition`(date: LocalDay) {
        let calendar = LocalCalendar(timeZone: TimeZone(identifier: "Australia/Lord_Howe")!, firstWeekday: .monday)
        let day = calendar.window(for: date)
        let hours = calendar.buckets(.hour, covering: day)
        #expect(hours.first?.start == day.start && hours.last?.end == day.end)
        #expect(zip(hours, hours.dropFirst()).allSatisfy { $0.end == $1.start })
        #expect(hours.map(\.durationSeconds).reduce(0, +) == day.durationSeconds)
    }

    @Test(arguments: ["Australia/Lord_Howe", "Pacific/Chatham", "America/New_York",
                      "Europe/Dublin", "Africa/Casablanca", "America/Havana"])
    func `EC-T1 transition buckets contain their instant and always advance`(zone: String) throws {
        let calendar = LocalCalendar(timeZone: TimeZone(identifier: zone)!, firstWeekday: .monday)
        var cursor = Instant.utc("2025-01-01T00:00:00Z")
        let end = Instant.utc("2027-01-01T00:00:00Z")
        for _ in 0..<8 {
            guard let date = calendar.calendar.timeZone.nextDaylightSavingTimeTransition(after: cursor.date),
                  let transition = Timestamp(date), transition < end else { break }
            for offset: Int64 in [-3_601, -3_600, -1_801, -1_800, -1, 0, 1, 1_799, 1_800, 3_599, 3_600] {
                let instant = transition.adding(seconds: offset)
                let bucket = calendar.bucket(.hour, containing: instant)
                #expect(bucket.contains(instant), "\(zone) \(instant)")
                let next = calendar.bucket(.hour, containing: bucket.end)
                #expect(next.start == bucket.end && next.end > bucket.end)
            }
            let range = TimeWindow(start: transition.adding(seconds: -2 * 86_400),
                                   end: transition.adding(seconds: 2 * 86_400))
            for width in [BucketWidth.hour, .day, .week, .month] {
                var bucket = calendar.bucket(width, containing: range.start)
                var count = 0
                while bucket.end < range.end && count < 200 {
                    #expect(bucket.start.epochSeconds % 900 == 0 && bucket.end.epochSeconds % 900 == 0)
                    let next = calendar.bucket(width, containing: bucket.end)
                    try #require(next.start == bucket.end && next.end > bucket.end, "\(zone) \(width)")
                    bucket = next
                    count += 1
                }
                try #require(bucket.end >= range.end)
                let buckets = calendar.buckets(width, covering: range)
                #expect(zip(buckets, buckets.dropFirst()).allSatisfy { $0.end == $1.start })
            }
            cursor = transition.adding(seconds: 1)
        }
    }

    @Test func `EC-T1 an Indian hour starts at half past the UTC hour`() {
        let bucket = Self.india.bucket(.hour, containing: Instant.utc("2026-11-01T10:10:00Z"))
        #expect(bucket.start == Instant.utc("2026-11-01T09:30:00Z"))
        // Quarter hours divide India's offset, so they are plain epoch arithmetic.
        #expect(Self.india.bucket(.quarterHour, containing: Instant.utc("2026-11-01T10:10:00Z")).start
                == Instant.utc("2026-11-01T10:00:00Z"))
    }

    @Test func `buckets tile their range with no gap or overlap`() {
        let range = TimeWindow(start: Instant.utc("2025-12-20T00:00:00Z"), end: Instant.utc("2026-03-15T00:00:00Z"))
        for width in BucketWidth.allCases {
            let buckets = Self.newYork.buckets(width, covering: range)
            #expect(zip(buckets, buckets.dropFirst()).allSatisfy { $0.end == $1.start }, "\(width)")
            #expect(buckets.first!.start <= range.start && buckets.last!.end >= range.end, "\(width)")
        }
    }

    @Test func `EC-T2 buckets skip a date removed by a zone change`() {
        let calendar = LocalCalendar(timeZone: TimeZone(identifier: "Pacific/Apia")!, firstWeekday: .monday)
        let range = TimeWindow(start: Instant.utc("2011-12-28T10:00:00Z"), end: Instant.utc("2012-01-02T10:00:00Z"))
        for width in [BucketWidth.day, .week, .month] {
            let buckets = calendar.buckets(width, covering: range)
            #expect(buckets.allSatisfy { $0.start < $0.end })
            #expect(zip(buckets, buckets.dropFirst()).allSatisfy { $0.end == $1.start })
            #expect(buckets.first!.start <= range.start && buckets.last!.end >= range.end)
        }
    }

    @Test func `months follow the calendar, February included`() {
        let year = TimeWindow(start: Self.india.window(for: LocalDay(year: 2028, month: 1, day: 1)).start,
                              end: Self.india.window(for: LocalDay(year: 2029, month: 1, day: 1)).start)
        let months = Self.india.buckets(.month, covering: year)
        #expect(months.count == 12)
        #expect(months[1].durationSeconds == 29 * 86_400)
    }

    @Test func `EC-T4 week buckets start on the configured weekday`() {
        let range = TimeWindow(start: Instant.utc("2026-10-01T00:00:00Z"), end: Instant.utc("2026-11-01T00:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let weeks = Self.india.buckets(.week, covering: range)
        #expect(weeks.count == 5)   // Monday 28 September to Monday 2 November
        // 2 is Monday.
        #expect(weeks.allSatisfy { calendar.component(.weekday, from: $0.start.date) == 2 })
    }

    static let widths: [(Int64, BucketWidth)] = [
        (1, .minute), (6, .minute), (7, .hour), (48, .hour), (49, .day),
        (90 * 24, .day), (91 * 24, .week), (731 * 24, .week), (732 * 24, .month)]

    @Test(arguments: widths)
    func `a range gets a width that keeps its chart readable`(hours: Int64, width: BucketWidth) {
        let start = Timestamp(epochSeconds: 0)
        #expect(BucketWidth.automatic(for: TimeWindow(start: start, end: start.adding(seconds: hours * Self.hour)))
                == width)
    }

    static let now = Instant.utc("2026-11-01T08:00:00Z")   // 13:30 in India

    static let presetDays: [(RangePreset, Int64)] = [
        (.today, 1), (.last7Days, 7), (.last30Days, 30), (.last90Days, 90), (.lastYear, 365)]

    @Test(arguments: presetDays)
    func `a preset covers whole local days ending today`(preset: RangePreset, days: Int64) {
        let window = Self.india.window(for: preset, now: Self.now, earliest: nil)
        #expect(window.end == Instant.utc("2026-11-01T18:30:00Z"))
        #expect(window.durationSeconds == days * 86_400)
    }

    @Test func `year to date starts on the first of January, and all starts on the earliest day`() {
        #expect(Self.india.window(for: .yearToDate, now: Self.now, earliest: nil).start
                == Instant.utc("2025-12-31T18:30:00Z"))
        let all = Self.india.window(for: .all, now: Self.now, earliest: Instant.utc("2024-02-10T20:00:00Z"))
        #expect(all.start == Instant.utc("2024-02-10T18:30:00Z"))
        // With no history, all is today.
        #expect(Self.india.window(for: .all, now: Self.now, earliest: nil)
                == Self.india.window(for: .today, now: Self.now, earliest: nil))
    }

    @Test func `EC-T1 the day before a short DST day is the whole calendar day`() {
        // 8 March 2026 in New York lasts 23 hours; the day before it is all
        // of 7 March, 24 hours, not the 23 hours before midnight.
        let day = Self.newYork.window(for: LocalDay(year: 2026, month: 3, day: 8))
        let previous = Self.newYork.previous(day)
        #expect(day.durationSeconds == 23 * Self.hour)
        #expect(previous == Self.newYork.window(for: LocalDay(year: 2026, month: 3, day: 7)))
    }

    @Test func `a window of part days steps back its own length, up to the same point in it`() {
        // 06:00 to 18:00 UTC, compared as far as 10:00.
        let window = TimeWindow(start: Instant.utc("2026-11-01T06:00:00Z"), end: Instant.utc("2026-11-01T18:00:00Z"))
        let previous = Self.india.previous(window, through: Instant.utc("2026-11-01T10:00:00Z"))
        #expect(previous == TimeWindow(start: Instant.utc("2026-10-31T18:00:00Z"),
                                       end: Instant.utc("2026-10-31T22:00:00Z")))
    }

    @Test func `the previous period is the same length, just before`() {
        let window = Self.india.window(for: .last7Days, now: Self.now, earliest: nil)
        let previous = Self.india.previous(window)
        #expect(previous.end == window.start && previous.durationSeconds == window.durationSeconds)
    }
}
