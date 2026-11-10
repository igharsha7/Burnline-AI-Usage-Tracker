//
//  SettingsModel.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import Foundation
import Observation

/// The user's first day of the week: the locale's, or a fixed day.
public enum WeekStart: Int, CaseIterable, Sendable {
    case system = 0
    case sunday = 1
    case monday = 2

    var title: String {
        switch self {
        case .system: "System Setting"
        case .sunday: "Sunday"
        case .monday: "Monday"
        }
    }

    /// The day the calendar starts weeks on; nil leaves it to the locale.
    public var weekday: Weekday? { self == .system ? nil : Weekday(rawValue: rawValue) }
}

/// What Settings and onboarding read and change: the user's preferences,
/// kept in the app's defaults, and the state of each provider, pricing and
/// the store. Changes apply at once where the running app can take them; a
/// week start applies at the next launch, since every range is built on it.
@Observable
public final class SettingsModel {
    public static let pricingUpdatesKey = "pricingUpdates"
    /// Days of full per-event detail; 0 keeps every event forever.
    public static let detailRetentionKey = "detailRetentionDays"
    /// Years of history kept at all; 0 keeps everything.
    public static let historyRetentionKey = "historyRetentionYears"
    public static let weekStartKey = "weekStart"
    public static let onboardedKey = "onboardingCompleted"
    public static let trackedKey = "trackedProviders"
    public static let showAchievementsKey = ActivityPreferences.showAchievementsKey
    /// The name engraved on the back of the user's medals.
    public static let nameKey = "userName"

    var alerts: AlertSettings {
        didSet {
            alertStore.save(alerts)
            let alerts = alerts
            Task { [live] in await live?.notifications.update(settings: alerts) }
        }
    }
    var pricingUpdates: Bool {
        didSet {
            defaults.set(pricingUpdates, forKey: Self.pricingUpdatesKey)
            let enabled = pricingUpdates
            Task { [live] in await live?.pricing.setEnabled(enabled) }
        }
    }
    private(set) var retention: DetailRetention
    private(set) var history: HistoryRetention
    var weekStart: WeekStart {
        didSet { defaults.set(weekStart.rawValue, forKey: Self.weekStartKey) }
    }
    /// Whether the progression surface appears anywhere in the app.
    public internal(set) var showAchievements: Bool {
        didSet { defaults.set(showAchievements, forKey: Self.showAchievementsKey) }
    }
    /// What to call the user, as typed; empty when they would rather not
    /// say. Kept in preferences on this Mac and nowhere else.
    var name: String {
        didSet { defaults.set(name, forKey: Self.nameKey) }
    }
    /// The name as engraved: trimmed, or nil when there is none.
    var engravedName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    /// Whether first-run onboarding has been finished.
    private(set) var onboarded: Bool
    /// The providers chosen for tracking, the only ones Burnline reads.
    private(set) var tracked: Set<ProviderKey>
    /// Whether each provider's tool is on this Mac, read without importing.
    private(set) var detections: [ProviderKey: ProviderDetection] = [:]

    private(set) var permission: NotificationPermission?
    private(set) var imports: [ProviderKey: ImportResult] = [:]
    private(set) var health: [ProviderKey: ProviderHealth] = [:]
    /// Sessions known per provider, for onboarding's import progress.
    private(set) var sessions: [ProviderKey: Int] = [:]
    private(set) var trackingStart: Timestamp?
    private(set) var priceVersions: Int?
    private(set) var pricesFetchedAt: Timestamp?
    /// What the last Check Now found, in words.
    private(set) var pricingOutcome: String?
    private(set) var databaseBytes: Int64?
    private(set) var busy = false
    /// What the last data action did, in words, and whether it failed.
    private(set) var dataOutcome: (text: String, failed: Bool)?
    /// Projects the user can delete, by name.
    private(set) var projects: [Project] = []
    /// Quits and reopens the app, for a restore. Set by the app.
    @ObservationIgnored public var relaunch: (() -> Void)?

    @ObservationIgnored private var live: LiveIngestion?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let alertStore: AlertSettingsStore
    @ObservationIgnored let clock: any WallClock

