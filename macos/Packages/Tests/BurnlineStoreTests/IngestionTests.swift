//
//  IngestionTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import GRDB
import Testing

/// Model identity, deduplication, and batch writes through `ingest`.
struct IngestionTests {
    static let manifestURL = StoreFixture.repositoryRoot.appending(path: "shared/pricing/model_aliases.json")
    static let everything = TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: .max))

    static func record(_ id: String, model: String? = "claude-opus-5", at seconds: Int64 = 1_000,
                       output: Int64 = 10, session: String = "s1", file: String = "/a.jsonl",
                       project: ProjectCandidate? = nil) throws -> IncomingUsage {
        IncomingUsage(sourceEventID: id, sessionSourceID: session, project: project, rawModel: model,
                      timestamp: Timestamp(epochSeconds: seconds), tokens: try TokenCounts(input: 1, output: output),
                      sourceType: "test", file: file, schemaVersion: nil, offset: 0)
    }

    static func syncedDatabase() throws -> BurnlineDatabase {
        let database = try StoreFixture().open()
        try database.models.sync(ModelAliasManifest.load(from: manifestURL))
        return database
    }

    static func modelName(of event: UsageEvent, in database: BurnlineDatabase) throws -> String? {
        try event.modelID.flatMap { id in
            try database.read { try String.fetchOne($0, sql: "SELECT canonical_name FROM models WHERE id = ?",
                                                    arguments: [id]) }
        }
    }

    @Test func `EC-M1 a non-model value is kept visible and never priced`() throws {
        let database = try Self.syncedDatabase()
        try database.ingest([Self.record("a", model: "<synthetic>"), Self.record("b", model: "<brand-new-marker>")],
                            issues: [], provider: .claudeCode)
        let events = try database.usage.events(in: Self.everything)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.cost == .unpriced(.nonModel) })
    }

    @Test func `EC-M1 a non-model named by the manifest is recognised`() throws {
        let database = try Self.syncedDatabase()
        let resolution = try database.models.resolve(provider: .codex, raw: "codex-auto-review",
                                                     at: Timestamp(epochSeconds: 0))
        #expect(resolution.kind == .nonModel)
    }

    @Test func `EC-M2 dated and undated identifiers are one model`() throws {
        let database = try Self.syncedDatabase()
        let dated = try database.models.resolve(provider: .claudeCode, raw: "claude-haiku-4-5-20251001",
                                                at: Timestamp(epochSeconds: 0))
        let undated = try database.models.resolve(provider: .claudeCode, raw: "claude-haiku-4-5",
                                                  at: Timestamp(epochSeconds: 0))
        #expect(dated.modelID != nil && dated == undated)
    }

    @Test func `EC-M3 an unrecognised model is kept, counted, and unpriced`() throws {
        let database = try Self.syncedDatabase()
        try database.ingest([Self.record("a", model: "claude-from-the-future-9")], issues: [], provider: .claudeCode)
        let event = try #require(try database.usage.events(in: Self.everything).first)
        #expect(try Self.modelName(of: event, in: database) == "claude-from-the-future-9")
        #expect(event.cost == .unpriced(.unknownModel))
    }

    @Test func `EC-M4 a renamed model resolves by the time of each event`() throws {
        let database = try StoreFixture().open()
        let manifest = """
        {"schemaVersion": 1, "providers": {"claude_code": {"nonModels": [], "models": [
          {"canonical": "old-model", "display": "Old", "aliases": [
            {"raw": "shared-name", "validUntil": "2026-06-01T00:00:00Z"}]},
          {"canonical": "new-model", "display": "New", "aliases": [
            {"raw": "shared-name", "validFrom": "2026-06-01T00:00:00Z"}]}]}}}
        """
        let url = TestDirectory.file("aliases.json")
        try manifest.write(to: url, atomically: true, encoding: .utf8)
        try database.models.sync(ModelAliasManifest.load(from: url))

        let boundary: Int64 = 1_780_272_000   // 2026-06-01T00:00:00Z
        try database.ingest([Self.record("before", model: "shared-name", at: boundary - 1),
                             Self.record("at", model: "shared-name", at: boundary)],
                            issues: [], provider: .claudeCode)
        let names = try database.usage.events(in: Self.everything).map { try Self.modelName(of: $0, in: database) }
        #expect(names == ["old-model", "new-model"])
    }

    @Test func `EC-M5 an empty model is unknown but still counted`() throws {
        let database = try Self.syncedDatabase()
        try database.ingest([Self.record("a", model: nil), Self.record("b", model: "  ")],
                            issues: [], provider: .claudeCode)
        let events = try database.usage.events(in: Self.everything)
        #expect(events.count == 2 && events.allSatisfy { $0.modelID == nil })
    }

    @Test func `syncing the manifest twice changes nothing`() throws {
        let database = try Self.syncedDatabase()
        let manifest = try ModelAliasManifest.load(from: Self.manifestURL)
        let rows = {
            try database.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM models ORDER BY id")
                    + Row.fetchAll(db, sql: "SELECT * FROM model_aliases ORDER BY 1, 2")
            }
        }
        let before = try rows()
        try database.models.sync(manifest)
        #expect(try rows() == before)
    }

    @Test func `EC-I4 the same event in two files is stored once`() throws {
        let database = try Self.syncedDatabase()
        try database.ingest([Self.record("msg_1", file: "/session.jsonl")], issues: [], provider: .claudeCode)
        try database.ingest([Self.record("msg_1", file: "/session/subagents/agent.jsonl")], issues: [],
                            provider: .claudeCode)
        #expect(try database.usage.count() == 1)
    }

    @Test(arguments: [[5, 90], [90, 5]] as [[Int64]])
    func `the most complete snapshot of an event wins in either order`(outputs: [Int64]) throws {
        let database = try Self.syncedDatabase()
        for output in outputs {
            try database.ingest([Self.record("msg_1", output: output)], issues: [], provider: .claudeCode)
        }
        #expect(try database.usage.events(in: Self.everything).map(\.tokens.output) == [90])
    }

    @Test func `sessions and projects are created once and shared by their events`() throws {
        let database = try Self.syncedDatabase()
        let project = ProjectCandidate(identity: .gitRemote("github.com/me/app"), displayName: "app", path: "/x")
        try database.ingest([Self.record("a", at: 10, project: project), Self.record("b", at: 20, project: project),
                             Self.record("c", at: 30, session: "s2", project: project)],
                            issues: [], provider: .claudeCode)
        let events = try database.usage.events(in: Self.everything)
        #expect(Set(events.compactMap(\.projectID)).count == 1)
        #expect(Set(events.compactMap(\.sessionID)).count == 2)
        let session = try database.sessions.findOrCreate(provider: .claudeCode, sourceSessionID: "s1",
                                                         projectID: nil, seenAt: Timestamp(epochSeconds: 15))
        #expect(session.startedAt == Timestamp(epochSeconds: 10) && session.endedAt == Timestamp(epochSeconds: 20))
    }

    @Test func `parser errors are stored as reasons with their line`() throws {
        let database = try Self.syncedDatabase()
        try database.ingest([], issues: [ParseIssue(file: "/a.jsonl", line: 7, reason: "unreadable JSON")],
                            provider: .claudeCode)
        let row = try #require(try database.read { try Row.fetchOne($0, sql: "SELECT * FROM parser_errors") })
        #expect(row["line_number"] as Int == 7)
        #expect(row["reason"] as String == "unreadable JSON")
    }

    @Test func `manifest problems are told apart`() throws {
        let directory = TestDirectory.make("manifest")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let malformed = directory.appending(path: "malformed.json")
        let future = directory.appending(path: "future.json")
        try "{ not json".write(to: malformed, atomically: true, encoding: .utf8)
        try "{\"schemaVersion\": 2, \"providers\": {}}".write(to: future, atomically: true, encoding: .utf8)

        #expect { try ModelAliasManifest.load(from: directory.appending(path: "absent.json")) } throws: {
            if case .missing = $0 as? ModelAliasManifest.LoadError { true } else { false }
        }
        #expect { try ModelAliasManifest.load(from: malformed) } throws: {
            if case .malformed = $0 as? ModelAliasManifest.LoadError { true } else { false }
        }
        #expect(throws: ModelAliasManifest.LoadError.unsupportedSchemaVersion(found: 2, supported: 1)) {
            try ModelAliasManifest.load(from: future)
        }
    }

    @Test func `the shipped schema adds the one-hour column, resume state, and service tier`() throws {
        let database = try StoreFixture().open()
        #expect(try database.schemaVersion() == StoreFixture.shippedVersion)
        let columns = try database.read { try String.fetchAll($0, sql: "SELECT name FROM pragma_table_info('usage_events')") }
        #expect(columns.contains("cache_write_1h_tokens"))
        let stateColumns = try database.read {
            try String.fetchAll($0, sql: "SELECT name FROM pragma_table_info('source_states')")
        }
        #expect(stateColumns.contains("resume_state"))
        #expect(columns.contains("service_tier"))
    }
}
