//
//  StoreFixture.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import GRDB

/// A database in a fresh temporary directory, built from the schema files the
/// app actually ships.
struct StoreFixture {
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()   // BurnlineStoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // macos
        .deletingLastPathComponent()   // repository root
    static let shippedSchemaDirectory = repositoryRoot.appending(path: "shared/schema")

    let location: StoreLocation
    let clock = ManualClock(Timestamp(epochSeconds: 1_793_450_000))

    init() throws {
        location = StoreLocation(directory: TestDirectory.make("Store"))
    }

    /// A store in `directory`, outside the run's scratch folder, for a
    /// database that must outlive the test run.
    init(keepingIn directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        location = StoreLocation(directory: directory)
    }

    static func shippedSchema() throws -> Schema {
        try Schema(directory: shippedSchemaDirectory)
    }

    /// The version a freshly built database is at.
    static var shippedVersion: Int { (try? shippedSchema().latestVersion) ?? 0 }

    /// The shipped migrations plus `sql`, numbered after them, for testing
    /// upgrades the app has not shipped yet.
    func schema(addingMigrations sql: [String]) throws -> Schema {
        let extra = Dictionary(uniqueKeysWithValues: sql.enumerated().map { index, text in
            (String(format: "%03d_test_%d.sql", Self.shippedVersion + index + 1, index), text)
        })
        return try schema(adding: extra)
    }

    /// The shipped migrations up to and including `version`, as an older
    /// build shipped them.
    func schema(through version: Int) throws -> Schema {
        let directory = location.directory.appending(path: "schema-v\(version)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: Self.shippedSchemaDirectory.path)
        where Int(name.prefix(3)).map({ $0 <= version }) ?? false {
            try FileManager.default.copyItem(at: Self.shippedSchemaDirectory.appending(path: name),
                                             to: directory.appending(path: name))
        }
        return try Schema(directory: directory)
    }

    /// The shipped migrations plus `extra` files, named by the caller.
    func schema(adding extra: [String: String]) throws -> Schema {
        let directory = location.directory.appending(path: "schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: Self.shippedSchemaDirectory.path) {
            try FileManager.default.copyItem(at: Self.shippedSchemaDirectory.appending(path: name),
                                             to: directory.appending(path: name))
        }
        for (name, sql) in extra {
            try sql.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }
        return try Schema(directory: directory)
    }

    func open(schema: Schema? = nil, mode: BurnlineDatabase.AccessMode = .writer) throws -> BurnlineDatabase {
        try BurnlineDatabase.open(at: location, schema: schema ?? Self.shippedSchema(), clock: clock, mode: mode)
    }

    /// A usage event with only the fields a test cares about.
    static func event(_ id: String, at seconds: Int64 = 1_793_000_000, modelID: Int64? = nil,
                      cost: CostAttribution = .unpriced(.unknownModel),
                      provider: ProviderKey = .claudeCode) throws -> UsageEvent {
        UsageEvent(provider: provider, modelID: modelID, sessionID: nil, projectID: nil,
                   timestamp: Timestamp(epochSeconds: seconds),
                   tokens: try TokenCounts(input: 100, cachedInput: 20, output: 10),
                   cost: cost,
                   source: SourceReference(sourceType: "jsonl", file: "/tmp/a.jsonl", eventID: id,
                                           schemaVersion: nil, offset: 0))
    }

    /// Inserts a model row directly, for tests that are not about model identity.
    static func insertModel(_ name: String, kind: String = "model", into database: BurnlineDatabase) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO models (provider_id, canonical_name, display_name, kind, created_at)
                VALUES (?, ?, ?, ?, 0)
                """,
                arguments: [database.providerID(.claudeCode), name, name, kind])
            return db.lastInsertedRowID
        }
    }

    /// The main database file's bytes, for proving a refused open wrote nothing.
    func databaseBytes() throws -> Data {
        try Data(contentsOf: location.databaseFile)
    }
}

/// The `StoreError` that `body` throws, or nil if it succeeds or throws
/// something else.
func storeError(_ body: () throws -> Void) -> StoreError? {
    do { try body(); return nil } catch { return error as? StoreError }
}
