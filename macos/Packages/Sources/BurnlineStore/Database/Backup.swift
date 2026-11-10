//
//  Backup.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import GRDB

extension BurnlineDatabase {
    /// A consistent copy of the whole database at `file`, taken while
    /// ingestion keeps writing: SQLite copies a snapshot.
    public func backup(to file: URL) throws(StoreError) {
        do {
            try pool.backup(to: DatabaseQueue(path: file.path))
        } catch {
            throw StoreError.from(error, file: file)
        }
    }
}

extension DatabaseBackups {
    /// A restore waiting for the next launch, beside the database.
    static let stagedName = "burnline.pending-restore.sqlite"

    static func stagedFile(in location: StoreLocation) -> URL {
        location.directory.appending(path: stagedName)
    }

    /// Whether a restore is waiting for the next launch.
    public static func hasStagedRestore(in location: StoreLocation) -> Bool {
        FileManager.default.fileExists(atPath: stagedFile(in: location).path)
    }

    /// Copies `backup` beside the database and checks the copy, so the
    /// user's file is only ever read. A backup that is not a sound Burnline
    /// database, or one from a newer Burnline, is refused and nothing is
    /// staged. The running database is replaced at the next open, when no
    /// connection holds it.
    public static func stageRestore(_ backup: URL, in location: StoreLocation,
                                    schema: Schema) throws(StoreError) -> BackupInspection {
        let staged = stagedFile(in: location)
        let manager = FileManager.default
        try? manager.removeItem(at: staged)
        do {
            try manager.copyItem(at: backup, to: staged)
        } catch {
            throw .sqlite("cannot copy the backup: \(error.localizedDescription)")
        }
        do {
            let inspection = try inspect(staged, schema: schema)
            removeCompanions(of: staged)
            return inspection
        } catch {
            removeCompanions(of: staged)
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    /// Withdraws a staged restore.
    public static func cancelStagedRestore(in location: StoreLocation) {
        try? FileManager.default.removeItem(at: stagedFile(in: location))
    }

    /// Replaces the database with the staged backup, if one waits. Called
    /// at open with the writer lock held and before any connection exists.
    /// The replaced database is moved aside, never deleted.
    static func applyStagedRestore(in location: StoreLocation, clock: any WallClock) throws(StoreError) {
        let staged = stagedFile(in: location)
        guard FileManager.default.fileExists(atPath: staged.path) else { return }
        try restore(staged, to: location, clock: clock)
        try? FileManager.default.removeItem(at: staged)
    }

    /// Reads a database file's version and contents, after SQLite's own
    /// integrity check. Opened as a plain queue, as the version probe is,
    /// since a WAL file cannot be opened read-only without its `-shm`.
    static func inspect(_ file: URL, schema: Schema) throws(StoreError) -> BackupInspection {
        do {
            let queue = try DatabaseQueue(path: file.path)
            defer { try? queue.close() }
            return try queue.read { db in
                let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                guard version > 0, try db.tableExists("usage_events") else {
                    throw StoreError.sqlite("this is not a Burnline backup")
                }
                guard version <= schema.latestVersion else {
                    throw StoreError.newerSchema(found: version, supported: schema.latestVersion)
                }
                let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                guard integrity == ["ok"] else { throw StoreError.corrupt(file) }
                let events = try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_events") ?? 0
                // Rollups arrived in version 8; before them, events are all there is.
                let span = try db.tableExists("usage_rollups")
                    ? "SELECT min(bucket) * \(BurnlineDatabase.bucketSeconds), (max(bucket) + 1) * \(BurnlineDatabase.bucketSeconds) - 1 FROM usage_rollups"
                    : "SELECT min(timestamp), max(timestamp) FROM usage_events"
                let row = try Row.fetchOne(db, sql: span)
                return BackupInspection(schemaVersion: version, events: events,
                                        earliest: (row?[0] as Int64?).map(Timestamp.init(epochSeconds:)),
                                        latest: (row?[1] as Int64?).map(Timestamp.init(epochSeconds:)))
            }
        } catch {
            throw StoreError.from(error, file: file)
        }
    }

    private static func removeCompanions(of file: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(filePath: file.path + suffix))
        }
    }
}