    public init(defaults: UserDefaults = .standard, alertStore: AlertSettingsStore = AlertSettingsStore(),
                clock: any WallClock = SystemClock()) {
        self.defaults = defaults
        self.alertStore = alertStore
        self.clock = clock
        alerts = alertStore.load()
        pricingUpdates = defaults.object(forKey: Self.pricingUpdatesKey) as? Bool ?? true
        retention = (defaults.object(forKey: Self.detailRetentionKey) as? Int).map(DetailRetention.init(days:)) ?? .default
        history = HistoryRetention(years: defaults.integer(forKey: Self.historyRetentionKey))
        weekStart = WeekStart(rawValue: defaults.integer(forKey: Self.weekStartKey)) ?? .system
        showAchievements = defaults.object(forKey: Self.showAchievementsKey) as? Bool ?? true
        name = defaults.string(forKey: Self.nameKey) ?? ""
        onboarded = defaults.bool(forKey: Self.onboardedKey)
        tracked = Self.tracked(in: defaults)
    }

    /// The saved choice. Before there was a choice, everyone onboarded
    /// tracked every provider, so they keep doing so; a new user tracks
    /// nothing until onboarding asks.
    static func tracked(in defaults: UserDefaults) -> Set<ProviderKey> {
        if let saved = defaults.stringArray(forKey: trackedKey) { return Set(saved.compactMap(ProviderKey.init(rawValue:))) }
        return defaults.bool(forKey: onboardedKey) ? Set(ProviderKey.trackable) : []
    }

    /// Starts tracking `providers`, importing their history now. Saved first,
    /// so a choice made before ingestion connects applies when it does.
    func track(_ providers: some Collection<ProviderKey>) async {
        tracked.formUnion(providers)
        defaults.set(tracked.map(\.rawValue).sorted(), forKey: Self.trackedKey)
        if let live {
            for provider in providers { await live.track(provider) }
        }
        await reload()
    }

    /// The medals importing found: every one added since `moment`, judged
    /// now, however long ago it was earned. Empty before ingestion connects.
    func foundMedals(since moment: Timestamp) async -> [Achievement] {
        guard let live else { return [] }
        return (try? await Self.found(live.activity, since: moment)) ?? []
    }

    /// Marks medals the user has just been shown, so they do not play their
    /// arrival again.
    func celebrate(_ medals: [Achievement]) async {
        guard let live, !medals.isEmpty else { return }
        try? await Self.celebrate(live.activity, medals)
    }

    @concurrent
    private static func found(_ activity: ActivityService, since moment: Timestamp) async throws -> [Achievement] {
        try activity.found(since: moment)
    }

    @concurrent
    private static func celebrate(_ activity: ActivityService, _ medals: [Achievement]) async throws {
        try activity.celebrate(medals)
    }

    /// What launch builds ingestion with.
    public var launchPricingUpdates: Bool { pricingUpdates }
    public var launchRetention: DetailRetention { retention }
    public var launchHistory: HistoryRetention { history }
    public var launchWeekStart: Weekday? { weekStart.weekday }
    public var isOnboarded: Bool { onboarded }
    public var launchTracked: Set<ProviderKey> { tracked }

    public func connect(_ live: LiveIngestion) {
        self.live = live
        Task {
            // A choice made while ingestion was still opening.
            for provider in tracked { await live.track(provider) }
            await reload()
        }
    }

    public var databaseDirectory: URL { LiveIngestion.databaseDirectory }

    /// Reads everything shown again. Cheap: counts and file sizes.
    func reload() async {
        guard let live else { return }
        permission = await live.notifications.permission()
        imports = await live.reconciler.latest
        health = await live.reconciler.health()
        detections = await live.reconciler.detections()
        (priceVersions, pricesFetchedAt) = await live.pricing.info()
        databaseBytes = Self.size(of: databaseDirectory)
        projects = ((try? await Self.projects(live.catalog)) ?? []).filter { $0.mergedIntoID == nil }
        let figures = try? await Self.figures(live.aggregation)
        trackingStart = figures?.start
        sessions = figures?.sessions ?? [:]
    }

    /// Reads only what shows an import's progress: each provider's health,
    /// its sessions so far, and where history begins. Polled while importing,
    /// where the full `reload` would walk the database folder and list every
    /// project each second, competing with the import for the database.
    func reloadProgress() async {
        guard let live else { return }
        health = await live.reconciler.health()
        let figures = try? await Self.figures(live.aggregation)
        trackingStart = figures?.start
        sessions = figures?.sessions ?? [:]
    }

