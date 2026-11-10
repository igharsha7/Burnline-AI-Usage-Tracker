//
//  DashboardView.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import SwiftUI

/// The dashboard window: a compact sidebar of areas beside the chosen page,
/// under a native toolbar holding the range, the metric and refresh. On
/// macOS 26 the system draws the sidebar and toolbar in Liquid Glass, the
/// navigation layer the guidance reserves glass for; pages are opaque.
public struct DashboardView: View {
    @Bindable var model: DashboardModel
    let status: StatusModel
    @Environment(SettingsModel.self) private var settings: SettingsModel?

    public init(model: DashboardModel, status: StatusModel) {
        self.model = model
        self.status = status
    }

    static let minimumSize = CGSize(width: 900, height: 560)

    public var body: some View {
        if let failure = model.startupFailure {
            StoreFailureView(failure: failure, recovery: model.recovery)
                .navigationTitle("Burnline")
                .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        } else {
            dashboard
        }
    }

    private var dashboard: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            NavigationStack(path: $model.path) {
                area
                    .navigationDestination(for: Destination.self) { destination in
                        switch destination {
                        case .project(let id): ProjectPage(model: model, id: id)
                        case .session(let id): SessionPage(model: model, id: id)
                        }
                    }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                let problems = model.savingProblems
                if !problems.isEmpty {
                    SavingBanner(problems: problems)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Palette.background)
                }
            }
        }
        .toolbar(id: "dashboard") { toolbar }
        .environment(model.tour)
        // Each stop moves the dashboard to its page; the end returns to the
        // overview, where the tour began.
        .onChange(of: model.tour.index) { old, _ in
            if let step = model.tour.current {
                show(step)
            } else if old != nil {
                show(TourStep.all[0])
            }
        }
        // Offered once, after the first page has settled.
        .task {
            try? await Task.sleep(for: .seconds(1))
            model.tour.startIfNew()
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .task(id: model.refreshes) { await model.follow() }
        // The menu bar already wakes at midnight; reuse its day boundary.
        .onChange(of: status.today?.endsAt) { model.refresh() }
        .onChange(of: settings?.showAchievements) { _, visible in
            if visible == false, model.area == .achievements { model.area = .activity }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }

    @ViewBuilder private var area: some View {
        switch model.area ?? .overview {
        case .overview:
            if model.tab == .limits {
                Page { LimitsView(status: status).tourTarget(.limits) }
            } else {
                ScopePage(model: model, scope: model.scope(.overview)) {
                    ComparisonLine(model: model, scope: model.scope(.overview), status: status)
                }
            }
        case .provider(let provider): ProviderPage(model: model, status: status, provider: provider)
        case .projects: ProjectsPage(model: model)
        case .sessions: SessionsPage(model: model)
        case .activity: ActivityPage(model: model)
        case .achievements:
            if settings?.showAchievements != false { AchievementsPage(model: model) }
            else { ActivityPage(model: model) }
        }
    }

    private var title: String { (model.area ?? .overview).title }

    private var subtitle: String {
        if model.area == .overview && model.tab == .limits { return "Quota" }
        if model.area == .activity { return model.activity.range.title }
        if model.area == .achievements { return "All time" }
        return model.rangeLabel
    }

    private func show(_ step: TourStep) {
        model.show(step, tracked: settings?.tracked ?? Set(ProviderKey.trackable))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some CustomizableToolbarContent {
        // Separate items, so macOS 26 gives each its own glass rather than
        // fusing unrelated controls into one capsule. Each has an id, so
        // the toolbar can be rearranged from its context menu. The items
        // read the model in views of their own: were this builder to read
        // it, every range or tab change would hand the toolbar new items,
        // and it redraws them all, which shows as a flash.
        ToolbarItem(id: "back", placement: .navigation) { BackControl(model: model) }
        ToolbarItem(id: "range", placement: .primaryAction) { RangeControl(model: model) }
            .ownSurface()
        ToolbarItem(id: "view", placement: .primaryAction) { ViewControl(model: model) }
            .ownSurface()
        ToolbarItem(id: "refresh", placement: .primaryAction) {
            Button {
                model.refresh()
                Task { await status.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Refresh usage and quota")
        }
    }
}

/// Back to the page a day was opened from. A pushed page has the system's
/// own Back, so this stands aside while one is shown.
private struct BackControl: View {
    let model: DashboardModel

    var body: some View {
        if let origin = model.cameFrom, model.path.isEmpty {
            Button {
                model.goBack()
            } label: {
                Label("Back to \(origin.title)", systemImage: "chevron.left")
            }
            .keyboardShortcut("[")
            .help("Back to \(origin.title)")
        }
    }
}

/// Every range in one row, as the reference has it, so a range is one
/// click and the chosen one is always in view. A drilled or custom range
/// selects none of them; the subtitle names it. The activity page has its
/// own range, and Limits are now rather than a range, so it stands aside
/// for both.
private struct RangeControl: View {
    let model: DashboardModel

    var body: some View {
        if model.area != .activity && model.area != .achievements && !(model.area == .overview && model.tab == .limits) {
            SegmentedChoice(options: RangeChoice.allCases.map { (Optional($0), $0.title) },
                            selection: Binding(get: { model.rangeChoice }, set: { $0.map(model.choose) }))
                .help("Range: \(model.rangeLabel)")
                .accessibilityLabel("Range")
                .accessibilityValue(model.rangeLabel)
        }
    }
}

/// Drawn like the range row beside it, so the two read as one bar. Cost
/// and tokens apply to every page; Limits is the overview's own. The
/// activity page has its own measure.
private struct ViewControl: View {
    let model: DashboardModel

    private var tabs: [DashboardTab] {
        model.area == .overview ? DashboardTab.allCases : [.cost, .tokens]
    }

    var body: some View {
        if model.area != .activity && model.area != .achievements {
            SegmentedChoice(options: tabs.map { ($0, $0.title) },
                            selection: Binding(get: { tabs.contains(model.tab) ? model.tab : .cost },
                                               set: { model.tab = $0 }))
                .accessibilityLabel("View")
        }
    }
}

extension CustomizableToolbarContent {
    /// Drops macOS 26's glass from behind an item that draws its own
    /// surface, so it is not a box inside a capsule.
    @ToolbarContentBuilder func ownSurface() -> some CustomizableToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

extension DashboardModel {
    /// The range as the subtitle and chips name it.
    var rangeLabel: String {
        if let choice = rangeChoice { return choice.spoken }
        if case .custom(let window) = range {
            // A whole day is named as one, not by its first hour.
            let isDay = calendar.window(for: calendar.day(containing: window.start)) == window
            let width = isDay ? .day : BucketWidth.automatic(for: window)
            return BucketLabel.row(window, width: width > .hour ? .day : width, calendar: calendar, now: clock.now)
        }
        return ""
    }
}

/// The areas. Providers fold into one group of the ones being tracked, the
/// ones Burnline reads first, since the list will grow long; a provider says
/// something under its name only when it is not up to date, so a quiet
/// sidebar means all is well, and one that is not detected says so without
/// being opened. A provider not yet tracked is added from the end of
/// the group.
private struct Sidebar: View {
    @Bindable var model: DashboardModel
    @AppStorage("sidebar.providersExpanded") private var expanded = true
    @State private var adding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SettingsModel.self) private var settings: SettingsModel?

    private var tracked: Set<ProviderKey> { settings?.tracked ?? Set(ProviderKey.trackable) }

    private var providers: [ProviderKey] { model.providerPages(tracked: tracked) }

    var body: some View {
        List(selection: $model.area) {
            Label("Overview", systemImage: "chart.xyaxis.line").tag(Area.overview)
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(providers, id: \.self) { provider in
                    ProviderLabel(provider: provider, health: model.health[provider])
                        .tag(Area.provider(provider))
                }
                if let settings, ProviderKey.trackable.contains(where: { !settings.tracked.contains($0) }) {
                    Button { adding = true } label: {
                        Label("Add Provider…", systemImage: "plus.circle")
                            .foregroundStyle(Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Track another coding tool")
                }
            } label: {
                // The group is not a page, so its whole row opens and closes
                // it, not only the chevron, through the outline view, which
                // animates as the chevron does.
                Label("Providers", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if !SidebarGroup.toggle(in: NSApp.keyWindow) { expanded.toggle() } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(expanded ? "Collapses the providers" : "Expands the providers")
            }
            Label("Projects", systemImage: "folder").tag(Area.projects)
            Label("Sessions", systemImage: "clock").tag(Area.sessions)
            Label("Activity", systemImage: "square.grid.3x3").tag(Area.activity)
            if settings?.showAchievements != false {
                HStack {
                    Label("Achievements", systemImage: "medal")
                    Spacer(minLength: 4)
                    if model.newMedals > 0 {
                    // New medals waiting, until their arrival plays.
                    Text(model.newMedals.formatted())
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color(nsColor: .systemRed), in: Capsule())
                        .contentTransition(.numericText(value: Double(model.newMedals)))
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: model.newMedals)
                .padding(.leading, 18)
                .tag(Area.achievements)
                .accessibilityValue(model.newMedals > 0 ? "\(model.newMedals) new" : "")
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $adding) {
            if let settings { AddProviderSheet(settings: settings) { model.refresh() } }
        }
    }
}

private struct ProviderLabel: View {
    let provider: ProviderKey
    let health: ProviderHealth?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                if let health, !HealthText.isUpToDate(health) {
                    Text(HealthText.short(health)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            ProviderLogo(provider: provider, size: 15)
                .opacity(HealthText.isMeasured(health) ? 1 : 0.35)
        }
        .accessibilityElement(children: .combine)
    }
}

/// How a provider's health reads in words.
enum HealthText {
    static func short(_ health: ProviderHealth) -> String {
        switch health {
        case .healthy: "Up to date"
        case .degraded: "Needs attention"
        case .notInstalled: "Not detected"
        case .unavailable: "Not supported yet"
        }
    }

    static func long(_ health: ProviderHealth, now: Timestamp) -> String {
        switch health {
        case .healthy(let last): "Synced \(Countdown.compact(now.seconds(since: last))) ago."
        case .degraded(let reason, _): reason
        case .notInstalled: "Not detected on this Mac."
        case .unavailable(let reason): reason
        }
    }

    static func isUpToDate(_ health: ProviderHealth) -> Bool {
        if case .healthy = health { true } else { false }
    }

    /// Whether usage can be read at all; nil is not yet known.
    static func isMeasured(_ health: ProviderHealth?) -> Bool {
        switch health {
        case .unavailable, .notInstalled: false
        case .healthy, .degraded, nil: true
        }
    }
}

// MARK: Pages

/// A page's frame: a scrolling column of content, centred and capped in
/// width, on the opaque background.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(TourModel.self) private var tour: TourModel?

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                content
                    .padding(.horizontal, PageInsets.horizontal)
                    .padding(.top, PageInsets.top)
                    .padding(.bottom, PageInsets.bottom)
                    .frame(maxWidth: 1240)
                    .frame(maxWidth: .infinity)
            }
            .tourLayer(tour, scroll: scroll)
        }
        .background(Palette.background)
    }
}

/// The room a page leaves around its content.
enum PageInsets {
    static let horizontal: CGFloat = 36
    static let top: CGFloat = 24
    static let bottom: CGFloat = 40
}

/// Below this a page stacks the provider split under the headline figure.
nonisolated private let sideBySideWidth: CGFloat = 780

/// The figures for one scope: the headline, the chart, where the tokens went,
/// the breakdown and, where the scope has one, the ten-day ledger. Every page
/// is this, under a header of its own.
struct ScopePage<Header: View>: View {
    let model: DashboardModel
    let scope: ScopeModel
    @ViewBuilder var header: Header

    /// Whether the page is wide enough to set the provider split beside the
    /// figure. Only the crossing is stored, so resizing redraws the page
    /// once, not on every point of the drag.
    @State private var wide = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 20) {
                FilterBar(model: model, scope: scope.scope).tourTarget(.filters)
                header.arrival(0)
                figures
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= sideBySideWidth } action: { wide = $0 }
        }
        .task(id: FollowKey(scope: scope.scope, query: model.query)) { await scope.follow(model.query) }
    }

    @ViewBuilder private var figures: some View {
        if let failure = scope.failure, scope.data == nil {
            ContentUnavailableView {
                Label("Usage could not be read", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { model.refresh() }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else if let data = scope.data {
            if data.trackingStart == nil {
                ContentUnavailableView("Nothing tracked yet", systemImage: "flame",
                                       description: Text("Usage from Codex and Claude Code appears here as soon as either runs."))
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                content(data)
            }
        } else {
            ProgressView("Reading usage…").controlSize(.small).frame(maxWidth: .infinity, minHeight: 360)
        }
    }

    private func content(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Hero(data: data, metric: model.metric, rangeLabel: rangeLabel(data), previousLabel: previousLabel(data),
                 hidden: scope.hiddenProviders, health: model.health, wide: wide, toggle: scope.toggle)
                .padding(.bottom, 20)
                .arrival(1)
                .tourTarget(.hero)
            Card {
                UsageChart(buckets: data.buckets, width: data.series.width, providers: data.providers.map(\.provider),
                           hidden: scope.hiddenProviders, metric: model.metric, calendar: model.calendar, now: data.now)
            }
            .arrival(2)
            .tourTarget(.chart)
            TokenMixCard(totals: data.summary.totals, providers: data.providers).arrival(3).tourTarget(.tokenMix)
            Card { BreakdownSection(model: model, scope: scope, width: data.series.width) }.arrival(4)
                .tourTarget(.breakdown)
            if scope.scope.ledger {
                Card { ledger }.arrival(5)
            }
            if scope.scope == .overview {
                ComparisonFooter(model: model, totals: data.summary.totals, range: data.range).arrival(6)
            }
        }
        .animation(Motion.standard(reduced: reduceMotion), value: scope.hiddenProviders)
    }

    /// A session covers its own span, not the toolbar's range.
    private func rangeLabel(_ data: DashboardData) -> String {
        guard case .session = scope.scope, case .custom(let window) = data.range else { return model.rangeLabel }
        return "Session · " + BucketLabel.moment(window.start, calendar: model.calendar, now: data.now)
    }

    @ViewBuilder private var ledger: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Last \(DashboardData.ledgerDays) days", detail: "Day by day") {
                // The ten days are a view, not the extent of history.
                Button("Show \(RangeChoice.quarter.spoken.lowercased())") {
                    model.choose(.quarter)
                    scope.breakdown = nil
                }
                .buttonStyle(.link)
            }
            if let table = scope.table(.ledger(model.metric)) {
                BreakdownTable(columns: table.columns, lines: table.lines, drill: model.drill)
            }
        }
    }

    /// What the change pill compares with. A range still running is compared
    /// with the same point in the one before it, not the whole of it:
    /// "yesterday at this time", "the same point in the previous 7 days".
    private func previousLabel(_ data: DashboardData) -> String? {
        guard data.previous != nil else { return nil }
        let running = data.summary.window.end > model.clock.now
        let days = (data.summary.window.durationSeconds + 43_200) / 86_400
        if days <= 1 { return running ? "yesterday at this time" : "the day before" }
        return running ? "the same point in the previous \(days) days" : "the previous \(days) days"
    }
}

