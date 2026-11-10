//
//  AchievementRepository.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

extension BurnlineDatabase {
    public var achievements: AchievementRepository { AchievementRepository(database: self) }
}

/// Achievements earned, each stored once. A stored one is never rewritten,
/// so recomputing after a backfill or a repricing cannot move its date.
public struct AchievementRepository: Sendable {
    let database: BurnlineDatabase

    /// Stores the ones not stored yet and leaves the rest as they are.
    /// Returns how many were new.
    @discardableResult
    public func award(_ achievements: [Achievement], at createdAt: Timestamp) throws(StoreError) -> Int {
        try database.write { db in
            let statement = try db.cachedStatement(sql: """
                INSERT INTO achievements (key, tier, provider_id, value, awarded_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (key, tier) DO NOTHING
                """)
            var added = 0
            for achievement in achievements {
                try statement.execute(arguments: [
                    achievement.kind.rawValue, achievement.tier, achievement.provider.map(database.providerID),
                    achievement.value, achievement.awardedAt.epochSeconds, createdAt.epochSeconds])
                added += db.changesCount
            }
            return added
        }
    }

    /// Takes the achievements no notification has been decided for, oldest
    /// first, and marks them announced. `firstEver` is true when none had
    /// ever been announced: a new store's first awards are its backfill, too
    /// many and too old to announce.
    public func takeUnannounced(at now: Timestamp) throws(StoreError) -> (achievements: [Achievement], firstEver: Bool) {
        try database.write { db in
            let firstEver = try Int.fetchOne(db, sql: "SELECT count(*) FROM achievements WHERE announced_at IS NOT NULL") == 0
            let unannounced = try Row.fetchAll(db, sql: """
                SELECT * FROM achievements WHERE announced_at IS NULL ORDER BY awarded_at, id
                """).compactMap(achievement)
            try db.execute(sql: "UPDATE achievements SET announced_at = ? WHERE announced_at IS NULL",
                           arguments: [now.epochSeconds])
            return (unannounced, firstEver)
        }
    }

    /// The achievements whose arrival has not been played yet, oldest first.
    public func uncelebrated() throws(StoreError) -> [Achievement] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM achievements WHERE celebrated_at IS NULL ORDER BY awarded_at, id
                """).compactMap(achievement)
        }
    }

    /// Marks only the achievements whose arrival just played. A medal awarded
    /// while that arrival is open remains waiting for the next one.
    public func celebrate(_ achievements: [Achievement], at now: Timestamp) throws(StoreError) {
        guard !achievements.isEmpty else { return }
        try database.write { db in
            let statement = try db.cachedStatement(sql: """
                UPDATE achievements SET celebrated_at = ?
                WHERE key = ? AND tier = ? AND celebrated_at IS NULL
                """)
            for achievement in achievements {
                try statement.execute(arguments: [now.epochSeconds, achievement.kind.rawValue, achievement.tier])
            }
        }
    }

    /// Every stored achievement, oldest first. Rows of a kind this build does
    /// not know are skipped, not failed on.
    public func all() throws(StoreError) -> [Achievement] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM achievements ORDER BY awarded_at, id").compactMap(achievement)
        }
    }

    /// The achievements added to the store at or after `moment`, oldest
    /// earned first: what an import has just found, whenever it was earned.
    public func added(since moment: Timestamp) throws(StoreError) -> [Achievement] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM achievements WHERE created_at >= ? ORDER BY awarded_at, id",
                             arguments: [moment.epochSeconds]).compactMap(achievement)
        }
    }

    private func achievement(_ row: Row) -> Achievement? {
        guard let kind = AchievementKind(rawValue: row["key"]), let tier: String = row["tier"] else { return nil }
        let providerID: Int64? = row["provider_id"]
        return Achievement(kind: kind, tier: tier,
                           provider: providerID.flatMap { id in ProviderKey.allCases.first { database.providerID($0) == id } },
                           value: row["value"] ?? 0, awardedAt: Timestamp(epochSeconds: row["awarded_at"]))
    }
}
