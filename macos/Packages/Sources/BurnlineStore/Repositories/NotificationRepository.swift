//
//  NotificationRepository.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

extension BurnlineDatabase {
    public var notifications: NotificationRepository { NotificationRepository(database: self) }
}

/// The alerts already sent, so none repeats at the next refresh or after a
/// restart.
public struct NotificationRepository: Sendable {
    let database: BurnlineDatabase

    public func record(_ key: AlertKey, at firedAt: Timestamp) throws(StoreError) {
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO notification_events (
                  provider_id, quota_key, notification_type, threshold, fired_at, cycle_token)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [key.provider.map(database.providerID), key.quotaKey, key.kind.rawValue,
                            key.threshold, firedAt.epochSeconds, key.cycleToken])
        }
    }

    /// Every alert fired since `since`. Older ones belong to windows, days
    /// and weeks long over, so they can never match again.
    public func fired(since: Timestamp) throws(StoreError) -> Set<AlertKey> {
        let providers = Dictionary(uniqueKeysWithValues: ProviderKey.allCases.map { (database.providerID($0), $0) })
        return try database.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM notification_events WHERE fired_at >= ?", arguments: [since.epochSeconds])
            return Set(rows.compactMap { row -> AlertKey? in
                guard let kind = AlertKind(rawValue: row["notification_type"]),
                      let cycle: String = row["cycle_token"] else { return nil }
                let providerID: Int64? = row["provider_id"]
                return AlertKey(provider: providerID.flatMap { providers[$0] }, quotaKey: row["quota_key"],
                                kind: kind, threshold: row["threshold"], cycleToken: cycle)
            })
        }
    }
}
