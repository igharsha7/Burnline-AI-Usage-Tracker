//
//  DataControl.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

// The vocabulary of the user's control over Burnline's copy of their
// history, shared by the store that carries it out and the interface that
// asks for it.

/// What the user asked to delete from Burnline's own copy of their history.
/// Provider files are never touched: Burnline deletes only what it stored.
public enum DeletionScope: Hashable, Sendable {
    case provider(ProviderKey)
    /// The project and every project merged into it.
    case project(Int64)
    /// Usage inside the window. Compacted history is kept in 15-minute
    /// totals, so there only whole quarter hours inside the window go.
    case range(TimeWindow)
    case everything
}

public struct DeletionReport: Equatable, Sendable {
    public let events: Int
    public let sessions: Int

    public init(events: Int, sessions: Int) {
        self.events = events
        self.sessions = sessions
    }
}

/// What a database check found. Empty problems is a healthy store.
public struct DatabaseCheck: Equatable, Sendable {
    public let problems: [String]
    public var isHealthy: Bool { problems.isEmpty }

    public init(problems: [String]) {
        self.problems = problems
    }
}

/// What a backup holds, read before anything is replaced with it.
public struct BackupInspection: Equatable, Sendable {
    public let schemaVersion: Int
    public let events: Int
    /// The oldest and newest usage it covers, compacted history included.
    public let earliest: Timestamp?
    public let latest: Timestamp?

    public init(schemaVersion: Int, events: Int, earliest: Timestamp?, latest: Timestamp?) {
        self.schemaVersion = schemaVersion
        self.events = events
        self.earliest = earliest
        self.latest = latest
    }
}

/// What an export holds. Usage metadata only: Burnline stores no prompt,
/// reply or code, so none can be exported.
public enum ExportDataset: String, CaseIterable, Sendable {
    /// Every event still kept in full, inside the detail window.
    case events
    /// The 15-minute totals per provider, model and project, for all of
    /// history, compacted time included.
    case totals
}

/// One exported value: text, a whole number, or nothing.
public enum ExportValue: Equatable, Sendable {
    case text(String)
    case integer(Int64)
    case null
}
