//
//  PricingRepository.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

extension BurnlineDatabase {
    public var pricing: PricingRepository { PricingRepository(database: self) }
}

/// The append-only pricing history. There is deliberately no update or delete:
/// a price change is a new version, so historical cost never moves.
public struct PricingRepository: Sendable {
    let database: BurnlineDatabase

    /// Events re-priced per transaction when a new version arrives.
    static let repriceBatchSize = 5_000

    /// Where newly added versions apply: the events whose cost may change.
    public struct AffectedWindow: Hashable, Sendable {
        public let modelID: Int64
        public let from: Timestamp
        public let until: Timestamp?
    }

    /// Records a new version and returns it with its id.
    @discardableResult
    public func append(modelID: Int64, validFrom: Timestamp, validUntil: Timestamp?,
                       serviceTier: ServiceTier = .standard, abovePromptTokens: Int64 = 0, rates: TokenRates,
                       source: String, confidence: PricingConfidence) throws(StoreError) -> PricingVersion {
        let version = PricingVersion(id: 0, modelID: modelID, validFrom: validFrom, validUntil: validUntil,
                                     serviceTier: serviceTier, abovePromptTokens: abovePromptTokens,
                                     rates: rates, source: source, confidence: confidence)
        let createdAt = database.clock.now.epochSeconds
        let id = try database.write { db in
            try Self.insert(version, in: db, createdAt: createdAt)
            return db.lastInsertedRowID
        }
        return PricingVersion(id: id, modelID: modelID, validFrom: validFrom, validUntil: validUntil,
                              serviceTier: serviceTier, abovePromptTokens: abovePromptTokens,
                              rates: rates, source: source, confidence: confidence)
    }

    /// Adds every version of `manifest` not already stored, and returns where
    /// the new ones apply. Loading the same manifest twice adds nothing. A
    /// manifest model the database has not seen is created, so its events,
    /// when they come, are priced on arrival.
    @discardableResult
    public func apply(_ manifest: PricingManifest) throws(StoreError) -> [AffectedWindow] {
        let now = database.clock.now.epochSeconds
        return try database.write { db in
            var affected: [AffectedWindow] = []
            for entry in manifest.versions {
                guard let provider = ProviderKey(rawValue: entry.provider),
                      let from = Timestamp(entry.validFrom) else { continue }
                let model = try ModelRepository.resolve(db, providerID: database.providerID(provider),
                                                        raw: entry.model, at: from, now: now)
                guard let modelID = model.modelID, model.kind == .model else { continue }
                let until = entry.validUntil.flatMap(Timestamp.init)
                let version = PricingVersion(
                    id: 0, modelID: modelID, validFrom: from, validUntil: until, serviceTier: entry.tier,
                    abovePromptTokens: entry.abovePromptTokens ?? 0, rates: try entry.tokenRates(),
                    source: entry.source, confidence: entry.confidence)
                if try Self.insert(version, in: db, createdAt: now, ignoringDuplicates: true) {
                    affected.append(AffectedWindow(modelID: modelID, from: from, until: until))
                }
            }
            return affected
        }
    }

    /// Re-prices the events in `windows` against the full history, so only
    /// what a new version could change is touched, and always at the
    /// rates of the event's own time, never today's.
    @discardableResult
    public func reprice(_ windows: [AffectedWindow]) throws(StoreError) -> Int {
        var changed = 0
        for window in windows {
            // Ids are positive, so (from, 0) precedes every event in the window.
            var cursor = (timestamp: window.from.epochSeconds, id: Int64(0))
            while true {
                let (count, last) = try database.write { db in
                    try Self.repriceBatch(window, after: cursor, in: db, database: database)
                }
                changed += count
                guard let last else { break }
                cursor = last
            }
        }
        return changed
    }

