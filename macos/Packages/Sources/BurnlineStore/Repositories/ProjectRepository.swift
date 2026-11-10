//
//  ProjectRepository.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

extension BurnlineDatabase {
    public var projects: ProjectRepository { ProjectRepository(database: self) }
    public var sessions: SessionRepository { SessionRepository(database: self) }
}

public struct ProjectRepository: Sendable {
    /// Longest redirect chain followed before giving up. A merge loop cannot be
    /// created through `merge`, but a corrupt row must not hang a read.
    static let maxRedirects = 32

    let database: BurnlineDatabase

    /// The project with `identity`, created on first sight. Every sighting
    /// refreshes when it was last seen, where, and the name it derived; the
    /// user's alias is theirs and never touched.
    public func findOrCreate(identity: ProjectIdentity, displayName: String,
                             path: String?, seenAt: Timestamp) throws(StoreError) -> Project {
        try database.write { db in
            let candidate = ProjectCandidate(identity: identity, displayName: displayName, path: path)
            let id = try Self.findOrCreate(db, candidate, seenAt: seenAt)
            return Self.project(from: try Row.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?",
                                                       arguments: [id])!)
        }
    }

    /// Inside a transaction the caller holds. Returns the project's id.
    static func findOrCreate(_ db: Database, _ candidate: ProjectCandidate, seenAt: Timestamp) throws -> Int64 {
        try db.cachedStatement(sql: """
            INSERT INTO projects (identity_kind, identity_key, display_name, last_known_path,
                                  first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (identity_kind, identity_key) DO UPDATE SET
              last_known_path = CASE WHEN excluded.last_seen_at >= last_seen_at
                                     THEN coalesce(excluded.last_known_path, last_known_path)
                                     ELSE last_known_path END,
              display_name = CASE WHEN excluded.last_seen_at >= last_seen_at
                                  THEN excluded.display_name ELSE display_name END,
              first_seen_at = min(first_seen_at, excluded.first_seen_at),
              last_seen_at = max(last_seen_at, excluded.last_seen_at)
            """).execute(arguments: [candidate.identity.kind, candidate.identity.key, candidate.displayName, candidate.path,
                        seenAt.epochSeconds, seenAt.epochSeconds])
        return try Int64.fetchOne(
            db.cachedStatement(sql: "SELECT id FROM projects WHERE identity_kind = ? AND identity_key = ?"),
            arguments: [candidate.identity.kind, candidate.identity.key])!
    }

    /// Every project, merged ones included, most recently seen first.
    public func all() throws(StoreError) -> [Project] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM projects ORDER BY last_seen_at DESC, id").map(Self.project(from:))
        }
    }

    /// Names the project as the user calls it; nil or blank restores the
    /// name derived from its identity.
    public func rename(_ id: Int64, to alias: String?) throws(StoreError) {
        let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.write { db in
            try db.execute(sql: "UPDATE projects SET user_alias = ? WHERE id = ?",
                           arguments: [alias?.isEmpty == false ? alias : nil, id])
        }
    }

    /// Redirects `source` into `target`. No usage rows are rewritten, so
    /// `unmerge` restores the original grouping exactly. Refuses a merge that
    /// would make a loop.
    public func merge(_ source: Int64, into target: Int64) throws(StoreError) {
        guard source != target else { throw .sqlite("a project cannot be merged into itself") }
        try database.write { db in
            let descendants = try Int64.fetchAll(db, sql: """
                WITH RECURSIVE descendants(id) AS (
                  SELECT ? UNION SELECT p.id FROM projects p JOIN descendants d ON p.merged_into_id = d.id)
                SELECT id FROM descendants
                """, arguments: [source])
            guard !descendants.contains(target) else {
                throw StoreError.sqlite("merging \(source) into \(target) would make a loop")
            }
            // Refuses a target whose chain is already as long as allowed.
            _ = try Self.resolve(target, in: db)
            try db.execute(sql: "UPDATE projects SET merged_into_id = ? WHERE id = ?", arguments: [target, source])
        }
    }

    public func unmerge(_ project: Int64) throws(StoreError) {
        try database.write { db in
            try db.execute(sql: "UPDATE projects SET merged_into_id = NULL WHERE id = ?", arguments: [project])
        }
    }

    /// The project `id` currently groups under, following merges.
    public func resolve(_ id: Int64) throws(StoreError) -> Int64 {
        try database.read { db in try Self.resolve(id, in: db) }
    }

    private static func resolve(_ id: Int64, in db: Database) throws -> Int64 {
        var current = id
        for _ in 0..<maxRedirects {
            guard let next = try Int64.fetchOne(
                db, sql: "SELECT merged_into_id FROM projects WHERE id = ?", arguments: [current]) else {
                return current
            }
            current = next
        }
        throw StoreError.sqlite("project \(id) has a redirect chain longer than \(maxRedirects)")
    }

    private static func project(from row: Row) -> Project {
        let key: String = row["identity_key"]
        let identity: ProjectIdentity = switch row["identity_kind"] as String {
        case "git_remote": .gitRemote(key)
        case "git_root": .gitRoot(pathHash: key)
        default: .path(pathHash: key)
        }
        return Project(
            id: row["id"], identity: identity, displayName: row["display_name"], userAlias: row["user_alias"],
            lastKnownPath: row["last_known_path"], mergedIntoID: row["merged_into_id"],
            firstSeenAt: Timestamp(epochSeconds: row["first_seen_at"]),
            lastSeenAt: Timestamp(epochSeconds: row["last_seen_at"]))
    }
}

