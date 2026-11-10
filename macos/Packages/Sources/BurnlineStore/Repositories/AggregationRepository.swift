//
//  AggregationRepository.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import GRDB

extension BurnlineDatabase {
    public var aggregation: AggregationRepository { AggregationRepository(database: self) }
}

/// The aggregation queries. Bucketing happens in SQL: the caller passes the
/// bucket edges, worked out on the user's calendar, as a JSON list that each
/// query joins against an index, so a day of 23 hours or an hour starting at
/// half past is exact and nothing is grouped in Swift.
///
/// Rollups answer everything at 15-minute resolution, compacted history
/// included. Events answer what rollups cannot: minute buckets and sessions,
/// both only for history still within the detail window.
public struct AggregationRepository: Sendable {
    let database: BurnlineDatabase

    public enum Source: Sendable {
        /// 15-minute rollups: any range, edges rounded to quarter hours.
        case rollups
        /// Events: exact edges, but only since the compaction boundary.
        case events
    }

    /// Totals per bucket and group, one dictionary per bucket in `buckets`.
    /// A bucket or group without usage is absent from its dictionary.
    public func series(_ buckets: [TimeWindow], grouping: Grouping, filters: UsageFilters,
                       from source: Source) throws(StoreError) -> [[GroupKey: UsageTotals]] {
        guard !buckets.isEmpty else { return [] }
        let source = filters.sessions.isEmpty ? source : .events
        let edges = buckets.enumerated().map { index, window in
            source == .rollups ? [Int64(index), Self.bucket(atOrAfter: window.start), Self.bucket(atOrAfter: window.end)]
                               : [Int64(index), window.start.epochSeconds, window.end.epochSeconds]
        }
        let query = Self.query(source: source, grouping: grouping, filters: filters, edges: edges, database: database)
        return try database.read { db in
            var result = [[GroupKey: UsageTotals]](repeating: [:], count: buckets.count)
            for row in try Row.fetchAll(db, sql: query.sql, arguments: query.arguments) {
                let index: Int = row["edge"]
                result[index][key(grouping, row["grp"])] = try Self.totals(from: row)
            }
            return result
        }
    }

    /// One row per group over `window`, largest cost first, named for display.
    /// `.session` always reads events; other groupings use `source`.
    public func breakdown(_ window: TimeWindow, by key: BreakdownKey,
                          filters: UsageFilters, from source: Source = .rollups) throws(StoreError) -> [BreakdownRow] {
        let source: Source = key == .session || !filters.sessions.isEmpty ? .events : source
        let edges = source == .rollups
            ? [[0, Self.bucket(atOrAfter: window.start), Self.bucket(atOrAfter: window.end)]]
            : [[0, window.start.epochSeconds, window.end.epochSeconds]]
        let query = Self.query(source: source, grouping: key.grouping, bySession: key == .session,
                               filters: filters, edges: edges, database: database)
        return try database.read { db in
            let names = try Self.names(for: key, in: db)
            return try Row.fetchAll(db, sql: query.sql, arguments: query.arguments).map { row in
                let group = key == .session ? GroupKey.session(row["grp"]) : self.key(key.grouping, row["grp"])
                let last: Int64? = row["last_used"]
                return BreakdownRow(key: group, name: Self.name(of: group, names: names),
                                    provider: self.provider(of: group, names: names),
                                    isModel: Self.isModel(group, names: names),
                                    totals: try Self.totals(from: row),
                                    lastUsed: last.map(Timestamp.init(epochSeconds:)))
            }.sorted { ($0.totals.cost, $0.totals.tokens.processed) > ($1.totals.cost, $1.totals.tokens.processed) }
        }
    }

