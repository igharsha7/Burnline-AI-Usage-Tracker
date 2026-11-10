//
//  UsageRepository.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

extension BurnlineDatabase {
    public var usage: UsageRepository { UsageRepository(database: self) }
}

/// Usage events: the facts everything else is computed from.
public struct UsageRepository: Sendable {
    let database: BurnlineDatabase

    /// Inserts `events` in one transaction and returns how many rows were
    /// added or completed. If any insert fails, none are kept.
    ///
    /// Deduplication is on `(provider, source event id)`, which is what makes
    /// re-reading a file safe. A repeat replaces the stored event only
    /// when it is more complete: providers write streaming snapshots of one
    /// response, and the later snapshot carries the final output count. Order
    /// does not matter, so the most complete snapshot always wins.
    @discardableResult
    public func insert(_ events: [UsageEvent]) throws(StoreError) -> Int {
        let createdAt = database.clock.now.epochSeconds
        return try database.write { db in
            try Self.insert(events, in: db, database: database, createdAt: createdAt)
        }
    }

    /// The insert, inside a transaction the caller holds.
    static func insert(_ events: [UsageEvent], in db: Database, database: BurnlineDatabase,
                       createdAt: Int64) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO usage_events (
              provider_id, model_id, session_id, project_id, timestamp,
              input_tokens, cached_input_tokens, cache_write_tokens, cache_write_1h_tokens,
              output_tokens, reasoning_tokens, service_tier,
              pricing_version_id, cost_nanos, pricing_confidence,
              source_file_id, source_event_id, source_schema_version, source_offset,
              created_at, cache_savings_nanos)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (provider_id, source_event_id) DO UPDATE SET
              model_id = excluded.model_id,
              session_id = excluded.session_id,
              project_id = excluded.project_id,
              timestamp = excluded.timestamp,
              input_tokens = excluded.input_tokens,
              cached_input_tokens = excluded.cached_input_tokens,
              cache_write_tokens = excluded.cache_write_tokens,
              cache_write_1h_tokens = excluded.cache_write_1h_tokens,
              output_tokens = excluded.output_tokens,
              reasoning_tokens = excluded.reasoning_tokens,
              service_tier = excluded.service_tier,
              pricing_version_id = excluded.pricing_version_id,
              cost_nanos = excluded.cost_nanos,
              pricing_confidence = excluded.pricing_confidence,
              cache_savings_nanos = excluded.cache_savings_nanos,
              source_file_id = excluded.source_file_id,
              source_schema_version = excluded.source_schema_version,
              source_offset = excluded.source_offset
            WHERE excluded.output_tokens > usage_events.output_tokens
               OR (excluded.output_tokens = usage_events.output_tokens
                   AND excluded.input_tokens + excluded.cached_input_tokens + excluded.cache_write_tokens
                     > usage_events.input_tokens + usage_events.cached_input_tokens
                       + usage_events.cache_write_tokens)
            """)
        var sourceFiles = SourceFiles()
        var rates: [Int64: TokenRates] = [:]
        var changed = 0
        // Compacted history lives only in the rollups; an event from it, such
        // as from a re-read archive, would be counted twice.
        var late = try BurnlineDatabase.LateHistory(in: db)
        for event in events {
            let providerID = database.providerID(event.provider)
            guard try late.accepts(event.timestamp, providerID: providerID, in: db) else { continue }
            if case .priced(_, let versionID, _) = event.cost, rates[versionID] == nil {
                rates[versionID] = try PricingRepository.rates(ofVersion: versionID, in: db)
            }
            let pricing = PricingColumns(event.cost, tokens: event.tokens, rates: { rates[$0] })
            let sourceFileID = try sourceFiles.id(providerID: providerID, type: event.source.sourceType,
                                                  path: event.source.file, in: db)
            try statement.execute(arguments: [
                providerID, event.modelID, event.sessionID, event.projectID,
                event.timestamp.epochSeconds,
                event.tokens.input, event.tokens.cachedInput, event.tokens.cacheWrite,
                event.tokens.cacheWriteOneHour, event.tokens.output, event.tokens.reasoning,
                event.serviceTier, pricing.versionID, pricing.costNanos, pricing.confidence,
                sourceFileID, event.source.eventID, event.source.schemaVersion, event.source.offset,
                createdAt, pricing.cacheSavingsNanos,
            ])
            changed += db.changesCount
        }
        return changed
    }

    /// Events whose timestamp falls in `window`, oldest first.
    public func events(in window: TimeWindow, provider: ProviderKey? = nil) throws(StoreError) -> [UsageEvent] {
        try database.read { db in
            var sql = """
                SELECT e.*, p.key AS provider_key, m.kind AS model_kind,
                       f.source_type AS source_type, f.path AS source_file,
                       EXISTS (SELECT 1 FROM pricing_versions v WHERE v.model_id = e.model_id) AS model_has_pricing
                FROM usage_events e
                JOIN providers p ON p.id = e.provider_id
                JOIN source_files f ON f.id = e.source_file_id
                LEFT JOIN models m ON m.id = e.model_id
                WHERE e.timestamp >= ? AND e.timestamp < ?
                """
            var arguments: StatementArguments = [window.start.epochSeconds, window.end.epochSeconds]
            if let provider {
                sql += " AND e.provider_id = ?"
                arguments += [database.providerID(provider)]
            }
            sql += " ORDER BY e.timestamp, e.id"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.event(from:))
        }
    }

    /// Cache savings in `window`, from the rollups: each event's saving at
    /// the rates its cost was computed with, so a band or tier price is
    /// honoured, and kept after its event is compacted.
    public func cacheSavings(in window: TimeWindow, provider: ProviderKey? = nil) throws(StoreError) -> CacheSavings {
        try totals(in: window, provider: provider).cacheSavings
    }

    public func count() throws(StoreError) -> Int {
        try database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_events") ?? 0 }
    }

    /// How many stored events fall before `cutoff`: what a shorter retention
    /// period would delete. The interface shows this before the change, because
    /// provider history older than the providers' own retention cannot be
    /// re-imported once Burnline drops it.
    public func countBefore(_ cutoff: Timestamp) throws(StoreError) -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_events WHERE timestamp < ?",
                             arguments: [cutoff.epochSeconds]) ?? 0
        }
    }

    private static func event(from row: Row) throws -> UsageEvent {
        let tokens = try tokens(from: row)
        return UsageEvent(
            provider: ProviderKey(rawValue: row["provider_key"]) ?? .codex,
            modelID: row["model_id"], sessionID: row["session_id"], projectID: row["project_id"],
            timestamp: Timestamp(epochSeconds: row["timestamp"]),
            tokens: tokens, serviceTier: row["service_tier"],
            cost: cost(from: row),
            source: SourceReference(
                sourceType: row["source_type"], file: row["source_file"], eventID: row["source_event_id"],
                schemaVersion: row["source_schema_version"], offset: row["source_offset"]))
    }

    private static func tokens(from row: Row) throws -> TokenCounts {
        try TokenCounts(
            input: row["input_tokens"], cachedInput: row["cached_input_tokens"],
            cacheWrite: row["cache_write_tokens"], cacheWriteOneHour: row["cache_write_1h_tokens"],
            output: row["output_tokens"],
            reasoning: row["reasoning_tokens"])
    }

    /// The schema stores a cost or NULL, not the reason for NULL, so the reason
    /// is derived from what is known about the model: none at all, not a
    /// model, never priced (a model Burnline has no prices for, such as a new
    /// release), or priced but with a gap at this event's time.
    private static func cost(from row: Row) -> CostAttribution {
        if let nanos: Int64 = row["cost_nanos"], let versionID: Int64 = row["pricing_version_id"] {
            let confidence = (row["pricing_confidence"] as String?).flatMap(PricingConfidence.init) ?? .unknown
            return .priced(Nanodollars(raw: nanos), pricingVersionID: versionID, confidence: confidence)
        }
        if (row["model_id"] as Int64?) == nil { return .unpriced(.unknownModel) }
        if (row["model_kind"] as String?) == "non_model" { return .unpriced(.nonModel) }
        return (row["model_has_pricing"] as Bool?) == true ? .unpriced(.noPricingVersion) : .unpriced(.unknownModel)
    }
}

/// `CostAttribution` as the pricing columns, with the cache savings the
/// price implies. Unpriced is all NULL, never a zero cost.
struct PricingColumns {
    let versionID: Int64?
    let costNanos: Int64?
    let confidence: String?
    /// NULL when unpriced, or when the price has no cache rates of its own;
    /// zero for an event without cache tokens.
    let cacheSavingsNanos: Int64?

    init(_ cost: CostAttribution, tokens: TokenCounts, rates: (Int64) -> TokenRates?) {
        switch cost {
        case .priced(let amount, let versionID, let confidence):
            self.versionID = versionID
            self.costNanos = amount.raw
            self.confidence = confidence.rawValue
            self.cacheSavingsNanos = rates(versionID).flatMap { Pricer.cacheSavings(tokens, at: $0) }?.raw
        case .unpriced:
            self.versionID = nil
            self.costNanos = nil
            self.confidence = nil
            self.cacheSavingsNanos = nil
        }
    }
}

/// Source file ids for one transaction, looked up or created once each: a
/// batch is nearly always one file.
struct SourceFiles {
    private struct Key: Hashable {
        let providerID: Int64
        let type: String
        let path: String?
    }

    private var ids: [Key: Int64] = [:]

    mutating func id(providerID: Int64, type: String, path: String?, in db: Database) throws -> Int64 {
        let key = Key(providerID: providerID, type: type, path: path)
        if let id = ids[key] { return id }
        // `IS` rather than `=`, so a source without a file matches its own row.
        let id = try Int64.fetchOne(db.cachedStatement(sql: """
                SELECT id FROM source_files WHERE provider_id = ? AND source_type = ? AND path IS ?
                """), arguments: [providerID, type, path])
            ?? {
                try db.cachedStatement(sql: "INSERT INTO source_files (provider_id, source_type, path) VALUES (?, ?, ?)")
                    .execute(arguments: [providerID, type, path])
                return db.lastInsertedRowID
            }()
        ids[key] = id
        return id
    }
}
