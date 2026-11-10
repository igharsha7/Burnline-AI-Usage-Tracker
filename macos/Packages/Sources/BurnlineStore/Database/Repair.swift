//
//  Repair.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

extension BurnlineDatabase {
    /// Checks the file and Burnline's own invariants: SQLite's integrity and
    /// foreign keys, rollups agreeing with the events behind them, daily
    /// totals agreeing with the rollups, and no event before the compaction
    /// boundary. Reads only.
    public func check() throws(StoreError) -> DatabaseCheck {
        try read { db in
            var problems: [String] = []
            let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            if integrity != ["ok"] {
                problems.append("SQLite integrity check: \(integrity.prefix(5).joined(separator: "; "))")
            }
            let keys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
            if keys > 0 { problems.append("\(keys) rows point at rows that no longer exist") }

            let rollupColumns = """
                bucket, provider_id, model_id, project_id, events, input_tokens, cached_input_tokens,
                cache_write_tokens, cache_write_1h_tokens, output_tokens, reasoning_tokens, cost_nanos,
                unpriced_events, cache_savings_nanos, cache_savings_tokens
                """
            let stored = "SELECT \(rollupColumns) FROM usage_rollups WHERE bucket * \(Self.bucketSeconds) >= (SELECT compacted_before FROM compaction)"
            let drift = try Int.fetchOne(db, sql: """
                SELECT (SELECT count(*) FROM (\(Self.rollupsFromEvents) EXCEPT \(stored)))
                     + (SELECT count(*) FROM (\(stored) EXCEPT \(Self.rollupsFromEvents)))
                """) ?? 0
            if drift > 0 { problems.append("\(drift) quarter-hour totals disagree with their events") }

            let sums = """
                events, input_tokens, cached_input_tokens, cache_write_tokens, cache_write_1h_tokens,
                output_tokens, reasoning_tokens, cost_nanos, unpriced_events, cache_savings_nanos, cache_savings_tokens
                """
            let fromRollups = """
                SELECT bucket / 96, provider_id, model_id, project_id, sum(events), sum(input_tokens),
                  sum(cached_input_tokens), sum(cache_write_tokens), sum(cache_write_1h_tokens), sum(output_tokens),
                  sum(reasoning_tokens), sum(cost_nanos), sum(unpriced_events), sum(cache_savings_nanos),
                  sum(cache_savings_tokens)
                FROM usage_rollups GROUP BY 1, 2, 3, 4
                """
            let daily = "SELECT day, provider_id, model_id, project_id, \(sums) FROM daily_rollups"
            let dailyDrift = try Int.fetchOne(db, sql: """
                SELECT (SELECT count(*) FROM (\(fromRollups) EXCEPT \(daily)))
                     + (SELECT count(*) FROM (\(daily) EXCEPT \(fromRollups)))
                """) ?? 0
            if dailyDrift > 0 { problems.append("\(dailyDrift) daily totals disagree with the quarter-hour totals") }

            // Events before the boundary are history imported late, waiting
            // for the next pass. Their rollups must count each of them; a
            // bucket counting fewer has lost track of one.
            let early = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM (
                  SELECT timestamp / 900 AS bucket, provider_id, coalesce(model_id, 0) AS model,
                         coalesce(project_id, 0) AS project, count(*) AS events
                  FROM usage_events WHERE timestamp < (SELECT compacted_before FROM compaction)
                  GROUP BY 1, 2, 3, 4) e
                LEFT JOIN usage_rollups r ON r.bucket = e.bucket AND r.provider_id = e.provider_id
                  AND r.model_id = e.model AND r.project_id = e.project
                WHERE coalesce(r.events, 0) < e.events
                """) ?? 0
            if early > 0 { problems.append("\(early) quarter hours of late history are missing from the totals") }
            return DatabaseCheck(problems: problems)
        }
    }

    /// Points events at the model their raw name now resolves to, for names
    /// the manifest learned after the events arrived: an unrecognised name
    /// was kept as its own unpriced model, and an alias added since
    /// maps it to a known one. Time-bounded aliases apply by each event's
    /// time. Compacted history keeps its models, having no events.
    /// Returns how many events moved; the caller re-prices them.
    @discardableResult
    public func remapModels() throws(StoreError) -> Int {
        let alias = """
            SELECT a.model_id FROM model_aliases a JOIN models m ON m.id = usage_events.model_id
            WHERE a.provider_id = usage_events.provider_id AND a.raw_model_name = m.canonical_name
              AND (a.valid_from IS NULL OR a.valid_from <= usage_events.timestamp)
              AND (a.valid_until IS NULL OR usage_events.timestamp < a.valid_until)
            ORDER BY a.valid_from IS NULL, a.valid_from DESC LIMIT 1
            """
        return try write { db in
            try db.execute(sql: """
                UPDATE usage_events SET model_id = (\(alias))
                WHERE model_id IS NOT NULL AND coalesce((\(alias)), model_id) != model_id
                  AND timestamp >= (SELECT compacted_before FROM compaction)
                """)
            return db.changesCount
        }
    }

    /// How many rows each table holds, for diagnostics: counts only.
    public func diagnosticCounts() throws(StoreError) -> [String: Int] {
        try read { db in
            var counts: [String: Int] = [:]
            for table in ["usage_events", "usage_rollups", "sessions", "projects", "models", "pricing_versions",
                          "quota_snapshots", "source_states", "parser_errors", "pending_repricing", "achievements"] {
                counts[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
            }
            return counts
        }
    }
}
