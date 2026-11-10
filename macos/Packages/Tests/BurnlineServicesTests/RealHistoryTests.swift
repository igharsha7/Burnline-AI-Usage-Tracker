//
//  RealHistoryTests.swift
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

/// Imports this machine's real Claude Code history into a throwaway database.
/// Off by default, because it depends on the machine; run with
///
///     BURNLINE_REAL_HISTORY=1 swift test --filter RealHistoryTests
///
/// It prints counts only: no paths beyond the summary, no content.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_REAL_HISTORY"] != nil))
struct RealHistoryTests {
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func `the real Claude Code history imports without crashing`() async throws {
        let directory = TestDirectory.make("RealHistory")
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: directory),
            schema: Schema(directory: Self.repositoryRoot.appending(path: "shared/schema")),
            clock: SystemClock())
        try database.models.sync(ModelAliasManifest.load(
            from: Self.repositoryRoot.appending(path: "shared/pricing/model_aliases.json")))

        let actor = IngestionActor(database: database)
        let started = ContinuousClock.now
        let result = try await actor.sync(from: ClaudeCodeAdapter())
        let elapsed = ContinuousClock.now - started
        let again = ContinuousClock.now
        let idle = try await actor.sync(from: ClaudeCodeAdapter())
        let idleElapsed = ContinuousClock.now - again

        let summary = try database.read { db in
            try [
                "events": Int.fetchOne(db, sql: "SELECT count(*) FROM usage_events") ?? 0,
                "sessions": Int.fetchOne(db, sql: "SELECT count(*) FROM sessions") ?? 0,
                "projects": Int.fetchOne(db, sql: "SELECT count(*) FROM projects") ?? 0,
                "models": Int.fetchOne(db, sql: "SELECT count(*) FROM models WHERE provider_id = 2") ?? 0,
                "parser_errors": Int.fetchOne(db, sql: "SELECT count(*) FROM parser_errors") ?? 0,
                "output_tokens": Int.fetchOne(db, sql: "SELECT sum(output_tokens) FROM usage_events") ?? 0,
                "cache_write_1h": Int.fetchOne(db, sql: "SELECT sum(cache_write_1h_tokens) FROM usage_events") ?? 0,
            ]
        }
        let kinds = try database.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT identity_kind FROM projects ORDER BY 1")
        }
        print("IMPORT", result.filesRead, "files,", result.linesRead, "lines,", result.recordsParsed, "records,",
              result.eventsWritten, "written,", result.issues, "issues,", result.unreadableFiles, "unreadable, in",
              elapsed)
        print("DATABASE", summary.sorted { $0.key < $1.key }, "project kinds", kinds)
        print("IDLE", idle.filesRead, "read,", idle.filesUnchanged, "unchanged, in", idleElapsed)

        #expect(result.unreadableFiles == 0)
        #expect(summary["events"]! > 0)
        #expect(idle.filesRead == 0 && idleElapsed < .milliseconds(100))
    }

    @Test func `the real Codex history imports, and a second pass reads nothing`() async throws {
        let directory = TestDirectory.make("RealHistory")
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: directory),
            schema: Schema(directory: Self.repositoryRoot.appending(path: "shared/schema")),
            clock: SystemClock())
        try database.models.sync(ModelAliasManifest.load(
            from: Self.repositoryRoot.appending(path: "shared/pricing/model_aliases.json")))
        let actor = IngestionActor(database: database)

        let started = ContinuousClock.now
        let first = try await actor.sync(from: CodexAdapter())
        let firstElapsed = ContinuousClock.now - started
        let again = ContinuousClock.now
        let second = try await actor.sync(from: CodexAdapter())
        let secondElapsed = ContinuousClock.now - again

        let summary = try database.read { db in
            try [
                "events": Int.fetchOne(db, sql: "SELECT count(*) FROM usage_events") ?? 0,
                "sessions": Int.fetchOne(db, sql: "SELECT count(*) FROM sessions") ?? 0,
                "projects": Int.fetchOne(db, sql: "SELECT count(*) FROM projects") ?? 0,
                "unmodelled": Int.fetchOne(db, sql: "SELECT count(*) FROM usage_events WHERE model_id IS NULL") ?? 0,
                "input": Int.fetchOne(db, sql: "SELECT sum(input_tokens) FROM usage_events") ?? 0,
                "cached": Int.fetchOne(db, sql: "SELECT sum(cached_input_tokens) FROM usage_events") ?? 0,
                "output": Int.fetchOne(db, sql: "SELECT sum(output_tokens) FROM usage_events") ?? 0,
                "reasoning": Int.fetchOne(db, sql: "SELECT sum(reasoning_tokens) FROM usage_events") ?? 0,
            ]
        }
        print("CODEX FIRST", first.filesRead, "files,", first.linesRead, "lines,", first.recordsParsed, "records,",
              first.eventsWritten, "written,", first.issues, "issues,", first.unreadableFiles, "unreadable, in",
              firstElapsed)
        print("CODEX SECOND", second.filesRead, "read,", second.filesUnchanged, "unchanged,", second.linesRead,
              "lines, in", secondElapsed)
        print("CODEX DATABASE", summary.sorted { $0.key < $1.key })

        // An unreadable file, such as a damaged archive, is counted and
        // skipped rather than fatal, so it is printed above, not asserted.
        #expect(first.issues == 0)
        #expect(summary["events"]! > 0)
        // The storage phase's budget for a sync that finds nothing new.
        #expect(second.filesRead == 0 && secondElapsed < .milliseconds(100))
    }
}
