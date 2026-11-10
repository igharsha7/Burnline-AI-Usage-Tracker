//
//  UpdateModel.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation
import Observation

/// What checks for, offers and installs updates. Sparkle in a release
/// build; tests and demos pass their own.
public protocol Updater: AnyObject {
    var automaticallyChecks: Bool { get set }
    var lastCheck: Date? { get }
    /// Begins the scheduled checks. Called once, after the model is set.
    func start(reporting model: UpdateModel)
    /// Checks now, and shows what it finds, including an update already found.
    func check()
}

/// In-app updates as the interface sees them: whether an update is waiting,
/// the channel followed, and whether checks run by themselves. The sidebar,
/// the popover, the app menu and Settings all read this one model.
@Observable
public final class UpdateModel {
    static let channelKey = "updates.channel"

    public let build: BuildInfo
    /// The version found and not yet installed, offered in the sidebar and
    /// the popover until it is installed or a check finds nothing.
    public private(set) var available: String?
    /// Why this build cannot update itself, or nil when it can.
    public let unavailableReason: String?
    public private(set) var lastCheck: Date?

    /// The channel followed. A nightly build follows nightly until told otherwise.
    public var channel: UpdateChannel {
        didSet { defaults.set(channel.rawValue, forKey: Self.channelKey) }
    }

    public var automaticallyChecks: Bool {
        didSet { updater?.automaticallyChecks = automaticallyChecks }
    }

    @ObservationIgnored private let updater: (any Updater)?
    @ObservationIgnored private let defaults: UserDefaults

    /// `updater` is nil when this build cannot update, and `unavailableReason` says why.
    public init(build: BuildInfo, defaults: UserDefaults, updater: (any Updater)?, unavailableReason: String? = nil) {
        self.build = build
        self.defaults = defaults
        self.updater = updater
        self.unavailableReason = updater == nil ? unavailableReason ?? "This build cannot update itself." : nil
        channel = defaults.string(forKey: Self.channelKey).flatMap(UpdateChannel.init(rawValue:)) ?? build.channel
        automaticallyChecks = updater?.automaticallyChecks ?? false
        lastCheck = updater?.lastCheck
        updater?.start(reporting: self)
    }

    public var canCheck: Bool { updater != nil }

    /// The feed channels the updater may take versions from.
    public var allowedFeedChannels: Set<String> { channel.feedChannels }

    public func check() {
        updater?.check()
    }

    /// Moving onto nightly is asked about first: a nightly can migrate the
    /// database past what a stable release reads.
    func needsConfirmation(toFollow next: UpdateChannel) -> Bool {
        next == .nightly && build.channel == .stable && channel == .stable
    }

    /// What following `channel` means for this build, when it is not obvious.
    var channelNote: String? {
        switch (build.channel, channel) {
        case (.nightly, .stable):
            "This nightly stays until a stable release is newer. To go back to an older stable version, restore a backup "
                + "taken before the nightly."
        case (_, .nightly):
            "Nightly builds carry the newest work before a release, and can change the database in ways a stable "
                + "release does not yet read."
        default: nil
        }
    }

    // The updater's reports.

    public func found(_ version: String) { available = version }

    public func foundNothing() { available = nil }

    public func checked() { lastCheck = updater?.lastCheck }
}
