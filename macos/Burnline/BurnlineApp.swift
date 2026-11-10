//
//  BurnlineApp.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import BurnlineServices
import BurnlineUI
import os
import SwiftUI
import UserNotifications

/// The composition root: the dashboard window and the menu-bar item.
@main
struct BurnlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One dashboard over one model: a Window, so File has no New Window.
        Window("Usage", id: SceneID.dashboard) {
            DashboardWindow(dashboard: appDelegate.dashboard, status: appDelegate.status, settings: appDelegate.settings)
                .environment(appDelegate.updates)
        }
        .defaultSize(width: 1120, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            AboutCommand()
            UpdateCommands(updates: appDelegate.updates)
            DashboardCommands(model: appDelegate.dashboard, settings: appDelegate.settings)
        }

        Settings {
            SettingsView(settings: appDelegate.settings, status: appDelegate.status)
                .environment(appDelegate.updates)
        }

        Window("About Burnline", id: SceneID.about) {
            AboutView()
                .environment(appDelegate.updates)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 640)

        MenuBarExtra {
            PopoverView(model: appDelegate.status)
                .environment(appDelegate.updates)
        } label: {
            MenuBarLabel(model: appDelegate.status)
                .environment(appDelegate.updates)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "io.github.igharsha7.Burnline", category: "ingestion")
    private var ingestion: Task<Void, Never>?
    private var pricingUpdates: Task<Void, Never>?
    private var storeMaintenance: Task<Void, Never>?
    private var quotaUpdates: Task<Void, Never>?
    private var maintenance: StoreMaintenance?
    private var wakeObserver: (any NSObjectProtocol)?
    /// What the menu bar shows. Built empty at launch so the scenes can use
    /// it at once, and connected once ingestion is up.
    let status = StatusModel()
    /// What the dashboard shows, connected the same way.
    let dashboard: DashboardModel
    /// Preferences, onboarding and the Settings window's figures.
    let settings: SettingsModel
    /// In-app updates and the channel followed.
    let updates: UpdateModel

    override init() {
        // A restore chosen before the last quit brings its settings; they
        // are set before anything reads them. Its database is swapped in
        // when the store opens.
        if let staged = DataService.takeStagedSettings(in: LiveIngestion.databaseDirectory) {
            PreferenceBackup.apply(staged)
        }
        dashboard = DashboardModel()
        settings = SettingsModel(defaults: Self.settingsDefaults)
        updates = UpdateModel.live(defaults: Self.settingsDefaults)
        super.init()
        settings.relaunch = { Self.relaunch() }
    }

    /// Where Settings keeps its preferences: the user's own, except in a
    /// debug build given `BURNLINE_DEFAULTS_SUITE`, which keeps them, with
    /// onboarding and the providers chosen, in a domain of its own, so the
    /// first run can be tried without touching the real ones.
    private static var settingsDefaults: UserDefaults {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["BURNLINE_DEFAULTS_SUITE"],
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        #endif
        return .standard
    }

    /// Quits, and opens Burnline again once this process has gone, so the
    /// new one can take the writer lock. A debug build passes its scratch
    /// store and Keychain choice on, so a relaunch stays on the same store.
    private static func relaunch() {
        var arguments = ["-n"]
        #if DEBUG
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("BURNLINE_") {
            arguments += ["--env", "\(key)=\(value)"]
        }
        #endif
        arguments.append(Bundle.main.bundleURL.path)
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        waiter.arguments = ["-c", "while /bin/kill -0 $0 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$@\"",
                            String(ProcessInfo.processInfo.processIdentifier)] + arguments
        do {
            try waiter.run()
            NSApp.terminate(nil)
        } catch {
            Logger(subsystem: "io.github.igharsha7.Burnline", category: "restore")
                .error("Could not reopen: \(String(describing: error), privacy: .public)")
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Burnline is dark only: every window, the popover, Settings and
        // About, whatever the system appearance. Set before any window opens.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Both channels share one bundle identifier, so an update can move
        // between them, and macOS caches the Dock icon by identifier. A
        // nightly sets its own, so it never shows the release's.
        if updates.build.isNightly { NSApp.applicationIconImage = AboutView.icon }
        DockPresence.apply(menuBarOnly: DockPresence.isMenuBarOnly)
        // Set before launch finishes, so a click that launched the app arrives.
        UNUserNotificationCenter.current().delegate = self
    }

    /// In menu-bar-only mode, as when launched at login that way, the
    /// dashboard does not open by itself.
    private func closeDashboardIfMenuBarOnly() {
        // The first run always shows onboarding.
        guard DockPresence.isMenuBarOnly, settings.isOnboarded else { return }
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(SceneID.dashboard) == true {
                window.close()
            }
        }
    }

    /// Opens the store off the main thread, applies the bundled prices,
    /// imports what is new since the last run, then
    /// keeps watching, with the store maintained once a day, quota read on
    /// its own schedule, and its updates turned into notifications. After
    /// every wake, history is synced first, to make up for missed file
    /// events, then quota is read before any
    /// reset is judged.
    func applicationDidFinishLaunching(_ notification: Notification) {
        closeDashboardIfMenuBarOnly()
        guard let resources = Bundle.main.resourceURL else { return }
        let updates = settings.launchPricingUpdates, retention = settings.launchRetention
        let history = settings.launchHistory
        let weekStart = settings.launchWeekStart
        let tracked = settings.launchTracked
        let log = log
        ingestion = Task {
            // Opening the store and reading the price history take tens of
            // milliseconds, so they run off the main thread; the menu bar and
            // dashboard show their loading state until they connect.
            let live: LiveIngestion
            do {
                live = try await Self.makeIngestion(resources: resources, pricingUpdates: updates, retention: retention,
                                                    history: history, weekStart: weekStart, tracked: tracked)
            } catch {
                log.error("Ingestion did not start: \(String(describing: error), privacy: .public)")
                fail(StoreFailure(error), resources: resources)
                return
            }
            // The comparisons are texture: without the corpus they are left
            // out, and everything else runs.
            let corpus: ComparisonCorpus?
            do {
                corpus = try await Self.loadCorpus(resources: resources)
            } catch {
                log.error("Comparisons are off: \(String(describing: error), privacy: .public)")
                corpus = nil
            }
            await start(live, corpus: corpus)
        }
    }

    @concurrent
    private static func loadCorpus(resources: URL) async throws -> ComparisonCorpus {
        try ComparisonCorpus.load(from: resources.appending(path: "corpus/comparisons.json"))
    }

    /// The database did not open. The menu bar and dashboard say why and
    /// offer the ways out, rather than waiting for figures that never come;
    /// in menu-bar-only mode the dashboard opens so it is seen.
    private func fail(_ failure: StoreFailure, resources: URL) {
        status.fail(failure)
        dashboard.fail(failure, recovery: StoreRecovery(
            databaseFolder: LiveIngestion.databaseDirectory, backupsFolder: LiveIngestion.backupsDirectory,
            stageRestore: { try LiveIngestion.stageRestore(from: $0, resources: resources) },
            cancelRestore: LiveIngestion.cancelRestore, relaunch: { Self.relaunch() }))
    }

    @concurrent
    private static func makeIngestion(resources: URL, pricingUpdates: Bool, retention: DetailRetention,
                                      history: HistoryRetention, weekStart: Weekday?,
                                      tracked: Set<ProviderKey>) async throws -> LiveIngestion {
        try LiveIngestion(resources: resources, pricingUpdates: pricingUpdates, retention: retention, history: history,
                          weekStart: weekStart, tracked: tracked)
    }

    private func start(_ live: LiveIngestion, corpus: ComparisonCorpus?) async {
        let reconciler = live.reconciler
        let pricing = live.pricing
        let maintenance = live.maintenance
        let quota = live.quota
        // One engine, so the dashboard and the menu bar share its rotation.
        let comparisons = corpus.map { ComparisonEngine(corpus: $0, recents: UserDefaultsRecentStore()) }
        status.comparisons = comparisons
        status.connect(status: live.status, quota: quota, changes: live.changes, calendar: live.calendar)
        dashboard.connect(aggregation: live.aggregation, catalog: live.catalog, activity: live.activity,
                          changes: live.changes, health: { await reconciler.health() }, calendar: live.calendar,
                          comparisons: comparisons)
        if let corpus { await live.notifications.use(milestones: corpus) }
        settings.connect(live)
        self.maintenance = maintenance
        let log = log
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task {
                await reconciler.reconcile()
                await quota.refreshAll()
            }
        }
        do { try await pricing.applyLocal() } catch {
            log.error("Bundled prices were not applied: \(String(describing: error), privacy: .public)")
        }
        pricingUpdates = Task { await pricing.run() }
        await reconciler.reconcile()
        // Health is known only once every provider has synced.
        dashboard.refresh()
        quotaUpdates = Task { await quota.run() }
        storeMaintenance = Task { await maintenance.run() }
        for result in await reconciler.latest.values {
            log.info("""
                Synced \(result.provider.rawValue, privacy: .public): \(result.filesRead) files read, \
                \(result.filesUnchanged) unchanged, \(result.eventsWritten) events written
                """)
        }
        await reconciler.run()
    }

    func applicationWillTerminate(_ notification: Notification) {
        maintenance?.atQuit()
    }

    /// Closing the dashboard leaves the menu-bar item running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// A click on a medal's notification opens the Achievements page, which
    /// plays the medal's arrival. Other notifications only bring the app up.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        guard identifier.hasPrefix(NotificationService.achievementPrefix) else { return }
        await MainActor.run {
            guard settings.showAchievements else { return }
            dashboard.showAchievements()
            status.requestDashboard()
        }
    }
}