extension ScopePage where Header == EmptyView {
    init(model: DashboardModel, scope: ScopeModel) {
        self.init(model: model, scope: scope) { EmptyView() }
    }
}

/// The breakdown and its controls. Its filter text is its own state, so
/// typing redraws this section, not the page.
struct BreakdownSection: View {
    let model: DashboardModel
    @Bindable var scope: ScopeModel
    let width: BucketWidth
    var title = "Breakdown"
    /// Set where the table is the page, to show it a screenful at a time.
    var pageSize: Int?
    var rowsTop: ((CGFloat) -> Void)?

    @State private var search = ""
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title) {
                SearchField(text: $search, focused: $searching)
                if options.count > 1 {
                    SegmentedChoice(options: options, selection: $scope.breakdown)
                        .accessibilityLabel("Breakdown by")
                }
            }
            if let table = scope.table(scope.breakdown.map { .ranked($0, model.metric) } ?? .buckets(model.metric)) {
                BreakdownTable(columns: table.columns, lines: table.lines, ranked: scope.breakdown != nil,
                               search: search, drill: model.drill, applied: model.isApplied, undo: model.lift,
                               pageSize: pageSize, rowsTop: rowsTop)
                    // A new shape starts from its own order.
                    .id(scope.breakdown)
            }
        }
        .onChange(of: model.searchRequests) { searching = true }
    }

    /// The groupings the scope lists, then its time buckets, except on the
    /// list pages, which are lists of one thing.
    private var options: [(BreakdownKey?, String)] {
        let groupings = scope.scope.breakdowns.map { (Optional($0), BreakdownShape.title($0)) }
        return switch scope.scope {
        case .projects, .sessions: groupings
        default: groupings + [(nil, BucketLabel.noun(width))]
        }
    }
}