    @concurrent
    private static func figures(_ aggregation: AggregationService) async throws
        -> (start: Timestamp?, sessions: [ProviderKey: Int]) {
        var sessions: [ProviderKey: Int] = [:]
        for provider in ProviderKey.allCases {
            sessions[provider] = try aggregation.sessions(.all, filters: UsageFilters(providers: [provider]))
        }
        return (try aggregation.trackingStart(), sessions)
    }

    @concurrent
    private static func projects(_ catalog: CatalogService) async throws -> [Project] {
        try catalog.projects()
    }

    private static func size(of directory: URL) -> Int64? {
        let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        return files?.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: Actions

    /// Syncs every provider's history now, as after a missed change.
    func rescan() async {
        guard let live, !busy else { return }
        busy = true
        defer { busy = false }
        await live.reconciler.reconcile()
        await reload()
    }

    func refreshQuota() async {
        await live?.quota.refreshAll()
    }

    func checkPrices() async {
        guard let live else { return }
        pricingOutcome = switch await live.pricing.refresh(force: true) {
        case .disabled: "Price updates are off."
        case .fresh, .unchanged: "Prices are up to date."
        case .updated(let versions, let repriced):
            "Added \(versions) price \(versions == 1 ? "change" : "changes"); \(repriced) events re-priced."
        case .failed(let reason): "Could not check: \(reason)"
        }
        await reload()
    }

    /// Whether moving to `new` compacts history that `old` kept in full,
    /// which Settings confirms first.
    static func shrinks(from old: DetailRetention, to new: DetailRetention) -> Bool {
        shrinks(from: old.window, to: new.window)
    }

    /// Whether moving to `new` deletes history `old` kept.
    static func shrinks(from old: HistoryRetention, to new: HistoryRetention) -> Bool {
        shrinks(from: old.window, to: new.window)
    }

    /// Windows in seconds, nil for forever.
    private static func shrinks(from old: Int64?, to new: Int64?) -> Bool {
        guard let new else { return false }
        return old.map { new < $0 } ?? true
    }

    /// Applies a new detail window. A shrink compacts at once; what it
    /// removes is per-event detail, and cannot be brought back.
    func change(retention: DetailRetention) async {
        self.retention = retention
        defaults.set(retention.rawValue, forKey: Self.detailRetentionKey)
        guard let live else { return }
        busy = true
        await live.maintenance.change(to: retention)
        busy = false
        await reload()
    }

    /// Sends the test notification, asking for permission first if it was
    /// never asked: the user has just said why they want it.
    func testNotification() async {
        guard let live else { return }
        permission = await live.notifications.sendTest()
    }

    /// A shorter history span deletes what falls outside it, at once.
    func change(history: HistoryRetention) async {
        self.history = history
        defaults.set(history.rawValue, forKey: Self.historyRetentionKey)
        guard let live else { return }
        await perform("Deleting older history…") {
            await live.maintenance.change(history: history)
            return history == .forever ? "Burnline keeps all history." : "History older than that was deleted."
        }
    }

    // MARK: Data

    /// Runs one data action, one at a time, reporting what it did or why
    /// it failed.
    private func perform(_ working: String, _ action: () async throws -> String) async {
        guard !busy else { return }
        busy = true
        dataOutcome = (working, false)
        do {
            dataOutcome = (try await action(), false)
        } catch {
            dataOutcome = (Self.describe(error), true)
        }
        busy = false
        await reload()
    }

    func export(_ dataset: ExportDataset, as format: ExportFormat, to file: URL) async {
        guard let data = live?.data else { return }
        await perform("Exporting…") {
            let rows = try await data.export(dataset, as: format, to: file)
            return "Exported \(rows.formatted()) \(rows == 1 ? "row" : "rows") to \(file.lastPathComponent)."
        }
    }

    func backup(to folder: URL) async {
        guard let data = live?.data else { return }
        let settings = PreferenceBackup.export(from: defaults)
        let destination = Self.unused(folder)
        await perform("Backing up…") {
            try await data.backup(to: destination, settings: settings)
            return "Backed up to \(destination.lastPathComponent)."
        }
    }

    /// A failure in words: the system's own for a file error, Burnline's
    /// for its database.
    static func describe(_ error: any Error) -> String {
        let system = error as NSError
        if system.domain == NSCocoaErrorDomain || system.domain == NSPOSIXErrorDomain {
            return system.localizedDescription
        }
        return switch StoreFailure(error) {
        case .other(let reason): reason.prefix(1).uppercased() + reason.dropFirst()
        case let failure: failure.title + "."
        }
    }

    /// `folder`, or the first "name 2", "name 3" beside it that is free: a
    /// backup never writes into, or replaces, a folder that already exists,
    /// even one the save panel offered to replace.
    static func unused(_ folder: URL) -> URL {
        let manager = FileManager.default
        var candidate = folder
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = folder.deletingLastPathComponent().appending(path: "\(folder.lastPathComponent) \(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// Checks a backup and stages it; the caller confirms before relaunching.
    func stageRestore(from backup: URL) async -> RestorePlan? {
        guard let data = live?.data else { return nil }
        do {
            return try await data.stageRestore(from: backup)
        } catch {
            dataOutcome = (RestoreText.refusal(error), true)
            return nil
        }
    }

    func cancelRestore() {
        live?.data.cancelRestore()
    }

    func delete(_ scope: DeletionScope) async {
        guard let data = live?.data else { return }
        await perform("Deleting…") {
            let report = try await data.delete(scope)
            return "Deleted \(report.events.formatted()) \(report.events == 1 ? "event" : "events") and "
                + "\(report.sessions.formatted()) \(report.sessions == 1 ? "session" : "sessions")."
        }
    }

    func repair(_ action: RepairAction) async {
        guard let data = live?.data else { return }
        await perform(action.working) {
            switch action {
            case .rescan:
                try await data.rescanFromStart()
                return "Re-read every provider's history."
            case .rebuildTotals:
                try await data.rebuildTotals()
                return "Rebuilt the totals from the events."
            case .modelNames:
                let moved = try await data.reapplyModelNames()
                return moved == 0 ? "Every event already has its right model."
                    : "Moved \(moved.formatted()) events to their models and re-priced them."
            case .prices:
                let repriced = try await data.recalculatePrices()
                return "Re-priced \(repriced.formatted()) events at the prices of their time."
            case .check:
                let check = try await data.check()
                return check.isHealthy ? "The database is healthy." : check.problems.joined(separator: "\n")
            }
        }
    }

    /// The diagnostics report, for the user to paste into a bug report.
    func diagnostics() async -> String? {
        guard let data = live?.data else { return nil }
        let settings = [
            "Detail window: \(retention.rawValue == 0 ? "forever" : "\(retention.rawValue) days")",
            "History: \(history.rawValue == 0 ? "forever" : "\(history.rawValue) years")",
            "Price updates: \(pricingUpdates ? "on" : "off")",
            "Notifications: \(permission.map { "\($0)" } ?? "unknown")",
        ]
        return await data.diagnostics(app: AboutView.version, settings: settings)
    }

    func finishOnboarding() {
        onboarded = true
        defaults.set(true, forKey: Self.onboardedKey)
    }
}

/// The manual repairs Settings offers.
enum RepairAction: CaseIterable {
    case rescan, rebuildTotals, modelNames, prices, check

    var title: String {
        switch self {
        case .rescan: "Re-scan from the Start"
        case .rebuildTotals: "Rebuild Totals"
        case .modelNames: "Re-apply Model Names"
        case .prices: "Recalculate Prices"
        case .check: "Check Database"
        }
    }

    var detail: String {
        switch self {
        case .rescan: "Reads every provider's history again. Deleted usage still in their files comes back."
        case .rebuildTotals: "Recomputes the quarter-hour totals from the events behind them."
        case .modelNames: "Applies model names Burnline learned since events arrived, then re-prices them."
        case .prices: "Re-prices every event at the price in force when it happened, never today's."
        case .check: "Checks the file and that every total agrees with what it sums."
        }
    }

    var working: String {
        switch self {
        case .rescan: "Re-reading history…"
        case .rebuildTotals: "Rebuilding totals…"
        case .modelNames: "Re-applying model names…"
        case .prices: "Recalculating prices…"
        case .check: "Checking…"
        }
    }
}
