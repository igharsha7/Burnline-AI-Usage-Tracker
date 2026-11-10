//
//  SyncPerformanceTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineProviders
import BurnlineServices
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import Testing

/// Ingestion's share of the performance gate: a first import of an invented
/// Claude Code history, then the sync that runs whenever nothing has changed,
/// which Burnline repeats all day. Off unless `BURNLINE_PERF` names a
/// directory for the figures; see `StorePerformanceTests`.
@Suite(.enabled(if: PerformanceReport.enabled), .serialized)
struct SyncPerformanceTests {
    static let files = 2_000
    static let linesPerFile = 50
    static let runs = 7

    /// docs/performance.md: an idle sync with nothing changed.
    static let idleSyncBudget = 100.0
    /// No budget of its own: the comparison with the base branch guards it.
    /// This only catches an import that has stopped working at a usable speed.
    static let firstImportBudget = 30_000.0

    @Test func `an idle sync stays cheap, and a first import does not slow down`() async throws {
        let root = TestDirectory.make("SyncPerformance")
        let projects = root.appending(path: "claude/projects")
        for file in 0..<Self.files {
            let session = "session-\(file)"
            let lines = (0..<Self.linesPerFile).map { line in
                IngestionActorTests.line(id: "msg-\(file)-\(line)", session: session,
                                         cwd: "/Users/someone/project-\(file % 40)", output: line + 1)
            }
            let url = projects.appending(path: "project-\(file % 40)/\(session).jsonl")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
        }

        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: root.appending(path: "db")),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")),
            clock: ManualClock(Timestamp(epochSeconds: 1_793_450_000)))
        let actor = IngestionActor(database: database)
        let adapter = ClaudeCodeAdapter(projectsDirectories: [projects])

        let started = ContinuousClock.now
        let first = try await actor.sync(from: adapter)
        let importing = ContinuousClock.now - started
        #expect(first.filesRead == Self.files && first.eventsWritten == Self.files * Self.linesPerFile)

        var idle: ImportResult?
        let idleTime = try await PerformanceReport.fastest(of: Self.runs) {
            idle = try await actor.sync(from: adapter)
        }
        #expect(idle?.filesRead == 0 && idle?.filesUnchanged == Self.files)

        var report = PerformanceReport()
        report.record(.init(id: "first-import", title: "First import, \(Self.files) files",
                            value: PerformanceReport.milliseconds(importing), unit: "ms",
                            budget: Self.firstImportBudget, better: .lower, doc: "first-import"))
        report.record(.init(id: "idle-sync", title: "Idle sync, \(Self.files) files unchanged",
                            value: PerformanceReport.milliseconds(idleTime), unit: "ms",
                            budget: Self.idleSyncBudget, better: .lower, doc: "idle"))
        try report.write(suite: "sync")
        for metric in report.metrics {
            #expect(metric.withinBudget, "\(metric.title): \(metric.value) \(metric.unit), budget \(metric.budget)")
        }
    }
}
