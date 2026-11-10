//
//  DashboardModel.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import Foundation
import Observation

/// What the dashboard measures: equivalent cost or processed tokens. Quota
/// has its own tab, since it is a state, not a sum over a range.
public enum DashboardTab: String, CaseIterable, Sendable {
    case cost, tokens, limits

    var title: String {
        switch self {
        case .cost: "Cost"
        case .tokens: "Tokens"
        case .limits: "Limits"
        }
    }
}

enum Metric: Hashable, Sendable {
    case cost, tokens

    /// The figure plotted and ranked by. Dollars as a Double only for drawing
    /// and ordering; every figure shown is formatted from nanodollars.
    func value(_ totals: UsageTotals) -> Double {
        switch self {
        case .cost: Double(totals.cost.raw) / Double(Nanodollars.perDollar)
        case .tokens: Double(totals.tokens.processed)
        }
    }

    func text(_ totals: UsageTotals) -> String {
        switch self {
        case .cost: Format.cost(totals.cost)
        case .tokens: Format.figure(totals.tokens.processed)
        }
    }

    var noun: String { self == .cost ? "cost" : "tokens" }
}

/// The ranges the toolbar offers, by their short names.
enum RangeChoice: String, CaseIterable {
    case today, week, month, quarter, yearToDate, year, all

    var preset: RangePreset {
        switch self {
        case .today: .today
        case .week: .last7Days
        case .month: .last30Days
        case .quarter: .last90Days
        case .yearToDate: .yearToDate
        case .year: .lastYear
        case .all: .all
        }
    }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7D"
        case .month: "30D"
        case .quarter: "90D"
        case .yearToDate: "YTD"
        case .year: "1Y"
        case .all: "All"
        }
    }

    var spoken: String {
        switch self {
        case .today: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .quarter: "Last 90 days"
        case .yearToDate: "Year to date"
        case .year: "Last 365 days"
        case .all: "All time"
        }
    }
}

/// The sidebar's areas.
enum Area: Hashable {
    case overview
    case provider(ProviderKey)
    case projects
    case sessions
    case activity
    case achievements

    var title: String {
        switch self {
        case .overview: "Usage"
        case .provider(let provider): provider.displayName
        case .projects: "Projects"
        case .sessions: "Sessions"
        case .activity: "Activity"
        case .achievements: "Achievements"
        }
    }
}

/// A page pushed over an area: one project or one session.
enum Destination: Hashable {
    case project(Int64)
    case session(Int64)
}

/// The global filters, kept between launches and always shown as chips, so
/// a figure never changes without the reason on screen. Names travel with
/// ids so a chip can say what it filters before the catalog has loaded.
struct GlobalFilters: Codable, Hashable {
    var providers: Set<ProviderKey> = []
    var models: [Int64: String] = [:]
    var projects: [Int64: String] = [:]

    var isEmpty: Bool { providers.isEmpty && models.isEmpty && projects.isEmpty }

    var usage: UsageFilters {
        UsageFilters(providers: providers, models: Set(models.keys), projects: Set(projects.keys))
    }
}

/// What the stores and services the dashboard reads from, once connected.
struct DashboardServices {
    let aggregation: AggregationService
    let catalog: CatalogService
    let activity: ActivityService
    let changes: ChangeFeed
    let health: @Sendable () async -> [ProviderKey: ProviderHealth]
}

/// The dashboard's shared state: where the user is, the range and filters
/// every page applies, and what the pages share, the project catalog and
/// provider health. Each page's figures live in its `ScopeModel`.
@Observable
public final class DashboardModel {
    var area: Area? = .overview {
        didSet {
            if area != oldValue {
                path = []
                cameFrom = nil
            }
        }
    }
    /// The area a day was opened from, so Back can return to it. Moving to
    /// any area by other means forgets it.
    private(set) var cameFrom: Area?
    var path: [Destination] = []
    var tab: DashboardTab = .cost
    var range: RangePreset = .last30Days {
        didSet { if let choice = rangeChoice { defaults.set(choice.rawValue, forKey: Self.rangeKey) } }
    }
    /// The toolbar range a drill into one bucket came from, to go back to.
    private(set) var rangeBeforeDrill: RangePreset?
    var filters = GlobalFilters() {
        didSet { if let data = try? JSONEncoder().encode(filters) { defaults.set(data, forKey: Self.filtersKey) } }
    }
    /// Bumped by Refresh, so every page on screen reads again.
    private(set) var refreshes = 0
    /// Fresh medals whose arrival has not played, shown on the sidebar.
    private(set) var newMedals = 0
    /// Bumped by Command-F, so the page's search field takes focus.
    private(set) var searchRequests = 0

    private(set) var projects: [Project] = []
    private(set) var health: [ProviderKey: ProviderHealth] = [:]
    private(set) var failure: String?
    /// The database never opened; the window says why rather than waiting.
    private(set) var startupFailure: StoreFailure?
    @ObservationIgnored private(set) var recovery: StoreRecovery?
    private(set) var calendar = LocalCalendar(timeZone: .current, firstWeekday: .monday)

