//
//  DashboardRows.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// One bucket of the chart or a time-shaped table, and whether it was
/// tracked: a day before tracking began is not a day of zero.
nonisolated struct DashboardBucket: Identifiable, Sendable {
    let window: TimeWindow
    let tracked: Bool
    let total: UsageTotals
    let providers: [ProviderKey: UsageTotals]

    var id: Int64 { window.start.epochSeconds }
}

extension UsageSeries {
    /// The buckets up to now, oldest first. Later ones have not happened, so
    /// they are left out rather than drawn as zero.
    nonisolated func dashboardBuckets(trackingStart: Timestamp?, now: Timestamp) -> [DashboardBucket] {
        buckets.filter { $0.window.start <= now }.map { bucket in
            var providers: [ProviderKey: UsageTotals] = [:]
            for case (.provider(let provider), let totals) in bucket.groups { providers[provider] = totals }
            return DashboardBucket(window: bucket.window,
                                   tracked: trackingStart.map { bucket.window.end > $0 } ?? false,
                                   total: bucket.total, providers: providers)
        }
    }
}

/// A row of the breakdown table, in either shape. Values are kept apart from
/// their text so every numeric column sorts by number.
struct BreakdownLine: Identifiable {
    enum Drill: Hashable {
        case model(id: Int64, name: String)
        case project(Int64)
        case session(Int64)
        case window(TimeWindow)
    }

    let id: String
    let name: String
    /// A model's provider, for its mark and underline colour.
    let provider: ProviderKey?
    /// By column id: what the column sorts by, and what it shows.
    let values: [String: Double]
    let texts: [String: String]
    /// The row's share of the whole; nil for a row that is not a model.
    let share: Double?
    /// The row's figure against the largest row's, from 0 to 1, drawn as a
    /// bar behind the row so magnitudes read at a glance.
    let magnitude: Double
    /// A ranked row, which names a model and its provider.
    let ranked: Bool
    let tracked: Bool
    let drill: Drill?
    /// The natural order, before any sort the user picks.
    let order: Int
    /// A ranked row's own figures, shown when it is opened.
    var detail: Detail?

    struct Detail {
        let totals: UsageTotals
        let lastUsed: String?
    }
}

/// A breakdown column. The first is the name; the rest are numbers.
struct BreakdownColumn: Identifiable, Hashable {
    let id: String
    let title: String
}

enum BreakdownShape {
    typealias Table = (columns: [BreakdownColumn], lines: [BreakdownLine])

    /// Model / Cost / Share / Tokens, or the same for projects and
    /// sessions: ranked rows, each drilling into what it names. A session is
    /// named for its project and when it started.
    static func ranked(_ rows: [BreakdownRow], by key: BreakdownKey, metric: Metric, sessions: [Int64: Session] = [:],
                       calendar: LocalCalendar = .init(timeZone: .current, firstWeekday: .monday),
                       now: Timestamp = .init(epochSeconds: 0)) -> (columns: [BreakdownColumn], lines: [BreakdownLine]) {
        // Only models count toward the whole a share is of.
        let whole = rows.filter(\.isModel).reduce(0) { $0 + metric.value($1.totals) }
        let other: Metric = metric == .cost ? .tokens : .cost
        let columns = [BreakdownColumn(id: "name", title: Self.title(key)),
                       BreakdownColumn(id: "metric", title: metric == .cost ? "Cost" : "Tokens"),
                       BreakdownColumn(id: "share", title: "Share"),
                       BreakdownColumn(id: "other", title: other == .cost ? "Cost" : "Tokens")]
        let ranked = rows.sorted { metric.value($0.totals) > metric.value($1.totals) }
        let largest = ranked.first.map { metric.value($0.totals) } ?? 0
        let lines = ranked.enumerated().map { index, row in
            let share: Double? = row.isModel ? (whole > 0 ? metric.value(row.totals) / whole : 0) : nil
            let drill: BreakdownLine.Drill? = switch row.key {
            case .model(let id?): .model(id: id, name: row.name)
            case .project(let id?): .project(id)
            case .session(let id): .session(id)
            default: nil
            }
            var name = row.name
            if case .session(let id) = row.key, let started = sessions[id]?.startedAt {
                name += " · " + BucketLabel.moment(started, calendar: calendar, now: now)
            }
            return BreakdownLine(
                id: "\(row.key)", name: name, provider: row.provider,
                values: ["metric": metric.value(row.totals), "share": share ?? -1, "other": other.value(row.totals)],
                texts: ["metric": metric.text(row.totals), "share": share.map(Format.share) ?? "—",
                        "other": other.text(row.totals)],
                share: share, magnitude: largest > 0 ? metric.value(row.totals) / largest : 0,
                ranked: true, tracked: true, drill: drill, order: index,
                detail: .init(totals: row.totals,
                              lastUsed: row.lastUsed.map { BucketLabel.moment($0, calendar: calendar, now: now) }))
        }
        return (columns, lines)
    }