/// The global filters and a drilled range, each a chip that says what it
/// narrows and clears it, then a menu to add more. Shown on every page, so
/// a figure never changes without the reason on screen. A session's page
/// shows only the range chip: nothing narrows a session further.
struct FilterBar: View {
    let model: DashboardModel
    let scope: Scope

    var body: some View {
        HStack(spacing: 8) {
            if model.rangeBeforeDrill != nil {
                FilterChip(title: model.rangeLabel, systemImage: "calendar", clear: model.clearDrill)
            }
            if !isSession {
                ForEach(model.filters.providers.sorted { $0.rawValue < $1.rawValue }, id: \.self) { provider in
                    FilterChip(title: provider.displayName, systemImage: "circle.fill",
                               tint: Palette.accent(provider)) { model.toggle(provider) }
                }
                ForEach(model.filters.models.sorted { $0.value < $1.value }, id: \.key) { id, name in
                    FilterChip(title: name, systemImage: "cpu") { model.filters.models[id] = nil }
                }
                ForEach(model.filters.projects.keys.sorted(), id: \.self) { id in
                    FilterChip(title: model.name(ofProject: id), systemImage: "folder") { model.filters.projects[id] = nil }
                }
                addMenu
                if !model.filters.isEmpty {
                    Button("Clear All", action: model.clearFilters).buttonStyle(.link).font(.callout)
                }
            }
        }
    }

