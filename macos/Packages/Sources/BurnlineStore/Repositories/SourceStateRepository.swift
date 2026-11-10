//
//  SourceStateRepository.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

extension BurnlineDatabase {
    public var sourceStates: SourceStateRepository { SourceStateRepository(database: self) }
}

/// How far ingestion has read one provider file, so a restart resumes rather
/// than re-reading. The inode and size let ingestion notice a file that was
/// rotated or rewritten underneath it.
///
/// `resumeState` is whatever the provider's parser needs to pick up mid-file,
/// written and read only by that parser. Without it, the file is re-read from
/// the start.
public struct SourceState: Hashable, Sendable {
    public let provider: ProviderKey
    public let identifier: String
    public var inode: Int64?
    public var fileSize: Int64?
    public var lastModifiedAt: Timestamp?
    /// Subsecond part of the source modification time; nil for legacy states.
    public var lastModifiedNanoseconds: Int64?
    public var lastOffset: Int64
    public var lastEventIdentifier: String?
    public var lastScanAt: Timestamp?
    public var resumeState: String?

    public init(provider: ProviderKey, identifier: String, inode: Int64? = nil, fileSize: Int64? = nil,
                lastModifiedAt: Timestamp? = nil, lastOffset: Int64 = 0,
                lastEventIdentifier: String? = nil, lastScanAt: Timestamp? = nil,
                resumeState: String? = nil, lastModifiedNanoseconds: Int64? = nil) {
        self.provider = provider
        self.identifier = identifier
        self.inode = inode
        self.fileSize = fileSize
        self.lastModifiedAt = lastModifiedAt
        self.lastOffset = lastOffset
        self.lastEventIdentifier = lastEventIdentifier
        self.lastScanAt = lastScanAt
        self.resumeState = resumeState
        self.lastModifiedNanoseconds = lastModifiedNanoseconds
    }
}

public struct SourceStateRepository: Sendable {
    let database: BurnlineDatabase

    public func state(provider: ProviderKey, identifier: String) throws(StoreError) -> SourceState? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM source_states WHERE provider_id = ? AND source_identifier = ?",
                arguments: [database.providerID(provider), identifier]
            ).map { Self.state(from: $0, provider: provider) }
        }
    }

    /// Every state of `provider`, by identifier, in one read: what a sync
    /// compares the provider's current files against.
    public func states(provider: ProviderKey) throws(StoreError) -> [String: SourceState] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM source_states WHERE provider_id = ?",
                                        arguments: [database.providerID(provider)])
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let state = Self.state(from: row, provider: provider)
                return (state.identifier, state)
            })
        }
    }

    /// Forgets files the provider no longer has, so states stay bounded by the
    /// files that exist. A file that comes back is read again from the
    /// start, and the events already stored absorb the repeat.
    @discardableResult
    public func remove(provider: ProviderKey, identifiers: some Collection<String>) throws(StoreError) -> Int {
        guard !identifiers.isEmpty else { return 0 }
        return try database.write { db in
            let statement = try db.cachedStatement(sql: """
                DELETE FROM source_states WHERE provider_id = ? AND source_identifier = ?
                """)
            for identifier in identifiers {
                try statement.execute(arguments: [database.providerID(provider), identifier])
            }
            return identifiers.count
        }
    }

    /// Forgets every file's position, so the next sync reads all of each
    /// file again. Events already stored are recognised and not doubled.
    public func removeAll() throws(StoreError) {
        try database.write { db in try db.execute(sql: "DELETE FROM source_states") }
    }

    private static func state(from row: Row, provider: ProviderKey) -> SourceState {
        SourceState(
            provider: provider, identifier: row["source_identifier"], inode: row["inode"], fileSize: row["file_size"],
            lastModifiedAt: (row["last_modified_at"] as Int64?).map(Timestamp.init(epochSeconds:)),
            lastOffset: row["last_offset"], lastEventIdentifier: row["last_event_identifier"],
            lastScanAt: (row["last_scan_at"] as Int64?).map(Timestamp.init(epochSeconds:)),
            resumeState: row["resume_state"], lastModifiedNanoseconds: row["last_modified_nanoseconds"])
    }

    public func save(_ state: SourceState) throws(StoreError) {
        try database.write { db in
            try Self.save(state, providerID: database.providerID(state.provider), in: db)
        }
    }

    /// Saves inside a transaction the caller already holds, so ingestion can
    /// commit new events and the offset that produced them together. Then a
    /// crash can lose neither one without the other.
    static func save(_ state: SourceState, providerID: Int64, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO source_states (
              provider_id, source_identifier, inode, file_size, last_modified_at,
              last_offset, last_event_identifier, last_scan_at, resume_state, last_modified_nanoseconds)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (provider_id, source_identifier) DO UPDATE SET
              inode = excluded.inode,
              file_size = excluded.file_size,
              last_modified_at = excluded.last_modified_at,
              last_offset = excluded.last_offset,
              last_event_identifier = excluded.last_event_identifier,
              last_scan_at = excluded.last_scan_at,
              resume_state = excluded.resume_state,
              last_modified_nanoseconds = excluded.last_modified_nanoseconds
            """,
            arguments: [
                providerID, state.identifier, state.inode, state.fileSize, state.lastModifiedAt?.epochSeconds,
                state.lastOffset, state.lastEventIdentifier, state.lastScanAt?.epochSeconds, state.resumeState,
                state.lastModifiedNanoseconds,
            ])
    }
}
