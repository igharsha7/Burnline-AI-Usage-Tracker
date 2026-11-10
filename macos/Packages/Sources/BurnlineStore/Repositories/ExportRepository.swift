//
//  ExportRepository.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

extension BurnlineDatabase {
    public var exports: ExportRepository { ExportRepository(database: self) }
}

/// Normalized rows for export, streamed so a history of millions of events
/// is never held in memory. Times are UTC in ISO 8601, and money is exact
/// US dollars written from nanodollars, never through floating point.
public struct ExportRepository: Sendable {
    let database: BurnlineDatabase

    public static func columns(_ dataset: ExportDataset) -> [String] {
        switch dataset {
        case .events:
            ["timestamp", "provider", "model", "project", "session", "input_tokens", "cached_input_tokens",
             "cache_write_tokens", "cache_write_1h_tokens", "output_tokens", "reasoning_tokens", "cost_usd",
             "cache_savings_usd", "pricing_confidence", "service_tier"]
        case .totals:
            ["bucket_start", "provider", "model", "project", "events", "input_tokens", "cached_input_tokens",
             "cache_write_tokens", "cache_write_1h_tokens", "output_tokens", "reasoning_tokens", "cost_usd",
             "unpriced_events", "cache_savings_usd"]
        }
    }

    /// Calls `body` with each row's values, in `columns(dataset)` order,
    /// oldest first. Returns how many rows there were.
    @discardableResult
    public func rows(_ dataset: ExportDataset,
                     _ body: ([ExportValue]) throws -> Void) throws(StoreError) -> Int {
        try database.read { db in
            let cursor = try Row.fetchCursor(db, sql: Self.query(dataset))
            var count = 0
            while let row = try cursor.next() {
                try body(row.databaseValues.map { value in
                    switch value.storage {
                    case .int64(let number): .integer(number)
                    case .string(let text): .text(text)
                    case .double(let number): .text(String(number))
                    case .blob, .null: .null
                    }
                })
                count += 1
            }
            return count
        }
    }

    /// `12.345678901` from nanodollars, exactly.
    private static func dollars(_ column: String) -> String {
        "CASE WHEN \(column) IS NULL THEN NULL ELSE printf('%s%d.%09d', CASE WHEN \(column) < 0 THEN '-' ELSE '' END, abs(\(column) / 1000000000), abs(\(column) % 1000000000)) END"
    }

    private static func time(_ seconds: String) -> String {
        "strftime('%Y-%m-%dT%H:%M:%SZ', \(seconds), 'unixepoch')"
    }

    /// A project is named as the dashboard names it: after the one it is
    /// merged into, by the user's alias where there is one.
    private static let project = "coalesce(root.user_alias, root.display_name)"

    static func query(_ dataset: ExportDataset) -> String {
        switch dataset {
        case .events:
            """
            \(AggregationRepository.projectRoots)
            SELECT \(time("e.timestamp")), p.key, m.canonical_name, \(project), s.source_session_id,
                   e.input_tokens, e.cached_input_tokens, e.cache_write_tokens, e.cache_write_1h_tokens,
                   e.output_tokens, e.reasoning_tokens, \(dollars("e.cost_nanos")),
                   \(dollars("e.cache_savings_nanos")), e.pricing_confidence, e.service_tier
            FROM usage_events e
            JOIN providers p ON p.id = e.provider_id
            LEFT JOIN models m ON m.id = e.model_id
            LEFT JOIN roots ON roots.id = e.project_id
            LEFT JOIN projects root ON root.id = roots.root
            LEFT JOIN sessions s ON s.id = e.session_id
            ORDER BY e.timestamp, e.id
            """
        case .totals:
            """
            \(AggregationRepository.projectRoots)
            SELECT \(time("r.bucket * \(BurnlineDatabase.bucketSeconds)")), p.key, m.canonical_name, \(project),
                   r.events, r.input_tokens, r.cached_input_tokens, r.cache_write_tokens, r.cache_write_1h_tokens,
                   r.output_tokens, r.reasoning_tokens, \(dollars("r.cost_nanos")), r.unpriced_events,
                   \(dollars("r.cache_savings_nanos"))
            FROM usage_rollups r
            JOIN providers p ON p.id = r.provider_id
            LEFT JOIN models m ON m.id = r.model_id
            LEFT JOIN roots ON roots.id = r.project_id
            LEFT JOIN projects root ON root.id = roots.root
            ORDER BY r.bucket, p.key, r.model_id, r.project_id
            """
        }
    }
}
