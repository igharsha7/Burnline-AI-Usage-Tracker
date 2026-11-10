//
//  Maintenance.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import GRDB

/// `PRAGMA auto_vacuum` values.
enum Vacuum {
    static let incremental = 2
}

/// What one maintenance pass did, for diagnostics.
public struct MaintenanceReport: Hashable, Sendable {
    public let parserErrorsRemoved: Int
    public let pagesReclaimed: Int
}

/// Keeping a lifetime database small and quick without dropping a fact.
///
/// Every step works in short transactions, so ingestion keeps writing while
/// it runs; none rewrites the whole file.
extension BurnlineDatabase {
    /// Parser errors are diagnostics, kept for this long.
    public static let parserErrorRetention: Int64 = 90 * 86_400
    /// Rows deleted per transaction when history is removed.
    static let deletionBatch = 10_000
    /// Free pages returned to the disk per transaction. At 4 KB pages this is
    /// 8 MB, a few milliseconds of the writer's time.
    static let reclaimPagesPerStep = 2_048

    /// Prunes old parser errors, returns free pages to the disk, and lets
    /// SQLite refresh its planner statistics. Run daily and at quit.
    @discardableResult
    public func maintain() throws(StoreError) -> MaintenanceReport {
        let cutoff = clock.now.epochSeconds - Self.parserErrorRetention
        let removed = try write { db in
            try db.execute(sql: "DELETE FROM parser_errors WHERE occurred_at < ?", arguments: [cutoff])
            return db.changesCount
        }
        let pages = try reclaimSpace()
        try optimize()
        return MaintenanceReport(parserErrorsRemoved: removed, pagesReclaimed: pages)
    }

    /// Updates the statistics the query planner uses, only where they are
    /// stale. Cheap enough to run at quit.
    public func optimize() throws(StoreError) {
        do { try pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA optimize") } }
        catch { throw StoreError.from(error, file: location.databaseFile) }
    }

    /// Returns the file's free pages to the disk a step at a time.
    /// Free pages appear when rows are deleted; without this the file never
    /// shrinks.
    @discardableResult
    public func reclaimSpace() throws(StoreError) -> Int {
        var reclaimed = 0
        while true {
            let step = try write { db -> Int in
                let free = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                guard free > 0 else { return 0 }
                try db.execute(sql: "PRAGMA incremental_vacuum(\(Self.reclaimPagesPerStep))")
                return free - (try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0)
            }
            guard step > 0 else { return reclaimed }
            reclaimed += step
        }
    }
}

extension BurnlineDatabase {
    /// The rollups as events say they should be, for every bucket not yet
    /// compacted. Triggers keep them so; this is for repair and tests.
    static let rollupsFromEvents = """
        SELECT timestamp / 900, provider_id, coalesce(model_id, 0), coalesce(project_id, 0),
               count(*), sum(input_tokens), sum(cached_input_tokens), sum(cache_write_tokens),
               sum(cache_write_1h_tokens), sum(output_tokens), sum(reasoning_tokens),
               coalesce(sum(cost_nanos), 0), sum(cost_nanos IS NULL), coalesce(sum(cache_savings_nanos), 0),
               coalesce(sum(CASE WHEN cache_savings_nanos IS NULL THEN 0
                                 ELSE cached_input_tokens + cache_write_tokens END), 0)
        FROM usage_events WHERE timestamp >= (SELECT compacted_before FROM compaction)
        GROUP BY 1, 2, 3, 4
        """

    /// Rebuilds the rollups of time not yet compacted from its events. They
    /// are derived, so this loses nothing; compacted buckets have no events
    /// left and are kept as they are.
    public func rebuildRollups() throws(StoreError) {
        try write { db in
            try db.execute(sql: """
                DELETE FROM usage_rollups WHERE bucket * 900 >= (SELECT compacted_before FROM compaction)
                """)
            try db.execute(sql: """
                INSERT INTO usage_rollups (bucket, provider_id, model_id, project_id, events, input_tokens,
                  cached_input_tokens, cache_write_tokens, cache_write_1h_tokens, output_tokens, reasoning_tokens,
                  cost_nanos, unpriced_events, cache_savings_nanos, cache_savings_tokens)
                """ + Self.rollupsFromEvents)
        }
    }
}

extension UsageRepository {
    /// Deletes all history before `cutoff`: events, a batch per transaction
    /// so a large deletion never holds the writer for long, and the
    /// rollups of compacted time wholly before it. The space is
    /// returned to the disk by `reclaimSpace`. Sessions, projects and source
    /// files stay: they are small, and other events may still point at them.
    @discardableResult
    public func deleteEvents(before cutoff: Timestamp) throws(StoreError) -> Int {
        // Compacted history has no events left to delete, only rollups.
        try database.write { db in
            try db.execute(sql: """
                DELETE FROM usage_rollups
                WHERE (bucket + 1) * ? <= ? AND bucket * ? < (SELECT compacted_before FROM compaction)
                """, arguments: [BurnlineDatabase.bucketSeconds, cutoff.epochSeconds, BurnlineDatabase.bucketSeconds])
        }
        var deleted = 0
        while true {
            let batch = try database.write { db in
                try db.execute(sql: """
                    DELETE FROM usage_events WHERE id IN (
                      SELECT id FROM usage_events WHERE timestamp < ? LIMIT ?)
                    """, arguments: [cutoff.epochSeconds, BurnlineDatabase.deletionBatch])
                return db.changesCount
            }
            deleted += batch
            if batch < BurnlineDatabase.deletionBatch { return deleted }
        }
    }
}