public struct SessionRepository: Sendable {
    let database: BurnlineDatabase

    /// The session with the provider's own id, created on first sight. Later
    /// sightings widen its time span rather than replacing it.
    public func findOrCreate(provider: ProviderKey, sourceSessionID: String, projectID: Int64?,
                             seenAt: Timestamp) throws(StoreError) -> Session {
        let providerID = database.providerID(provider)
        return try database.write { db in
            let id = try Self.findOrCreate(db, providerID: providerID, sourceSessionID: sourceSessionID,
                                           projectID: projectID, seenAt: seenAt)
            let row = try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])!
            return Session(
                id: id, provider: provider, sourceSessionID: sourceSessionID,
                projectID: row["project_id"], startedAt: Timestamp(epochSeconds: row["started_at"]),
                endedAt: (row["ended_at"] as Int64?).map(Timestamp.init(epochSeconds:)))
        }
    }

    /// The sessions with these ids, in no particular order; unknown ids are
    /// left out.
    public func sessions(ids: some Collection<Int64>) throws(StoreError) -> [Session] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.*, p.key AS provider_key FROM sessions s JOIN providers p ON p.id = s.provider_id
                WHERE s.id IN (SELECT value FROM json_each(?))
                """, arguments: [AggregationRepository.json(Array(ids))]).compactMap { row in
                guard let provider = ProviderKey(rawValue: row["provider_key"]) else { return nil }
                return Session(id: row["id"], provider: provider, sourceSessionID: row["source_session_id"],
                               projectID: row["project_id"], startedAt: Timestamp(epochSeconds: row["started_at"]),
                               endedAt: (row["ended_at"] as Int64?).map(Timestamp.init(epochSeconds:)))
            }
        }
    }

    /// Every session's start, end and provider, oldest first, for achievements.
    public func records() throws(StoreError) -> [AchievementHistory.Session] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.started_at, s.ended_at, p.key FROM sessions s JOIN providers p ON p.id = s.provider_id
                ORDER BY s.started_at, s.id
                """).compactMap { row in
                let ended: Int64? = row["ended_at"]
                return ProviderKey(rawValue: row["key"]).map {
                    AchievementHistory.Session(startedAt: Timestamp(epochSeconds: row["started_at"]),
                                               endedAt: ended.map(Timestamp.init(epochSeconds:)), provider: $0)
                }
            }
        }
    }

    /// Inside a transaction the caller holds. Returns the session's id.
    static func findOrCreate(_ db: Database, providerID: Int64, sourceSessionID: String, projectID: Int64?,
                             seenAt: Timestamp) throws -> Int64 {
        try db.cachedStatement(sql: """
            INSERT INTO sessions (provider_id, source_session_id, project_id, started_at, ended_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (provider_id, source_session_id) DO UPDATE SET
              project_id = coalesce(project_id, excluded.project_id),
              started_at = min(started_at, excluded.started_at),
              ended_at = max(coalesce(ended_at, excluded.ended_at), excluded.ended_at)
            """).execute(arguments: [providerID, sourceSessionID, projectID, seenAt.epochSeconds, seenAt.epochSeconds])
        return try Int64.fetchOne(
            db.cachedStatement(sql: "SELECT id FROM sessions WHERE provider_id = ? AND source_session_id = ?"),
            arguments: [providerID, sourceSessionID])!
    }
}
