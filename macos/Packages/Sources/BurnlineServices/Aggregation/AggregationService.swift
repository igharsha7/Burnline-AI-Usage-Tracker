//
//  AggregationService.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import Foundation

/// Everything charts and tables show, from one place. Views never issue SQL:
/// they ask for a range, a bucket width, a grouping and filters, and get sums
/// that carry their own pricing coverage.
///
/// Ranges resolve on the user's calendar, so day and longer buckets follow
/// the local zone across daylight-saving changes. Everything at a
/// quarter hour or coarser reads the rollups, so it covers compacted history
/// too; minute buckets read events.
public struct AggregationService: Sendable {
    let database: BurnlineDatabase
    let calendar: LocalCalendar
    let clock: any WallClock

    public init(database: BurnlineDatabase, calendar: LocalCalendar, clock: any WallClock = SystemClock()) {
        self.database = database
        self.calendar = calendar
        self.clock = clock
    }

    /// The span a preset covers now.
    public func window(for range: RangePreset) throws(StoreError) -> TimeWindow {
        let now = clock.now
        let earliest = range == .all ? try database.aggregation.earliest() : nil
        return calendar.window(for: range, now: now, earliest: earliest)
    }

    /// The start of the local day tracking began: the day of the oldest
    /// usage, compacted history included. Earlier days are untracked, not
    /// zero. Nil before anything is tracked.
    public func trackingStart() throws(StoreError) -> Timestamp? {
        try database.aggregation.earliest().map { calendar.window(for: calendar.day(containing: $0)).start }
    }

    /// The last `count` local days, today included, as for the day ledger.
    public func lastDays(_ count: Int) -> RangePreset {
        let days = calendar.days(endingWith: clock.now, count: count)
        return .custom(TimeWindow(start: calendar.window(for: days[0]).start,
                                  end: calendar.window(for: days[days.count - 1]).end))
    }

    /// The previous period up to the same point in it: for a range still
    /// running, today until now against yesterday until this time, never
    /// against all of yesterday. Nil for all time, which has nothing before it.
    public func previous(_ range: RangePreset) throws(StoreError) -> RangePreset? {
        if range == .all { return nil }
        let window = try window(for: range)
        return .custom(calendar.previous(window, through: min(window.end, max(window.start, clock.now))))
    }

    /// A chart's series: every bucket of the range, empty ones included, with
    /// totals per group. `width` nil picks one for the range's length. A
    /// first or last bucket reaching outside the range counts only its part
    /// inside, so the series always sums to the range's summary.
    public func aggregate(_ range: RangePreset, width: BucketWidth? = nil, grouping: Grouping,
                          filters: UsageFilters = .none) throws(StoreError) -> UsageSeries {
        let window = try window(for: range)
        let width = try resolvedWidth(for: window, requested: width)
        let buckets = calendar.buckets(width, covering: window)
        let queryWindows = buckets.map {
            TimeWindow(start: max($0.start, window.start), end: min($0.end, window.end))
        }
        let values = try series(queryWindows, grouping: grouping, filters: filters,
                                                     from: width == .minute ? .events : .rollups)
        var series: [SeriesBucket] = []
        for (window, groups) in zip(buckets, values) {
            series.append(SeriesBucket(window: window, total: try Self.sum(groups.values),
                                       groups: grouping == .total ? [:] : groups))
        }
        return UsageSeries(width: width, grouping: grouping, buckets: series)
    }

    /// The headline figures for a range.
    public func summary(_ range: RangePreset, filters: UsageFilters = .none) throws(StoreError) -> UsageSummary {
        let window = try window(for: range)
        let source: AggregationRepository.Source = try resolvedWidth(for: window) == .minute ? .events : .rollups
        let total = try series([window], grouping: .total, filters: filters, from: source)
        let dayWindows = calendar.buckets(.day, covering: window).map {
            TimeWindow(start: max($0.start, window.start), end: min($0.end, window.end))
        }
        let days = try series(dayWindows, grouping: .total, filters: filters, from: source)
        return UsageSummary(window: window, totals: total[0][.total] ?? .zero,
                            sessions: try database.aggregation.sessions(in: window, filters: filters),
                            activeDays: days.count { !$0.isEmpty })
    }

