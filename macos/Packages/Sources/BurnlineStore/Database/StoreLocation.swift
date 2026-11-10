//
//  StoreLocation.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// Where the database, its lock, and its backups live. Injected, so tests use a
/// temporary directory and the app uses Application Support.
public struct StoreLocation: Sendable {
    static let databaseName = "burnline.sqlite"
    static let lockName = "burnline.sqlite.lock"
    static let backupsName = "Backups"

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/Burnline/`, where the app keeps its data.
    public static var applicationSupport: StoreLocation {
        StoreLocation(directory: URL.applicationSupportDirectory.appending(path: "Burnline"))
    }

    public var databaseFile: URL { directory.appending(path: Self.databaseName) }
    public var backupsDirectory: URL { directory.appending(path: Self.backupsName) }
    var lockFile: URL { directory.appending(path: Self.lockName) }

    /// SQLite's companion files in WAL mode. They belong to the database and
    /// move with it.
    var companionFiles: [URL] {
        ["-wal", "-shm"].map { directory.appending(path: Self.databaseName + $0) }
    }
}

/// File-copy backups of the database, taken before migrations and offered as
/// the way back from a corrupt or failed state. Restoring never deletes the
/// file it replaces; it is moved aside.
public enum DatabaseBackups {
    /// Backups in `location`, newest first.
    public static func list(in location: StoreLocation) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: location.backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> (url: URL, stamp: String, version: Int, suffix: Int)? in
            guard let name = file.lastPathComponent.wholeMatch(
                of: /burnline-v([0-9]+)-([0-9]{8}T[0-9]{6}Z)(?:-([0-9]+))?\.sqlite/),
                  let version = Int(name.1) else { return nil }
            return (file, String(name.2), version, name.3.flatMap { Int($0) } ?? 1)
        }
            .sorted { a, b in
                (a.stamp, a.version, a.suffix) > (b.stamp, b.version, b.suffix)
            }
            .map(\.url)
    }

    /// Replaces the database with `backup`. The database must not be open.
    /// Returns where the replaced file was moved, so nothing is lost if the
    /// backup turns out to be the wrong one.
    @discardableResult
    public static func restore(_ backup: URL, to location: StoreLocation,
                               clock: any WallClock) throws(StoreError) -> URL? {
        let manager = FileManager.default
        let stamp = fileStamp(clock.now)
        var staging = location.directory.appending(path: "burnline.restore-\(stamp).sqlite")
        var suffix = 2
        while manager.fileExists(atPath: staging.path) {
            staging = location.directory.appending(path: "burnline.restore-\(stamp)-\(suffix).sqlite")
            suffix += 1
        }
        defer { try? manager.removeItem(at: staging) }
        let replacedBase = "\(location.databaseFile.lastPathComponent).replaced-\(stamp)"
        var replacedName = replacedBase
        var replacedSuffix = 2
        while ["", "-wal", "-shm"].contains(where: {
            manager.fileExists(atPath: location.directory.appending(path: replacedName + $0).path)
        }) {
            replacedName = "\(replacedBase)-\(replacedSuffix)"
            replacedSuffix += 1
        }
        var setAside: URL?
        var moved: [(original: URL, destination: URL)] = []
        do {
            // Finish the fallible copy before moving the current database:
            // a missing backup or full disk must leave it ready to reopen.
            try manager.copyItem(at: backup, to: staging)
            for file in [location.databaseFile] + location.companionFiles where manager.fileExists(atPath: file.path) {
                let companion = file.lastPathComponent.dropFirst(location.databaseFile.lastPathComponent.count)
                let destination = location.directory
                    .appending(path: "\(replacedName)\(companion)")
                try manager.moveItem(at: file, to: destination)
                moved.append((file, destination))
                if file == location.databaseFile { setAside = destination }
            }
            try manager.moveItem(at: staging, to: location.databaseFile)
        } catch {
            for file in moved.reversed() {
                try? manager.moveItem(at: file.destination, to: file.original)
            }
            throw .sqlite("restore failed: \(error.localizedDescription)")
        }
        return setAside
    }

    /// How many backups are kept. Each is a full copy of the database, so they
    /// are bounded by count; the newest is the one a failed or wrong
    /// migration is undone from.
    public static let kept = 3

    /// Removes all but the newest `kept` backups.
    static func prune(in location: StoreLocation) {
        for stale in list(in: location).dropFirst(kept) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// A unique path for a new backup of a database at `version`.
    static func newBackupURL(in location: StoreLocation, version: Int, at instant: Timestamp) -> URL {
        let base = "burnline-v\(version)-\(fileStamp(instant))"
        var candidate = location.backupsDirectory.appending(path: "\(base).sqlite")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = location.backupsDirectory.appending(path: "\(base)-\(suffix).sqlite")
            suffix += 1
        }
        return candidate
    }

    /// `20261031T183000Z`: sortable, and safe in a file name.
    static func fileStamp(_ instant: Timestamp) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant.date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", parts.year!, parts.month!, parts.day!,
                      parts.hour!, parts.minute!, parts.second!)
    }
}
