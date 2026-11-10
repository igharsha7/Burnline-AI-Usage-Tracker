//
//  AggregationTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineStore
import Foundation
import GRDB
import Testing

/// The aggregation queries: sums per calendar bucket, filtered and grouped,
/// agreeing with the plain totals and carrying their pricing coverage.
struct AggregationTests {
    static let everything = IngestionTests.everything
    static let india = LocalCalendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!, firstWeekday: .monday)

    static func project(_ name: String) -> ProjectCandidate {
        ProjectCandidate(identity: .gitRemote("github.com/burnline/\(name)"), displayName: name, path: "/\(name)")
    }

    /// Two projects, two models and two providers over three hours; Opus is
    /// priced and Sonnet is not.
    static func small() throws -> BurnlineDatabase {
        let database = try IngestionTests.syncedDatabase()
        let claude = try (0..<12).map { index in
            try IngestionTests.record("c\(index)", model: index.isMultiple(of: 3) ? "claude-sonnet-5-5" : "claude-opus-5",
                                      at: 3_600 + Int64(index) * 900, session: index < 6 ? "s1" : "s2",
                                      project: project(index < 6 ? "api" : "web"))
        }
        try database.ingest(claude, issues: [], provider: .claudeCode)
        try database.ingest([try IngestionTests.record("x0", model: "gpt-5.5", at: 4_000, session: "x",
                                                       project: project("api"))],
                            issues: [], provider: .codex)
        try database.pricing.reprice(database.pricing.apply(PricingStoreTests.manifest([
            ("claude-opus-5", "1970-01-01T00:00:00Z", "20")])))
        return database
    }

    static func id(_ db: Database, _ sql: String, _ name: String) throws -> Int64 {
        try Int64.fetchOne(db, sql: sql, arguments: [name])!
    }

    static func modelID(_ database: BurnlineDatabase, _ name: String) throws -> Int64 {
        try database.read { try id($0, "SELECT id FROM models WHERE canonical_name = ?", name) }
    }

    static func projectID(_ database: BurnlineDatabase, _ name: String) throws -> Int64 {
        try database.read { try id($0, "SELECT id FROM projects WHERE display_name = ?", name) }
    }

    static func hours(_ range: ClosedRange<Int64>) -> [TimeWindow] {
        range.map { TimeWindow(start: Timestamp(epochSeconds: $0 * 3_600), end: Timestamp(epochSeconds: ($0 + 1) * 3_600)) }
    }

    @Test func `every bucket's total matches the plain totals, from rollups and from events`() throws {
        let database = try Self.small()
        let buckets = Self.hours(0...4)
        for source in [AggregationRepository.Source.rollups, .events] {
            let series = try database.aggregation.series(buckets, grouping: .total, filters: .none, from: source)
            try #require(series.count == buckets.count)
            for (window, groups) in zip(buckets, series) {
                let expected = try database.usage.totals(in: window)
                #expect((groups[.total] ?? .zero) == expected, "\(source) \(window)")
            }
        }
    }

    @Test func `groups add up to the bucket's total`() throws {
        let database = try Self.small()
        let buckets = Self.hours(0...4)
        let totals = try database.aggregation.series(buckets, grouping: .total, filters: .none, from: .rollups)
        for grouping in [Grouping.provider, .model, .project] {
            let grouped = try database.aggregation.series(buckets, grouping: grouping, filters: .none, from: .rollups)
            try #require(grouped.count == totals.count && totals.count == buckets.count)
            for (total, groups) in zip(totals, grouped) {
                let sum = try groups.values.reduce(UsageTotals.zero) { try $0.adding($1) }
                #expect(sum == (total[.total] ?? .zero), "\(grouping)")
            }
        }
    }

    @Test func `EC-U3 each bucket's coverage comes from its own events`() throws {
        let database = try Self.small()
        let buckets = Self.hours(1...3)
        let series = try database.aggregation.series(buckets, grouping: .model, filters: .none, from: .rollups)
        let opus = GroupKey.model(try Self.modelID(database, "claude-opus-5"))
        let sonnet = GroupKey.model(try Self.modelID(database, "claude-sonnet-5-5"))
        for groups in series {
            #expect(groups[opus]?.costCoverage == 1)
            #expect(groups[sonnet]?.costCoverage == 0 && groups[sonnet]?.cost.raw == 0)
        }
        // The 1am hour holds two Opus, two Sonnet and one unpriced Codex event.
        let total = try database.aggregation.series([buckets[0]], grouping: .total, filters: .none, from: .rollups)
        #expect(total[0][.total]?.events == 5 && total[0][.total]?.costCoverage == 0.4)
    }

    @Test func `filters narrow by provider, model and project, merges followed`() throws {
        let database = try Self.small()
        let all = [TimeWindow(start: .init(epochSeconds: 0), end: .init(epochSeconds: 86_400))]
        func events(_ filters: UsageFilters) throws -> Int64 {
            try database.aggregation.series(all, grouping: .total, filters: filters, from: .rollups)[0][.total]?.events ?? 0
        }
        let api = try Self.projectID(database, "api"), web = try Self.projectID(database, "web")
        #expect(try events(.init(providers: [.codex])) == 1)
        #expect(try events(.init(models: [try Self.modelID(database, "claude-opus-5")])) == 8)
        #expect(try events(.init(projects: [api])) == 7)
        #expect(try events(.init(providers: [.claudeCode], projects: [api])) == 6)

        try database.projects.merge(web, into: api)
        #expect(try events(.init(projects: [api])) == 13)
        #expect(try events(.init(projects: [web])) == 0)
        let byProject = try database.aggregation.series(all, grouping: .project, filters: .none, from: .rollups)[0]
        #expect(byProject.keys.sorted { "\($0)" < "\($1)" } == [.project(api)])
        #expect(try database.aggregation.sessions(in: all[0], filters: .init(projects: [api])) == 3)
    }

    @Test func `the breakdown names its rows and puts the costliest first`() throws {
        let database = try Self.small()
        let day = TimeWindow(start: .init(epochSeconds: 0), end: .init(epochSeconds: 86_400))
        let models = try database.aggregation.breakdown(day, by: .model, filters: .none)
        #expect(models.map(\.name).first == "Claude Opus 5")
        #expect(models.map(\.totals.events).reduce(0, +) == 13)
        let providers = try database.aggregation.breakdown(day, by: .provider, filters: .none)
        #expect(Set(providers.map(\.name)) == ["Claude Code", "Codex"])
        let sessions = try database.aggregation.breakdown(day, by: .session, filters: .none)
        #expect(sessions.count == 3 && sessions.map(\.totals.events).sorted() == [1, 6, 6])
        #expect(sessions.contains { $0.name == "Web" })
        // Events know the last use to the second; rollups to the quarter hour.
        #expect(sessions.compactMap(\.lastUsed).max() == Timestamp(epochSeconds: 3_600 + 11 * 900))
        #expect(models.compactMap(\.lastUsed).max() == Timestamp(epochSeconds: 3_600 + 12 * 900 - 1))
    }

    @Test func `breakdown rows carry their provider where they have one`() throws {
        let database = try Self.small()
        let day = TimeWindow(start: .init(epochSeconds: 0), end: .init(epochSeconds: 86_400))
        let models = try database.aggregation.breakdown(day, by: .model, filters: .none)
        #expect(models.first { $0.name == "Claude Opus 5" }?.provider == .claudeCode)
        #expect(models.allSatisfy { $0.provider != nil && $0.isModel })
        let providers = try database.aggregation.breakdown(day, by: .provider, filters: .none)
        #expect(providers.allSatisfy { if case .provider(let key) = $0.key { $0.provider == key } else { false } })
        #expect(try database.aggregation.breakdown(day, by: .session, filters: .none).allSatisfy { $0.provider != nil })
        // A project can span providers, so it names none.
        #expect(try database.aggregation.breakdown(day, by: .project, filters: .none).allSatisfy { $0.provider == nil })
    }

    @Test func `a value that is not a model is listed but marked`() throws {
        let database = try Self.small()
        try database.ingest([IncomingUsage(sourceEventID: "synthetic", sessionSourceID: "s", project: nil,
                                           rawModel: "<synthetic>", timestamp: .init(epochSeconds: 600),
                                           tokens: try TokenCounts(output: 5), sourceType: "test", file: "/a.jsonl",
                                           schemaVersion: nil, offset: 0)],
                            issues: [], provider: .claudeCode)
        let day = TimeWindow(start: .init(epochSeconds: 0), end: .init(epochSeconds: 86_400))
        let rows = try database.aggregation.breakdown(day, by: .model, filters: .none)
        #expect(rows.first { $0.name == "<synthetic>" }?.isModel == false)
        #expect(rows.filter(\.isModel).count == rows.count - 1)
    }

    @Test func `sessions count the ones active in the range`() throws {
        let database = try Self.small()
        let early = TimeWindow(start: .init(epochSeconds: 0), end: .init(epochSeconds: 3_601))
        #expect(try database.aggregation.sessions(in: early, filters: .none) == 1)
        #expect(try database.aggregation.sessions(in: Self.everything, filters: .init(providers: [.codex])) == 1)
    }

    @Test func `EC-T1 local weeks and months, whole UTC days and partial ones, sum exactly`() throws {
        let (_, database, shape) = try CompactionTests.history(events: 5_000)
        let span = TimeWindow(start: shape.end.adding(seconds: -700 * 86_400), end: shape.end)
        for width in [BucketWidth.day, .week, .month] {
            let buckets = Self.india.buckets(width, covering: span)
            let series = try database.aggregation.series(buckets, grouping: .total, filters: .none, from: .rollups)
            try #require(series.count == buckets.count)
            for (window, groups) in zip(buckets, series) {
                #expect((groups[.total] ?? .zero) == (try database.usage.totals(in: window)), "\(width) \(window)")
            }
        }
    }

    @Test func `compacted history still charts and breaks down, by quarter hour`() throws {
        let (_, database, shape) = try CompactionTests.history(events: 5_000)
        let year = TimeWindow(start: shape.end.adding(seconds: -365 * 86_400), end: shape.end)
        let days = Self.india.buckets(.day, covering: year)
        let before = try database.aggregation.series(days, grouping: .provider, filters: .none, from: .rollups)
        let breakdown = try database.aggregation.breakdown(year, by: .project, filters: .none)
        try database.compact(before: shape.end.adding(seconds: -180 * 86_400))
        #expect(try database.aggregation.series(days, grouping: .provider, filters: .none, from: .rollups) == before)
        #expect(try database.aggregation.breakdown(year, by: .project, filters: .none) == breakdown)
        #expect(try database.aggregation.earliest()! <= shape.end.adding(seconds: -365 * 86_400))
    }

    @Test func `EC-I6 sessions without a project match the none filter`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([IngestionTests.record("none")], issues: [], provider: .claudeCode)
        #expect(try database.aggregation.sessions(in: Self.everything, filters: .init(projects: [0])) == 1)
    }

    @Test func `EC-U1 an empty window has no active sessions`() throws {
        let database = try Self.small()
        let instant = Timestamp(epochSeconds: 4_000)
        #expect(try database.aggregation.sessions(in: TimeWindow(start: instant, end: instant), filters: .none) == 0)
    }

    @Test func `EC-R6 daily updates keep representable large token sums exact`() throws {
        let database = try IngestionTests.syncedDatabase()
        let large = Int64.max / 2
        try database.ingest([IngestionTests.record("large", output: large)], issues: [], provider: .claudeCode)
        try database.ingest([IngestionTests.record("small", output: 10)], issues: [], provider: .claudeCode)
        try database.read { db in
            let type = try String.fetchOne(db, sql: "SELECT typeof(output_tokens) FROM daily_rollups")
            let value = try String.fetchOne(db, sql: "SELECT CAST(output_tokens AS TEXT) FROM daily_rollups")
            #expect(type == "integer")
            #expect(value == String(large + 10))
        }
    }

    @Test func `EC-R6 cache token overflow throws a store error`() throws {
        let database = try IngestionTests.syncedDatabase()
        let event = IncomingUsage(sourceEventID: "cache", sessionSourceID: "s", project: nil, rawModel: nil,
                                  timestamp: Timestamp(epochSeconds: 1_000),
                                  tokens: try TokenCounts(cachedInput: Int64.max - 10, cacheWrite: 11),
                                  sourceType: "test", file: "/a.jsonl", schemaVersion: nil, offset: 0)
        try database.ingest([event], issues: [], provider: .claudeCode)
        #expect(throws: StoreError.self) {
            try database.aggregation.series([Self.everything], grouping: .total, filters: .none, from: .rollups)
        }
        #expect(throws: StoreError.self) {
            try database.aggregation.series([Self.everything], grouping: .total, filters: .none, from: .events)
        }
        #expect(throws: StoreError.self) { try database.usage.totals(in: Self.everything) }
    }

    @Test func `EC-U1 daily split matches plain rollups at empty and rounded edges`() throws {
        let database = try IngestionTests.syncedDatabase()
        let records = try (0..<200).map { try IngestionTests.record("edge\($0)", at: Int64($0) * 900) }
        try database.ingest(records, issues: [], provider: .claudeCode)
        let edges: [Int64] = [-172_800, -901, -1, 0, 1, 899, 900, 86_399, 86_400, 86_401, 172_800, .max]
        let windows = edges.enumerated().flatMap { index, lo in
            edges[index...].map { TimeWindow(start: Timestamp(epochSeconds: lo), end: Timestamp(epochSeconds: $0)) }
        }
        let series = try database.aggregation.series(windows, grouping: .total, filters: .none, from: .rollups)
        try #require(series.count == windows.count)
        for (window, groups) in zip(windows, series) {
            #expect((groups[.total] ?? .zero) == (try database.usage.totals(in: window)), "\(window)")
        }
    }

    @Test func `EC-D10 deleting the latest bucket updates daily last used`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([IngestionTests.record("first", at: 900), IngestionTests.record("last", at: 85_500)],
                            issues: [], provider: .claudeCode)
        try database.write { try $0.execute(sql: "DELETE FROM usage_events WHERE source_event_id = 'last'") }
        let (kept, expected) = try StorageTests.rollups(database)
        #expect(kept == expected)
        let rows = try database.aggregation.breakdown(Self.everything, by: .provider, filters: .none)
        #expect(rows.first?.lastUsed == Timestamp(epochSeconds: 1_799))
    }

    @Test func `EC-I6 EC-M5 none filters agree for events and rollups`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([IngestionTests.record("none", model: nil)], issues: [], provider: .claudeCode)
        for source in [AggregationRepository.Source.events, .rollups] {
            let series = try database.aggregation.series([Self.everything], grouping: .project,
                                                         filters: .init(models: [0], projects: [0]), from: source)
            #expect(series[0][.project(nil)]?.events == 1)
        }
    }

    @Test func `EC-D10 EC-R4 daily sums survive batch updates and rebuilding a split compacted day`() throws {
        let database = try IngestionTests.syncedDatabase()
        let records = try (0..<600).map {
            try IngestionTests.record("batch\($0)", at: Int64($0) * 450, output: Int64($0))
        }
        try database.ingest(records, issues: [], provider: .claudeCode)
        try database.pricing.reprice(database.pricing.apply(PricingStoreTests.manifest([
            ("claude-opus-5", "1970-01-01T00:00:00Z", "20")])))
        try database.write { db in
            try db.execute(sql: "UPDATE usage_events SET cost_nanos = cost_nanos + 7, cache_savings_nanos = 3")
        }
        #expect(try StorageTests.rollups(database).kept == StorageTests.rollups(database).expected)
        let before = try database.aggregation.breakdown(Self.everything, by: .provider, filters: .none)
        try database.compact(before: Timestamp(epochSeconds: 86_400 + 17 * 900))
        try database.rebuildRollups()
        #expect(try StorageTests.rollups(database).kept == StorageTests.rollups(database).expected)
        #expect(try database.aggregation.breakdown(Self.everything, by: .provider, filters: .none) == before)
        try database.usage.deleteEvents(before: Timestamp(epochSeconds: 2 * 86_400 + 901))
        #expect(try StorageTests.rollups(database).kept == StorageTests.rollups(database).expected)
        let window = TimeWindow(start: Timestamp(epochSeconds: 2 * 86_400), end: Timestamp(epochSeconds: 3 * 86_400))
        let rows = try database.aggregation.breakdown(window, by: .provider, filters: .none)
        #expect(rows.first?.lastUsed == Timestamp(epochSeconds: 3 * 86_400 - 1))
        #expect(try database.aggregation.series([window], grouping: .total, filters: .none, from: .rollups)[0][.total]
                == database.usage.totals(in: window))
    }

    @Test func `EC-D10 EC-D11 rebuilding after interrupted compaction preserves both tiers`() throws {
        let database = try Self.small()
        let before = try database.aggregation.breakdown(Self.everything, by: .provider, filters: .none)
        let boundary = Timestamp(epochSeconds: 9_000)
        // Compaction commits the boundary before it starts deleting events.
        try database.write { db in
            try db.execute(sql: "UPDATE compaction SET compacted_before = ?", arguments: [boundary.epochSeconds])
        }
        try database.rebuildRollups()
        #expect(try database.aggregation.breakdown(Self.everything, by: .provider, filters: .none) == before)
        try database.compact(before: boundary)
        #expect(try StorageTests.rollups(database).kept == StorageTests.rollups(database).expected)
    }

    @Test func `EC-U1 last used takes the latest bucket from head daily tier and tail`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest((0..<4).map { try IngestionTests.record("last\($0)", at: Int64($0) * 86_400 + 900) },
                            issues: [], provider: .claudeCode)
        let day: Int64 = 86_400
        let edges: [(Int64, Int64)] = [(3 * day + 1_800, 3 * day + 1_799),
                                      (3 * day, 2 * day + 1_799), (day, 1_799)]
        for (end, last) in edges {
            let window = TimeWindow(start: Timestamp(epochSeconds: 900), end: Timestamp(epochSeconds: end))
            let rows = try database.aggregation.breakdown(window, by: .provider, filters: .none)
            #expect(rows.first?.lastUsed == Timestamp(epochSeconds: last))
        }
    }

    @Test func `EC-U1 tied breakdown rows keep their order across detail and rollup sources`() throws {
        let database = try IngestionTests.syncedDatabase()
        try database.ingest([IngestionTests.record("z", model: "z-model"),
                             IngestionTests.record("a", model: "a-model")], issues: [], provider: .claudeCode)
        let detail = try database.aggregation.breakdown(Self.everything, by: .model, filters: .none, from: .events)
        let rollups = try database.aggregation.breakdown(Self.everything, by: .model, filters: .none)
        #expect(detail.count == 2 && detail[0].totals == detail[1].totals)
        #expect(detail.map(\.key) == rollups.map(\.key))
    }

    @Test func `a session filter reads events, whatever source is asked for`() throws {
        let database = try Self.small()
        let rows = try database.aggregation.breakdown(Self.everything, by: .session, filters: .none)
        let s1 = try #require(rows.first { $0.totals.events == 6 && $0.provider == .claudeCode })
        guard case .session(let id) = s1.key else { Issue.record("not a session row"); return }
        let filters = UsageFilters(sessions: [id])
        let all = [TimeWindow(start: .init(epochSeconds: 0), end: .init(epochSeconds: 86_400))]
        for source in [AggregationRepository.Source.rollups, .events] {
            let series = try database.aggregation.series(all, grouping: .model, filters: filters, from: source)[0]
            #expect(series.values.reduce(0) { $0 + $1.events } == 6)
        }
        #expect(try database.aggregation.breakdown(all[0], by: .model, filters: filters).count == 2)
        #expect(try database.aggregation.sessions(in: all[0], filters: filters) == 1)
    }

    @Test func `EC-P7 a renamed project keeps its history, and a blank name restores the derived one`() throws {
        let database = try Self.small()
        let api = try Self.projectID(database, "api"), web = try Self.projectID(database, "web")
        try database.projects.rename(api, to: "  Backend ")
        try database.projects.merge(web, into: api)
        let rows = try database.aggregation.breakdown(Self.everything, by: .project, filters: .none)
        #expect(rows.map(\.name) == ["Backend"])
        #expect(rows[0].totals.events == 13)
        #expect(try database.projects.all().map(\.id).sorted() == [api, web].sorted())

        try database.projects.rename(api, to: " ")
        try database.projects.unmerge(web)
        let restored = try database.aggregation.breakdown(Self.everything, by: .project, filters: .none)
        #expect(Set(restored.map(\.name)) == ["Api", "Web"])
        #expect(restored.map(\.totals.events).sorted() == [6, 7])
    }

    @Test func `sessions are looked up by id with their provider and span`() throws {
        let database = try Self.small()
        let ids = try database.read { try Int64.fetchAll($0, sql: "SELECT id FROM sessions") }
        let sessions = try database.sessions.sessions(ids: ids + [9_999])
        #expect(sessions.count == 3)
        let x = try #require(sessions.first { $0.sourceSessionID == "x" })
        #expect(x.provider == .codex && x.startedAt == Timestamp(epochSeconds: 4_000))
        #expect(try database.sessions.sessions(ids: []).isEmpty)
    }

    @Test func `EC-P7 session names follow the merged project alias`() throws {
        let database = try Self.small()
        let api = try Self.projectID(database, "api"), web = try Self.projectID(database, "web")
        try database.projects.merge(web, into: api)
        try database.write { try $0.execute(sql: "UPDATE projects SET user_alias = 'Backend' WHERE id = ?", arguments: [api]) }
        let rows = try database.aggregation.breakdown(Self.everything, by: .session, filters: .init(projects: [api]))
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.name == "Backend" })
    }

    @Test(arguments: [AggregationRepository.Source.rollups, .events])
    func `the queries search an index rather than scan`(source: AggregationRepository.Source) throws {
        let database = try Self.small()
        let edges: [[Int64]] = [[0, 0, 100], [1, 100, 200]]
        let filters = UsageFilters(providers: [.claudeCode], projects: [1])
        let query = AggregationRepository.query(source: source, grouping: .model, filters: filters,
                                                edges: edges, database: database)
        let steps = try database.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + query.sql, arguments: query.arguments)
                .map { $0["detail"] as String }
        }
        let alias = source == .rollups ? "x" : "e"
        let searches = source == .rollups
            ? ["SEARCH x USING PRIMARY KEY (bucket>? AND bucket<?)", "SEARCH x USING PRIMARY KEY (day>? AND day<?)"]
            : ["SEARCH e USING INDEX idx_usage_ts"]
        for search in searches { #expect(steps.contains { $0.hasPrefix(search) }, "\(steps)") }
        #expect(!steps.contains { $0 == "SCAN \(alias)" || $0.hasPrefix("SCAN \(alias) ") }, "\(steps)")
    }
}