    private var isSession: Bool {
        if case .session = scope { return true }
        return false
    }

    private var addMenu: some View {
        Menu {
            Section("Provider") {
                // Only providers being tracked have anything to narrow to.
                ForEach(ProviderKey.trackable.filter { model.health[$0] != nil || model.filters.providers.contains($0) },
                        id: \.self) { provider in
                    Toggle(provider.displayName, isOn: Binding(get: { model.filters.providers.contains(provider) },
                                                               set: { _ in model.toggle(provider) }))
                }
            }
            Section("Project") {
                ForEach(model.rootProjects.prefix(Self.menuLimit)) { project in
                    Toggle(project.name,
                           isOn: Binding(get: { model.filters.projects[project.id] != nil },
                                         set: { on in
                                             if on { model.filter(project: project.id) }
                                             else { model.filters.projects[project.id] = nil }
                                         }))
                }
            }
            let models = model.scope(.overview).data?.models.filter(\.isModel) ?? []
            if !models.isEmpty {
                Section("Model") {
                    ForEach(models.prefix(Self.menuLimit), id: \.key) { row in
                        if case .model(let id?) = row.key {
                            Toggle(row.name, isOn: Binding(get: { model.filters.models[id] != nil },
                                                           set: { on in
                                                               if on { model.filter(model: id, name: row.name) }
                                                               else { model.filters.models[id] = nil }
                                                           }))
                        }
                    }
                }
            }
        } label: {
            FilterButtonLabel(count: model.filters.providers.count + model.filters.models.count
                                  + model.filters.projects.count)
                .accessibilityElement(children: .ignore)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Narrow every page to a provider, project or model")
        .accessibilityLabel("Filter")
    }

    /// A menu longer than this is past scanning; the rest are a search away
    /// in the breakdown.
    static let menuLimit = 15
}

/// The Filter menu's face: a pill the height of the chips beside it, with
/// how many filters are on, lifting under the pointer.
private struct FilterButtonLabel: View {
    let count: Int

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").imageScale(.small)
            Text("Filter")
            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Palette.textPrimary.opacity(0.14), in: Capsule())
                    .transition(Motion.icon)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.textSecondary)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(hovered ? Palette.textPrimary : Palette.textPrimary.opacity(0.85))
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .padding(.vertical, 5)
        .background(Palette.control.opacity(hovered ? 1 : 0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.separator.opacity(hovered ? 0.9 : 0.5), lineWidth: 0.5))
        .contentShape(Capsule())
        .animation(Motion.standard(reduced: reduceMotion), value: count)
        .onHover { inside in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { hovered = inside } }
    }
}

private struct FilterChip: View {
    let title: String
    let systemImage: String
    var tint: Color = Palette.textSecondary
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).imageScale(.small).foregroundStyle(tint)
            Text(title).lineLimit(1).truncationMode(.middle)
            Button(action: clear) {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Palette.textSecondary)
            .accessibilityLabel("Remove filter \(title)")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.control, in: Capsule())
    }
}

private struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary).imageScale(.small)
            TextField("Filter rows", text: $text).textFieldStyle(.plain)
                .focused(focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.pressable).foregroundStyle(Palette.textSecondary)
                .accessibilityLabel("Clear filter")
                .transition(Motion.icon)
            }
        }
        .animation(Motion.standard, value: text.isEmpty)
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 180)
        .background(Palette.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
