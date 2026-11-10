//
//  UsageTotals.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// Sums over a span of history: what lifetime and long-range figures show.
/// They come from the 15-minute rollups, so they are the same whether or not
/// the span's events have been compacted away.
public struct UsageTotals: Equatable, Sendable {
    public let events: Int64
    public let tokens: TokenCounts
    /// Priced events only; `unpricedEvents` says how many are missing from it.
    public let cost: Nanodollars
    public let unpricedEvents: Int64
    public let cacheSavings: CacheSavings

    public init(events: Int64, tokens: TokenCounts, cost: Nanodollars, unpricedEvents: Int64,
                cacheSavings: CacheSavings) {
        self.events = events
        self.tokens = tokens
        self.cost = cost
        self.unpricedEvents = unpricedEvents
        self.cacheSavings = cacheSavings
    }

    public static let zero = UsageTotals(events: 0, tokens: .zero, cost: Nanodollars(raw: 0), unpricedEvents: 0,
                                         cacheSavings: CacheSavings())

    /// The share of events whose cost is included, which every headline cost
    /// carries; nil with no events at all.
    public var costCoverage: Double? {
        events == 0 ? nil : Double(events - unpricedEvents) / Double(events)
    }

    /// Both spans' totals together; throws only if a sum overflows.
    public func adding(_ other: UsageTotals) throws -> UsageTotals {
        func sum(_ a: Int64, _ b: Int64) throws(TokenCountError) -> Int64 {
            let (value, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw .overflow }
            return value
        }
        let tokens = try TokenCounts(
            input: sum(self.tokens.input, other.tokens.input),
            cachedInput: sum(self.tokens.cachedInput, other.tokens.cachedInput),
            cacheWrite: sum(self.tokens.cacheWrite, other.tokens.cacheWrite),
            cacheWriteOneHour: sum(self.tokens.cacheWriteOneHour, other.tokens.cacheWriteOneHour),
            output: sum(self.tokens.output, other.tokens.output),
            reasoning: sum(self.tokens.reasoning, other.tokens.reasoning))
        return UsageTotals(
            events: try sum(events, other.events), tokens: tokens, cost: try cost.adding(other.cost),
            unpricedEvents: try sum(unpricedEvents, other.unpricedEvents),
            cacheSavings: CacheSavings(
                saved: try cacheSavings.saved.adding(other.cacheSavings.saved),
                coveredCacheTokens: try sum(cacheSavings.coveredCacheTokens, other.cacheSavings.coveredCacheTokens),
                cacheTokens: try sum(cacheSavings.cacheTokens, other.cacheSavings.cacheTokens)))
    }
}
