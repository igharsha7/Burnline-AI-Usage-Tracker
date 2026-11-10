//
//  DashboardTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import BurnlineStore
import BurnlineTestSupport
@testable import BurnlineUI
import Foundation
import Testing

/// What the dashboard derives from the figures: its buckets, both shapes of
/// the breakdown, the labels, and where a drill-down returns to.
struct DashboardTests {
    /// 2 November 2026, 12:00 UTC: 17:30 in India.
    static let now = Timestamp(epochSeconds: 1_793_620_800)
    static let india = LocalCalendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!, firstWeekday: .monday)
    static let us = Locale(identifier: "en_US")

    static func totals(events: Int64, tokens: Int64, dollars: Int64) throws -> UsageTotals {
        UsageTotals(events: events, tokens: try TokenCounts(output: tokens),
                    cost: Nanodollars(raw: dollars * Nanodollars.perDollar), unpricedEvents: 0, cacheSavings: CacheSavings())
    }

    /// The last `count` days to today, each with the given Codex and Claude
    /// dollars; nil is a day with no usage.
    static func days(_ dollars: [(codex: Int64, claude: Int64)?]) throws -> UsageSeries {
        let days = india.days(endingWith: now, count: dollars.count)
        return UsageSeries(width: .day, grouping: .provider, buckets: try zip(days, dollars).map { day, value in
            guard let value else { return SeriesBucket(window: india.window(for: day), total: .zero, groups: [:]) }
            let codex = try totals(events: 1, tokens: value.codex * 1_000, dollars: value.codex)
            let claude = try totals(events: 1, tokens: value.claude * 1_000, dollars: value.claude)
            return SeriesBucket(window: india.window(for: day), total: try codex.adding(claude),
                                groups: [.provider(.codex): codex, .provider(.claudeCode): claude])
        })
    }

    @Test func `dashboard figures keep three significant figures`() {
        #expect(Format.figure(842) == "842")
        #expect(Format.figure(44_400) == "44.4K")
        #expect(Format.figure(1_540_000) == "1.54M")
        #expect(Format.figure(135_200_000) == "135M")
        #expect(Format.figure(5_980_000_000) == "5.98B")
        // Rounding up into the next unit names that unit.
        #expect(Format.figure(999_600) == "1M")
        #expect(Format.figure(10_000_000) == "10M" && Format.figure(2_500_000) == "2.5M")
        #expect(Format.share(0.263) == "26.3%")
        #expect(Format.share(0.0004) == "<0.1%")
        #expect(Format.share(0) == "0%")
    }

    @Test func `EC-U2 buckets before tracking are untracked and future ones are left out`() throws {
        let series = try Self.days([nil, nil, (1, 2), nil, (3, 4)])
        let start = series.buckets[2].window.start
        let buckets = series.dashboardBuckets(trackingStart: start, now: Self.now)
        #expect(buckets.map(\.tracked) == [false, false, true, true, true])
        // A tracked day with nothing in it is a zero, with its providers absent.
        #expect(buckets[3].total.events == 0 && buckets[3].providers.isEmpty)
        #expect(buckets[4].providers[.codex]?.cost == Nanodollars(raw: 3 * Nanodollars.perDollar))

        let today = UsageSeries(width: .hour, grouping: .provider, buckets: Self.india.buckets(
            .hour, covering: Self.india.window(for: Self.india.day(containing: Self.now))
        ).map { SeriesBucket(window: $0, total: .zero, groups: [:]) })
        // 17:30: the hours from 18:00 on have not happened.
        #expect(today.dashboardBuckets(trackingStart: start, now: Self.now).count == 18)
    }

    @Test func `ranked models share the whole, but only models count toward it`() throws {
        let rows = [
            BreakdownRow(key: .model(1), name: "claude-opus-5", provider: .claudeCode,
                         totals: try Self.totals(events: 1, tokens: 100, dollars: 3), lastUsed: nil),
            BreakdownRow(key: .model(2), name: "gpt-6.1-sol", provider: .codex,
                         totals: try Self.totals(events: 1, tokens: 700, dollars: 1), lastUsed: nil),
            BreakdownRow(key: .model(3), name: "<synthetic>", provider: .claudeCode, isModel: false,
                         totals: try Self.totals(events: 1, tokens: 200, dollars: 0), lastUsed: nil),
        ]
        let cost = BreakdownShape.ranked(rows, by: .model, metric: .cost)
        #expect(cost.columns.map(\.title) == ["Model", "Cost", "Share", "Tokens"])
        #expect(cost.lines.map(\.name) == ["claude-opus-5", "gpt-6.1-sol", "<synthetic>"])
        #expect(cost.lines.map { $0.texts["share"] } == ["75.0%", "25.0%", "—"])
        // By tokens, the non-model's 200 stay out of the whole of 800.
        let tokens = BreakdownShape.ranked(rows, by: .model, metric: .tokens)
        #expect(tokens.lines.map(\.name) == ["gpt-6.1-sol", "<synthetic>", "claude-opus-5"])
        #expect(tokens.lines.compactMap(\.share) == [0.875, 0.125])
        #expect(tokens.lines.allSatisfy { $0.ranked })
    }

    @Test func `EC-U2 the time shape pivots providers into columns, newest first`() throws {
        let series = try Self.days([nil, (1, 2), nil, (3, 4)])
        let buckets = series.dashboardBuckets(trackingStart: series.buckets[1].window.start, now: Self.now)
        let shape = BreakdownShape.buckets(buckets, width: .day, providers: [.codex, .claudeCode], metric: .cost,
                                           calendar: Self.india, now: Self.now)
        #expect(shape.columns.map(\.title) == ["Day", "Codex", "Claude Code", "Total", "Tokens"])
        #expect(shape.lines.first?.name.hasSuffix("Today") == true)
        #expect(shape.lines.map { $0.texts["metric"] } == ["$7.00", Format.cost(.init(raw: 0)), "$3.00", ""])
        #expect(shape.lines.map { $0.texts["other"] } == ["7K", "0", "3K", ""])
        // Before tracking began: no figures, and nowhere to drill.
        #expect(shape.lines.last?.tracked == false && shape.lines.last?.drill == nil)
        #expect(shape.lines.dropLast().allSatisfy { $0.drill != nil })
        // Hours have no drill-down below them.
        let hours = BreakdownShape.buckets(buckets, width: .hour, providers: [.codex], metric: .tokens,
                                           calendar: Self.india, now: Self.now)
        #expect(hours.lines.allSatisfy { $0.drill == nil })
    }

    @Test func `EC-U1 a tracked zero cost is explicit in the ledger`() throws {
        let series = try Self.days([(1, 2), nil])
        let buckets = series.dashboardBuckets(trackingStart: series.buckets[0].window.start, now: Self.now)
        let table = BreakdownShape.buckets(buckets, width: .day, providers: [.codex], metric: .cost,
                                           calendar: Self.india, now: Self.now)
        #expect(table.lines[0].texts["metric"] == Format.cost(.init(raw: 0)))
        #expect(table.lines[0].texts[ProviderKey.codex.rawValue] == Format.cost(.init(raw: 0)))
    }

    @Test func `EC-U1 the chart spoken summary keeps the cost cents`() throws {
        let totals = UsageTotals(events: 1, tokens: .zero, cost: Nanodollars(raw: 12_840_000_000),
                                 unpricedEvents: 0, cacheSavings: CacheSavings())
        let bucket = DashboardBucket(window: Self.india.bucket(.hour, containing: Self.now), tracked: true,
                                     total: totals, providers: [.codex: totals])
        let chart = UsageChart(buckets: [bucket], width: .hour, providers: [.codex], hidden: [], metric: .cost,
                               calendar: Self.india, now: Self.now)
        #expect(chart.summary(["Today"]) == "Codex: \(Format.cost(totals.cost)) in all, most in Today at \(Format.cost(totals.cost)).")
    }

    @Test func `buckets are named for their width`() {
        let day = Self.india.window(for: Self.india.day(containing: Self.now))
        #expect(BucketLabel.row(day, width: .day, calendar: Self.india, now: Self.now, locale: Self.us) == "Nov 2 · Today")
        let hour = Self.india.bucket(.hour, containing: Self.now)
        #expect(BucketLabel.row(hour, width: .hour, calendar: Self.india, now: Self.now, locale: Self.us)
                    .replacingOccurrences(of: "\u{202F}", with: " ") == "5 PM today")
        let month = Self.india.month(containing: Self.now)
        #expect(BucketLabel.row(month, width: .month, calendar: Self.india, now: Self.now, locale: Self.us) == "Nov 2026")
        #expect(BucketLabel.adjective(.week) == "Weekly" && BucketLabel.noun(.hour) == "Hour")
    }

    /// A scratch defaults domain, so tests never read or write the app's.
    static func defaults() -> UserDefaults {
        let name = "BurnlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func `projects and sessions rank like models and open what they name`() throws {
        let started = Self.now.adding(seconds: -3_600)
        let rows = [
            BreakdownRow(key: .session(7), name: "burnline", provider: .claudeCode,
                         totals: try Self.totals(events: 1, tokens: 100, dollars: 2), lastUsed: nil),
            BreakdownRow(key: .session(8), name: "web", provider: .codex,
                         totals: try Self.totals(events: 1, tokens: 100, dollars: 1), lastUsed: nil),
        ]
        let sessions: [Int64: Session] = [7: Session(id: 7, provider: .claudeCode, sourceSessionID: "a", projectID: 1,
                                   startedAt: started, endedAt: Self.now)]
        let shape = BreakdownShape.ranked(rows, by: .session, metric: .cost, sessions: sessions,
                                          calendar: Self.india, now: Self.now)
        #expect(shape.columns.first?.title == "Session")
        #expect(shape.lines[0].name.hasPrefix("burnline · Today"))
        // A session whose start is not known is named for its project alone.
        #expect(shape.lines[1].name == "web")
        #expect(shape.lines.map { $0.drill } == [BreakdownLine.Drill.session(7), .session(8)])

        let project = BreakdownRow(key: .project(3), name: "api", provider: nil,
                                   totals: try Self.totals(events: 1, tokens: 1, dollars: 1), lastUsed: nil)
        #expect(BreakdownShape.ranked([project], by: .project, metric: .cost).lines[0].drill == .project(3))
    }

    @Test func `a page narrows the global filters to its scope, and a session ignores them`() {
        let global = UsageFilters(providers: [.codex], models: [4], projects: [9])
        #expect(Scope.overview.filters(global) == global)
        #expect(Scope.provider(.claudeCode).filters(global)
                == UsageFilters(providers: [.claudeCode], models: [4], projects: [9]))
        #expect(Scope.project(2).filters(global) == UsageFilters(providers: [.codex], models: [4], projects: [2]))
        #expect(Scope.session(5).filters(global) == UsageFilters(sessions: [5]))
    }

    @Test func `filters and a chosen range are kept between launches, a drilled range is not`() {
        let defaults = Self.defaults()
        let model = DashboardModel(defaults: defaults)
        model.choose(.week)
        model.filter(model: 4, name: "gpt-6.1-sol")
        model.toggle(.codex)
        model.show(Self.india.window(for: Self.india.day(containing: Self.now)))

        let relaunched = DashboardModel(defaults: defaults)
        #expect(relaunched.range == .last7Days)
        #expect(relaunched.filters.models == [4: "gpt-6.1-sol"] && relaunched.filters.providers == [.codex])
        #expect(relaunched.query.filters == UsageFilters(providers: [.codex], models: [4]))

        relaunched.clearFilters()
        #expect(DashboardModel(defaults: defaults).filters.isEmpty)
    }

    @Test func `rows open their project or session, and changing area starts from its top`() {
        let model = DashboardModel(defaults: Self.defaults())
        model.drill(.project(3))
        model.drill(.session(8))
        #expect(model.path == [.project(3), .session(8)])
        model.drill(.model(id: 4, name: "claude-opus-5"))
        #expect(model.filters.models[4] == "claude-opus-5")
        model.area = .sessions
        #expect(model.path.isEmpty)
    }

    @Test func `a day opened from the heatmap goes back to it with the range it had`() {
        let model = DashboardModel(clock: ManualClock(Self.now), defaults: Self.defaults())
        model.choose(.year)
        model.area = .activity
        let day = Self.india.window(for: LocalDay(year: 2026, month: 10, day: 6))
        model.open(day: day, from: .activity)
        #expect(model.area == .overview && model.range == .custom(day) && model.cameFrom == .activity)
        model.goBack()
        #expect(model.area == .activity && model.range == RangeChoice.year.preset && model.cameFrom == nil)

        // Leaving by any other way forgets where the day came from.
        model.open(day: day, from: .activity)
        model.area = .projects
        #expect(model.cameFrom == nil)
    }

    @Test func `EC-U4 an older catalog reload cannot overwrite current provider health`() async throws {
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: TestDirectory.make("Dashboard reload")),
            schema: Schema(directory: DashboardLoadTimingTests.repositoryRoot.appending(path: "shared/schema")),
            clock: ManualClock(Self.now))
        let aggregation = AggregationService(database: database, calendar: Self.india, clock: ManualClock(Self.now))
        let health = HeldHealth()
        let model = DashboardModel(clock: ManualClock(Self.now), defaults: Self.defaults())
        model.connect(aggregation: aggregation, catalog: CatalogService(database: database),
                      activity: ActivityService(database: database, aggregation: aggregation, calendar: Self.india),
                      changes: ChangeFeed(), health: { await health.read() }, calendar: Self.india, comparisons: nil)
        // Drain the catalog read started by connect before controlling the race.
        await model.reloadCatalog()
        await health.holdNext()
        let older = Task { await model.reloadCatalog() }
        await health.waitUntilHeld()
        await model.reloadCatalog()
        await health.release(at: Self.now)
        await older.value
        #expect(model.health[.codex] == .notInstalled)
    }

    @Test func `EC-U4 leaving a page cancels its outstanding load`() async throws {
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: TestDirectory.make("Page cancellation")),
            schema: Schema(directory: DashboardLoadTimingTests.repositoryRoot.appending(path: "shared/schema")),
            clock: ManualClock(Self.now))
        let aggregation = AggregationService(database: database, calendar: Self.india, clock: ManualClock(Self.now))
        let model = DashboardModel(clock: ManualClock(Self.now), defaults: Self.defaults())
        model.connect(aggregation: aggregation, catalog: CatalogService(database: database),
                      activity: ActivityService(database: database, aggregation: aggregation, calendar: Self.india,
                                                clock: ManualClock(Self.now)),
                      changes: ChangeFeed(), health: { [:] }, calendar: Self.india, comparisons: nil)
        let scope = model.scope(.overview)
        let page = Task { await scope.follow(model.query) }
        #expect(await eventually { scope.loading != nil })
        page.cancel()
        await page.value
        #expect(scope.loading?.isCancelled == true)

        let activity = model.activity
        let activityPage = Task { await activity.follow() }
        #expect(await eventually { activity.loading != nil })
        activityPage.cancel()
        await activityPage.value
        #expect(activity.loading?.isCancelled == true)
    }

    @Test func `a drill-down returns to the range it came from`() {
        let model = DashboardModel(defaults: Self.defaults())
        model.choose(.quarter)
        let day = Self.india.window(for: Self.india.day(containing: Self.now))
        model.show(day)
        #expect(model.range == .custom(day) && model.rangeChoice == nil)
        // Drilling again from a drill keeps the original range to go back to.
        model.show(Self.india.bucket(.hour, containing: Self.now))
        model.clearDrill()
        #expect(model.range == .last90Days && model.rangeBeforeDrill == nil)
        model.show(day)
        model.choose(.week)
        #expect(model.range == .last7Days && model.rangeBeforeDrill == nil)
    }
}

