//
//  BurnlineDatabase.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import GRDB

/// The open database. Opening is where every dangerous case is decided, in
/// this order: take the writer lock, refuse a corrupt or newer file, back up,
/// migrate atomically, seed the providers.
///
/// Reads are concurrent. Writes are serialised by the pool, and in the app all
/// of them come from the ingestion actor.
public final class BurnlineDatabase: Sendable {
    public enum AccessMode: Sendable {
        /// Takes the writer lock and migrates. The app's normal mode.
        case writer
        /// No lock, no migration, no writes. For a reader alongside a running
        /// app, such as an export. It relies on the writer's `-shm` file, which
        /// SQLite needs to read a WAL database without write access.
        case readOnly
    }

    /// How long a statement waits for a lock held by another connection.
    static let busyTimeout: TimeInterval = 5
    /// WAL pages written between automatic checkpoints, 32 MB at 4 KB pages.
    /// Each checkpoint makes two full syncs to the disk, which at SQLite's
    /// default of 1,000 pages took three quarters of an import's time.
    static let walCheckpointPages = 8_192
    /// The writer's page cache. SQLite's default of 2 MB re-reads index pages
    /// on nearly every insert once the database outgrows it.
    static let writerCacheKilobytes = 32 * 1_024
    /// The size the WAL is cut back to after a checkpoint. SQLite
    /// reuses the WAL from the start once readers move on, but without a
    /// limit the file keeps the size of the largest write it ever held.
    /// Above the checkpoint interval, so normal use never truncates it.
    static let walSizeLimit = 64 * 1_024 * 1_024

    public let location: StoreLocation
    let pool: DatabasePool
    let clock: any WallClock
    let providerIDs: [ProviderKey: Int64]
    private let writerLock: WriterLock?

