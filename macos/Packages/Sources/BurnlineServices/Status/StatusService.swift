//
//  StatusService.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// Today's totals, for the menu-bar title and the popover's headline.
public struct TodayStatus: Equatable, Sendable {
    public let tokens: Int64
    /// Equivalent cost at API prices of the priced events.
    public let cost: Nanodollars
    /// The share of today's events that are priced; nil with none.
    public let costCoverage: Double?
    /// When the day ends, so the figures can start over without waiting for usage.
    public let endsAt: Timestamp
}

/// A provider producing usage right now, from its recent events alone.
public struct LiveActivity: Equatable, Sendable {
    public let provider: ProviderKey
    public let model: String?
    public let project: String?
    /// Every token processed, cache re-reads included: the figure the
    /// dashboard's totals count.
    public let tokensPerMinute: Double
    public let costPerMinute: Nanodollars
    /// When it stops being live unless more usage arrives.
    public let endsAt: Timestamp
    /// Tokens other than cache re-reads. An agent re-reads its whole
    /// conversation from cache on every reply, so the processed rate runs a
    /// hundred times what is actually new; this is the rate a person can
    /// picture.
    public var newTokensPerMinute: Double = 0
    /// Every session that produced usage within the live window, across
    /// providers, the busiest first.
    public var sessions: [ActiveSession] = []

    /// Equivalent cost an hour across every active session: what heat is
    /// measured by.
    public var costPerHour: Nanodollars {
        Nanodollars(raw: sessions.reduce(0) { $0 + $1.costPerHour.raw })
    }
}

/// One session producing usage right now, named for its project.
public struct ActiveSession: Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let provider: ProviderKey?
    /// Equivalent cost per hour at its pace over the rate window.
    public let costPerHour: Nanodollars
}

/// What the menu bar shows that is not quota: today's totals and live
/// activity. Reads run off the main actor.
public struct StatusService: Sendable {
    let aggregation: AggregationService
    let calendar: LocalCalendar
    let clock: any WallClock

    /// A provider is live while its last event is this recent.
    public static let liveWindow: Int64 = 2 * 60
    /// The span its rate is measured over: the stretch heat is judged by.
    public static let rateWindow: Int64 = HeatScale.span

    public init(aggregation: AggregationService, calendar: LocalCalendar, clock: any WallClock = SystemClock()) {
        self.aggregation = aggregation
        self.calendar = calendar
        self.clock = clock
    }

    @concurrent
    public func today() async -> TodayStatus? {
        let day = calendar.window(for: calendar.day(containing: clock.now))
        guard let summary = try? aggregation.summary(.custom(day)) else { return nil }
        return TodayStatus(tokens: summary.totals.tokens.processed, cost: summary.totals.cost,
                           costCoverage: summary.totals.costCoverage, endsAt: day.end)
    }

    /// The provider whose usage arrived most recently, if within `liveWindow`,
    /// with its pace over the last `rateWindow` and the model and project it
    /// is mostly using.
    @concurrent
    public func live() async -> LiveActivity? {
        let now = clock.now
        let recent = TimeWindow(start: now.adding(seconds: -Self.rateWindow), end: now.adding(seconds: 1))
        guard let rows = try? aggregation.breakdown(.custom(recent), by: .provider),
              let latest = rows.filter({ $0.lastUsed != nil }).max(by: { $0.lastUsed! < $1.lastUsed! }),
              case .provider(let provider) = latest.key, let lastUsed = latest.lastUsed,
              now.seconds(since: lastUsed) <= Self.liveWindow else { return nil }
        let only = UsageFilters(providers: [provider])
        let model = (try? aggregation.breakdown(.custom(recent), by: .model, filters: only))?.first?.name
        let project = (try? aggregation.breakdown(.custom(recent), by: .project, filters: only))?.first?.name
        let minutes = Double(Self.rateWindow) / 60
        let tokens = latest.totals.tokens
        let perHour = 3_600 / Self.rateWindow
        let sessions = ((try? aggregation.breakdown(.custom(recent), by: .session)) ?? [])
            .compactMap { row -> ActiveSession? in
                guard case .session(let id) = row.key, let last = row.lastUsed,
                      now.seconds(since: last) <= Self.liveWindow else { return nil }
                return ActiveSession(id: id, name: row.name, provider: row.provider,
                                     costPerHour: Nanodollars(raw: row.totals.cost.raw * perHour))
            }
        return LiveActivity(provider: provider, model: model, project: project,
                            tokensPerMinute: Double(tokens.processed) / minutes,
                            costPerMinute: Nanodollars(raw: latest.totals.cost.raw / Int64(minutes)),
                            endsAt: lastUsed.adding(seconds: Self.liveWindow),
                            newTokensPerMinute: Double(tokens.processed - tokens.cachedInput) / minutes,
                            sessions: sessions)
    }

    /// How hard this history works when it works, from the last
    /// `HeatScale.lookback` of usage: the scale live heat is judged on.
    @concurrent
    public func heatScale() async -> HeatScale {
        let now = clock.now
        let window = TimeWindow(start: now.adding(seconds: -HeatScale.lookback), end: now)
        return HeatScale(spanCosts: (try? aggregation.busySpanCosts(in: window, span: HeatScale.span)) ?? [])
    }

    /// What this Mac sent to `provider` from `start` until now, or until
    /// `end` if that is sooner: a window waiting for its reset to be
    /// confirmed counts nothing after it.
    @concurrent
    public func usage(of provider: ProviderKey, from start: Timestamp, until end: Timestamp?) async -> UsageTotals? {
        let end = min(clock.now, end ?? clock.now)
        guard end > start else { return nil }
        return try? aggregation.summary(.custom(TimeWindow(start: start, end: end)),
                                        filters: UsageFilters(providers: [provider])).totals
    }
}