    /// The cost of each `span`-second stretch of `window` that holds priced
    /// usage, in no particular order: how hard the history worked when it
    /// worked, for judging how hard the present is. Reads events, so
    /// compacted history adds none.
    public func busySpanCosts(in window: TimeWindow, span: Int64) throws(StoreError) -> [Int64] {
        guard window.start < window.end, span > 0 else { return [] }
        return try database.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT sum(cost_nanos) AS cost FROM usage_events
                WHERE timestamp >= ? AND timestamp < ? AND cost_nanos IS NOT NULL
                GROUP BY timestamp / ? HAVING cost > 0
                """, arguments: [window.start.epochSeconds, window.end.epochSeconds, span])
        }
    }

    /// Sessions active at some point in `window`. Under a model filter, the
    /// sessions that used one of the models in it, which only events know,
    /// so compacted history counts none.
    public func sessions(in window: TimeWindow, filters: UsageFilters) throws(StoreError) -> Int {
        guard window.start < window.end else { return 0 }
        var sql = """
            \(Self.projectRoots)
            SELECT count(*) FROM sessions s LEFT JOIN roots ON roots.id = s.project_id
            WHERE s.started_at < ? AND coalesce(s.ended_at, s.started_at) >= ?
            """
        var arguments: StatementArguments = [window.end.epochSeconds, window.start.epochSeconds]
        if !filters.providers.isEmpty {
            sql += " AND s.provider_id IN (SELECT value FROM json_each(?))"
            arguments += [Self.json(filters.providers.map(database.providerID))]
        }
        if !filters.projects.isEmpty {
            sql += " AND coalesce(roots.root, s.project_id, 0) IN (SELECT value FROM json_each(?))"
            arguments += [Self.json(Array(filters.projects))]
        }
        if !filters.sessions.isEmpty {
            sql += " AND s.id IN (SELECT value FROM json_each(?))"
            arguments += [Self.json(Array(filters.sessions))]
        }
        if !filters.models.isEmpty {
            sql += " AND s.id IN (SELECT e.session_id FROM usage_events e WHERE e.timestamp >= ? AND e.timestamp < ?"
                + " AND coalesce(e.model_id, 0) IN (SELECT value FROM json_each(?)))"
            arguments += [window.start.epochSeconds, window.end.epochSeconds, Self.json(Array(filters.models))]
        }
        return try database.read { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    /// Sessions active at some point in each window, unfiltered, in one read.
    public func sessionCounts(in windows: [TimeWindow]) throws(StoreError) -> [Int] {
        guard !windows.isEmpty else { return [] }
        let bounds = windows.map { [$0.start.epochSeconds, $0.end.epochSeconds] }
        let counts = try database.read { db in
            try Row.fetchAll(db, sql: """
                WITH w(i, lo, hi) AS (
                  SELECT key, json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?))
                SELECT w.i, count(s.id) FROM w
                JOIN sessions s ON s.started_at < w.hi AND coalesce(s.ended_at, s.started_at) >= w.lo
                GROUP BY w.i
                """, arguments: [Self.json(bounds)]).map { (row: Row) in (row[0] as Int, row[1] as Int) }
        }
        var result = Array(repeating: 0, count: windows.count)
        for (index, count) in counts { result[index] = count }
        return result
    }

    /// Each window's processed tokens by project, merged projects counted
    /// under the one they joined, from the rollups so compacted history
    /// counts. Windows are whole quarter hours, as local days are.
    public func projectTokens(in windows: [TimeWindow]) throws(StoreError) -> [[Int64: Int64]] {
        guard !windows.isEmpty else { return [] }
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                \(Self.projectRoots),
                w(i, lo, hi) AS (
                  SELECT key, json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?))
                SELECT w.i, coalesce(roots.root, r.project_id),
                       sum(r.input_tokens + r.cached_input_tokens + r.output_tokens)
                FROM w JOIN usage_rollups r ON r.bucket >= w.lo AND r.bucket < w.hi
                LEFT JOIN roots ON roots.id = r.project_id
                WHERE r.project_id != 0
                GROUP BY w.i, coalesce(roots.root, r.project_id)
                """, arguments: [Self.json(Self.bucketBounds(windows))]).map { (row: Row) in
                (row[0] as Int, row[1] as Int64, row[2] as Int64)
            }
        }
        var result = Array(repeating: [Int64: Int64](), count: windows.count)
        for (index, project, tokens) in rows { result[index][project] = tokens }
        return result
    }

    /// The different models, not tools, used in each window.
    public func modelCounts(in windows: [TimeWindow]) throws(StoreError) -> [Int] {
        guard !windows.isEmpty else { return [] }
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                WITH w(i, lo, hi) AS (
                  SELECT key, json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?))
                SELECT w.i, count(DISTINCT r.model_id)
                FROM w JOIN usage_rollups r ON r.bucket >= w.lo AND r.bucket < w.hi
                JOIN models m ON m.id = r.model_id
                WHERE m.kind = 'model'
                GROUP BY w.i
                """, arguments: [Self.json(Self.bucketBounds(windows))]).map { (row: Row) in (row[0] as Int, row[1] as Int) }
        }
        var result = Array(repeating: 0, count: windows.count)
        for (index, count) in rows { result[index] = count }
        return result
    }

    /// Windows as rollup bucket ranges, start inclusive and end exclusive.
    private static func bucketBounds(_ windows: [TimeWindow]) -> [[Int64]] {
        let seconds = BurnlineDatabase.bucketSeconds
        return windows.map { [$0.start.epochSeconds / seconds, ($0.end.epochSeconds + seconds - 1) / seconds] }
    }

    /// When each model and each project was first used, from the rollups so
    /// compacted history counts.
    public func firstUses() throws(StoreError) -> (models: [Timestamp], projects: [Timestamp]) {
        try database.read { db in
            let models = try Int64.fetchAll(db, sql: """
                SELECT MIN(r.bucket) * 900 FROM usage_rollups r JOIN models m ON m.id = r.model_id
                WHERE m.kind = 'model' GROUP BY r.model_id
                """).map(Timestamp.init(epochSeconds:))
            let projects = try Int64.fetchAll(db, sql: """
                \(Self.projectRoots)
                SELECT MIN(r.bucket) * 900 FROM usage_rollups r LEFT JOIN roots ON roots.id = r.project_id
                WHERE r.project_id != 0 GROUP BY coalesce(roots.root, r.project_id)
                """).map(Timestamp.init(epochSeconds:))
            return (models, projects)
        }
    }

    /// The quarter hours with any usage in each window, read from the
    /// rollups so compacted history counts. Windows are whole quarter hours,
    /// as local days are, and in order.
    public func activeQuarterHours(in windows: [TimeWindow]) throws(StoreError) -> [Int] {
        guard let first = windows.first, let last = windows.last else { return [] }
        let seconds = BurnlineDatabase.bucketSeconds
        let buckets = try database.read { db in
            try Int64.fetchAll(db, sql: "SELECT DISTINCT bucket FROM usage_rollups WHERE bucket >= ? AND bucket < ? ORDER BY bucket",
                               arguments: [first.start.epochSeconds / seconds, (last.end.epochSeconds + seconds - 1) / seconds])
        }
        var counts = Array(repeating: 0, count: windows.count), index = 0
        for bucket in buckets {
            let at = bucket * seconds
            while index < windows.count, at >= windows[index].end.epochSeconds { index += 1 }
            guard index < windows.count else { break }
            if at >= windows[index].start.epochSeconds { counts[index] += 1 }
        }
        return counts
    }

    /// The oldest instant with usage, compacted history included.
    public func earliest() throws(StoreError) -> Timestamp? {
        try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT min(bucket) FROM usage_rollups").map {
                Timestamp(epochSeconds: $0 * BurnlineDatabase.bucketSeconds)
            }
        }
    }

    // MARK: Building the queries

    /// Every project mapped to the one it is merged into, through any chain
    /// of merges. Merging never makes a loop, so the recursion ends.
    static let projectRoots = """
        WITH RECURSIVE roots(id, root) AS (
          SELECT id, id FROM projects WHERE merged_into_id IS NULL
          UNION ALL
          SELECT p.id, roots.root FROM projects p JOIN roots ON p.merged_into_id = roots.id)
        """

    /// The rollups of each edge, as `r`: whole UTC days from `daily_rollups`,
    /// and the partial days at either end, or an edge shorter than a day,
    /// from `usage_rollups`. A tenth of the rows for a long range, and exact
    /// to the quarter hour. `last` is the latest bucket each row covers.
    static let dailySplit = """
        parts(i, lo, head, first, past, tail, hi) AS MATERIALIZED (
          SELECT i, lo, CASE WHEN (lo + 95) / 96 < hi / 96 THEN (lo + 95) / 96 * 96 ELSE hi END,
                 (lo + 95) / 96, hi / 96,
                 CASE WHEN (lo + 95) / 96 < hi / 96 THEN hi / 96 * 96 ELSE hi END, hi
          FROM edges),
        r AS (
          SELECT p.i, x.bucket AS last, \(rollupColumns) FROM parts p
            JOIN usage_rollups x ON x.bucket >= p.lo AND x.bucket < p.head
          UNION ALL
          SELECT p.i, x.last_bucket, \(rollupColumns) FROM parts p
            JOIN daily_rollups x ON x.day >= p.first AND x.day < p.past
          UNION ALL
          SELECT p.i, x.bucket, \(rollupColumns) FROM parts p
            JOIN usage_rollups x ON x.bucket >= p.tail AND x.bucket < p.hi)
        """

    private static let rollupColumns = """
        x.provider_id, x.model_id, x.project_id, x.events, x.input_tokens, x.cached_input_tokens, \
        x.cache_write_tokens, x.cache_write_1h_tokens, x.output_tokens, x.reasoning_tokens, x.cost_nanos, \
        x.unpriced_events, x.cache_savings_nanos, x.cache_savings_tokens
        """

    /// `bySession` groups events by session instead of by `grouping`; only
    /// events know their session.
    static func query(source: Source, grouping: Grouping, bySession: Bool = false, filters: UsageFilters,
                              edges: [[Int64]], database: BurnlineDatabase) -> (sql: String, arguments: StatementArguments) {
        let rollups = source == .rollups
        let t = rollups ? "r" : "e"
        let model = rollups ? "r.model_id" : "coalesce(e.model_id, 0)"
        let project = rollups ? "coalesce(roots.root, r.project_id)" : "coalesce(roots.root, e.project_id, 0)"
        let group: String = if bySession { "e.session_id" } else {
            switch grouping {
            case .total: "0"
            case .provider: "\(t).provider_id"
            case .model: model
            case .project: project
            }
        }
        let sums = rollups ? """
            sum(r.events) AS events, sum(r.input_tokens) AS input, sum(r.cached_input_tokens) AS cached,
            sum(r.cache_write_tokens) AS write, sum(r.cache_write_1h_tokens) AS write1h,
            sum(r.output_tokens) AS output, sum(r.reasoning_tokens) AS reasoning, sum(r.cost_nanos) AS cost,
            sum(r.unpriced_events) AS unpriced, sum(r.cache_savings_nanos) AS saved,
            sum(r.cache_savings_tokens) AS covered, (max(r.last) + 1) * 900 - 1 AS last_used
            """ : """
            count(*) AS events, sum(e.input_tokens) AS input, sum(e.cached_input_tokens) AS cached,
            sum(e.cache_write_tokens) AS write, sum(e.cache_write_1h_tokens) AS write1h,
            sum(e.output_tokens) AS output, sum(e.reasoning_tokens) AS reasoning,
            coalesce(sum(e.cost_nanos), 0) AS cost, sum(e.cost_nanos IS NULL) AS unpriced,
            coalesce(sum(e.cache_savings_nanos), 0) AS saved,
            sum(CASE WHEN e.cache_savings_nanos IS NULL THEN 0 ELSE e.cached_input_tokens + e.cache_write_tokens END)
              AS covered, max(e.timestamp) AS last_used
            """
        let from = rollups
            ? ",\n" + dailySplit + "\nSELECT r.i AS edge, \(group) AS grp, \(sums) FROM r"
            : "\nSELECT edges.i AS edge, \(group) AS grp, \(sums) FROM edges "
                + "JOIN usage_events e ON e.timestamp >= edges.lo AND e.timestamp < edges.hi"
        // Merges matter only to a project grouping or filter; joining them
        // otherwise costs a lookup per row.
        let merges = !bySession && grouping == .project || !filters.projects.isEmpty
        var sql = """
            \(merges ? projectRoots + "," : "WITH")
            edges(i, lo, hi) AS MATERIALIZED (
              SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]')
              FROM json_each(?))\(from)
            \(merges ? "LEFT JOIN roots ON roots.id = \(t).project_id" : "")
            WHERE 1
            """
        var arguments: StatementArguments = [json(edges)]
        if !filters.providers.isEmpty {
            sql += " AND \(t).provider_id IN (SELECT value FROM json_each(?))"
            arguments += [json(filters.providers.map(database.providerID))]
        }
        if !filters.models.isEmpty {
            sql += " AND \(model) IN (SELECT value FROM json_each(?))"
            arguments += [json(Array(filters.models))]
        }
        if !filters.projects.isEmpty {
            sql += " AND \(project) IN (SELECT value FROM json_each(?))"
            arguments += [json(Array(filters.projects))]
        }
        if !filters.sessions.isEmpty {
            precondition(!rollups, "rollups do not know their session")
            sql += " AND e.session_id IN (SELECT value FROM json_each(?))"
            arguments += [json(Array(filters.sessions))]
        }
        sql += " GROUP BY edge, grp"
        return (sql, arguments)
    }

    /// The first rollup bucket starting at or after `instant`.
    static func bucket(atOrAfter instant: Timestamp) -> Int64 {
        let seconds = BurnlineDatabase.bucketSeconds
        let value = instant.epochSeconds
        return value / seconds + (value % seconds > 0 ? 1 : 0)
    }

    static func json(_ values: some Encodable) -> String {
        String(decoding: try! JSONEncoder().encode(values), as: UTF8.self)
    }

    private func key(_ grouping: Grouping, _ value: Int64) -> GroupKey {
        switch grouping {
        case .total: .total
        case .provider: database.providerIDs.first { $0.value == value }.map { .provider($0.key) } ?? .total
        case .model: .model(value == 0 ? nil : value)
        case .project: .project(value == 0 ? nil : value)
        }
    }

    // MARK: Reading rows

    static func totals(from row: Row) throws -> UsageTotals {
        let tokens = try TokenCounts(
            input: row["input"] ?? 0, cachedInput: row["cached"] ?? 0, cacheWrite: row["write"] ?? 0,
            cacheWriteOneHour: row["write1h"] ?? 0, output: row["output"] ?? 0, reasoning: row["reasoning"] ?? 0)
        let (cacheTokens, overflow) = tokens.cachedInput.addingReportingOverflow(tokens.cacheWrite)
        guard !overflow else { throw TokenCountError.overflow }
        return UsageTotals(
            events: row["events"] ?? 0, tokens: tokens, cost: Nanodollars(raw: row["cost"] ?? 0),
            unpricedEvents: row["unpriced"] ?? 0,
            cacheSavings: CacheSavings(saved: Nanodollars(raw: row["saved"] ?? 0),
                                       coveredCacheTokens: row["covered"] ?? 0,
                                       cacheTokens: cacheTokens))
    }

    typealias Names = [Int64: (name: String, provider: Int64?, isModel: Bool)]

    /// Each row's name, its provider's id where the row has one provider
    /// (models and sessions do, projects span several), and whether a model
    /// row is a model at all.
    private static func names(for key: BreakdownKey, in db: Database) throws -> Names {
        let sql: String? = switch key {
        case .provider: nil
        case .model: "SELECT id, display_name, NULL, NULL, provider_id, kind = 'model' FROM models"
        case .project: "SELECT id, user_alias, display_name, last_known_path, NULL, 1 FROM projects"
        case .session: """
            \(projectRoots)
            SELECT s.id, p.user_alias, p.display_name, p.last_known_path, s.provider_id, 1, s.source_session_id
            FROM sessions s LEFT JOIN roots ON roots.id = s.project_id
            LEFT JOIN projects p ON p.id = roots.root
            """
        }
        guard let sql else { return [:] }
        return Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: sql).map { row in
            // A project reads as `Project.name` does: the alias, else the
            // derived name made readable. A model's name is its own.
            let alias: String? = row[1], stored: String? = row[2]
            let name = key == .model ? alias : alias ?? stored.map { ProjectName.readable($0, path: row[3]) }
            return (row[0], (name ?? row[6], row[4], row[5]))
        })
    }

    private static func name(of key: GroupKey, names: Names) -> String {
        switch key {
        case .total: "Total"
        case .provider(let provider): provider.displayName
        case .model(let id): id.flatMap { names[$0]?.name } ?? "No model"
        case .project(let id): id.flatMap { names[$0]?.name } ?? "No project"
        case .session(let id): names[id]?.name ?? "Session \(id)"
        }
    }

    /// Values such as `<synthetic>` stand in the model field without being
    /// models; they stay visible but out of model-share arithmetic.
    private static func isModel(_ key: GroupKey, names: Names) -> Bool {
        if case .model(let id?) = key { return names[id]?.isModel ?? true }
        return true
    }

    private func provider(of key: GroupKey, names: Names) -> ProviderKey? {
        if case .provider(let provider) = key { return provider }
        let id: Int64? = switch key {
        case .total, .project, .provider: nil
        case .model(let id): id.flatMap { names[$0]?.provider }
        case .session(let id): names[id]?.provider
        }
        return id.flatMap { id in database.providerIDs.first { $0.value == id }?.key }
    }
}
