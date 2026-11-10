//
//  IngestionActorTests.swift
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

/// End to end: a fixture Claude Code directory, through the real adapter and
/// the real store.
struct IngestionActorTests {
    let root = TestDirectory.make("IngestionActor")
    var projects: URL { root.appending(path: "claude/projects") }
    static let repositoryRoot = RealHistoryTests.repositoryRoot

    func database() throws -> BurnlineDatabase {
        try BurnlineDatabase.open(
            at: StoreLocation(directory: root.appending(path: "db")),
            schema: Schema(directory: Self.repositoryRoot.appending(path: "shared/schema")),
            clock: ManualClock(Timestamp(epochSeconds: 1_793_450_000)))
    }

    static func line(id: String, session: String, cwd: String, output: Int = 10) -> String {
        """
        {"type":"assistant","sessionId":"\(session)","cwd":"\(cwd)","timestamp":"2026-10-30T12:00:00Z",\
        "message":{"id":"\(id)","model":"claude-opus-5","usage":{"input_tokens":1,"cache_read_input_tokens":0,\
        "cache_creation_input_tokens":0,"output_tokens":\(output)}}}
        """
    }

    func write(_ lines: [String], to relative: String) throws {
        let file = projects.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// A repository with a remote, so moving it must not split the project.
    func repository(at relative: String) throws -> URL {
        let directory = root.appending(path: relative)
        try FileManager.default.createDirectory(at: directory.appending(path: ".git"), withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = git@github.com:me/app.git\n"
            .write(to: directory.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        return directory
    }

    @Test func `sessions match the transcript files that hold usage`() async throws {
        let repository = try repository(at: "work/app")
        try write([Self.line(id: "m1", session: "s1", cwd: repository.path),
                   Self.line(id: "m1", session: "s1", cwd: repository.path, output: 40),
                   Self.line(id: "m2", session: "s1", cwd: repository.path)], to: "p/s1.jsonl")
        // A subagent transcript belongs to its parent session.
        try write([Self.line(id: "m3", session: "s1", cwd: repository.path)], to: "p/s1/subagents/agent-a.jsonl")
        try write([Self.line(id: "m4", session: "s2", cwd: repository.path)], to: "p/s2.jsonl")
        // A session that ended before any reply holds no usage.
        try write(["{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}"], to: "p/s3.jsonl")

        let database = try database()
        let result = try await IngestionActor(database: database)
            .sync(from: ClaudeCodeAdapter(projectsDirectories: [projects]))

        #expect(result.filesRead == 4 && result.unreadableFiles == 0 && result.issues == 0)
        #expect(try database.usage.count() == 4)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sessions") } == 2)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT sum(output_tokens) FROM usage_events") } == 70)
    }

    @Test func `EC-P1 moving a repository between imports does not create a second project`() async throws {
        let database = try database()
        let actor = IngestionActor(database: database)
        let adapter = ClaudeCodeAdapter(projectsDirectories: [projects])

        let before = try repository(at: "old/location/app")
        try write([Self.line(id: "m1", session: "s1", cwd: before.path)], to: "p/s1.jsonl")
        _ = try await actor.sync(from: adapter)

        let after = root.appending(path: "new/place/app-renamed")
        try FileManager.default.createDirectory(at: after.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: before, to: after)
        try write([Self.line(id: "m2", session: "s2", cwd: after.path)], to: "p/s2.jsonl")
        // A fresh adapter, as after a relaunch, so nothing is served from cache.
        _ = try await actor.sync(from: ClaudeCodeAdapter(projectsDirectories: [projects]))

        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM projects") } == 1)
        let path = try database.read { try String.fetchOne($0, sql: "SELECT last_known_path FROM projects") }
        #expect(path?.hasSuffix("app-renamed") == true)
    }

    @Test func `EC-P1 a reused adapter resolves a replacement repository at the same path`() async throws {
        let database = try database()
        let actor = IngestionActor(database: database)
        let adapter = ClaudeCodeAdapter(projectsDirectories: [projects])
        let path = try repository(at: "work/app")
        try write([Self.line(id: "m1", session: "s1", cwd: path.path)], to: "p/s1.jsonl")
        _ = try await actor.sync(from: adapter)
        try "[remote \"origin\"]\n\turl = git@github.com:me/replacement.git\n"
            .write(to: path.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        try write([Self.line(id: "m2", session: "s2", cwd: path.path)], to: "p/s2.jsonl")
        _ = try await actor.sync(from: adapter)
        let remotes = try database.read {
            try String.fetchAll($0, sql: "SELECT identity_key FROM projects ORDER BY identity_key")
        }
        #expect(remotes == ["github.com/me/app", "github.com/me/replacement"])
    }

    @Test func `importing twice adds nothing`() async throws {
        try write([Self.line(id: "m1", session: "s1", cwd: "/nowhere")], to: "p/s1.jsonl")
        let database = try database()
        let actor = IngestionActor(database: database)
        let adapter = ClaudeCodeAdapter(projectsDirectories: [projects])
        _ = try await actor.sync(from: adapter)
        let second = try await actor.sync(from: adapter)
        #expect(second.eventsWritten == 0)
        #expect(try database.usage.count() == 1)
    }

    @Test func `an unreadable file is skipped without stopping the rest`() async throws {
        try write([Self.line(id: "m1", session: "s1", cwd: "/nowhere")], to: "p/good.jsonl")
        // A directory with a transcript's name cannot be read as a file.
        try FileManager.default.createDirectory(at: projects.appending(path: "p/bad.jsonl"),
                                                withIntermediateDirectories: true)
        let database = try database()
        let result = try await IngestionActor(database: database)
            .sync(from: ClaudeCodeAdapter(projectsDirectories: [projects]))
        #expect(result.unreadableFiles == 1)
        #expect(try database.usage.count() == 1)
    }

    @Test func `EC-I11 a provider that is not installed imports nothing and is not an error`() async throws {
        let result = try await IngestionActor(database: database()).sync(
            from: ClaudeCodeAdapter(projectsDirectories: [root.appending(path: "absent")]))
        #expect(result.detection == .notInstalled && result.filesRead == 0)
    }
}
