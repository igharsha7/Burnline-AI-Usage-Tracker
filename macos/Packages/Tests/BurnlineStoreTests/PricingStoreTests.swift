//
//  PricingStoreTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineStore
import Foundation
import Testing

/// Pricing manifests applied to a real store, and events priced through it.
struct PricingStoreTests {
    static let shippedURL = StoreFixture.repositoryRoot.appending(path: "shared/pricing/pricing.json")
    static let everything = IngestionTests.everything

    /// A manifest of `versions`, each `(model, validFrom, output rate)`.
    static func manifest(_ versions: [(String, String, String)], provider: String = "claude_code") throws
        -> PricingManifest {
        let entries = versions.map { model, from, output in
            """
            {"provider":"\(provider)","model":"\(model)","validFrom":"\(from)","tier":"standard",\
            "source":"litellm","confidence":"exact","perMillion":{"input":"1","output":"\(output)"}}
            """
        }
        return try PricingManifest.decode(Data("""
            {"schemaVersion":1,"versions":[\(entries.joined(separator: ","))]}
            """.utf8))
    }

    static func costs(_ database: BurnlineDatabase) throws -> [String: Int64?] {
        let pairs = try database.read { db in
            try String.fetchAll(db, sql: "SELECT source_event_id || '=' || coalesce(cost_nanos, '') FROM usage_events")
        }
        return Dictionary(uniqueKeysWithValues: pairs.map { pair in
            let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
            return (String(parts[0]), Int64(parts[1]))
        })
    }

    @Test func `the shipped manifest loads, and prices every model the aliases name`() throws {
        let manifest = try PricingManifest.load(from: Self.shippedURL)
        #expect(manifest.preserves(manifest))
        let aliases = try ModelAliasManifest.load(from: IngestionTests.manifestURL)
        let priced = Set(manifest.versions.filter { $0.tier == .standard }.map { "\($0.provider)/\($0.model)" })
        for (provider, entry) in aliases.providers {
            for model in entry.models {
                #expect(priced.contains("\(provider)/\(model.canonical)"), "\(model.canonical) has no price")
            }
        }
    }