    /// The cost of each `span`-second stretch of `window` that held usage.
    public func busySpanCosts(in window: TimeWindow, span: Int64) throws(StoreError) -> [Int64] {
        try database.aggregation.busySpanCosts(in: window, span: span)
    }

    /// Sessions active in a range, without the rest of a summary.
    public func sessions(_ range: RangePreset, filters: UsageFilters = .none) throws(StoreError) -> Int {
        try database.aggregation.sessions(in: try window(for: range), filters: filters)
    }

    /// The breakdown table's rows for a range, largest cost first. Sessions
    /// are listed only within the detail window.
    public func breakdown(_ range: RangePreset, by key: BreakdownKey,
                          filters: UsageFilters = .none) throws(StoreError) -> [BreakdownRow] {
        let window = try window(for: range)
        let source: AggregationRepository.Source = try resolvedWidth(for: window) == .minute ? .events : .rollups
        return try database.aggregation.breakdown(window, by: key, filters: filters, from: source)
    }

    /// Totals per window and group. Rollups hold whole quarter hours and
    /// would round an end that falls inside one up to the quarter's end,
    /// counting usage after it. So a window read from rollups takes its whole
    /// quarters from them and any part-quarter at an edge from events, exact
    /// to the second. An edge in compacted history, whose events are gone, is
    /// left out rather than overcounted.
    private func series(_ windows: [TimeWindow], grouping: Grouping, filters: UsageFilters,
                        from source: AggregationRepository.Source) throws(StoreError) -> [[GroupKey: UsageTotals]] {
        guard source == .rollups, filters.sessions.isEmpty else {
            return try database.aggregation.series(windows, grouping: grouping, filters: filters, from: source)
        }
        let quarter = BurnlineDatabase.bucketSeconds
        func down(_ instant: Timestamp) -> Timestamp {
            instant.adding(seconds: -(((instant.epochSeconds % quarter) + quarter) % quarter))
        }
        func up(_ instant: Timestamp) -> Timestamp {
            let floor = down(instant)
            return floor == instant ? instant : floor.adding(seconds: quarter)
        }
        let compacted = try database.compactedBefore()

        var whole: [TimeWindow] = []
        var edges: [(index: Int, window: TimeWindow)] = []
        for (index, window) in windows.enumerated() {
            let first = up(window.start), last = down(window.end)
            if first < last {
                whole.append(TimeWindow(start: first, end: last))
                if window.start < first { edges.append((index, TimeWindow(start: window.start, end: first))) }
                if last < window.end { edges.append((index, TimeWindow(start: last, end: window.end))) }
            } else {
                // Within one quarter: nothing whole to read from the rollups.
                whole.append(TimeWindow(start: window.start, end: window.start))
                if window.start < window.end { edges.append((index, window)) }
            }
        }
        edges.removeAll { $0.window.start < compacted }

        var result = try database.aggregation.series(whole, grouping: grouping, filters: filters, from: .rollups)
        guard !edges.isEmpty else { return result }
        let parts = try database.aggregation.series(edges.map(\.window), grouping: grouping, filters: filters,
                                                    from: .events)
        for (edge, groups) in zip(edges, parts) {
            for (key, totals) in groups {
                result[edge.index][key] = try Self.sum([result[edge.index][key] ?? .zero, totals])
            }
        }
        return result
    }

    private func resolvedWidth(for window: TimeWindow, requested: BucketWidth? = nil) throws(StoreError) -> BucketWidth {
        let width = requested ?? .automatic(for: window)
        // Minutes need events, which compacted history no longer has.
        if width == .minute, window.start < (try database.compactedBefore()) { return .quarterHour }
        return width
    }

    private static func sum(_ totals: some Sequence<UsageTotals>) throws(StoreError) -> UsageTotals {
        do { return try totals.reduce(UsageTotals.zero) { try $0.adding($1) } }
        catch { throw .sqlite("a total overflowed: \(error)") }
    }
}
