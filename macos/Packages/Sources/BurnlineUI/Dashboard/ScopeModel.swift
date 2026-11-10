//
//  ScopeModel.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import BurnlineServices
import Foundation
import Observation
import SwiftUI

/// What a page covers: all usage, or one provider, project or session, and
/// the tables it lists. Every scope applies the global filters except a
/// session's, which is already as narrow as usage gets.
enum Scope: Hashable {
    case overview
    case provider(ProviderKey)
    case projects
    case sessions
    case project(Int64)
    case session(Int64)

    var breakdowns: [BreakdownKey] {
        switch self {
        case .overview: [.model, .project]
        case .provider: [.model, .project, .session]
        case .projects: [.project]
        case .sessions: [.session]
        case .project: [.model, .session]
        case .session: [.model]
        }
    }

    /// Whether the page ends with the ten-day ledger.
    var ledger: Bool {
        switch self {
        case .overview, .provider, .project: true
        case .projects, .sessions, .session: false
        }
    }

    func filters(_ global: UsageFilters) -> UsageFilters {
        var filters = global
        switch self {
        case .overview, .projects, .sessions: break
        case .provider(let provider): filters.providers = [provider]
        case .project(let id): filters.projects = [id]
        case .session(let id): filters = UsageFilters(sessions: [id])
        }
        return filters
    }
}

/// What a page reads: the range, the global filters, and a counter that
/// Refresh bumps. A page reloads whenever this changes.
struct ScopeQuery: Hashable {
    let range: RangePreset
    let filters: UsageFilters
    let refresh: Int
}

/// What a page's follow task is keyed on. Moving between pages of one kind,
/// such as from one provider to another, keeps the view's identity, so the
/// query alone would leave the new page following the old scope.
struct FollowKey: Hashable {
    let scope: Scope
    let query: ScopeQuery
}

/// One provider's share of the range.
nonisolated struct ProviderFigures: Sendable {
    let provider: ProviderKey
    let totals: UsageTotals
    let sessions: Int
}

/// Everything one page shows, read together so the figures agree.
nonisolated struct DashboardData: Sendable {
    let range: RangePreset
    let filters: UsageFilters
    let summary: UsageSummary
    let previous: UsageSummary?
    let providers: [ProviderFigures]
    let series: UsageSeries
    let breakdowns: [BreakdownKey: [BreakdownRow]]
    /// The sessions the session table lists, for when each started.
    let sessions: [Int64: Session]
    let ledger: UsageSeries?
    /// The start of the day tracking began; earlier buckets are untracked.
    let trackingStart: Timestamp?
    let now: Timestamp
    /// The series and the ledger as the views draw them, derived once here,
    /// off the main actor, rather than on every redraw.
    let buckets: [DashboardBucket]
    let ledgerBuckets: [DashboardBucket]

    static let ledgerDays = 10

    var models: [BreakdownRow] { breakdowns[.model] ?? [] }

    /// Reads the range off the main actor, the independent reads at once:
    /// the store is a pool, so they run on separate connections.
    @concurrent
    static func load(_ service: AggregationService, catalog: CatalogService? = nil, range: RangePreset,
                     filters: UsageFilters, breakdowns keys: [BreakdownKey] = [.model], ledger withLedger: Bool = true,
                     comparing: Bool = true, now: Timestamp) async throws -> DashboardData {
        async let summary = service.summary(range, filters: filters)
        async let previous = comparing ? service.previous(range).map { try service.summary($0, filters: filters) } : nil
        async let series = service.aggregate(range, grouping: .provider, filters: filters)
        async let ledger = withLedger
            ? service.aggregate(service.lastDays(ledgerDays), width: .day, grouping: .provider, filters: filters) : nil
        async let trackingStart = service.trackingStart()
        var breakdowns: [BreakdownKey: [BreakdownRow]] = [:]
        for key in keys {
            breakdowns[key] = try service.breakdown(range, by: key, filters: filters)
        }
        var sessions: [Int64: Session] = [:]
        if let rows = breakdowns[.session], let catalog {
            let ids = rows.compactMap { row -> Int64? in if case .session(let id) = row.key { id } else { nil } }
            for session in try catalog.sessions(ids: ids) { sessions[session.id] = session }
        }
        // One grouped read for every provider's totals, then each one's sessions.
        var providers: [ProviderFigures] = []
        for row in try service.breakdown(range, by: .provider, filters: filters) {
            // A provider with nothing in the range is absent, not drawn at zero.
            guard case .provider(let provider) = row.key, row.totals.events > 0 else { continue }
            var narrowed = filters
            narrowed.providers = [provider]
            providers.append(ProviderFigures(provider: provider, totals: row.totals,
                                             sessions: try service.sessions(range, filters: narrowed)))
        }
        providers.sort { ProviderKey.allCases.firstIndex(of: $0.provider)! < ProviderKey.allCases.firstIndex(of: $1.provider)! }
        let (seriesValue, ledgerValue, start) = try await (series, ledger, trackingStart)
        return DashboardData(range: range, filters: filters, summary: try await summary, previous: try await previous,
                             providers: providers, series: seriesValue, breakdowns: breakdowns, sessions: sessions,
                             ledger: ledgerValue, trackingStart: start, now: now,
                             buckets: seriesValue.dashboardBuckets(trackingStart: start, now: now),
                             ledgerBuckets: ledgerValue?.dashboardBuckets(trackingStart: start, now: now) ?? [])
    }
}

