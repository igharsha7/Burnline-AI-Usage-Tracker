//
//  SparkleUpdater.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import Foundation
@preconcurrency import Sparkle

/// Updates through Sparkle: a signed feed of versions checked once a day,
/// each download verified against the public key in Info.plist before it
/// is installed. Sparkle sends nothing about the Mac: system profiling is
/// off in Info.plist.
///
/// A scheduled check that finds an update does not interrupt: the update
/// waits in the sidebar and the popover, a gentle reminder, until it is
/// chosen. A check asked for shows Sparkle's own window at once.
final class SparkleUpdater: NSObject, Updater, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?
    private weak var model: UpdateModel?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func start(reporting model: UpdateModel) {
        self.model = model
        controller?.startUpdater()
    }

    func check() {
        // In menu-bar-only mode the app is not active, and Sparkle's window
        // would open behind the one in use.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { model?.allowedFeedChannels ?? [] }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { model?.found(version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { model?.foundNothing() }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: (any Error)?) {
        MainActor.assumeIsolated { model?.checked() }
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled updates are never shown by Sparkle; the sidebar and the
    /// popover offer them instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }
}

#if DEBUG
/// A pretend updater for a debug build given `BURNLINE_DEMO_UPDATE`, a
/// version to offer, so the update button can be seen and screenshotted
/// without a feed. Checking does nothing.
final class DemoUpdater: Updater {
    let version: String
    var automaticallyChecks = true
    var lastCheck: Date?

    init(version: String) { self.version = version }

    func start(reporting model: UpdateModel) { model.found(version) }

    func check() {}
}
#endif

extension UpdateModel {
    /// The app's updater: Sparkle in a release build that carries a feed
    /// and a public key, nothing in a debug build, which must never replace
    /// itself with a release.
    public static func live(defaults: UserDefaults,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> UpdateModel {
        let build = BuildInfo.main(environment: environment)
        #if DEBUG
        if let version = environment["BURNLINE_DEMO_UPDATE"] {
            return UpdateModel(build: build, defaults: defaults, updater: DemoUpdater(version: version))
        }
        return UpdateModel(build: build, defaults: defaults, updater: nil,
                           unavailableReason: "Development builds do not update themselves.")
        #else
        let info = Bundle.main.infoDictionary ?? [:]
        let key = info["SUPublicEDKey"] as? String ?? ""
        let feed = info["SUFeedURL"] as? String ?? ""
        guard !key.isEmpty, !feed.isEmpty else {
            return UpdateModel(build: build, defaults: defaults, updater: nil,
                               unavailableReason: "This build was not signed for updates.")
        }
        return UpdateModel(build: build, defaults: defaults, updater: SparkleUpdater())
        #endif
    }
}
