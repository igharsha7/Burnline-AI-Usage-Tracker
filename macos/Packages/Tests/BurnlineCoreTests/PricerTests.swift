//
//  PricerTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Testing

struct PricerTests {
    static func dollars(_ text: String) -> Nanodollars { Nanodollars(decimalString: text)! }

    /// Opus-like rates: $4 in, $0.4 cached, $5 / $8 cache writes, $20 out.
    static let rates = TokenRates(input: dollars("4"), cachedInput: dollars("0.4"), cacheWrite: dollars("5"),
                                  cacheWriteOneHour: dollars("8"), output: dollars("20"))

    static func version(_ id: Int64, from: Int64 = 0, until: Int64? = nil, tier: ServiceTier = .standard,
                        above: Int64 = 0, rates: TokenRates = rates, source: String = "litellm",
                        confidence: PricingConfidence = .exact) -> PricingVersion {
        PricingVersion(id: id, modelID: 1, validFrom: Timestamp(epochSeconds: from),
                       validUntil: until.map(Timestamp.init(epochSeconds:)), serviceTier: tier,
                       abovePromptTokens: above, rates: rates, source: source, confidence: confidence)
    }

    static func price(_ tokens: TokenCounts, tier: ServiceTier? = .standard, at seconds: Int64 = 100,
                      _ versions: [PricingVersion]) -> CostAttribution {
        Pricer.price(tokens, tier: tier, at: Timestamp(epochSeconds: seconds), versions: versions)
    }

    @Test func `EC-R6 cache savings rejects overflowing token sums without trapping`() throws {
        var savings = CacheSavings()
        let tokens = try TokenCounts(cachedInput: Int64.max, cacheWrite: 1)
        #expect(throws: MoneyError.overflow) { try savings.add(tokens, rates: nil) }
        #expect(savings == CacheSavings())
    }

    @Test func `EC-R6 EC-R8 a prompt sum beyond Int64 still selects the long band`() throws {
        let tokens = try TokenCounts(input: Int64.max, cacheWrite: 1)
        let free = TokenRates(input: .zero, cacheWrite: .zero, output: .zero)
        let versions = [Self.version(1, rates: free), Self.version(2, above: 272_000, rates: free)]
        #expect(Self.price(tokens, versions) == .priced(.zero, pricingVersionID: 2, confidence: .exact))
    }

