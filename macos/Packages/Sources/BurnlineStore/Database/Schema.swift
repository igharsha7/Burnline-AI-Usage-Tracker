//
//  Schema.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// The shipped migrations, read from `shared/schema/`.
///
/// The schema is never restated in Swift. Each `NNN_name.sql` file is one
/// migration, and its number is the schema version it produces, recorded in
/// `PRAGMA user_version` exactly as the contracts document specifies. That is
/// deliberately not GRDB's `DatabaseMigrator`, which tracks migrations in a
/// table of its own: a database migrated by another platform's implementation
/// would have no rows there, and GRDB would try to apply migration 1 again.
public struct Schema: Sendable {
    public struct Migration: Sendable {
        public let version: Int
        public let name: String
        public let sql: String
    }

    public let migrations: [Migration]

    /// The version a fully migrated database is at.
    public var latestVersion: Int { migrations.last?.version ?? 0 }

    /// Loads every `NNN_name.sql` file in `directory`. Other files, such as the
    /// README, are ignored. Numbering must run 1, 2, 3… with no gaps or repeats,
    /// because a gap would make the recorded version ambiguous.
    public init(directory: URL) throws(StoreError) {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch { throw .invalidSchema("cannot read \(directory.path): \(error.localizedDescription)") }

        var migrations: [Migration] = []
        for name in names {
            guard let match = name.wholeMatch(of: /([0-9]{3})_[A-Za-z0-9_]+\.sql/),
                  let version = Int(match.1) else { continue }
            do {
                let sql = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
                migrations.append(Migration(version: version, name: name, sql: sql))
            } catch {
                throw .invalidSchema("cannot read \(name): \(error.localizedDescription)")
            }
        }
        migrations.sort { $0.version < $1.version }

        guard !migrations.isEmpty else { throw .invalidSchema("no migrations in \(directory.path)") }
        for (index, migration) in migrations.enumerated() where migration.version != index + 1 {
            throw .invalidSchema("expected migration \(index + 1), found \(migration.name)")
        }
        self.migrations = migrations
    }

    /// Migrations a database at `version` still needs, in order.
    func pending(after version: Int) -> [Migration] {
        migrations.filter { $0.version > version }
    }
}
