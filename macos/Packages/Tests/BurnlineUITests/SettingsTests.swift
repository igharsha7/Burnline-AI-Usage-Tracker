//
//  SettingsTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
@testable import BurnlineUI
import BurnlineTestSupport
import Foundation
import Testing

/// The preferences Settings keeps, and the rules around them.
struct SettingsTests {
    /// A scratch defaults domain and its name, so tests never touch the app's.
    static func defaults() -> (UserDefaults, String) {
        let name = "BurnlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test func `EC-U6 a fresh profile starts in onboarding, with the defaults`() {
        let (defaults, name) = Self.defaults()
        let settings = SettingsModel(defaults: defaults, alertStore: AlertSettingsStore(suiteName: name))
        #expect(!settings.isOnboarded)
        #expect(settings.launchPricingUpdates && settings.launchRetention == .default && settings.launchWeekStart == nil)
        #expect(settings.showAchievements)
        #expect(settings.alerts == AlertSettings())
    }

    @Test func `a new user tracks nothing until onboarding asks, and someone already onboarded keeps every provider`() {
        let (fresh, name) = Self.defaults()
        #expect(SettingsModel(defaults: fresh, alertStore: AlertSettingsStore(suiteName: name)).launchTracked.isEmpty)

        let (existing, other) = Self.defaults()
        existing.set(true, forKey: SettingsModel.onboardedKey)
        #expect(SettingsModel(defaults: existing, alertStore: AlertSettingsStore(suiteName: other)).launchTracked
                    == Set(ProviderKey.trackable))
    }

    @Test func `the providers chosen are kept for the next launch`() async {
        let (defaults, name) = Self.defaults()
        let store = AlertSettingsStore(suiteName: name)
        await SettingsModel(defaults: defaults, alertStore: store).track([.codex])
        #expect(SettingsModel(defaults: defaults, alertStore: store).launchTracked == [.codex])
    }

    @Test func `choices are kept for the next launch`() {
        let (defaults, name) = Self.defaults()
        let store = AlertSettingsStore(suiteName: name)
        let settings = SettingsModel(defaults: defaults, alertStore: store)
        settings.pricingUpdates = false
        settings.weekStart = .sunday
        settings.alerts.burnRate = false
        settings.showAchievements = false
        settings.finishOnboarding()

        let relaunched = SettingsModel(defaults: defaults, alertStore: store)
        #expect(!relaunched.launchPricingUpdates && relaunched.launchWeekStart == .sunday)
        #expect(!relaunched.alerts.burnRate && relaunched.isOnboarded)
        #expect(!relaunched.showAchievements)
        #expect(WeekStart.monday.weekday == .monday && WeekStart.system.weekday == nil)
    }

    @Test func `Claude Code's login is read by default, and turning it off is kept`() {
        let (defaults, name) = Self.defaults()
        let store = AlertSettingsStore(suiteName: name)
        let settings = SettingsModel(defaults: defaults, alertStore: store)
        #expect(settings.readClaudeLogin && settings.launchClaudeLogin().isEnabled)
        settings.readClaudeLogin = false
        let access = SettingsModel(defaults: defaults, alertStore: store).launchClaudeLogin()
        #expect(!access.isEnabled && access.status == .off && !access.takePrompt())
    }

    @Test func `only the first launch that reads Claude Code's login lets macOS ask unprompted`() {
        let (defaults, name) = Self.defaults()
        let store = AlertSettingsStore(suiteName: name)
        #expect(SettingsModel(defaults: defaults, alertStore: store).launchClaudeLogin().takePrompt())
        #expect(!SettingsModel(defaults: defaults, alertStore: store).launchClaudeLogin().takePrompt())
    }

    @Test func `EC-D5 only a shorter detail window asks first`() {
        #expect(SettingsModel.shrinks(from: .forever, to: .year))
        #expect(SettingsModel.shrinks(from: .year, to: .ninetyDays))
        #expect(!SettingsModel.shrinks(from: .ninetyDays, to: .year))
        #expect(!SettingsModel.shrinks(from: .year, to: .forever))
        #expect(!SettingsModel.shrinks(from: .halfYear, to: .halfYear))
    }

    @Test func `EC-D5 only a shorter history span asks first`() {
        #expect(SettingsModel.shrinks(from: HistoryRetention.forever, to: .fiveYears))
        #expect(SettingsModel.shrinks(from: HistoryRetention.twoYears, to: .oneYear))
        #expect(!SettingsModel.shrinks(from: HistoryRetention.oneYear, to: .forever))
    }

    @Test func `a backup carries the preferences, and restoring sets only those it knows`() throws {
        let source = UserDefaults(suiteName: "PreferenceBackup-\(UUID())")!
        source.set(2, forKey: SettingsModel.weekStartKey)
        source.set("roast", forKey: ActivityPreferences.comparisonToneKey)
        source.set("secret", forKey: "someOtherApp")
        let data = PreferenceBackup.export(from: source)

        let target = UserDefaults(suiteName: "PreferenceBackup-\(UUID())")!
        target.set(true, forKey: SettingsModel.onboardedKey)
        PreferenceBackup.apply(data, to: target)
        #expect(target.integer(forKey: SettingsModel.weekStartKey) == 2)
        #expect(target.string(forKey: ActivityPreferences.comparisonToneKey) == "roast")
        #expect(target.object(forKey: "someOtherApp") == nil)
        #expect(target.bool(forKey: SettingsModel.onboardedKey))
    }

    @Test func `the About notices carry the attribution NOTICE requires, word for word`() throws {
        let notice = try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "NOTICE"), encoding: .utf8)
        let lines = AboutView.attribution.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            #expect(notice.contains(line))
        }
        #expect(lines.count == 3)
    }

    @Test func `a backup goes beside a folder of the same name, never into it`() throws {
        let directory = TestDirectory.make("Backup names")
        let chosen = directory.appending(path: "Burnline Backup 2026-11-02")
        #expect(SettingsModel.unused(chosen) == chosen)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: directory.appending(path: "Burnline Backup 2026-11-02 2"),
                                                withIntermediateDirectories: false)
        #expect(SettingsModel.unused(chosen).lastPathComponent == "Burnline Backup 2026-11-02 3")
    }

    @Test func `EC-D2 staging a recovery backup does not block the main thread`() async {
        do {
            _ = try await StoreRecovery.stage({ _ in
                #expect(!Thread.isMainThread)
                throw CocoaError(.fileReadNoSuchFile)
            }, from: URL(filePath: "/unused-backup"))
            Issue.record("the staging error should reach the caller")
        } catch {
            #expect((error as? CocoaError)?.code == .fileReadNoSuchFile)
        }
    }

    @Test func `a data failure reads as words, not as a type dump`() {
        #expect(SettingsModel.describe(StoreFailure.diskFull) == "The disk is full.")
        // A system error reads as the system's own sentence, in the user's language.
        let exists = CocoaError(.fileWriteFileExists)
        #expect(SettingsModel.describe(exists) == exists.localizedDescription)
        #expect(!SettingsModel.describe(exists).contains("CocoaError"))
    }
}
