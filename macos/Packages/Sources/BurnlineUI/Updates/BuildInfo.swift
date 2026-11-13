//
//  BuildInfo.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// A release channel. Stable is every release; nightly adds a build of the
/// newest work each time it is merged. See docs/updates.md.
public enum UpdateChannel: String, CaseIterable, Sendable {
    case stable
    case nightly

    var title: String {
        switch self {
        case .stable: "Stable"
        case .nightly: "Nightly"
        }
    }

    /// The feed channels an updater on this channel accepts, beyond the
    /// default one every stable release is published in. Nightly takes
    /// both, so a stable release newer than the last nightly still arrives.
    var feedChannels: Set<String> {
        switch self {
        case .stable: []
        case .nightly: [UpdateChannel.nightly.rawValue]
        }
    }
}

/// What this build is: its channel, its version, and for a nightly the day
/// it was built, read from the bundle's Info.plist.
public struct BuildInfo: Equatable, Sendable {
    /// The Info.plist key the `BURNLINE_CHANNEL` build setting fills.
    static let channelKey = "BurnlineChannel"

    public let channel: UpdateChannel
    /// The version people see, such as `0.1.0` or `0.2.0-nightly.20261111`.
    public let version: String
    /// The build number, which rises with every published build of either channel.
    public let build: String?
    /// The day a nightly was built, from its version's suffix.
    public let nightlyDate: DateComponents?

    public init(info: [String: Any]) {
        let version = info["CFBundleShortVersionString"] as? String ?? "development"
        let channel = (info[Self.channelKey] as? String).flatMap(UpdateChannel.init(rawValue:)) ?? .stable
        self.channel = channel
        self.version = version
        self.build = info["CFBundleVersion"] as? String
        self.nightlyDate = channel == .nightly ? Self.nightlyDate(in: version) : nil
    }

    /// This app's build. A debug build given `BURNLINE_CHANNEL` takes that
    /// channel instead, so the nightly look can be tried without a nightly.
    public static func main(environment: [String: String] = ProcessInfo.processInfo.environment) -> BuildInfo {
        var info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        if let channel = environment["BURNLINE_CHANNEL"] { info[channelKey] = channel }
        #endif
        return BuildInfo(info: info)
    }

    public var isNightly: Bool { channel == .nightly }

    /// The version and build number together, as About shows them.
    var fullVersion: String { build.map { "\(version) (\($0))" } ?? version }

    /// The version for a diagnostics report, saying the channel when it is not stable.
    var diagnosticVersion: String { isNightly ? "\(fullVersion), nightly" : fullVersion }

    /// The nightly's day as a short date, such as "Nov 11", or nil.
    var nightlyDay: String? {
        guard let nightlyDate, let date = Calendar(identifier: .gregorian).date(from: nightlyDate) else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The `yyyymmdd` after "nightly." in a version such as `0.2.0-nightly.20261111`.
    static func nightlyDate(in version: String) -> DateComponents? {
        guard let match = version.firstMatch(of: /nightly\.(\d{4})(\d{2})(\d{2})/),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }
}