    static func title(_ key: BreakdownKey) -> String {
        switch key {
        case .provider: "Provider"
        case .model: "Model"
        case .project: "Project"
        case .session: "Session"
        }
    }

    /// Bucket / one column per provider / Total / the other metric, newest
    /// first: providers become the columns. The day ledger is this shape over
    /// ten days.
    static func buckets(_ buckets: [DashboardBucket], width: BucketWidth, providers: [ProviderKey], metric: Metric,
                        calendar: LocalCalendar, now: Timestamp) -> (columns: [BreakdownColumn], lines: [BreakdownLine]) {
        let other: Metric = metric == .cost ? .tokens : .cost
        let columns = [BreakdownColumn(id: "name", title: BucketLabel.noun(width))]
            + providers.map { BreakdownColumn(id: $0.rawValue, title: $0.displayName) }
            + [BreakdownColumn(id: "metric", title: "Total"),
               BreakdownColumn(id: "other", title: other == .cost ? "Cost" : "Tokens")]
        let largest = buckets.map { metric.value($0.total) }.max() ?? 0
        let lines = buckets.reversed().enumerated().map { index, bucket in
            var values: [String: Double] = ["metric": metric.value(bucket.total), "other": other.value(bucket.total)]
            var texts: [String: String] = [:]
            for provider in providers {
                let totals = bucket.providers[provider] ?? .zero
                values[provider.rawValue] = metric.value(totals)
                texts[provider.rawValue] = Self.text(totals, metric, tracked: bucket.tracked)
            }
            texts["metric"] = Self.text(bucket.total, metric, tracked: bucket.tracked)
            texts["other"] = Self.text(bucket.total, other, tracked: bucket.tracked)
            return BreakdownLine(
                id: "\(bucket.id)", name: BucketLabel.row(bucket.window, width: width, calendar: calendar, now: now),
                provider: nil, values: values, texts: texts, share: nil,
                magnitude: largest > 0 ? metric.value(bucket.total) / largest : 0, ranked: false, tracked: bucket.tracked,
                drill: width >= .day && bucket.tracked ? .window(bucket.window) : nil, order: index)
        }
        return (columns, lines)
    }

    /// A tracked bucket with no usage reads as an explicit zero;
    /// one before tracking began reads as nothing at all.
    private static func text(_ totals: UsageTotals, _ metric: Metric, tracked: Bool) -> String {
        guard tracked else { return "" }
        return metric.text(totals)
    }
}

/// How buckets are named in a table row, a tooltip, and a chart title.
enum BucketLabel {
    static func noun(_ width: BucketWidth) -> String {
        switch width {
        case .minute: "Minute"
        case .quarterHour: "Time"
        case .hour: "Hour"
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    /// Every row and chart point is labelled, so formatters are kept per
    /// template, zone and locale rather than made each time.
    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ template: String, calendar: LocalCalendar, locale: Locale) -> DateFormatter {
        let key = "\(template)|\(calendar.calendar.timeZone.identifier)|\(calendar.calendar.identifier)|\(locale.identifier)"
        if let formatter = formatters[key] { return formatter }
        let formatter = DateFormatter()
        formatter.calendar = calendar.calendar
        formatter.timeZone = calendar.calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = formatter
        return formatter
    }

    /// "Hourly", "Daily": the chart's title is this and the metric.
    static func adjective(_ width: BucketWidth) -> String {
        switch width {
        case .minute: "Per-minute"
        case .quarterHour: "Quarter-hourly"
        case .hour: "Hourly"
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        }
    }

    /// "Today 2:40 PM", "Oct 31, 9:05 AM": when something happened.
    static func moment(_ instant: Timestamp, calendar: LocalCalendar, now: Timestamp, locale: Locale = .current) -> String {
        let time = formatter("jmm", calendar: calendar, locale: locale).string(from: instant.date)
        if calendar.day(containing: now) == calendar.day(containing: instant) { return "Today \(time)" }
        return formatter("MMMd", calendar: calendar, locale: locale).string(from: instant.date) + ", " + time
    }

    /// A date in a localized template, such as "Tue, Oct 14" for "MMMEd".
    static func date(_ instant: Timestamp, _ template: String, calendar: LocalCalendar,
                     locale: Locale = .current) -> String {
        formatter(template, calendar: calendar, locale: locale).string(from: instant.date)
    }

    /// "1 PM today", "Oct 31 · Today", "Week of Oct 27", "Oct 2026".
    static func row(_ window: TimeWindow, width: BucketWidth, calendar: LocalCalendar, now: Timestamp,
                    locale: Locale = .current) -> String {
        func format(_ template: String) -> String {
            formatter(template, calendar: calendar, locale: locale).string(from: window.start.date)
        }
        let today = calendar.day(containing: now) == calendar.day(containing: window.start)
        switch width {
        case .minute, .quarterHour: return format("jmm")
        case .hour: return format("j") + (today ? " today" : " " + format("MMMd"))
        case .day: return format("MMMd") + (today ? " · Today" : "")
        case .week: return "Week of " + format("MMMd")
        case .month: return format("MMMyyyy")
        }
    }
}
