//
//  Pricer.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// Prices one event against its model's pricing history.
///
/// Selection, from the rows that apply at the event's time:
/// rows of the event's tier, falling back to standard for a tier the model
/// has no rows for; then the highest prompt-length band the prompt exceeds;
/// then a user's price over any other; then the most recently started.
/// A model with rows but none covering the instant is a gap, and stays
/// unpriced rather than borrowing today's price.
///
/// Each component is costed at its own rate. A cache read or write with no
/// rate of its own is costed at the input rate, and the result is marked
/// estimated. Reasoning is never added: both providers count it inside output.
public enum Pricer {
    public static func price(_ tokens: TokenCounts, tier recorded: ServiceTier?, at instant: Timestamp,
                             versions: [PricingVersion]) -> CostAttribution {
        guard !versions.isEmpty else { return .unpriced(.unknownModel) }
        let current = versions.filter { $0.applies(at: instant) }
        let tier = recorded ?? .standard
        var estimated = recorded == nil
        var candidates = current.filter { $0.serviceTier == tier }
        if candidates.isEmpty, tier != .standard {
            candidates = current.filter { $0.serviceTier == .standard }
            estimated = true
        }

        // Input plus cache reads already fits Int64; adding cache writes
        // needs its unsigned range, since writes are not part of processed.
        let prompt = UInt64(tokens.input) + UInt64(tokens.cachedInput) + UInt64(tokens.cacheWrite)
        let chosen = candidates
            .filter { $0.abovePromptTokens == 0 || prompt > UInt64(clamping: $0.abovePromptTokens) }
            .max { a, b in
                (a.abovePromptTokens, a.source == PricingVersion.userSource ? 1 : 0, a.validFrom, a.id)
                    < (b.abovePromptTokens, b.source == PricingVersion.userSource ? 1 : 0, b.validFrom, b.id)
            }
        guard let chosen, let cost = cost(tokens, at: chosen.rates, estimated: &estimated) else {
            return .unpriced(.noPricingVersion)
        }
        // Estimated is weaker than exact or reconstructed, never stronger than unknown.
        let confidence = estimated && chosen.confidence != .unknown ? .estimated : chosen.confidence
        return .priced(cost, pricingVersionID: chosen.id, confidence: confidence)
    }

    /// Nil when input or output has tokens but no rate: a price missing a
    /// main component would understate the cost, so none is given.
    static func cost(_ tokens: TokenCounts, at rates: TokenRates, estimated: inout Bool) -> Nanodollars? {
        func rate(_ count: Int64, _ own: Nanodollars?, else fallback: Nanodollars?) -> Nanodollars? {
            if count > 0, own == nil { estimated = true }
            return own ?? fallback
        }
        let fiveMinute = tokens.cacheWrite - tokens.cacheWriteOneHour
        let parts: [(Int64, Nanodollars?)] = [
            (tokens.input, rates.input),
            (tokens.cachedInput, rate(tokens.cachedInput, rates.cachedInput, else: rates.input)),
            (fiveMinute, rate(fiveMinute, rates.cacheWrite, else: rates.input)),
            (tokens.cacheWriteOneHour,
             rate(tokens.cacheWriteOneHour, rates.cacheWriteOneHour, else: rates.cacheWrite ?? rates.input)),
            (tokens.output, rates.output),
        ]
        var total = Nanodollars(raw: 0)
        for (count, rate) in parts where count > 0 {
            guard let rate,
                  let part = try? Nanodollars.cost(tokens: count, ratePerMillionTokens: rate),
                  let sum = try? total.adding(part) else { return nil }
            total = sum
        }
        return total
    }
}

extension Pricer {
    /// What caching saved on one event: its cache reads and writes costed as
    /// plain input, less what they cost at the version's own cache rates.
    /// Writes cost more than input, so an event that only writes saves a
    /// negative amount. Nil when a cache component has no rate of its own:
    /// the input-rate fallback that prices it would show no saving
    /// where the true saving is unknown.
    public static func cacheSavings(_ tokens: TokenCounts, at rates: TokenRates) -> Nanodollars? {
        guard let input = rates.input else { return nil }
        let parts: [(Int64, Nanodollars?)] = [
            (tokens.cachedInput, rates.cachedInput),
            (tokens.cacheWrite - tokens.cacheWriteOneHour, rates.cacheWrite),
            (tokens.cacheWriteOneHour, rates.cacheWriteOneHour),
        ]
        var saved = Nanodollars(raw: 0)
        for (count, rate) in parts where count > 0 {
            guard let rate,
                  let uncached = try? Nanodollars.cost(tokens: count, ratePerMillionTokens: input),
                  let cached = try? Nanodollars.cost(tokens: count, ratePerMillionTokens: rate),
                  let sum = try? saved.adding(Nanodollars(raw: uncached.raw - cached.raw)) else { return nil }
            saved = sum
        }
        return saved
    }
}

/// Cache savings over many events, with the share of cache tokens they were
/// calculated for. Savings are summed per event at each event's own model and
/// rates, never as one discount across providers.
public struct CacheSavings: Equatable, Sendable {
    public private(set) var saved = Nanodollars(raw: 0)
    /// Cache-read and cache-write tokens on events whose price gives cache
    /// rates of its own.
    public private(set) var coveredCacheTokens: Int64 = 0
    public private(set) var cacheTokens: Int64 = 0

    public init() {}

    /// Savings already summed elsewhere, such as in the rollups.
    public init(saved: Nanodollars, coveredCacheTokens: Int64, cacheTokens: Int64) {
        self.saved = saved
        self.coveredCacheTokens = coveredCacheTokens
        self.cacheTokens = cacheTokens
    }

    /// The covered share of cache tokens, for display; nil with none at all.
    public var coverage: Double? {
        cacheTokens == 0 ? nil : Double(coveredCacheTokens) / Double(cacheTokens)
    }

    /// Adds one event priced at `rates`, or nil for an unpriced one.
    public mutating func add(_ tokens: TokenCounts, rates: TokenRates?) throws(MoneyError) {
        let (cache, cacheOverflow) = tokens.cachedInput.addingReportingOverflow(tokens.cacheWrite)
        let (total, totalOverflow) = cacheTokens.addingReportingOverflow(cache)
        guard !cacheOverflow, !totalOverflow else { throw .overflow }
        guard cache > 0 else { return }
        guard let rates, let eventSaving = Pricer.cacheSavings(tokens, at: rates) else {
            cacheTokens = total
            return
        }
        let (covered, coveredOverflow) = coveredCacheTokens.addingReportingOverflow(cache)
        guard !coveredOverflow else { throw .overflow }
        let saving = try saved.adding(eventSaving)
        saved = saving
        coveredCacheTokens = covered
        cacheTokens = total
    }
}
