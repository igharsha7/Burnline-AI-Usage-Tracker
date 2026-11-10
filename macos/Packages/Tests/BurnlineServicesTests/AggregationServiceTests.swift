//
//  AggregationServiceTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineServices
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import Testing

/// The single entry point the dashboard reads: presets resolved on the
/// user's calendar, a sensible width, and the right source for it.
struct AggregationServiceTests {
    /// 1 November 2026, 13:30 in India; 40,000 seconds earlier is still today.
    static let now = Timestamp(epochSeconds: 1_793_520_000)
    static let india = LocalCalendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!, firstWeekday: .monday)

    /// Events at the given offsets before `now`, in seconds, one session per day.
    static func service(eventsSecondsAgo offsets: [Int64]) throws -> (AggregationService, BurnlineDatabase) {
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: TestDirectory.make("Aggregation")),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")),
            clock: ManualClock(Self.now))
        let records = try offsets.enumerated().map { index, ago in
            IncomingUsage(sourceEventID: "e\(index)", sessionSourceID: "s\(ago / 86_400)", project: nil,
                          rawModel: "claude-opus-5", timestamp: Self.now.adding(seconds: -ago),
                          tokens: try TokenCounts(output: 10), sourceType: "test", file: "/a.jsonl",
                          schemaVersion: nil, offset: 0)
        }
        try database.ingest(records, issues: [], provider: .claudeCode)
        return (AggregationService(database: database, calendar: Self.india, clock: ManualClock(Self.now)), database)
    }

    static let offsets: [Int64] = [60, 120, 3_000, 40_000, 86_400 * 3, 86_400 * 3 + 50, 86_400 * 20, 86_400 * 400]

    @Test func `a preset gets its width, and its buckets cover it`() throws {
        let (service, _) = try Self.service(eventsSecondsAgo: Self.offsets)
        let today = try service.aggregate(.today, grouping: .total)
        #expect(today.width == .hour && today.buckets.count == 24)
        let week = try service.aggregate(.last7Days, grouping: .total)
        #expect(week.width == .day && week.buckets.count == 7)
        #expect(try service.aggregate(.lastYear, grouping: .total).width == .week)
        #expect(try service.aggregate(.all, grouping: .total).width == .week)
        #expect(week.buckets.map(\.total.events) == [0, 0, 0, 2, 0, 0, 4])
    }

    @Test func `series total the same as the plain totals of their range`() throws {
        let (service, database) = try Self.service(eventsSecondsAgo: Self.offsets)
        for preset in [RangePreset.today, .last7Days, .last30Days, .yearToDate, .all] {
            let series = try service.aggregate(preset, grouping: .provider)
            let sum = try series.buckets.reduce(UsageTotals.zero) { try $0.adding($1.total) }
            #expect(sum == (try database.usage.totals(in: try service.window(for: preset))), "\(preset)")
            #expect(series.buckets.allSatisfy { $0.groups.values.map(\.events).reduce(0, +) == $0.total.events })
        }
    }

    @Test func `minute buckets read events, and fall back to quarter hours once compacted`() throws {
        let (service, database) = try Self.service(eventsSecondsAgo: Self.offsets)
        let lastHour = RangePreset.custom(TimeWindow(start: Self.now.adding(seconds: -3_600), end: Self.now))
        let minutes = try service.aggregate(lastHour, grouping: .total)
        #expect(minutes.width == .minute && minutes.buckets.count == 60)
        #expect(minutes.buckets.map(\.total.events).reduce(0, +) == 3)

        try database.compact(before: Self.now)
        let compacted = try service.aggregate(lastHour, grouping: .total)
        #expect(compacted.width == .quarterHour && compacted.buckets.count == 4)
        #expect(compacted.buckets.map(\.total.events).reduce(0, +) == 3)
    }

    @Test func `EC-U1 custom summary counts active days only inside its range`() throws {
        let (service, _) = try Self.service(eventsSecondsAgo: [60, 86_400])
        let range = RangePreset.custom(TimeWindow(start: Self.now.adding(seconds: -86_300),
                                                 end: Self.now.adding(seconds: -900)))
        let summary = try service.summary(range)
        #expect(summary.totals.events == 0)
        #expect(summary.activeDays == 0)
    }

    @Test func `EC-U1 series excludes usage outside the preset in partial weeks`() throws {
        let (service, _) = try Self.service(eventsSecondsAgo: [365 * 86_400, 364 * 86_400, 60])
        let summary = try service.summary(.lastYear)
        #expect(summary.totals.events == 2)
        for width in [BucketWidth.week, .month] {
            let series = try service.aggregate(.lastYear, width: width, grouping: .provider)
            let total = try series.buckets.reduce(UsageTotals.zero) { try $0.adding($1.total) }
            #expect(total == summary.totals, "\(width)")
        }
    }

    @Test func `EC-U1 minute summary and series honor exact custom edges`() throws {
        let (service, _) = try Self.service(eventsSecondsAgo: [120, 90, 60])
        let range = RangePreset.custom(TimeWindow(start: Self.now.adding(seconds: -115),
                                                 end: Self.now.adding(seconds: -65)))
        let summary = try service.summary(range)
        let series = try service.aggregate(range, grouping: .total)
        #expect(summary.totals.events == 1)
        #expect(summary.activeDays == 1)
        #expect(series.buckets.map(\.total.events).reduce(0, +) == 1)
        let breakdown = try service.breakdown(range, by: .provider)
        #expect(breakdown.map(\.totals.events).reduce(0, +) == 1)
    }

    @Test func `EC-D10 minute source selection agrees at and across compaction`() throws {
        let (service, database) = try Self.service(eventsSecondsAgo: [901, 900, 899, 60])
        let boundary = Self.now.adding(seconds: -900)
        try database.compact(before: boundary)
        for start in [boundary, boundary.adding(seconds: -900)] {
            let range = RangePreset.custom(TimeWindow(start: start, end: Self.now))
            let series = try service.aggregate(range, grouping: .provider)
            #expect(series.width == (start == boundary ? .minute : .quarterHour))
            let total = try series.buckets.reduce(UsageTotals.zero) { try $0.adding($1.total) }
            #expect(total.events == (start == boundary ? 3 : 4))
            #expect(total == (try service.summary(range)).totals)
            #expect(try service.breakdown(range, by: .provider).map(\.totals.events).reduce(0, +) == total.events)
        }
    }

    @Test func `EC-U6 all without history uses the injected calendar and clock`() throws {
        let (service, _) = try Self.service(eventsSecondsAgo: [])
        let today = Self.india.window(for: .today, now: Self.now, earliest: nil)
        #expect(try service.window(for: .all) == today)
        let series = try service.aggregate(.all, grouping: .provider)
        #expect(series.buckets.count == 24 && series.buckets.allSatisfy { $0.total == .zero })
        let summary = try service.summary(.all)
        #expect(summary.totals == .zero && summary.activeDays == 0 && summary.sessions == 0)
    }

    @Test func `the previous period ends at the same point in its span`() throws {
        let (service, _) = try Self.service(eventsSecondsAgo: Self.offsets)
        let today = try service.window(for: .today)
        // Today until now against yesterday until this time, not all of yesterday.
        #expect(try service.previous(.today) == .custom(TimeWindow(start: today.start.adding(seconds: -86_400),
                                                                   end: Self.now.adding(seconds: -86_400))))
        let week = try service.window(for: .last7Days)
        #expect(try service.previous(.last7Days) == .custom(TimeWindow(start: week.start.adding(seconds: -7 * 86_400),
                                                                       end: Self.now.adding(seconds: -7 * 86_400))))
        // A finished range compares whole with whole.
        let past = TimeWindow(start: today.start.adding(seconds: -2 * 86_400), end: today.start.adding(seconds: -86_400))
        #expect(try service.previous(.custom(past)) == .custom(Self.india.previous(past)))
        #expect(try service.previous(.all) == nil)
    }

    /// Events by when they happened and which model, in a fresh store whose clock reads `now`.
    static func service(at now: Timestamp, events: [(at: Timestamp, model: String, session: String)])
        throws -> AggregationService {
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: TestDirectory.make("Aggregation edges")),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")),
            clock: ManualClock(now))
        let records = try events.enumerated().map { index, event in
            IncomingUsage(sourceEventID: "e\(index)", sessionSourceID: event.session, project: nil,
                          rawModel: event.model, timestamp: event.at, tokens: try TokenCounts(output: 100),
                          sourceType: "test", file: "/a.jsonl", schemaVersion: nil, offset: 0)
        }
        try database.ingest(records, issues: [], provider: .claudeCode)
        return AggregationService(database: database, calendar: Self.india, clock: ManualClock(now))
    }

    @Test func `EC-T1 the day before a daylight-saving change compares at the same clock time`() {
        // 1 November 2026 in New York lasts 25 hours; at noon, yesterday by
        // this time is 31 October from midnight to noon, not from 23:00 on the 30th.
        let york = LocalCalendar(timeZone: TimeZone(identifier: "America/New_York")!, firstWeekday: .sunday)
        let today = york.window(for: LocalDay(year: 2026, month: 11, day: 1))
        #expect(today.durationSeconds == 25 * 3_600)
        let noon = today.start.adding(seconds: 13 * 3_600)
        let yesterday = york.window(for: LocalDay(year: 2026, month: 10, day: 31))
        #expect(york.previous(today, through: noon)
                    == TimeWindow(start: yesterday.start, end: yesterday.start.adding(seconds: 12 * 3_600)))
        // A week across the change steps back seven days, not seven times 24 hours.
        let week = TimeWindow(start: york.window(for: LocalDay(year: 2026, month: 10, day: 26)).start, end: today.end)
        #expect(york.previous(week).start == york.window(for: LocalDay(year: 2026, month: 10, day: 19)).start)
    }

    @Test func `yesterday by this time leaves out usage later in the same quarter hour`() throws {
        // 13:31 in India. Yesterday at 13:30 is before this time; 13:40 is
        // after it, though in the same quarter hour of the rollups.
        let now = Self.now.adding(seconds: 60)
        let service = try Self.service(at: now, events: [
            (now.adding(seconds: -86_400 - 60), "claude-opus-5", "a"),
            (now.adding(seconds: -86_400 + 540), "claude-opus-5", "a"),
        ])
        let previous = try #require(try service.previous(.today))
        #expect(try service.summary(previous).totals.events == 1)
    }

    @Test func `a model filter counts only the sessions that used the model`() throws {
        let service = try Self.service(at: Self.now, events: [
            (Self.now.adding(seconds: -600), "claude-opus-5", "a"),
            (Self.now.adding(seconds: -300), "claude-haiku-5", "b"),
        ])
        let models = try service.breakdown(.today, by: .model)
        let opus = try #require(models.first { $0.name.localizedCaseInsensitiveContains("opus") })
        guard case .model(let id?) = opus.key else { Issue.record("a model row has its id"); return }
        let summary = try service.summary(.today, filters: UsageFilters(models: [id]))
        #expect(summary.totals.events == 1 && summary.sessions == 1)
        #expect(try service.summary(.today).sessions == 2)
    }

    @Test func `EC-U2 tracking starts with the day of the oldest usage`() throws {
        let (service, _) = try Self.service(eventsSecondsAgo: Self.offsets)
        let oldest = Self.now.adding(seconds: -86_400 * 400)
        #expect(try service.trackingStart() == Self.india.window(for: Self.india.day(containing: oldest)).start)
        let (empty, _) = try Self.service(eventsSecondsAgo: [])
        #expect(try empty.trackingStart() == nil)
    }

    @Test func `the ledger range is ten local days ending today`() throws {
        let (service, _) = try Self.service(eventsSecondsAgo: Self.offsets)
        let ledger = try service.aggregate(service.lastDays(10), width: .day, grouping: .provider)
        #expect(ledger.buckets.count == 10)
        #expect(ledger.buckets.last?.window == (try service.window(for: .today)))
        // Days with no usage are rows of zero, not missing.
        #expect(ledger.buckets.map(\.total.events) == [0, 0, 0, 0, 0, 0, 2, 0, 0, 4])
    }

    @Test func `the summary counts sessions and active days`() throws {
        let (service, _) = try Self.service(eventsSecondsAgo: Self.offsets)
        let month = try service.summary(.last30Days)
        #expect(month.totals.events == 7)
        #expect(month.activeDays == 3 && month.sessions == 3)
        #expect(month.totals.costCoverage == 0)
        let breakdown = try service.breakdown(.last30Days, by: .session)
        #expect(breakdown.count == 3)
    }
}
