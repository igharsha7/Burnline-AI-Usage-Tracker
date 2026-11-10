//
//  StoreError.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import GRDB

/// Everything the store can refuse to do, phrased so the interface can say what
/// happened and what the user can do about it.
public enum StoreError: Error, Sendable {
    /// The disk is full or the database hit its size limit. The write rolled
    /// back; nothing partial was kept.
    case diskFull
    /// The file is not a readable SQLite database. It is left exactly as found,
    /// never recreated empty.
    case corrupt(URL)
    /// A migration failed and rolled back. The database is still at
    /// `version`, and `backup` holds a copy taken just before.
    case migrationFailed(version: Int, backup: URL?, reason: String)
    /// Another Burnline process holds the writer lock.
    case anotherWriterIsRunning
    /// The database was written by a newer Burnline. Reading it partially could
    /// lose columns this build does not know, so it is not opened.
    case newerSchema(found: Int, supported: Int)
    /// A read-only open found a database at a different schema version.
    case schemaMismatch(found: Int, expected: Int)
    /// The shipped schema files are malformed: missing, misnumbered, or with a
    /// gap. A build error, not a user one.
    case invalidSchema(String)
    /// Any other SQLite failure.
    case sqlite(String)

    /// Maps a SQLite failure onto the cases the interface distinguishes.
    static func from(_ error: any Error, file: URL) -> StoreError {
        if let storeError = error as? StoreError { return storeError }
        guard let databaseError = error as? DatabaseError else { return .sqlite(String(describing: error)) }
        switch databaseError.resultCode {
        case .SQLITE_FULL: return .diskFull
        case .SQLITE_CORRUPT, .SQLITE_NOTADB: return .corrupt(file)
        default: return .sqlite(databaseError.description)
        }
    }
}

extension StoreError {
    /// The failure as the interface explains it.
    public var failure: StoreFailure {
        switch self {
        case .diskFull: .diskFull
        case .corrupt: .corrupt
        case .migrationFailed(_, let backup, _): .migrationFailed(backup: backup)
        case .anotherWriterIsRunning: .anotherInstance
        case .newerSchema(let found, let supported): .newerVersion(found: found, supported: supported)
        case .schemaMismatch(let found, let expected): .other("database version \(found), expected \(expected)")
        case .invalidSchema(let reason), .sqlite(let reason): .other(reason)
        }
    }
}
