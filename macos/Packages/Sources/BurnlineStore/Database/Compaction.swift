//
//  Compaction.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import GRDB

/// Compacting history older than the user's detail window into the rollups
/// it already has (schema 9). Lifetime tokens, cost and charts are unchanged;
/// what goes is per-event detail, such as a session's individual replies.
extension BurnlineDatabase {
    /// Seconds per rollup bucket. A boundary is always a multiple of it.
    public static let bucketSeconds: Int64 = 900
    /// The share of stored events a compaction must remove before the file is
    /// rewritten. Deleting events leaves the dedup index's pages part empty
    /// (its keys are random), space incremental vacuum cannot return; only a
    /// `VACUUM` repacks it. Past this share the file left is small enough to
    /// rewrite in seconds, and the space recovered is worth it. Daily passes
    /// remove a day's worth and never reach it.
    static let vacuumShare = 0.25

    /// Events before this instant have been compacted away.
    public func compactedBefore() throws(StoreError) -> Timestamp {
        try read { db in try Self.compactedBefore(in: db) }
    }

    static func compactedBefore(in db: Database) throws -> Timestamp {
        Timestamp(epochSeconds: try Int64.fetchOne(
            db.cachedStatement(sql: "SELECT compacted_before FROM compaction")) ?? 0)
    }

    /// Which of a provider's old events may still be inserted: every one
    /// from the boundary on, and before it, one whose 15-minute bucket holds
    /// none of the provider's compacted history. In such a bucket the rollups
    /// count exactly the provider's stored events, so a new event cannot be
    /// one already counted; a bucket holding compacted history cannot tell,
    /// and refuses. History read for the first time after the rest
    /// was compacted, from a provider tracked later or a file found later,
    /// therefore still counts, and the next pass compacts it.
    ///
    /// A judgement holds for one transaction: inserting into a bucket without
    /// compacted history keeps it without.
    struct LateHistory {
        let boundary: Timestamp
        private var judged: [Int64: [Int64: Bool]] = [:]

        init(in db: Database) throws {
            boundary = try BurnlineDatabase.compactedBefore(in: db)
        }

        mutating func accepts(_ timestamp: Timestamp, providerID: Int64, in db: Database) throws -> Bool {
            guard timestamp < boundary else { return true }
            let bucket = timestamp.epochSeconds / BurnlineDatabase.bucketSeconds
            if let known = judged[providerID]?[bucket] { return known }
            let open = try Bool.fetchOne(db.cachedStatement(sql: """
                SELECT coalesce((SELECT sum(events) FROM usage_rollups WHERE bucket = ?1 AND provider_id = ?2), 0)
                     = (SELECT count(*) FROM usage_events
                        WHERE timestamp >= ?1 * ?3 AND timestamp < (?1 + 1) * ?3 AND provider_id = ?2)
                """), arguments: [bucket, providerID, BurnlineDatabase.bucketSeconds]) ?? false
            judged[providerID, default: [:]][bucket] = open
            return open
        }
    }

    /// Compacts every event before `cutoff`, rounded down to a whole bucket
    /// so no bucket is part compacted. The boundary moves first and only
    /// forward, so ingestion stops accepting older events before any is
    /// deleted; a crash midway leaves events whose rollups are already safe,
    /// and the next pass finishes them. Freed space returns to the disk, and a
    /// compaction that removes a large share is followed by a `VACUUM`.
    ///
    /// The boundary moves only as far as the end of the bucket holding the
    /// newest stored event before the cutoff: it marks history that is in the
    /// rollups, never time nothing was imported for. On a new store
    /// it stays put, so the first import keeps everything older than the
    /// window and a later pass compacts it.
    @discardableResult
    public func compact(before cutoff: Timestamp) throws(StoreError) -> Int {
        let boundary = cutoff.epochSeconds - ((cutoff.epochSeconds % Self.bucketSeconds) + Self.bucketSeconds)
            % Self.bucketSeconds
        try write { db in
            try db.execute(sql: """
                UPDATE compaction SET compacted_before = max(compacted_before, coalesce(
                  (SELECT min(?1, (max(timestamp) / ?2 + 1) * ?2) FROM usage_events WHERE timestamp < ?1),
                  0))
                """, arguments: [boundary, Self.bucketSeconds])
        }
        let current = try compactedBefore()
        let stored = try usage.count()
        var removed = 0
        while true {
            let batch = try write { db in
                try db.execute(sql: """
                    DELETE FROM usage_events WHERE id IN (
                      SELECT id FROM usage_events WHERE timestamp < ? LIMIT ?)
                    """, arguments: [current.epochSeconds, Self.deletionBatch])
                return db.changesCount
            }
            removed += batch
            if batch < Self.deletionBatch { break }
        }
        if removed > 0 { try reclaimSpace() }
        if stored > 0, Double(removed) >= Self.vacuumShare * Double(stored) { try vacuum() }
        return removed
    }

    /// Rewrites the file packed tight. Holds the writer for the rewrite, which
    /// is why only a large compaction asks for it.
    func vacuum() throws(StoreError) {
        do { try pool.writeWithoutTransaction { try $0.execute(sql: "VACUUM") } }
        catch { throw StoreError.from(error, file: location.databaseFile) }
    }
}

extension UsageRepository {
    /// Totals over the 15-minute buckets that start inside `window`, from the
    /// rollups. Every local day, week and month boundary falls on a bucket
    /// edge, so for those windows this is exact; a window cut mid-bucket is
    /// rounded to quarter hours, as every rollup query is.
    public func totals(in window: TimeWindow, provider: ProviderKey? = nil) throws(StoreError) -> UsageTotals {
        let first = AggregationRepository.bucket(atOrAfter: window.start)
        let end = AggregationRepository.bucket(atOrAfter: window.end)
        return try database.read { db in
            var sql = """
                SELECT coalesce(sum(events), 0) AS events, coalesce(sum(input_tokens), 0) AS input,
                       coalesce(sum(cached_input_tokens), 0) AS cached, coalesce(sum(cache_write_tokens), 0) AS write,
                       coalesce(sum(cache_write_1h_tokens), 0) AS write1h, coalesce(sum(output_tokens), 0) AS output,
                       coalesce(sum(reasoning_tokens), 0) AS reasoning, coalesce(sum(cost_nanos), 0) AS cost,
                       coalesce(sum(unpriced_events), 0) AS unpriced, coalesce(sum(cache_savings_nanos), 0) AS saved,
                       coalesce(sum(cache_savings_tokens), 0) AS covered
                FROM usage_rollups WHERE bucket >= ? AND bucket < ?
                """
            var arguments: StatementArguments = [first, end]
            if let provider {
                sql += " AND provider_id = ?"
                arguments += [database.providerID(provider)]
            }
            return try AggregationRepository.totals(from: Row.fetchOne(db, sql: sql, arguments: arguments)!)
        }
    }
}
