//
//  LiveIngestion.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineProviders
import BurnlineStore
import Foundation

/// The app's ingestion, assembled: the database in Application Support, every
/// provider's adapter, the reconciler that keeps the one in step with the
/// other, the pricing updater, the store's maintenance, the aggregation
/// the dashboard reads, live quota, and the notifications it raises. The app
/// holds this and never sees the store behind it.
public struct LiveIngestion: Sendable {
    public let reconciler: Reconciler
    public let pricing: PricingUpdater
    public let maintenance: StoreMaintenance
    public let aggregation: AggregationService
    public let catalog: CatalogService
    public let activity: ActivityService
    public let data: DataService
    public let quota: QuotaActor
    public let notifications: NotificationService
    public let status: StatusService
    /// Every change to usage and quota, for the interface.
    public let changes: ChangeFeed
    public let calendar: LocalCalendar

    /// `resources` holds the shared `schema` and `pricing` directories, as
    /// bundled with the app. Throws when the database cannot be opened, such
    /// as when another copy of Burnline is already writing to it.
    /// `pricingUpdates` allows the daily fetch of newer prices; `retention`
    /// is how long events are kept in full before compaction; `alerts` are
    /// the user's notification choices; `weekStart` is the user's first day
    /// of the week, nil for the locale's; `tracked` are the providers the
    /// user chose, the only ones read.
    public init(resources: URL, pricingUpdates: Bool, retention: DetailRetention, history: HistoryRetention = .default,
                alerts: AlertSettings = AlertSettingsStore().load(), weekStart: Weekday? = nil,
                tracked: Set<ProviderKey>) throws {
        let clock = SystemClock()
        // One resolver, so a repository both tools worked in is resolved once.
        let resolver = ProjectIdentityResolver()
        // Each provider's preferred source first. Codex's app-server and
        // Claude's usage endpoint see banked resets; the fallbacks do not.
        try self.init(
            resources: resources, pricingUpdates: pricingUpdates, retention: retention, history: history,
            alerts: alerts, weekStart: weekStart, tracked: tracked, location: Self.location, clock: clock,
            poster: SystemNotificationPoster(),
            readers: [
                FallbackQuotaReader([ClaudeUsageEndpointReader(clock: clock), ClaudeCodeUsageReader(clock: clock)]),
                FallbackQuotaReader([CodexAppServerReader(clock: clock), CodexRolloutQuotaReader()]),
            ],
            adapters: [ClaudeCodeAdapter(resolver: resolver), CodexAdapter(resolver: resolver), CursorAdapter()])
    }

    /// The same assembly with everything outside the process passed in:
    /// where the database lives, the clock, how notifications are shown, how
    /// quota is read and which adapters read history. Tests assemble the app
    /// here against a scratch directory and stubs.
    init(resources: URL, pricingUpdates: Bool, retention: DetailRetention, history: HistoryRetention,
         alerts: AlertSettings, weekStart: Weekday?, tracked: Set<ProviderKey>, location: StoreLocation,
         clock: any WallClock, poster: any NotificationPoster, readers: [any QuotaReader],
         adapters: [any UsageProviderAdapter]) throws {
        let schema = try Schema(directory: resources.appending(path: "schema"))
        let database = try BurnlineDatabase.open(at: location, schema: schema, clock: clock)
        try database.models.sync(ModelAliasManifest.load(
            from: resources.appending(path: "pricing/model_aliases.json")))
        pricing = PricingUpdater(
            database: database, bundled: try PricingManifest.load(from: resources.appending(path: "pricing/pricing.json")),
            cacheFile: location.directory.appending(path: "pricing.json"), enabled: pricingUpdates, clock: clock)
        maintenance = StoreMaintenance(database: database, retention: retention, history: history, clock: clock)
        let weekStart = weekStart ?? Weekday(rawValue: Calendar.current.firstWeekday) ?? .monday
        let calendar = LocalCalendar(timeZone: .current, firstWeekday: weekStart)
        self.calendar = calendar
        let changes = ChangeFeed()
        self.changes = changes
        let aggregation = AggregationService(database: database, calendar: calendar, clock: clock)
        catalog = CatalogService(database: database)
        activity = ActivityService(database: database, aggregation: aggregation, calendar: calendar, clock: clock)
        self.aggregation = aggregation
        status = StatusService(aggregation: aggregation, calendar: calendar, clock: clock)

        let notifications = NotificationService(database: database, poster: poster,
                                                aggregation: aggregation, settings: alerts, calendar: calendar,
                                                clock: clock, onAchievements: { changes.send(.achievements) })
        self.notifications = notifications
        let quota = QuotaActor(database: database, readers: readers, tracked: tracked, clock: clock, onUpdate: { await notifications.handle($0) }, onStateChange: { changes.send(.quota($0)) })
        self.quota = quota

        reconciler = Reconciler(
            ingestion: IngestionActor(database: database), adapters: adapters, tracked: tracked, clock: clock,
            onNewUsage: {
                await quota.noteUsage($0)
                changes.send(.usage($0))
                await notifications.noteUsage()
            },
            onStorageChange: { changes.send(.storage($0)) })
        data = DataService(database: database, reconciler: reconciler, changes: changes, schema: schema, clock: clock)
    }

    /// Starts tracking `provider`: its history is imported now and its quota
    /// read from here on.
    public func track(_ provider: ProviderKey) async {
        await reconciler.track(provider)
        await quota.track(provider)
    }

    /// Stages `backup` to replace the database at the next launch, for
    /// when the database could not be opened and so no `DataService`
    /// exists. The same checks apply as for any restore.
    public static func stageRestore(from backup: URL, resources: URL) throws -> RestorePlan {
        try DataService.stageRestore(from: backup, location: location,
                                     schema: Schema(directory: resources.appending(path: "schema")))
    }

    /// Withdraws a restore staged by `stageRestore(from:resources:)`.
    public static func cancelRestore() {
        DatabaseBackups.cancelStagedRestore(in: location)
        try? FileManager.default.removeItem(at: location.directory.appending(path: DataService.stagedSettingsName))
    }

    /// Where Burnline keeps the copies it takes before each update.
    public static var backupsDirectory: URL { location.backupsDirectory }

    /// Application Support, except in a debug build given
    /// `BURNLINE_STORE_DIR`, which runs the app against a throwaway database
    /// so an unreleased migration never reaches the real one.
    /// The folder the database lives in, for Settings to show.
    public static var databaseDirectory: URL { location.directory }

    static var location: StoreLocation {
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["BURNLINE_STORE_DIR"] {
            return StoreLocation(directory: URL(filePath: directory))
        }
        #endif
        return .applicationSupport
    }
}