    @Test func `each component is costed at its own rate, and reasoning is not added`() throws {
        let tokens = try TokenCounts(input: 1_000_000, cachedInput: 1_000_000, cacheWrite: 1_000_000,
                                     cacheWriteOneHour: 250_000, output: 1_000_000, reasoning: 400_000)
        // 4 + 0.4 + 0.75 × 5 + 0.25 × 8 + 20
        #expect(Self.price(tokens, [Self.version(7)])
                == .priced(Self.dollars("30.15"), pricingVersionID: 7, confidence: .exact))
    }

    @Test func `EC-R1 an event exactly on a price change takes the newer price`() throws {
        let tokens = try TokenCounts(output: 1_000_000)
        let older = Self.version(1, from: 0, until: 500)
        let newer = Self.version(2, from: 500, rates: TokenRates(input: Self.dollars("1"), output: Self.dollars("2")))
        #expect(Self.price(tokens, at: 499, [older, newer]).amount == Self.dollars("20"))
        #expect(Self.price(tokens, at: 500, [older, newer]).amount == Self.dollars("2"))
    }

    @Test func `EC-R2 a gap between versions is unpriced, never today's price`() throws {
        let versions = [Self.version(1, from: 0, until: 100), Self.version(2, from: 200)]
        #expect(Self.price(try TokenCounts(input: 5), at: 150, versions) == .unpriced(.noPricingVersion))
        #expect(Self.price(try TokenCounts(input: 5), at: 150, []) == .unpriced(.unknownModel))
    }

    @Test func `a newer open-ended version supersedes an older one without editing it`() throws {
        let cheaper = TokenRates(input: Self.dollars("2"), output: Self.dollars("10"))
        let versions = [Self.version(1, from: 0), Self.version(2, from: 1_000, rates: cheaper)]
        #expect(Self.price(try TokenCounts(output: 1_000_000), at: 999, versions).amount == Self.dollars("20"))
        #expect(Self.price(try TokenCounts(output: 1_000_000), at: 1_000, versions).amount == Self.dollars("10"))
    }

    @Test func `EC-R3 a missing cache rate falls back to input and says it is estimated`() throws {
        let noCache = TokenRates(input: Self.dollars("2"), output: Self.dollars("10"))
        let cached = Self.price(try TokenCounts(cachedInput: 1_000_000), [Self.version(1, rates: noCache)])
        #expect(cached == .priced(Self.dollars("2"), pricingVersionID: 1, confidence: .estimated))
        // Without cached tokens, the missing rate does not matter.
        let plain = Self.price(try TokenCounts(input: 1_000_000), [Self.version(1, rates: noCache)])
        #expect(plain == .priced(Self.dollars("2"), pricingVersionID: 1, confidence: .exact))
    }

    @Test func `a missing output rate leaves the event unpriced rather than understated`() throws {
        let inputOnly = TokenRates(input: Self.dollars("2"))
        #expect(Self.price(try TokenCounts(output: 10), [Self.version(1, rates: inputOnly)])
                == .unpriced(.noPricingVersion))
    }

    @Test func `EC-R7 a tier is priced at its own rates, and a tier without rates at standard, estimated`() throws {
        let priority = TokenRates(input: Self.dollars("8"), output: Self.dollars("40"))
        let versions = [Self.version(1), Self.version(2, tier: .priority, rates: priority)]
        let tokens = try TokenCounts(output: 1_000_000)
        #expect(Self.price(tokens, tier: .priority, versions)
                == .priced(Self.dollars("40"), pricingVersionID: 2, confidence: .exact))
        #expect(Self.price(tokens, tier: .flex, versions)
                == .priced(Self.dollars("20"), pricingVersionID: 1, confidence: .estimated))
        #expect(Self.price(tokens, tier: nil, versions)
                == .priced(Self.dollars("20"), pricingVersionID: 1, confidence: .estimated))
    }

    @Test func `EC-R8 a prompt longer than a band's threshold is priced at the band, every token of it`() throws {
        let long = TokenRates(input: Self.dollars("8"), cachedInput: Self.dollars("0.8"), output: Self.dollars("30"))
        let versions = [Self.version(1), Self.version(2, above: 272_000, rates: long)]
        let atLimit = try TokenCounts(input: 72_000, cachedInput: 200_000, output: 1_000)
        let over = try TokenCounts(input: 72_001, cachedInput: 200_000, output: 1_000)
        // 72,000 × $4 + 200,000 × $0.4 + 1,000 × $20 a million.
        #expect(Self.price(atLimit, versions) == .priced(Self.dollars("0.388"), pricingVersionID: 1, confidence: .exact))
        // One token more, and every token moves to the band: 72,001 × $8 + 200,000 × $0.8 + 1,000 × $30.
        #expect(Self.price(over, versions) == .priced(Self.dollars("0.766008"), pricingVersionID: 2, confidence: .exact))
    }

    @Test func `EC-R5 a user's price outranks the published one for the time it covers`() throws {
        let mine = TokenRates(input: Self.dollars("1"), output: Self.dollars("1"))
        let versions = [Self.version(1, from: 0),
                        Self.version(2, from: 0, rates: mine, source: PricingVersion.userSource)]
        #expect(Self.price(try TokenCounts(output: 1_000_000), versions).amount == Self.dollars("1"))
    }

    @Test func `recorded tiers map to what they bill as`() {
        #expect(ServiceTier(recorded: nil, provider: .codex) == .standard)
        #expect(ServiceTier(recorded: "default", provider: .codex) == .standard)
        #expect(ServiceTier(recorded: "fast", provider: .codex) == .priority)
        #expect(ServiceTier(recorded: "fast", provider: .claudeCode) == .fast)
        #expect(ServiceTier(recorded: "Priority", provider: .codex) == .priority)
        #expect(ServiceTier(recorded: "something-new", provider: .codex) == nil)
    }

    @Test func `cache savings are what the cache tokens would cost as plain input, less what they cost`() throws {
        let tokens = try TokenCounts(input: 5, cachedInput: 1_000_000, cacheWrite: 1_000_000,
                                     cacheWriteOneHour: 250_000, output: 9)
        // Reads save 4 − 0.4; writes cost 0.75 × (5 − 4) + 0.25 × (8 − 4) more than input.
        #expect(Pricer.cacheSavings(tokens, at: Self.rates) == Self.dollars("1.85"))
        #expect(Pricer.cacheSavings(try TokenCounts(cacheWrite: 1_000_000), at: Self.rates) == Self.dollars("-1"))
    }

    @Test func `EC-R3 a model without cache rates is left out of savings, and coverage says so`() throws {
        let noCacheRates = TokenRates(input: Self.dollars("4"), output: Self.dollars("20"))
        let reads = try TokenCounts(cachedInput: 1_000_000)
        #expect(Pricer.cacheSavings(reads, at: noCacheRates) == nil)

        var savings = CacheSavings()
        try savings.add(reads, rates: Self.rates)
        try savings.add(try TokenCounts(cachedInput: 3_000_000), rates: noCacheRates)
        try savings.add(try TokenCounts(input: 1, output: 1), rates: Self.rates)
        try savings.add(reads, rates: nil)
        #expect(savings.saved == Self.dollars("3.6"))
        #expect(savings.cacheTokens == 5_000_000 && savings.coverage == 0.2)
        #expect(CacheSavings().coverage == nil)
    }
}
