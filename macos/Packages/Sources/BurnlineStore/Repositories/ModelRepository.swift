//
//  ModelRepository.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import GRDB

extension BurnlineDatabase {
    public var models: ModelRepository { ModelRepository(database: self) }
}

/// What a raw model string turned out to be.
public struct ModelResolution: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case model
        case nonModel = "non_model"
    }

    /// Nil when the model field was empty: the event is still counted.
    public let modelID: Int64?
    public let kind: Kind
}

/// Model resolution for one transaction. A name whose aliases carry no time
/// bounds resolves the same way at every instant, so it is looked up once;
/// a name with bounded aliases is resolved per event.
struct ModelResolver {
    let providerID: Int64
    let now: Int64
    private var timeless: [String: ModelResolution] = [:]

    init(providerID: Int64, now: Int64) {
        self.providerID = providerID
        self.now = now
    }

    mutating func resolve(_ raw: String?, at instant: Timestamp, in db: Database) throws -> ModelResolution {
        guard let raw else { return try ModelRepository.resolve(db, providerID: providerID, raw: nil, at: instant, now: now) }
        if let known = timeless[raw] { return known }
        let resolution = try ModelRepository.resolve(db, providerID: providerID, raw: raw, at: instant, now: now)
        let bounded = try Bool.fetchOne(db.cachedStatement(sql: """
            SELECT EXISTS (SELECT 1 FROM model_aliases WHERE provider_id = ? AND raw_model_name = ?
                           AND (valid_from IS NOT NULL OR valid_until IS NOT NULL))
            """), arguments: [providerID, ModelRepository.plainName(raw)]) ?? true
        if !bounded { timeless[raw] = resolution }
        return resolution
    }
}

/// Model identity: canonical models, time-bounded aliases, and non-models.
public struct ModelRepository: Sendable {
    let database: BurnlineDatabase

    /// Brings the database in line with the bundled manifest. Adds and updates;
    /// never deletes, because events already point at these rows.
    public func sync(_ manifest: ModelAliasManifest) throws(StoreError) {
        let now = database.clock.now.epochSeconds
        try database.write { db in
            for (key, entry) in manifest.providers {
                guard let provider = ProviderKey(rawValue: key) else { continue }
                let providerID = database.providerID(provider)
                for model in entry.models {
                    let modelID = try Self.upsertModel(
                        db, providerID: providerID, canonical: model.canonical, display: model.display,
                        family: model.family, kind: .model, now: now)
                    for alias in model.aliases ?? [] {
                        try Self.insertAlias(db, providerID: providerID, alias: alias, modelID: modelID)
                    }
                }
                for name in entry.nonModels {
                    _ = try Self.upsertModel(db, providerID: providerID, canonical: name, display: name,
                                             family: nil, kind: .nonModel, now: now)
                }
            }
        }
    }

    public func resolve(provider: ProviderKey, raw: String?, at instant: Timestamp) throws(StoreError) -> ModelResolution {
        let now = database.clock.now.epochSeconds
        return try database.write { db in
            try Self.resolve(db, providerID: database.providerID(provider), raw: raw, at: instant, now: now)
        }
    }

    /// Resolves inside a transaction the caller holds, so a batch of events and
    /// the models they create commit together.
    ///
    /// Order: an alias valid at `instant`, then the canonical
    /// name itself, then a new row. A value in angle brackets, such as
    /// `<synthetic>`, is a non-model even before the manifest names it.
    /// Anything else unrecognised becomes a model with no price, kept visible
    /// rather than discarded.
    ///
    /// The raw value is first put in its plain form (see `plainName`), so the
    /// spellings tools use for one model resolve together.
    static func resolve(_ db: Database, providerID: Int64, raw: String?, at instant: Timestamp,
                        now: Int64) throws -> ModelResolution {
        guard let raw, case let name = plainName(raw), !name.isEmpty else {
            return ModelResolution(modelID: nil, kind: .model)
        }
        if let row = try Row.fetchOne(
            db.cachedStatement(sql: """
            SELECT m.id, m.kind FROM model_aliases a JOIN models m ON m.id = a.model_id
            WHERE a.provider_id = ? AND a.raw_model_name = ?
              AND (a.valid_from IS NULL OR a.valid_from <= ?)
              AND (a.valid_until IS NULL OR ? < a.valid_until)
            ORDER BY a.valid_from IS NULL, a.valid_from DESC
            LIMIT 1
            """),
            arguments: [providerID, name, instant.epochSeconds, instant.epochSeconds]) {
            return resolution(row)
        }
        if let row = try Row.fetchOne(
            db.cachedStatement(sql: "SELECT id, kind FROM models WHERE provider_id = ? AND canonical_name = ?"),
            arguments: [providerID, name]) {
            return resolution(row)
        }
        let kind: ModelResolution.Kind = name.hasPrefix("<") && name.hasSuffix(">") ? .nonModel : .model
        let id = try upsertModel(db, providerID: providerID, canonical: name, display: name,
                                 family: nil, kind: kind, now: now)
        return ModelResolution(modelID: id, kind: kind)
    }

    /// Lowercased and trimmed, without a routing prefix (`anthropic/…`) or a
    /// bracketed variant (`…[1m]`, Claude's long-context selector). A variant
    /// is the same model, priced by its prompt length, so it is not a second
    /// model in breakdowns either.
    static func plainName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !name.hasPrefix("<"), let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        return name
    }

    private static func resolution(_ row: Row) -> ModelResolution {
        ModelResolution(modelID: row["id"], kind: ModelResolution.Kind(rawValue: row["kind"]) ?? .model)
    }

    private static func upsertModel(_ db: Database, providerID: Int64, canonical: String, display: String,
                                    family: String?, kind: ModelResolution.Kind, now: Int64) throws -> Int64 {
        try db.execute(
            sql: """
            INSERT INTO models (provider_id, canonical_name, display_name, family, kind, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (provider_id, canonical_name) DO UPDATE SET
              display_name = excluded.display_name,
              family = coalesce(excluded.family, family),
              kind = excluded.kind
            """,
            arguments: [providerID, canonical, display, family, kind.rawValue, now])
        return try Int64.fetchOne(
            db, sql: "SELECT id FROM models WHERE provider_id = ? AND canonical_name = ?",
            arguments: [providerID, canonical])!
    }

    /// The schema's uniqueness constraint includes `valid_from`, and SQLite
    /// treats NULLs as distinct, so an open-ended alias is checked by hand.
    private static func insertAlias(_ db: Database, providerID: Int64, alias: ModelAliasManifest.Alias,
                                    modelID: Int64) throws {
        let from = alias.validFrom.flatMap(Timestamp.init)?.epochSeconds
        let until = alias.validUntil.flatMap(Timestamp.init)?.epochSeconds
        let exists = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (SELECT 1 FROM model_aliases
                           WHERE provider_id = ? AND raw_model_name = ? AND valid_from IS ?)
            """,
            arguments: [providerID, alias.raw, from]) ?? false
        guard !exists else { return }
        try db.execute(
            sql: """
            INSERT INTO model_aliases (provider_id, raw_model_name, model_id, valid_from, valid_until, source)
            VALUES (?, ?, ?, ?, ?, 'bundled')
            """,
            arguments: [providerID, alias.raw, modelID, from, until])
    }
}