/// One page's figures. They load off the main actor and reload as usage
/// arrives, but only while the page is on screen: its view runs `follow`.
@Observable
final class ScopeModel {
    let scope: Scope
    /// Providers hidden from the chart. Their figures stay in every total.
    var hiddenProviders: Set<ProviderKey> = []
    /// The table the breakdown shows: a grouping, or nil for time buckets.
    var breakdown: BreakdownKey?

    private(set) var data: DashboardData? {
        didSet { shapes = [:] }
    }
    private(set) var failure: String?
    /// The session this page covers, once read.
    private(set) var session: Session?

    @ObservationIgnored private unowned let dashboard: DashboardModel
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    @ObservationIgnored private let reloads = Coalescer()
    @ObservationIgnored private var followGeneration = 0
    /// Table rows already built for the current figures, by what they show.
    @ObservationIgnored private var shapes: [ShapeKey: BreakdownShape.Table] = [:]

    enum ShapeKey: Hashable {
        case ranked(BreakdownKey, Metric), buckets(Metric), ledger(Metric)
    }

    /// Usage arrives every few seconds while an agent runs; the figures
    /// follow at most this often.
    static let reloadInterval: Duration = .seconds(3)

    init(scope: Scope, dashboard: DashboardModel) {
        self.scope = scope
        self.dashboard = dashboard
        breakdown = scope.breakdowns.first
    }

    /// Loads `query` now and again as usage arrives, until the caller's task
    /// ends, as a view's `.task(id:)` does when the page goes or the query
    /// changes.
    func follow(_ query: ScopeQuery) async {
        guard !Task.isCancelled else { return }
        followGeneration += 1
        let generation = followGeneration
        reloads.cancel()
        defer {
            if generation == followGeneration {
                reloads.cancel()
                loading?.cancel()
            }
        }
        guard let changes = dashboard.services?.changes else { return }
        let stream = changes.changes()
        reload(query)
        for await change in stream {
            guard generation == followGeneration, !Task.isCancelled else { break }
            guard case .usage = change else { continue }
            reloads.schedule(after: Self.reloadInterval) { [weak self] in
                guard let self, generation == self.followGeneration else { return }
                self.reload(query)
            }
        }
    }

    private func reload(_ query: ScopeQuery) {
        guard let services = dashboard.services else { return }
        let scope = scope, now = dashboard.clock.now
        loading?.cancel()
        loading = Task { [weak self] in
            do {
                var range = query.range
                if case .session(let id) = scope {
                    // A session is compared with nothing, and spans only itself.
                    let session = try await Self.session(id, services.catalog)
                    guard !Task.isCancelled else { return }
                    self?.session = session
                    if let session { range = .custom(Self.span(of: session)) }
                }
                let data = try await DashboardData.load(
                    services.aggregation, catalog: services.catalog, range: range,
                    filters: scope.filters(query.filters), breakdowns: scope.breakdowns, ledger: scope.ledger,
                    comparing: !Self.isSession(scope), now: now)
                guard !Task.isCancelled else { return }
                // New figures arrive in the same spring as a change of
                // measure, so a new range counts and morphs rather than cuts.
                withAnimation(Motion.standard(reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
                    self?.data = data
                }
                self?.failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.failure = "Usage could not be read: \(error)"
            }
        }
    }

    private static func isSession(_ scope: Scope) -> Bool {
        if case .session = scope { return true }
        return false
    }

    /// From the session's first event to a minute past its last, so the
    /// last minute's usage is inside it.
    static func span(of session: Session) -> TimeWindow {
        TimeWindow(start: session.startedAt, end: (session.endedAt ?? session.startedAt).adding(seconds: 60))
    }

    @concurrent
    private static func session(_ id: Int64, _ catalog: CatalogService) async throws -> Session? {
        try catalog.sessions(ids: [id]).first
    }

    /// The rows a table shows, built once per set of figures: a redraw for a
    /// hover or a keystroke reuses them.
    func table(_ key: ShapeKey) -> BreakdownShape.Table? {
        guard let data else { return nil }
        if let table = shapes[key] { return table }
        let calendar = dashboard.calendar
        let table: BreakdownShape.Table = switch key {
        case .ranked(let grouping, let metric):
            BreakdownShape.ranked(data.breakdowns[grouping] ?? [], by: grouping, metric: metric,
                                  sessions: data.sessions, calendar: calendar, now: data.now)
        case .buckets(let metric):
            BreakdownShape.buckets(data.buckets, width: data.series.width, providers: data.providers.map(\.provider),
                                   metric: metric, calendar: calendar, now: data.now)
        case .ledger(let metric):
            BreakdownShape.buckets(data.ledgerBuckets, width: .day,
                                   providers: ProviderKey.allCases.filter { provider in
                                       data.ledgerBuckets.contains { $0.providers[provider] != nil } },
                                   metric: metric, calendar: calendar, now: data.now)
        }
        shapes[key] = table
        return table
    }

    func toggle(_ provider: ProviderKey) {
        if hiddenProviders.contains(provider) { hiddenProviders.remove(provider) } else { hiddenProviders.insert(provider) }
    }

    /// Sets the figures directly, for previews and tests.
    func show(_ data: DashboardData) {
        self.data = data
    }
}

/// Folds a burst of changes into one action, run once the burst has had
/// `after` to settle: changes arriving meanwhile are covered by it.
final class Coalescer {
    private var pending: Task<Void, Never>?

    func schedule(after delay: Duration, _ action: @escaping () async -> Void) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            await action()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
