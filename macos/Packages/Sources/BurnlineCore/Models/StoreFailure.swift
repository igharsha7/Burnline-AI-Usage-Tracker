//
//  StoreFailure.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// Why Burnline's own database could not be opened or written, in the
/// words the interface uses. Every case leaves the database as it was:
/// none is recovered from by starting over empty.
public enum StoreFailure: Error, Hashable, Sendable {
    /// The disk is full. The write rolled back, and nothing partial was kept.
    case diskFull
    /// The file is not a readable database. It is left exactly as found.
    case corrupt
    /// An update's migration failed and rolled back; `backup` was taken just before.
    case migrationFailed(backup: URL?)
    /// Another copy of Burnline is writing to the database.
    case anotherInstance
    /// A newer Burnline wrote the database, so this one does not read it.
    case newerVersion(found: Int, supported: Int)
    /// Anything else, with SQLite's own words.
    case other(String)

    public var title: String {
        switch self {
        case .diskFull: "The disk is full"
        case .corrupt: "Burnline’s database cannot be read"
        case .migrationFailed: "Burnline could not update its database"
        case .anotherInstance: "Burnline is already running"
        case .newerVersion: "This database is from a newer Burnline"
        case .other: "Burnline’s database could not be opened"
        }
    }

    /// The failure as part of a sentence: "New usage is not being saved: the disk is full."
    public var cause: String {
        switch self {
        case .diskFull: "the disk is full"
        case .corrupt: "Burnline’s database is damaged"
        case .migrationFailed: "an update to Burnline’s database failed"
        case .anotherInstance: "another copy of Burnline is writing"
        case .newerVersion: "the database is from a newer Burnline"
        case .other(let reason): reason
        }
    }

    /// What happened to the user's history, and what they can do.
    public var explanation: String {
        switch self {
        case .diskFull:
            "New usage is not being saved. Nothing already saved was lost, and your provider files are untouched, "
                + "so free some space and try again: everything since will be read."
        case .corrupt:
            "The file was left exactly as it was found. Restore a backup to carry on; usage still in your "
                + "provider files is read again afterwards."
        case .migrationFailed(let backup):
            "The update rolled back, so your history is as it was before. "
                + (backup == nil ? "" : "A copy was taken just before it, and can be restored. ")
                + "Try again, or restore that copy."
        case .anotherInstance:
            "Only one copy can keep the history at a time. Quit this one; the other carries on."
        case .newerVersion(let found, let supported):
            "It was saved by a version that uses database version \(found), and this one reads up to \(supported). "
                + "Opening it here could lose what the newer version recorded, so it was not opened. "
                + "Install the newer Burnline to keep using it."
        case .other(let reason):
            "SQLite reported: \(reason). Nothing was changed."
        }
    }

    /// Whether restoring a backup is a way out.
    public var offersRestore: Bool {
        switch self {
        case .corrupt, .migrationFailed: true
        case .diskFull, .anotherInstance, .newerVersion, .other: false
        }
    }

    /// Whether trying again, once the cause is dealt with, can work.
    public var canRetry: Bool {
        switch self {
        case .diskFull, .migrationFailed, .other: true
        case .corrupt, .anotherInstance, .newerVersion: false
        }
    }
}