    public static func open(at location: StoreLocation, schema: Schema, clock: any WallClock,
                            mode: AccessMode = .writer) throws(StoreError) -> BurnlineDatabase {
        let file = location.databaseFile
        do {
            try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        } catch {
            throw .sqlite("cannot create \(location.directory.path): \(error.localizedDescription)")
        }

        var lock: WriterLock?
        if mode == .writer {
            guard let acquired = try WriterLock(path: location.lockFile) else { throw .anotherWriterIsRunning }
            lock = acquired
            // A restore the user chose waits for this moment: the lock is
            // held and nothing has the file open.
            try DatabaseBackups.applyStagedRestore(in: location, clock: clock)
        }

        let existed = FileManager.default.fileExists(atPath: file.path)
        // Probe the version before the pool opens, because opening a pool
        // writes to the file (it switches the journal to WAL), and a database
        // from a newer build must not be touched at all.
        let version = existed ? try readVersion(of: file) : 0
        guard version <= schema.latestVersion else {
            throw .newerSchema(found: version, supported: schema.latestVersion)
        }
        if mode == .readOnly && version != schema.latestVersion {
            throw .schemaMismatch(found: version, expected: schema.latestVersion)
        }

        let pool: DatabasePool
        do { pool = try DatabasePool(path: file.path, configuration: configuration(mode)) }
        catch { throw StoreError.from(error, file: file) }

        if mode == .writer {
            if version == 0 { try useIncrementalVacuum(pool, file: file) }
            try migrate(pool, from: version, schema: schema, location: location, clock: clock)
            try seedProviders(pool, clock: clock, file: file)
            compactIntoIncrementalVacuum(pool)
        }

        let providerIDs: [ProviderKey: Int64]
        do {
            providerIDs = try pool.read { db in
                let rows = try Row.fetchAll(db, sql: "SELECT id, key FROM providers")
                return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                    ProviderKey(rawValue: row["key"]).map { ($0, row["id"] as Int64) }
                })
            }
        } catch { throw StoreError.from(error, file: file) }

        let database = BurnlineDatabase(location: location, pool: pool, clock: clock,
                                        providerIDs: providerIDs, writerLock: lock)
        // Schema 9 keeps cache savings per event, which only the pricer can
        // compute; events stored before it get theirs once, here.
        if mode == .writer, version > 0, version < cacheSavingsVersion, schema.latestVersion >= cacheSavingsVersion {
            try database.pricing.repriceAll()
            if schema.latestVersion >= pendingRepricingVersion {
                // The full pass already covered every queued version. Clear
                // only after success, so a failed or interrupted pass retries.
                try database.write { try $0.execute(sql: "DELETE FROM pending_repricing") }
            }
        }
        return database
    }

    /// The schema version that added per-event cache savings.
    static let cacheSavingsVersion = 9
    /// The schema version that queues interrupted pricing recalculations.
    static let pendingRepricingVersion = 11

    private init(location: StoreLocation, pool: DatabasePool, clock: any WallClock,
                 providerIDs: [ProviderKey: Int64], writerLock: WriterLock?) {
        self.location = location
        self.pool = pool
        self.clock = clock
        self.providerIDs = providerIDs
        self.writerLock = writerLock
    }

    /// The schema version recorded in the file.
    public func schemaVersion() throws(StoreError) -> Int {
        try read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }
    }

    // MARK: Access for repositories

    func read<T>(_ body: (Database) throws -> T) throws(StoreError) -> T {
        do { return try pool.read(body) }
        catch { throw StoreError.from(error, file: location.databaseFile) }
    }

    /// One transaction: everything in `body` commits, or none of it does.
    func write<T>(_ body: (Database) throws -> T) throws(StoreError) -> T {
        do { return try pool.write(body) }
        catch { throw StoreError.from(error, file: location.databaseFile) }
    }

    func providerID(_ provider: ProviderKey) -> Int64 {
        // Every case is seeded on open, so a missing id is a programming error.
        providerIDs[provider]!
    }

    // MARK: Opening

    private static func configuration(_ mode: AccessMode) -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(busyTimeout)
        configuration.readonly = mode == .readOnly
        if mode == .writer {
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_size_limit = \(walSizeLimit)")
                // In WAL mode, NORMAL syncs at checkpoints rather than at every
                // commit. Power loss can then drop the last few commits but
                // never corrupts the file, and a dropped batch is harmless:
                // its events and its file offset were committed together, so
                // the next sync re-reads those lines. Syncing every commit
                // cost most of the import time.
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
                try db.execute(sql: "PRAGMA wal_autocheckpoint = \(walCheckpointPages)")
                // Upserts write a statement journal; in memory it costs no I/O.
                try db.execute(sql: "PRAGMA temp_store = MEMORY")
                // The indexes an insert touches stay cached across batches.
                try db.execute(sql: "PRAGMA cache_size = -\(writerCacheKilobytes)")
            }
        }
        return configuration
    }

    /// Sets an empty file to return freed pages on request. It is a
    /// property of the file, settable only before the first table exists, so
    /// it cannot live in a migration.
    private static func useIncrementalVacuum(_ pool: DatabasePool, file: URL) throws(StoreError) {
        do { try pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL") } }
        catch { throw StoreError.from(error, file: file) }
    }

    /// A file created before incremental vacuum is switched to it, which takes
    /// one full `VACUUM`. That also returns the space earlier migrations left
    /// free. It runs at open, before any reader or ingestion, and only once:
    /// a failure (a full disk, say) leaves the file as it was, to retry at the
    /// next launch.
    private static func compactIntoIncrementalVacuum(_ pool: DatabasePool) {
        try? pool.writeWithoutTransaction { db in
            guard try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") != Vacuum.incremental else { return }
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            try db.execute(sql: "VACUUM")
        }
    }

    /// Reads `user_version` through a short-lived connection that only reads.
    /// A file that is not SQLite fails here, before anything has written to it.
    ///
    /// Not a read-only connection: SQLite cannot open a WAL database read-only
    /// while its `-shm` file is missing, which is exactly the state after a
    /// clean shutdown or a restore. A plain queue leaves the journal mode alone,
    /// so it writes nothing to the database file itself.
    private static func readVersion(of file: URL) throws(StoreError) -> Int {
        do {
            let probe = try DatabaseQueue(path: file.path)
            return try probe.read { db in
                // Forces SQLite to read the schema, which is what fails on a
                // file that is not a database.
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
                return try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            }
        } catch {
            throw StoreError.from(error, file: file)
        }
    }

    /// Applies every pending migration in one transaction, so a failure leaves
    /// the database exactly at `version`. An existing database is backed up
    /// first; the backup is what the user restores if a migration succeeded
    /// but turned out wrong.
    private static func migrate(_ pool: DatabasePool, from version: Int, schema: Schema,
                                location: StoreLocation, clock: any WallClock) throws(StoreError) {
        let pending = schema.pending(after: version)
        guard !pending.isEmpty else { return }

        var backup: URL?
        if version > 0 {
            let destination = DatabaseBackups.newBackupURL(in: location, version: version, at: clock.now)
            do {
                try FileManager.default.createDirectory(at: location.backupsDirectory,
                                                        withIntermediateDirectories: true)
                try pool.backup(to: DatabaseQueue(path: destination.path))
            } catch {
                // No backup means no migration: the user's data is never put at
                // risk without a way back.
                throw .migrationFailed(version: version, backup: nil,
                                       reason: "backup failed: \(error.localizedDescription)")
            }
            backup = destination
            DatabaseBackups.prune(in: location)
        }

        do {
            try pool.write { db in
                for migration in pending {
                    try db.execute(sql: migration.sql)
                    try db.execute(sql: "PRAGMA user_version = \(migration.version)")
                }
            }
        } catch {
            throw .migrationFailed(version: version, backup: backup, reason: String(describing: error))
        }
    }

    private static func seedProviders(_ pool: DatabasePool, clock: any WallClock,
                                      file: URL) throws(StoreError) {
        do {
            try pool.write { db in
                for provider in ProviderKey.allCases {
                    try db.execute(
                        sql: """
                        INSERT INTO providers (key, display_name, created_at) VALUES (?, ?, ?)
                        ON CONFLICT (key) DO NOTHING
                        """,
                        arguments: [provider.rawValue, provider.displayName, clock.now.epochSeconds])
                }
            }
        } catch {
            throw StoreError.from(error, file: file)
        }
    }
}