    /// Finishes recalculations queued with their pricing versions. The marker
    /// stays until every batch commits, so replay after a crash is harmless.
    @discardableResult
    public func repricePending() throws(StoreError) -> Int {
        let pending = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT v.id, v.model_id, v.valid_from, v.valid_until
                FROM pending_repricing p JOIN pricing_versions v ON v.id = p.pricing_version_id
                ORDER BY v.id
                """).map { row in
                    (id: row["id"] as Int64,
                     window: AffectedWindow(modelID: row["model_id"],
                                            from: Timestamp(epochSeconds: row["valid_from"]),
                                            until: (row["valid_until"] as Int64?).map(Timestamp.init(epochSeconds:))))
                }
        }
        var changed = 0
        for work in pending {
            changed += try reprice([work.window])
            try database.write { db in
                try db.execute(sql: "DELETE FROM pending_repricing WHERE pricing_version_id = ?", arguments: [work.id])
            }
        }
        return changed
    }

    /// Re-prices every event, for recalculating after a repair.
    @discardableResult
    public func repriceAll() throws(StoreError) -> Int {
        let models = try database.read { db in
            try Int64.fetchAll(db, sql: "SELECT DISTINCT model_id FROM usage_events WHERE model_id IS NOT NULL")
        }
        return try reprice(models.map { AffectedWindow(modelID: $0, from: Timestamp(epochSeconds: .min), until: nil) })
    }

    /// The version that priced `modelID`'s standard tier at `instant`, or nil
    /// for a gap. Never falls back to the current price: a visible gap beats a
    /// silently wrong historical cost.
    public func version(for modelID: Int64, at instant: Timestamp) throws(StoreError) -> PricingVersion? {
        let versions = try database.read { db in try Self.versions(for: modelID, in: db) }
        guard case .priced(_, let id, _) = Pricer.price(.zero, tier: .standard, at: instant, versions: versions)
        else { return nil }
        return versions.first { $0.id == id }
    }

    /// How many versions are stored, all models and sources.
    public func count() throws(StoreError) -> Int {
        try database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM pricing_versions") ?? 0 }
    }

    /// Every version of `modelID`, the input to `Pricer`.
    static func versions(for modelID: Int64, in db: Database) throws -> [PricingVersion] {
        try Row.fetchAll(db, sql: "SELECT * FROM pricing_versions WHERE model_id = ?", arguments: [modelID])
            .map(Self.version(from:))
    }

    /// Inserts `version`; with `ignoringDuplicates`, returns false instead of
    /// failing when the same version from the same source is already stored.
    @discardableResult
    private static func insert(_ version: PricingVersion, in db: Database, createdAt: Int64,
                               ignoringDuplicates: Bool = false) throws -> Bool {
        let rates = version.rates
        try db.execute(
            sql: """
            INSERT \(ignoringDuplicates ? "OR IGNORE " : "")INTO pricing_versions (
              model_id, valid_from, valid_until, service_tier, above_prompt_tokens,
              input_nanos_per_mtok, cached_input_nanos_per_mtok, cache_write_nanos_per_mtok,
              cache_write_1h_nanos_per_mtok, output_nanos_per_mtok, reasoning_nanos_per_mtok,
              source, confidence, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                version.modelID, version.validFrom.epochSeconds, version.validUntil?.epochSeconds,
                version.serviceTier.rawValue, version.abovePromptTokens,
                rates.input?.raw, rates.cachedInput?.raw, rates.cacheWrite?.raw,
                rates.cacheWriteOneHour?.raw, rates.output?.raw, rates.reasoning?.raw,
                version.source, version.confidence.rawValue, createdAt,
            ])
        return db.changesCount > 0
    }

    /// One batch of a window's events, in (timestamp, id) order after
    /// `cursor`. Walking the timestamp index keeps a narrow window, such as a
    /// price change from today, from scanning the whole table.
    private static func repriceBatch(_ window: AffectedWindow, after cursor: (timestamp: Int64, id: Int64),
                                     in db: Database, database: BurnlineDatabase)
        throws -> (Int, (timestamp: Int64, id: Int64)?) {
        let rows = try Row.fetchAll(
            db.cachedStatement(sql: """
            SELECT e.id, e.timestamp, e.input_tokens, e.cached_input_tokens, e.cache_write_tokens,
                   e.cache_write_1h_tokens, e.output_tokens, e.reasoning_tokens, e.service_tier,
                   p.key AS provider_key
            FROM usage_events e JOIN providers p ON p.id = e.provider_id
            WHERE (e.timestamp, e.id) > (?, ?) AND e.timestamp < ? AND e.model_id = ?
              AND e.timestamp >= (SELECT compacted_before FROM compaction)
            ORDER BY e.timestamp, e.id
            LIMIT ?
            """),
            arguments: [cursor.timestamp, cursor.id, window.until?.epochSeconds ?? Int64.max, window.modelID,
                        repriceBatchSize])
        guard let last = rows.last else { return (0, nil) }
        let versions = try versions(for: window.modelID, in: db)
        let update = try db.cachedStatement(sql: """
            UPDATE usage_events SET pricing_version_id = ?, cost_nanos = ?, pricing_confidence = ?,
                                    cache_savings_nanos = ?
            WHERE id = ?
            """)
        for row in rows {
            let tokens = try TokenCounts(
                input: row["input_tokens"], cachedInput: row["cached_input_tokens"],
                cacheWrite: row["cache_write_tokens"], cacheWriteOneHour: row["cache_write_1h_tokens"],
                output: row["output_tokens"], reasoning: row["reasoning_tokens"])
            let provider = ProviderKey(rawValue: row["provider_key"]) ?? .codex
            let cost = Pricer.price(tokens, tier: ServiceTier(recorded: row["service_tier"], provider: provider),
                                    at: Timestamp(epochSeconds: row["timestamp"]), versions: versions)
            let columns = PricingColumns(cost, tokens: tokens) { id in versions.first { $0.id == id }?.rates }
            try update.execute(arguments: [columns.versionID, columns.costNanos, columns.confidence,
                                           columns.cacheSavingsNanos, row["id"] as Int64])
        }
        return (rows.count, (last["timestamp"], last["id"]))
    }

    private static func version(from row: Row) -> PricingVersion {
        PricingVersion(
            id: row["id"], modelID: row["model_id"],
            validFrom: Timestamp(epochSeconds: row["valid_from"]),
            validUntil: (row["valid_until"] as Int64?).map(Timestamp.init(epochSeconds:)),
            serviceTier: ServiceTier(rawValue: row["service_tier"]) ?? .standard,
            abovePromptTokens: row["above_prompt_tokens"],
            rates: rates(from: row),
            source: row["source"],
            confidence: PricingConfidence(rawValue: row["confidence"]) ?? .unknown)
    }

    /// The rates of version `id`, or nil if there is no such version.
    static func rates(ofVersion id: Int64, in db: Database) throws -> TokenRates? {
        try Row.fetchOne(db.cachedStatement(sql: "SELECT * FROM pricing_versions WHERE id = ?"), arguments: [id])
            .map(rates(from:))
    }

    /// A version's rates, from a row carrying the `pricing_versions` rate columns.
    static func rates(from row: Row) -> TokenRates {
        func rate(_ column: String) -> Nanodollars? { (row[column] as Int64?).map(Nanodollars.init(raw:)) }
        return TokenRates(input: rate("input_nanos_per_mtok"),
                          cachedInput: rate("cached_input_nanos_per_mtok"),
                          cacheWrite: rate("cache_write_nanos_per_mtok"),
                          cacheWriteOneHour: rate("cache_write_1h_nanos_per_mtok"),
                          output: rate("output_nanos_per_mtok"),
                          reasoning: rate("reasoning_nanos_per_mtok"))
    }
}
