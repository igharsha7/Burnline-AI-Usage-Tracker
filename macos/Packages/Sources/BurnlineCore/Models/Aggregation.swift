//
//  Aggregation.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// What an aggregate is split by.
public enum Grouping: String, Sendable, CaseIterable {
    case total, provider, model, project
}

/// What the breakdown table lists rows of.
public enum BreakdownKey: Hashable, Sendable {
    case provider, model, project, session

    /// The grouping its sums come from; sessions are grouped separately.
    public var grouping: Grouping {
        switch self {
        case .provider: .provider
        case .model: .model
        case .project: .project
        case .session: .total
        }
    }
}

/// One group's identity. A nil model or project is usage that had none.
public enum GroupKey: Hashable, Sendable {
    case total
    case provider(ProviderKey)
    case model(Int64?)
    case project(Int64?)
    case session(Int64)
}

/// The global filters. An empty set means no filter on that dimension.
/// Projects are matched after merges, so filtering by a project includes
/// projects merged into it.
public struct UsageFilters: Hashable, Sendable {
    public var providers: Set<ProviderKey>
    public var models: Set<Int64>
    public var projects: Set<Int64>
    /// Only events know their session, so a session filter reads events and
    /// reaches no further back than the detail window.
    public var sessions: Set<Int64>

    public init(providers: Set<ProviderKey> = [], models: Set<Int64> = [], projects: Set<Int64> = [],
                sessions: Set<Int64> = []) {
        self.providers = providers
        self.models = models
        self.projects = projects
        self.sessions = sessions
    }

    public static let none = UsageFilters()
}

/// One bucket of a series: its totals, and its totals per group. Both shapes
/// of the breakdown come from this: read `groups` across buckets for one line
/// per provider, or one bucket's `groups` for a pivoted row.
public struct SeriesBucket: Equatable, Sendable {
    /// The whole calendar bucket, for labelling. Its totals cover only the
    /// part inside the requested range.
    public let window: TimeWindow
    public let total: UsageTotals
    public let groups: [GroupKey: UsageTotals]

    public init(window: TimeWindow, total: UsageTotals, groups: [GroupKey: UsageTotals]) {
        self.window = window
        self.total = total
        self.groups = groups
    }
}

public struct UsageSeries: Equatable, Sendable {
    public let width: BucketWidth
    public let grouping: Grouping
    /// Every bucket of the range, empty ones included, oldest first.
    public let buckets: [SeriesBucket]

    public init(width: BucketWidth, grouping: Grouping, buckets: [SeriesBucket]) {
        self.width = width
        self.grouping = grouping
        self.buckets = buckets
    }
}

/// One row of the breakdown table.
public struct BreakdownRow: Equatable, Sendable {
    public let key: GroupKey
    public let name: String
    /// The provider a model or session belongs to; nil for a project, which
    /// can span several.
    public let provider: ProviderKey?
    /// False for a value that occupies the model field without being a
    /// model, such as `<synthetic>`: shown, but left out of model shares.
    public let isModel: Bool
    public let totals: UsageTotals
    /// To the quarter hour when the row's history is compacted.
    public let lastUsed: Timestamp?

    public init(key: GroupKey, name: String, provider: ProviderKey? = nil, isModel: Bool = true,
                totals: UsageTotals, lastUsed: Timestamp?) {
        self.key = key
        self.name = name
        self.provider = provider
        self.isModel = isModel
        self.totals = totals
        self.lastUsed = lastUsed
    }
}

/// The headline figures for a range.
public struct UsageSummary: Equatable, Sendable {
    public let window: TimeWindow
    public let totals: UsageTotals
    /// Sessions active in the range. Sessions carry a provider and project but
    /// not a model, so the model filter does not narrow this count.
    public let sessions: Int
    /// Local days in the range with at least one event.
    public let activeDays: Int

    public init(window: TimeWindow, totals: UsageTotals, sessions: Int, activeDays: Int) {
        self.window = window
        self.totals = totals
        self.sessions = sessions
        self.activeDays = activeDays
    }
}