    @Test func `an event is priced on arrival at the rate of its own time`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.pricing.apply(Self.manifest([("claude-opus-5", "1970-01-01T00:00:00Z", "20"),
                                                  ("claude-opus-5", "1970-01-01T00:20:00Z", "10")]))
        try database.ingest([IngestionTests.record("old", at: 600, output: 1_000_000),
                             IngestionTests.record("new", at: 1_200, output: 1_000_000)],
                            issues: [], provider: .claudeCode)
        let events = try database.usage.events(in: Self.everything)
        // Plus one input token at $1 per million: 1,000 nanodollars.
        #expect(events.map(\.cost.amount) == [Nanodollars(raw: 20_000_001_000), Nanodollars(raw: 10_000_001_000)])
    }

    @Test func `applying a manifest twice adds nothing`() throws {
        let database = try IngestionTests.syncedDatabase()
        let manifest = try Self.manifest([("claude-opus-5", "1970-01-01T00:00:00Z", "20")])
        #expect(try database.pricing.apply(manifest).count == 1)
        #expect(try database.pricing.apply(manifest).isEmpty)
    }

    @Test func `EC-R4 a retroactive version re-prices only the events it covers`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([IngestionTests.record("before", at: 100), IngestionTests.record("after", at: 5_000),
                             IngestionTests.record("other-model", model: "claude-sonnet-5", at: 5_000)],
                            issues: [], provider: .claudeCode)
        #expect(try Self.costs(database).values.allSatisfy { $0 == nil })

        let windows = try database.pricing.apply(Self.manifest([("claude-opus-5", "1970-01-01T01:00:00Z", "20")]))
        #expect(try database.pricing.reprice(windows) == 1)
        let costs = try Self.costs(database)
        #expect(costs["before"] == .some(nil) && costs["other-model"] == .some(nil))
        // One input token at $1 and ten output tokens at $20 a million.
        #expect(costs["after"] == .some(201_000))
    }

    @Test func `a manifest model the store has not seen is created, so its events price on arrival`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.pricing.apply(Self.manifest([("claude-future-6", "1970-01-01T00:00:00Z", "20")]))
        try database.ingest([IngestionTests.record("e", model: "claude-future-6")], issues: [], provider: .claudeCode)
        #expect(try database.usage.events(in: Self.everything).first?.cost.amount != nil)
    }

    @Test func `a long-context variant name resolves to its model and its price`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.pricing.apply(Self.manifest([("claude-opus-5", "1970-01-01T00:00:00Z", "20")]))
        try database.ingest([IngestionTests.record("a", model: "claude-opus-5[1m]"),
                             IngestionTests.record("b", model: "anthropic/Claude-Opus-5")],
                            issues: [], provider: .claudeCode)
        let events = try database.usage.events(in: Self.everything)
        #expect(Set(events.map(\.modelID)).count == 1)
        #expect(events.allSatisfy { $0.cost.amount != nil })
    }

    @Test func `EC-R9 a fetched manifest that rewrites history is told apart from one that adds to it`() throws {
        let original = try Self.manifest([("claude-opus-5", "1970-01-01T00:00:00Z", "20")])
        let extended = try Self.manifest([("claude-opus-5", "1970-01-01T00:00:00Z", "20"),
                                          ("claude-opus-5", "2026-11-01T00:00:00Z", "10")])
        let rewritten = try Self.manifest([("claude-opus-5", "1970-01-01T00:00:00Z", "15")])
        #expect(extended.preserves(original))
        #expect(!rewritten.preserves(original))
    }

    @Test func `EC-R8 a negative prompt band refuses the manifest whole`() {
        let text = #"{"schemaVersion":1,"versions":[{"provider":"codex","model":"m","validFrom":"1970-01-01T00:00:00Z","tier":"standard","abovePromptTokens":-1,"source":"s","confidence":"exact","perMillion":{}}]}"#
        #expect(throws: PricingManifest.LoadError.self) { try PricingManifest.decode(Data(text.utf8)) }
    }

    @Test func `malformed manifests are refused whole`() {
        var bad = [
            #"{"schemaVersion":1,"versions":[{"provider":"claude_code","model":"m","validFrom":"1970-01-01T00:00:00Z","tier":"standard","source":"s","confidence":"exact","perMillion":{"input":"1e-6"}}]}"#,
            #"{"schemaVersion":1,"versions":[{"provider":"cursor-ish","model":"m","validFrom":"1970-01-01T00:00:00Z","tier":"standard","source":"s","confidence":"exact","perMillion":{}}]}"#,
            #"{"schemaVersion":1,"versions":[{"provider":"codex","model":"m","validFrom":"1970-01-01T00:00:00Z","tier":"turbo","source":"s","confidence":"exact","perMillion":{}}]}"#,
        ]
        let version = { (validFrom: String, validUntil: String?) in
            let until = validUntil.map { #","validUntil":"\#($0)""# } ?? ""
            return #"{"provider":"codex","model":"m","validFrom":"\#(validFrom)"\#(until),"tier":"standard","source":"s","confidence":"exact","perMillion":{"input":"1"}}"#
        }
        bad += [
            // A version that ends as it starts covers no time at all.
            #"{"schemaVersion":1,"versions":[\#(version("2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"))]}"#,
            // The same version twice would price one event two ways.
            #"{"schemaVersion":1,"versions":[\#(version("2026-01-01T00:00:00Z", nil)),\#(version("2026-01-01T00:00:00Z", nil))]}"#,
        ]
        for text in bad {
            #expect(throws: PricingManifest.LoadError.self) { try PricingManifest.decode(Data(text.utf8)) }
        }
        #expect(throws: PricingManifest.LoadError.unsupportedSchemaVersion(found: 2, supported: 1)) {
            try PricingManifest.decode(Data(#"{"schemaVersion":2,"versions":[]}"#.utf8))
        }
    }

    @Test func `cache savings use each event's own price, and count unpriced cache tokens as uncovered`() throws {
        let database = try IngestionTests.syncedDatabase()
        let entry = """
            {"provider":"claude_code","model":"claude-opus-5","validFrom":"1970-01-01T00:00:00Z","tier":"standard",\
            "source":"litellm","confidence":"exact","perMillion":{"input":"4","cachedInput":"0.4","output":"20"}}
            """
        try database.pricing.apply(PricingManifest.decode(Data(#"{"schemaVersion":1,"versions":[\#(entry)]}"#.utf8)))
        func cached(_ id: String, model: String) throws -> IncomingUsage {
            IncomingUsage(sourceEventID: id, sessionSourceID: "s", project: nil, rawModel: model,
                          timestamp: Timestamp(epochSeconds: 100), tokens: try TokenCounts(cachedInput: 1_000_000),
                          sourceType: "test", file: "/a.jsonl", schemaVersion: nil, offset: 0)
        }
        try database.ingest([cached("a", model: "claude-opus-5"), cached("b", model: "claude-unpriced-9")],
                            issues: [], provider: .claudeCode)
        let savings = try database.usage.cacheSavings(in: Self.everything)
        #expect(savings.saved == Nanodollars(decimalString: "3.6"))
        #expect(savings.coverage == 0.5)
    }
}
