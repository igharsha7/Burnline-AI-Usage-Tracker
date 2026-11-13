//
//  UpdateTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

@testable import BurnlineUI
import Foundation
import Testing

/// In-app updates: which build this is, the channel it follows, what it
/// offers, and what it asks before moving to nightly.
struct UpdateTests {
    /// An updater that records what it is asked and reports what a test tells it.
    final class FakeUpdater: Updater {
        var automaticallyChecks = true
        var lastCheck: Date?
        var checks = 0
        var startedWith: UpdateModel?

        func start(reporting model: UpdateModel) { startedWith = model }
        func check() { checks += 1 }
    }

    static func nightly(_ version: String = "0.2.0-nightly.20261111") -> BuildInfo {
        BuildInfo(info: ["CFBundleShortVersionString": version, "CFBundleVersion": "42", "BurnlineChannel": "nightly"])
    }

    static let stable = BuildInfo(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7",
                                         "BurnlineChannel": "stable"])

    @Test func `a nightly build reads its channel and the day it was built from its version`() {
        let build = Self.nightly()
        #expect(build.channel == .nightly && build.fullVersion == "0.2.0-nightly.20261111 (42)")
        #expect(build.nightlyDate == DateComponents(year: 2026, month: 11, day: 11))
        #expect(build.diagnosticVersion == "0.2.0-nightly.20261111 (42), nightly")
    }

    @Test func `a build without a channel, or with an unknown one, is stable and has no nightly day`() {
        let plain = BuildInfo(info: ["CFBundleShortVersionString": "0.1.0"])
        #expect(plain.channel == .stable && plain.fullVersion == "0.1.0" && plain.nightlyDate == nil)
        #expect(BuildInfo(info: ["BurnlineChannel": "beta"]).channel == .stable)
        #expect(BuildInfo(info: ["BurnlineChannel": "$(BURNLINE_CHANNEL)"]).version == "development")
        #expect(Self.nightly("0.2.0-nightly.20261399").nightlyDate == nil)
    }

    @Test func `a nightly build follows nightly until told otherwise, and the choice is kept`() {
        let (defaults, _) = SettingsTests.defaults()
        let model = UpdateModel(build: Self.nightly(), defaults: defaults, updater: FakeUpdater())
        #expect(model.channel == .nightly && model.allowedFeedChannels == ["nightly"])

        model.channel = .stable
        #expect(model.allowedFeedChannels.isEmpty)
        #expect(UpdateModel(build: Self.nightly(), defaults: defaults, updater: FakeUpdater()).channel == .stable)
    }

    @Test func `a nightly copy that updates to a stable release keeps following nightly`() {
        let (defaults, _) = SettingsTests.defaults()
        _ = UpdateModel(build: Self.nightly(), defaults: defaults, updater: FakeUpdater())

        let updated = UpdateModel(build: Self.stable, defaults: defaults, updater: FakeUpdater())
        #expect(updated.channel == .nightly && updated.allowedFeedChannels == ["nightly"])
    }

    @Test func `a stable copy follows stable from its first run`() {
        let (defaults, _) = SettingsTests.defaults()
        _ = UpdateModel(build: Self.stable, defaults: defaults, updater: FakeUpdater())
        #expect(UpdateModel(build: Self.nightly(), defaults: defaults, updater: FakeUpdater()).channel == .stable)
    }

    @Test func `only a stable build moving onto nightly is asked to confirm`() {
        let (defaults, _) = SettingsTests.defaults()
        let stable = UpdateModel(build: Self.stable, defaults: defaults, updater: FakeUpdater())
        #expect(stable.needsConfirmation(toFollow: .nightly))
        #expect(!stable.needsConfirmation(toFollow: .stable))

        let (otherDefaults, _) = SettingsTests.defaults()
        let nightly = UpdateModel(build: Self.nightly(), defaults: otherDefaults, updater: FakeUpdater())
        nightly.channel = .stable
        #expect(!nightly.needsConfirmation(toFollow: .nightly))
    }

    @Test func `a nightly build following stable is told it stays until a stable release is newer`() {
        let (defaults, _) = SettingsTests.defaults()
        let model = UpdateModel(build: Self.nightly(), defaults: defaults, updater: FakeUpdater())
        model.channel = .stable
        #expect(model.channelNote?.hasPrefix("This nightly stays until a stable release is newer.") == true)
    }

    @Test func `a stable build following nightly says it is stable until the next nightly is built`() {
        let (defaults, _) = SettingsTests.defaults()
        let model = UpdateModel(build: Self.stable, defaults: defaults, updater: FakeUpdater())
        model.channel = .nightly
        #expect(model.channelNote == "You're running a stable release, so it looks like one. The next nightly is "
            + "offered once one is built newer than this. Nightly builds carry the newest work before a release, "
            + "and can change the database in ways a stable release does not yet read.")
    }

    @Test func `an update found is offered until a check finds nothing`() {
        let (defaults, _) = SettingsTests.defaults()
        let updater = FakeUpdater()
        let model = UpdateModel(build: Self.stable, defaults: defaults, updater: updater)
        #expect(updater.startedWith === model && model.available == nil)

        model.found("0.2.0")
        #expect(model.available == "0.2.0")
        model.check()
        #expect(updater.checks == 1)
        model.foundNothing()
        #expect(model.available == nil)
    }

    @Test func `turning daily checks off reaches the updater, and the last check is read after each cycle`() {
        let (defaults, _) = SettingsTests.defaults()
        let updater = FakeUpdater()
        let model = UpdateModel(build: Self.stable, defaults: defaults, updater: updater)
        model.automaticallyChecks = false
        #expect(!updater.automaticallyChecks)

        let when = Date(timeIntervalSince1970: 1_793_541_600)
        updater.lastCheck = when
        model.checked()
        #expect(model.lastCheck == when)
    }

    @Test func `a build that cannot update says why and offers no check`() {
        let (defaults, _) = SettingsTests.defaults()
        let model = UpdateModel(build: Self.stable, defaults: defaults, updater: nil,
                                unavailableReason: "Development builds do not update themselves.")
        #expect(!model.canCheck && !model.automaticallyChecks)
        #expect(model.unavailableReason == "Development builds do not update themselves.")
        model.check()
        #expect(model.available == nil)
    }
}
