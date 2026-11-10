//
//  Deletion.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

extension BurnlineDatabase {
    /// Deletes the scope's usage: compacted totals first, then events a
    /// batch per transaction so ingestion keeps writing meanwhile.
    /// The rollup triggers subtract every deleted event, so every figure
    /// that remains stays exact. Sessions and projects left with nothing go
    /// too; a provider's quota history goes with it. Source file positions
    /// are kept, so deleted usage is not imported again unless the user
    /// re-scans from the start.
    @discardableResult
    public func delete(_ scope: DeletionScope) throws(StoreError) -> DeletionReport {
        let filter = try deletionFilter(scope)
        try write { db in
            try db.execute(sql: """
                DELETE FROM usage_rollups
                WHERE bucket * \(Self.bucketSeconds) < (SELECT compacted_before FROM compaction) AND \(filter.rollups)
                """, arguments: filter.arguments)
        }
        var events = 0
        while true {
            let batch = try write { db in
                try db.execute(sql: """
                    DELETE FROM usage_events WHERE id IN (
                      SELECT id FROM usage_events WHERE \(filter.events) LIMIT \(Self.deletionBatch))
                    """, arguments: filter.arguments)
                return db.changesCount
            }
            events += batch
            if batch < Self.deletionBatch { break }
        }
        let sessions = try write { db in
            try db.execute(sql: """
                DELETE FROM sessions WHERE \(filter.sessions)
                  AND id NOT IN (SELECT session_id FROM usage_events WHERE session_id IS NOT NULL)
                """, arguments: filter.arguments)
            let sessions = db.changesCount
            try removeOrphans(db, scope: scope, filter: filter)
            return sessions
        }
        return DeletionReport(events: events, sessions: sessions)
    }

    /// The scope as predicates on events, rollups and sessions, sharing one
    /// argument list.
    private func deletionFilter(_ scope: DeletionScope) throws(StoreError)
        -> (events: String, rollups: String, sessions: String, arguments: StatementArguments) {
        switch scope {
        case .provider(let provider):
            return ("provider_id = ?", "provider_id = ?", "provider_id = ?", [providerID(provider)])
        case .project(let id):
            let ids = try read { db in
                try Int64.fetchAll(db, sql: AggregationRepository.projectRoots + " SELECT id FROM roots WHERE root = ?",
                                   arguments: [id])
            }
            let list = "(SELECT value FROM json_each(?))"
            return ("project_id IN \(list)", "project_id IN \(list)", "project_id IN \(list)",
                    [AggregationRepository.json(ids)])
        case .range(let window):
            let start = window.start.epochSeconds, end = window.end.epochSeconds
            return ("timestamp >= :start AND timestamp < :end",
                    "bucket * \(Self.bucketSeconds) >= :start AND (bucket + 1) * \(Self.bucketSeconds) <= :end",
                    "started_at >= :start AND coalesce(ended_at, started_at) < :end",
                    ["start": start, "end": end])
        case .everything:
            return ("1", "1", "1", [])
        }
    }

    /// What deleting the usage leaves pointing at nothing.
    private func removeOrphans(_ db: Database, scope: DeletionScope,
                               filter: (events: String, rollups: String, sessions: String, arguments: StatementArguments))
        throws {
        let unused = """
            id NOT IN (SELECT project_id FROM usage_events WHERE project_id IS NOT NULL)
              AND id NOT IN (SELECT project_id FROM sessions WHERE project_id IS NOT NULL)
              AND id NOT IN (SELECT project_id FROM usage_rollups)
            """
        switch scope {
        case .provider(let provider):
            let id = providerID(provider)
            for table in ["pending_quota_resets", "quota_snapshots", "banked_resets", "notification_events",
                          "parser_errors"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE provider_id = ?", arguments: [id])
            }
        case .project:
            // The project and those merged into it, which first point
            // nowhere so that none blocks another's deletion.
            let ids = "id IN (SELECT value FROM json_each(?))"
            try db.execute(sql: "UPDATE projects SET merged_into_id = NULL WHERE \(ids)", arguments: filter.arguments)
            try db.execute(sql: "DELETE FROM projects WHERE \(ids) AND \(unused)", arguments: filter.arguments)
        case .range(let window):
            try db.execute(sql: "DELETE FROM quota_snapshots WHERE timestamp >= ? AND timestamp < ?",
                           arguments: [window.start.epochSeconds, window.end.epochSeconds])
        case .everything:
            for table in ["pending_quota_resets", "quota_snapshots", "banked_resets", "notification_events",
                          "parser_errors", "achievements"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            try db.execute(sql: "UPDATE projects SET merged_into_id = NULL")
            try db.execute(sql: "DELETE FROM projects WHERE \(unused)")
            // No compacted history is left, so nothing needs the boundary: a
            // later re-scan may import whatever the providers still keep.
            try db.execute(sql: "UPDATE compaction SET compacted_before = 0")
        }
    }
}
