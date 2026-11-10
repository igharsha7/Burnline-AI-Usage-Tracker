//
//  SettingsDataTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineProviders
@testable import BurnlineServices
import BurnlineStore
import BurnlineTestSupport
@testable import BurnlineUI
import Foundation
import Testing

/// A poster that shows nothing and is always allowed.
struct SilentPoster: NotificationPoster {
    func permission() async -> NotificationPermission { .allowed }
    func requestPermission() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async throws {}
}

/// Settings' data actions against the app as assembled, in a scratch folder:
/// what each one reports, and that a failure is said in words and never
/// leaves Settings stuck.
struct SettingsDataTests {
    struct Fixture {
        let root = TestDirectory.make("SettingsData")
        let settings: SettingsModel
        var location: StoreLocation { StoreLocation(directory: root.appending(path: "store")) }

        /// Claude Code history of two replies in one session, already imported.
        init() async throws {
            let projects = root.appending(path: "claude/projects")
            let transcript = projects.appending(path: "p/s1.jsonl")
            try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let lines = ["m1", "m2"].map { id in
                """
                {"type":"assistant","sessionId":"s1","cwd":"/nonexistent/burnline-fixture","timestamp":"2026-11-02T11:00:00Z",\
                "message":{"id":"\(id)","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":10}}}
                """
            }
            try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

            let live = try LiveIngestion(
                resources: StatusModelTests.repositoryRoot.appending(path: "shared"), pricingUpdates: false,
                retention: .default, history: .default, alerts: AlertSettings(), weekStart: .monday,
                tracked: [.claudeCode], location: StoreLocation(directory: root.appending(path: "store")),
                clock: ManualClock(StatusModelTests.now), poster: SilentPoster(), readers: [],
                adapters: [ClaudeCodeAdapter(projectsDirectories: [projects])])
            await live.reconciler.reconcile()

            let (defaults, name) = SettingsTests.defaults()
            settings = SettingsModel(defaults: defaults, alertStore: AlertSettingsStore(suiteName: name),
                                     clock: ManualClock(StatusModelTests.now))
            settings.connect(live)
        }

        var outcome: (text: String, failed: Bool)? { settings.dataOutcome }
    }

    @Test func `an export says how many rows it wrote, and where`() async throws {
        let fixture = try await Fixture()
        let file = fixture.root.appending(path: "events.json")

        await fixture.settings.export(.events, as: .json, to: file)

        #expect(fixture.outcome?.text == "Exported 2 rows to events.json.")
        #expect(fixture.outcome?.failed == false)
        #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [Any])?.count == 2)
    }

    @Test func `a backup never writes into a folder that exists, and can be staged and withdrawn`() async throws {
        let fixture = try await Fixture()
        let chosen = fixture.root.appending(path: "Burnline Backup")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        await fixture.settings.backup(to: chosen)

        #expect(fixture.outcome?.text == "Backed up to Burnline Backup 2.")
        let written = fixture.root.appending(path: "Burnline Backup 2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: chosen.path).isEmpty)

        let plan = try #require(await fixture.settings.stageRestore(from: written))
        #expect(plan.inspection.events == 2 && plan.includesSettings)
        #expect(DatabaseBackups.hasStagedRestore(in: fixture.location))
        fixture.settings.cancelRestore()
        #expect(!DatabaseBackups.hasStagedRestore(in: fixture.location))
    }

    @Test func `a failed action says why in words, and the next one still runs`() async throws {
        let fixture = try await Fixture()
        let unreachable = fixture.root.appending(path: "missing/folder/events.csv")

        await fixture.settings.export(.events, as: .csv, to: unreachable)

        #expect(fixture.outcome?.failed == true)
        #expect(fixture.outcome.map { !$0.text.isEmpty && !$0.text.contains("Error(") } == true)
        #expect(!fixture.settings.busy)

        await fixture.settings.repair(.check)
        #expect(fixture.outcome?.text == "The database is healthy.")
    }

    @Test func `deleting a provider's history says what went`() async throws {
        let fixture = try await Fixture()

        await fixture.settings.delete(.provider(.claudeCode))

        #expect(fixture.outcome?.text == "Deleted 2 events and 1 session.")
        #expect(fixture.outcome?.failed == false)
    }
}
