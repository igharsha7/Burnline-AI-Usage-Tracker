//
//  ActivityModel.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import Foundation
import Observation

/// The activity page's preferences, kept in the app's defaults and changed
/// in Settings.
enum ActivityPreferences {
    /// Streaks and achievements; off hides them everywhere.
    static let showAchievementsKey = "showAchievements"
    static let showComparisonsKey = "showComparisons"
    /// A `ComparisonTone` raw value, or `mix` for a different one each time.
    static let comparisonToneKey = "comparisonTone"
    static let mix = "mix"

    static func tone(_ raw: String) -> ComparisonTone? { ComparisonTone(rawValue: raw) }
}

/// What a heatmap cell's shade measures.
enum HeatmapMetric: String, CaseIterable {
    case tokens, cost, sessions, events

    var title: String { rawValue.capitalized }

    func value(_ day: ActivityDay) -> Double {
        switch self {
        case .tokens: Double(day.totals.tokens.processed)
        case .cost: Double(day.totals.cost.raw)
        case .sessions: Double(day.sessions)
        case .events: Double(day.totals.events)
        }
    }

    /// Each provider's part of a day, in this measure, largest first. A
    /// session is not split by provider, so sessions split by events.
    func parts(_ day: ActivityDay) -> [(provider: ProviderKey, share: Double)] {
        func value(_ totals: UsageTotals) -> Double {
            switch self {
            case .tokens: Double(totals.tokens.processed)
            case .cost: Double(totals.cost.raw)
            case .sessions, .events: Double(totals.events)
            }
        }
        let total = day.providers.values.reduce(0) { $0 + value($1) }
        guard total > 0 else { return [] }
        return day.providers.map { ($0.key, value($0.value) / total) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }
}

/// How far back the heatmap reaches.
enum HeatmapRange: String, CaseIterable {
    case threeMonths, sixMonths, year, all

    var title: String {
        switch self {
        case .threeMonths: "3 Months"
        case .sixMonths: "6 Months"
        case .year: "1 Year"
        case .all: "All Time"
        }
    }

    /// For the range row, matching the dashboard's 7D, 30D, 1Y.
    var short: String {
        switch self {
        case .threeMonths: "3M"
        case .sixMonths: "6M"
        case .year: "1Y"
        case .all: "All"
        }
    }

    /// "in the last year", for a sentence about the range.
    var span: String {
        switch self {
        case .threeMonths: "in the last 3 months"
        case .sixMonths: "in the last 6 months"
        case .year: "in the last year"
        case .all: "since tracking began"
        }
    }

    /// Days shown, today included; nil for every tracked day.
    var days: Int? {
        switch self {
        case .threeMonths: 91
        case .sixMonths: 182
        case .year: 365
        case .all: nil
        }
    }
}

/// The activity page's figures: every tracked day, streaks, achievements
/// and lifetime totals. Loads off the
/// main actor and follows usage while the page is on screen.
@Observable
final class ActivityModel {
    var metric = HeatmapMetric.tokens
    var range = HeatmapRange.year
    /// The day under the pointer, whose figures the heatmap's detail line shows.
    var hovered: LocalDay?

    private(set) var snapshot: ActivitySnapshot? {
        didSet { shelf = snapshot.map(AchievementShelf.init) }
    }
    /// The snapshot's medals arranged for the shelves, built once per
    /// snapshot rather than by every view that shows them.
    private(set) var shelf: AchievementShelf?
    private(set) var failure: String?

    @ObservationIgnored private unowned let dashboard: DashboardModel
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    @ObservationIgnored private let reloads = Coalescer()
    @ObservationIgnored private var followGeneration = 0

    init(dashboard: DashboardModel) {
        self.dashboard = dashboard
    }

    /// Loads now and again as usage arrives, until the caller's task ends,
    /// which the page restarts on Refresh.
    func follow() async {
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
        reload()
        for await change in stream {
            guard generation == followGeneration, !Task.isCancelled else { break }
            switch change {
            case .usage, .achievements: break
            default: continue
            }
            reloads.schedule(after: ScopeModel.reloadInterval) { [weak self] in
                guard let self, generation == self.followGeneration else { return }
                self.reload()
            }
        }
    }

    private func reload() {
        guard let activity = dashboard.services?.activity else { return }
        loading?.cancel()
        loading = Task { [weak self] in
            do {
                let snapshot = try await Self.load(activity)
                guard !Task.isCancelled else { return }
                // An unchanged reload leaves the pages alone, rather than
                // laying every medal and day out again for nothing.
                if self?.snapshot != snapshot { self?.snapshot = snapshot }
                self?.failure = nil
                self?.dashboard.noteNewMedals(snapshot.uncelebrated.count)
            } catch {
                guard !Task.isCancelled else { return }
                self?.failure = "Activity could not be read: \(error)"
            }
        }
    }

    @concurrent
    private static func load(_ activity: ActivityService) async throws -> ActivitySnapshot {
        try activity.snapshot()
    }

    /// Marks the new medals' arrivals played, then reads again, so they
    /// play once.
    func celebrated(_ achievements: [Achievement]) {
        guard let activity = dashboard.services?.activity else { return }
        Task { [weak self] in
            try? await Self.celebrate(achievements, with: activity)
            self?.reload()
        }
    }

    @concurrent
    private static func celebrate(_ achievements: [Achievement], with activity: ActivityService) async throws {
        try activity.celebrate(achievements)
    }

    /// The days the heatmap covers: the range's, or every tracked day.
    var visibleDays: [ActivityDay] {
        guard let days = snapshot?.days else { return [] }
        guard let count = range.days else { return days }
        return Array(days.suffix(count))
    }
}