    @ObservationIgnored private(set) var services: DashboardServices?
    @ObservationIgnored private var scopes: [Scope: ScopeModel] = [:]
    /// The playful comparisons, when the corpus loaded.
    @ObservationIgnored private(set) var comparisons: ComparisonEngine?
    /// The activity page's figures, kept like a page's scope model.
    @ObservationIgnored private(set) lazy var activity = ActivityModel(dashboard: self)
    @ObservationIgnored private var catalogGeneration = 0
    @ObservationIgnored private var followGeneration = 0
    @ObservationIgnored private let catalogReloads = Coalescer()
    @ObservationIgnored let clock: any WallClock
    @ObservationIgnored private let defaults: UserDefaults
    /// The guided tour, which moves the dashboard from stop to stop.
    public let tour: TourModel

    static let rangeKey = "dashboardRange"
    static let filtersKey = "dashboardFilters"

    public init(clock: any WallClock = SystemClock(), defaults: UserDefaults = .standard) {
        self.clock = clock
        self.defaults = defaults
        tour = TourModel(defaults: defaults)
        if let raw = defaults.string(forKey: Self.rangeKey), let choice = RangeChoice(rawValue: raw) {
            range = choice.preset
        }
        if let data = defaults.data(forKey: Self.filtersKey),
           let saved = try? JSONDecoder().decode(GlobalFilters.self, from: data) {
            filters = saved
        }
    }

    public func connect(aggregation: AggregationService, catalog: CatalogService, activity: ActivityService,
                        changes: ChangeFeed, health: @escaping @Sendable () async -> [ProviderKey: ProviderHealth],
                        calendar: LocalCalendar, comparisons: ComparisonEngine?) {
        services = DashboardServices(aggregation: aggregation, catalog: catalog, activity: activity, changes: changes,
                                     health: health)
        self.calendar = calendar
        self.comparisons = comparisons
        refresh()
    }

    /// The database could not be opened, so nothing will connect.
    public func fail(_ failure: StoreFailure, recovery: StoreRecovery) {
        startupFailure = failure
        self.recovery = recovery
    }

    /// Providers whose usage is not being saved, with why, for the banner
    /// every page carries while it lasts.
    var savingProblems: [(provider: ProviderKey, reason: String)] {
        ProviderKey.allCases.compactMap { provider in
            guard case .degraded(let reason, _) = health[provider] else { return nil }
            return (provider, reason)
        }
    }

    var metric: Metric { tab == .tokens ? .tokens : .cost }

    var rangeChoice: RangeChoice? { RangeChoice.allCases.first { $0.preset == range } }

    /// What every page on screen reads. A page reloads whenever it changes.
    var query: ScopeQuery { ScopeQuery(range: range, filters: filters.usage, refresh: refreshes) }

    /// The page model for `scope`, made once and kept, so returning to a page
    /// shows its last figures while new ones load.
    func scope(_ scope: Scope) -> ScopeModel {
        if let model = scopes[scope] { return model }
        let model = ScopeModel(scope: scope, dashboard: self)
        scopes[scope] = model
        return model
    }

    // MARK: Range

    func choose(_ choice: RangeChoice) {
        rangeBeforeDrill = nil
        range = choice.preset
    }

    /// Narrows the range to one bucket of the breakdown, such as a day.
    func show(_ window: TimeWindow) {
        rangeBeforeDrill = rangeBeforeDrill ?? range
        range = .custom(window)
    }

    /// Opens one day on the overview, remembering where it was opened from.
    /// Turns to the Achievements page, where new medals play their arrival.
    public func showAchievements() { area = .achievements }

    func open(day window: TimeWindow, from origin: Area) {
        show(window)
        area = .overview
        cameFrom = origin
    }

    /// Returns to where a day was opened from, with the range it had then.
    func goBack() {
        guard let origin = cameFrom else { return }
        if rangeBeforeDrill != nil { clearDrill() }
        area = origin
    }

    func clearDrill() {
        range = rangeBeforeDrill ?? RangeChoice.month.preset
        rangeBeforeDrill = nil
    }

    // MARK: Filters and navigation

    func filter(model id: Int64, name: String) {
        filters.models[id] = name
    }

    func filter(project id: Int64) {
        filters.projects[id] = name(ofProject: id)
    }

    func toggle(_ provider: ProviderKey) {
        if filters.providers.contains(provider) { filters.providers.remove(provider) } else { filters.providers.insert(provider) }
    }

    func clearFilters() {
        filters = GlobalFilters()
        if rangeBeforeDrill != nil { clearDrill() }
    }

    /// Follows a row of a table to what it names.
    func drill(_ target: BreakdownLine.Drill) {
        switch target {
        case .model(let id, let name): filter(model: id, name: name)
        case .project(let id): path.append(.project(id))
        case .session(let id): path.append(.session(id))
        case .window(let window): show(window)
        }
    }

