//
//  QuotaRepository.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

extension BurnlineDatabase {
    public var quota: QuotaRepository { QuotaRepository(database: self) }
}

/// Quota observations and banked resets. Snapshots are appended, never
/// edited: the history is what burn rate and reset detection read.
public struct QuotaRepository: Sendable {
    let database: BurnlineDatabase

    public func append(_ snapshot: QuotaSnapshot) throws(StoreError) {
        let createdAt = database.clock.now.epochSeconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO quota_snapshots (
                  provider_id, quota_key, quota_name, scope, timestamp,
                  used, remaining, limit_value, unit, percentage_used,
                  window_started_at, reset_at, status, source, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    database.providerID(snapshot.provider), snapshot.key, snapshot.name,
                    snapshot.scope.rawValue, snapshot.observedAt.epochSeconds,
                    snapshot.used, snapshot.remaining, snapshot.limit, snapshot.unit, snapshot.percentageUsed,
                    snapshot.windowStartedAt?.epochSeconds, snapshot.resetAt?.epochSeconds,
                    snapshot.status.rawValue, snapshot.source, createdAt,
                ])
        }
    }

    /// The most recent observation of one quota.
    public func latest(provider: ProviderKey, key: String) throws(StoreError) -> QuotaSnapshot? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM quota_snapshots WHERE provider_id = ? AND quota_key = ?
                ORDER BY timestamp DESC, id DESC LIMIT 1
                """,
                arguments: [database.providerID(provider), key]
            ).map { Self.snapshot(from: $0, provider: provider) }
        }
    }

    /// The most recent observation of every quota of `provider`, by key.
    public func latest(provider: ProviderKey) throws(StoreError) -> [QuotaSnapshot] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM quota_snapshots s WHERE provider_id = ? AND id = (
                  SELECT id FROM quota_snapshots WHERE provider_id = s.provider_id AND quota_key = s.quota_key
                  ORDER BY timestamp DESC, id DESC LIMIT 1)
                ORDER BY quota_key
                """,
                arguments: [database.providerID(provider)]
            ).map { Self.snapshot(from: $0, provider: provider) }
        }
    }

    /// One quota's observations from `since` on, oldest first, for burn rate.
    public func history(provider: ProviderKey, key: String, since: Timestamp) throws(StoreError) -> [QuotaSnapshot] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM quota_snapshots WHERE provider_id = ? AND quota_key = ? AND timestamp >= ?
                ORDER BY timestamp, id
                """,
                arguments: [database.providerID(provider), key, since.epochSeconds]
            ).map { Self.snapshot(from: $0, provider: provider) }
        }
    }

    /// Every quota window observed with a reset time: when it began, when it
    /// reset, and the most of its limit seen used. A window is told apart by
    /// its start where the source reports one, so a reset time the provider
    /// moves mid-window stays one cycle, ending at the latest reset reported.
    /// A source that reports no start is told apart by its reset:
    /// grouping all of them together would make every week one window.
    public func cycles() throws(StoreError) -> [AchievementHistory.QuotaCycle] {
        let providers = Dictionary(uniqueKeysWithValues: ProviderKey.allCases.map { (database.providerID($0), $0) })
        return try database.read { db in
            try Row.fetchAll(db, sql: """
                WITH cycles AS (
                  SELECT provider_id, quota_key, coalesce(window_started_at, reset_at) AS cycle,
                         MIN(coalesce(window_started_at, timestamp)) AS start,
                         MAX(percentage_used) AS peak, MAX(timestamp) AS last_seen
                  FROM quota_snapshots
                  WHERE window_started_at IS NOT NULL OR reset_at IS NOT NULL
                  GROUP BY provider_id, quota_key, coalesce(window_started_at, reset_at)
                  HAVING count(reset_at) > 0 AND count(percentage_used) > 0)
                , windows AS (
                SELECT c.provider_id, c.quota_key, c.cycle, c.start, c.peak, c.last_seen,
                       (SELECT q.reset_at FROM quota_snapshots q
                        WHERE q.provider_id = c.provider_id AND q.quota_key = c.quota_key
                          AND coalesce(q.window_started_at, q.reset_at) = c.cycle
                          AND q.reset_at IS NOT NULL
                        ORDER BY q.timestamp DESC, q.id DESC LIMIT 1) AS end
                FROM cycles c)
                SELECT w.*,
                       EXISTS(SELECT 1 FROM quota_snapshots q
                              WHERE q.provider_id = w.provider_id AND q.quota_key = w.quota_key
                                AND q.timestamp > w.last_seen
                                AND coalesce(q.window_started_at, q.reset_at) != w.cycle
                                AND (q.window_started_at > w.start OR q.reset_at > w.end)) AS confirmed
                FROM windows w
                ORDER BY end
                """).compactMap { row in
                guard let provider = providers[row["provider_id"]] else { return nil }
                return AchievementHistory.QuotaCycle(provider: provider, key: row["quota_key"],
                                                     start: Timestamp(epochSeconds: row["start"]),
                                                     end: Timestamp(epochSeconds: row["end"]), peak: row["peak"],
                                                     isConfirmedClosed: row["confirmed"])
            }
        }
    }

    /// Records the latest observation of a banked reset, keyed by the
    /// provider's own id, so its status can move from held to consumed,
    /// expired, or unknown.
    public func save(_ reset: BankedReset) throws(StoreError) {
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO banked_resets (
                  provider_id, source_reset_id, applies_to_quota_key, granted_at, expires_at,
                  consumed_at, status, source, observed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (provider_id, source_reset_id) DO UPDATE SET
                  applies_to_quota_key = excluded.applies_to_quota_key,
                  granted_at = excluded.granted_at,
                  expires_at = excluded.expires_at,
                  consumed_at = excluded.consumed_at,
                  status = excluded.status,
                  source = excluded.source,
                  observed_at = excluded.observed_at
                """,
                arguments: [
                    database.providerID(reset.provider), reset.sourceResetID, reset.appliesToQuotaKey,
                    reset.grantedAt?.epochSeconds, reset.expiresAt?.epochSeconds,
                    reset.consumedAt?.epochSeconds, reset.status.rawValue, reset.source,
                    reset.observedAt.epochSeconds,
                ])
        }
    }

    /// Every banked reset recorded for `provider`, soonest expiry first.
    public func bankedResets(for provider: ProviderKey) throws(StoreError) -> [BankedReset] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM banked_resets WHERE provider_id = ?
                ORDER BY expires_at IS NULL, expires_at, id
                """,
                arguments: [database.providerID(provider)]
            ).map { row in
                BankedReset(
                    provider: provider, sourceResetID: row["source_reset_id"],
                    appliesToQuotaKey: row["applies_to_quota_key"],
                    grantedAt: Self.timestamp(row["granted_at"]), expiresAt: Self.timestamp(row["expires_at"]),
                    consumedAt: Self.timestamp(row["consumed_at"]),
                    status: BankedResetStatus(rawValue: row["status"]) ?? .unknown,
                    source: row["source"], observedAt: Timestamp(epochSeconds: row["observed_at"]))
            }
        }
    }

    /// Saves the explanation still awaited for this cycle. The before figure
    /// references history already recorded, rather than duplicating a sample
    /// and changing its weight in the burn-rate estimate.
    public func savePending(_ reset: PendingQuotaReset) throws(StoreError) {
        try database.write { db in
            let beforeID: Int64?
            if let before = reset.before {
                beforeID = try Int64.fetchOne(db, sql: """
                    SELECT id FROM quota_snapshots WHERE provider_id = ? AND quota_key = ? AND timestamp <= ?
                      AND percentage_used IS ? AND window_started_at IS ? AND reset_at IS ?
                    ORDER BY timestamp DESC, id DESC LIMIT 1
                    """, arguments: [database.providerID(reset.provider), reset.key, before.observedAt.epochSeconds,
                                      before.percentageUsed, before.windowStartedAt?.epochSeconds, before.resetAt?.epochSeconds])
            } else { beforeID = nil }
            try db.execute(sql: """
                INSERT INTO pending_quota_resets (provider_id, quota_key, cycle_token, seen_at, before_snapshot_id)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (provider_id, quota_key) DO UPDATE SET
                  cycle_token = excluded.cycle_token, seen_at = excluded.seen_at,
                  before_snapshot_id = excluded.before_snapshot_id
                """, arguments: [database.providerID(reset.provider), reset.key, reset.cycleToken,
                                  reset.seenAt.epochSeconds, beforeID])
        }
    }

    public func removePending(provider: ProviderKey, key: String) throws(StoreError) {
        try database.write { db in
            try db.execute(sql: "DELETE FROM pending_quota_resets WHERE provider_id = ? AND quota_key = ?",
                           arguments: [database.providerID(provider), key])
        }
    }

    /// Pending explanations are loaded but never announced until a fresh read.
    public func pendingResets(provider: ProviderKey) throws(StoreError) -> [PendingQuotaReset] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.*, p.quota_key AS pending_key, p.cycle_token, p.seen_at
                FROM pending_quota_resets p LEFT JOIN quota_snapshots s ON s.id = p.before_snapshot_id
                WHERE p.provider_id = ? ORDER BY p.quota_key
                """, arguments: [database.providerID(provider)]).map { row in
                    let id: Int64? = row["id"]
                    return PendingQuotaReset(provider: provider, key: row["pending_key"], cycleToken: row["cycle_token"],
                                             before: id.map { _ in Self.snapshot(from: row, provider: provider) },
                                             seenAt: Timestamp(epochSeconds: row["seen_at"]))
                }
        }
    }

    private static func snapshot(from row: Row, provider: ProviderKey) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider, key: row["quota_key"], name: row["quota_name"],
            scope: QuotaScope(rawValue: row["scope"]) ?? .account,
            observedAt: Timestamp(epochSeconds: row["timestamp"]),
            used: row["used"], remaining: row["remaining"], limit: row["limit_value"], unit: row["unit"],
            percentageUsed: row["percentage_used"],
            windowStartedAt: timestamp(row["window_started_at"]), resetAt: timestamp(row["reset_at"]),
            status: QuotaStatus(rawValue: row["status"]) ?? .unknown, source: row["source"])
    }

    private static func timestamp(_ seconds: Int64?) -> Timestamp? {
        seconds.map(Timestamp.init(epochSeconds:))
    }
}