/// Holds one old read while a newer read reports that the provider disappeared.
private actor HeldHealth {
    private var hold = false
    private var held: CheckedContinuation<[ProviderKey: ProviderHealth], Never>?
    private var started: CheckedContinuation<Void, Never>?

    func holdNext() { hold = true }

    func read() async -> [ProviderKey: ProviderHealth] {
        guard hold else { return [.codex: .notInstalled] }
        hold = false
        return await withCheckedContinuation { continuation in
            held = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release(at now: Timestamp) {
        held?.resume(returning: [.codex: .healthy(lastImport: now)])
        held = nil
    }
}

/// The Providers shortcut and the tour's providers step open a page that is
/// there: a tracked provider, never one hidden from the sidebar.
struct ProviderPageTests {
    static func model() -> DashboardModel { DashboardModel(defaults: DashboardTests.defaults()) }

    @Test func `Command-2 opens the first tracked provider, not always Codex`() {
        let model = Self.model()
        model.showProviders(tracked: [.claudeCode])
        #expect(model.area == .provider(.claudeCode))
    }

    @Test func `Command-2 keeps the provider page already open`() {
        let model = Self.model()
        model.area = .provider(.claudeCode)
        model.showProviders(tracked: [.codex, .claudeCode])
        #expect(model.area == .provider(.claudeCode))
    }

    @Test func `Command-2 leaves an untracked provider's page for a tracked one`() {
        let model = Self.model()
        model.area = .provider(.codex)
        model.showProviders(tracked: [.claudeCode])
        #expect(model.area == .provider(.claudeCode))
    }

    @Test func `with nothing tracked, Command-2 stays where it is`() {
        let model = Self.model()
        model.area = .sessions
        model.showProviders(tracked: [])
        #expect(model.area == .sessions)
    }

    @Test func `the tour's providers step shows a tracked provider`() throws {
        let step = try #require(TourStep.all.first { $0.id == "providers" })
        let model = Self.model()
        model.show(step, tracked: [.codex])
        #expect(model.area == .provider(.codex))
        model.show(step, tracked: [])
        #expect(model.area == .overview)
    }
}