    /// Whether following `target` is already in effect: a model it narrows to.
    func isApplied(_ target: BreakdownLine.Drill) -> Bool {
        if case .model(let id, _) = target { filters.models[id] != nil } else { false }
    }

    /// Lifts what `drill` applied, where that is a filter; pages are left by Back.
    func lift(_ target: BreakdownLine.Drill) {
        if case .model(let id, _) = target { filters.models[id] = nil }
    }

    func requestSearch() { searchRequests += 1 }

    /// The provider pages, in the sidebar's order: tracked providers only,
    /// those Burnline can measure before those it cannot.
    func providerPages(tracked: Set<ProviderKey>) -> [ProviderKey] {
        ProviderKey.allCases.filter(tracked.contains).enumerated()
            .sorted { a, b in
                let x = HealthText.isMeasured(health[a.element]), y = HealthText.isMeasured(health[b.element])
                return x == y ? a.offset < b.offset : x
            }
            .map(\.element)
    }

    /// Opens a tour step's page. The provider step shows the first provider
    /// page there is, since the one it names may not be tracked.
    func show(_ step: TourStep, tracked: Set<ProviderKey>) {
        path.removeAll()
        if case .provider = step.area {
            area = providerPages(tracked: tracked).first.map(Area.provider) ?? .overview
        } else {
            area = step.area
        }
        tab = step.tab
    }

    /// Command-2: the first provider page, unless a provider page is already open.
    func showProviders(tracked: Set<ProviderKey>) {
        if case .provider(let open) = area, tracked.contains(open) { return }
        if let first = providerPages(tracked: tracked).first { area = .provider(first) }
    }

    // MARK: Projects

    /// The project's name as the user sees it: their alias, else the name its
    /// identity gave it.
    func name(ofProject id: Int64) -> String {
        guard let project = projects.first(where: { $0.id == id }) else { return filters.projects[id] ?? "Project" }
        return project.name
    }

    /// Projects that stand on their own, not merged into another.
    var rootProjects: [Project] { projects.filter { $0.mergedIntoID == nil } }

    func rename(project id: Int64, to alias: String?) {
        edit { try $0.rename(id, to: alias) }
    }

    func merge(project id: Int64, into target: Int64) {
        filters.projects[id] = nil
        edit { try $0.merge(id, into: target) }
    }

    func unmerge(project id: Int64) {
        edit { try $0.unmerge(id) }
    }

    /// Applies a correction off the main actor, then reads everything again,
    /// since a merge regroups every figure that involves either project.
    private func edit(_ change: @escaping @Sendable (CatalogService) throws -> Void) {
        guard let catalog = services?.catalog else { return }
        Task {
            do {
                try await Self.apply(change, to: catalog)
                failure = nil
            } catch {
                failure = "The change could not be saved: \(error)"
            }
            refresh()
        }
    }

    @concurrent
    private static func apply(_ change: @Sendable (CatalogService) throws -> Void,
                              to catalog: CatalogService) async throws {
        try change(catalog)
    }

    // MARK: Loading

    /// Reads every page on screen again, with the catalog and health.
    public func refresh() {
        refreshes += 1
        Task { await reloadCatalog() }
    }

    /// Keeps the catalog and health current while the window is open: the
    /// caller's task ends it, as a view's `.task` does when the window closes.
    func follow() async {
        guard !Task.isCancelled else { return }
        followGeneration += 1
        let generation = followGeneration
        catalogReloads.cancel()
        defer { if generation == followGeneration { catalogReloads.cancel() } }
        guard let changes = services?.changes else { return }
        let stream = changes.changes()
        await reloadCatalog()
        for await change in stream {
            guard generation == followGeneration, !Task.isCancelled else { break }
            if case .storage = change {
                await reloadCatalog()
                continue
            }
            switch change {
            case .usage, .achievements: break
            default: continue
            }
            catalogReloads.schedule(after: ScopeModel.reloadInterval) { [weak self] in
                guard let self, generation == self.followGeneration else { return }
                await self.reloadCatalog()
            }
        }
    }

    func reloadCatalog() async {
        guard let services else { return }
        catalogGeneration += 1
        let generation = catalogGeneration
        let health = await services.health()
        guard generation == catalogGeneration, !Task.isCancelled else { return }
        if let count = try? await Self.newMedals(services.activity) { newMedals = count }
        do {
            let projects = try await Self.projects(services.catalog)
            guard generation == catalogGeneration, !Task.isCancelled else { return }
            self.health = health
            self.projects = projects
        } catch {
            guard generation == catalogGeneration, !Task.isCancelled else { return }
            self.health = health
            failure = "Projects could not be read: \(error)"
        }
    }

    /// Sets the sidebar's count from what a page just read, so the two agree.
    func noteNewMedals(_ count: Int) { newMedals = count }

    @concurrent
    private static func newMedals(_ activity: ActivityService) async throws -> Int {
        try activity.uncelebratedCount()
    }

    @concurrent
    private static func projects(_ catalog: CatalogService) async throws -> [Project] {
        try catalog.projects()
    }
}
