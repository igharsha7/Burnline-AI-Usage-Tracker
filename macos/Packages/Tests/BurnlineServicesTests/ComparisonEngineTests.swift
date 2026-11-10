//  ComparisonEngineTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import Testing
@testable import BurnlineServices

/// Deterministic generator. Comparison output is randomised by design, so tests
/// inject a seed for the same reason they inject a clock: no assertion should
/// depend on chance.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

@MainActor
struct ComparisonEngineTests {

    // MARK: Fixtures

    /// The corpus is shared across platforms, so it lives outside the package
    /// in `shared/corpus/` and is read from there rather than bundled.
    static let corpusURL = URL(filePath: #filePath)
        .deletingLastPathComponent()   // BurnlineServicesTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // macos
        .deletingLastPathComponent()   // repository root
        .appending(path: "shared/corpus/comparisons.json")

    func makeEngine(seed: UInt64 = 42) throws -> ComparisonEngine {
        ComparisonEngine(corpus: try ComparisonCorpus.load(from: Self.corpusURL),
                         recents: InMemoryRecentStore(),
                         rng: SeededRNG(seed: seed))
    }

    // MARK: Corpus integrity

    @Test func `corpus loads at the supported schema version`() throws {
        let corpus = try ComparisonCorpus.load(from: Self.corpusURL)
        #expect(corpus.schemaVersion == ComparisonCorpus.supportedSchemaVersion)
        #expect(!corpus.units.isEmpty)
        #expect(!corpus.milestones.isEmpty)
    }

    /// The climb and the Landmarks medals stack paper as the corpus does, so
    /// a medal and a comparison never disagree about a height.
    @Test func `the paper stack matches the corpus's conversion`() throws {
        let corpus = try ComparisonCorpus.load(from: Self.corpusURL)
        #expect(corpus.conversions.tokensPerWord == PaperStack.tokensPerWord)
        let engine = try makeEngine()
        #expect(abs(engine.derived.stackHeightMeters(tokens: 1e9) - PaperStack.meters(tokens: 1_000_000_000)) < 1e-9)
        #expect(engine.count(of: "lit.war-and-peace", tokens: 587_287 * 1.3)?.count == 1)
    }

    /// Guards the failure the previous engine had: units that could be selected
    /// and then silently dropped because nothing knew how to render them.
    @Test func `every derived and composite unit has a renderer`() throws {
        #expect(try makeEngine().unrenderableUnitIDs.isEmpty)
    }

    @Test func `every milestone reference resolves to a real unit`() throws {
        let engine = try makeEngine()
        let corpus = try ComparisonCorpus.load(from: Self.corpusURL)
        for milestone in corpus.milestones {
            let rendered = engine.milestone(crossing: milestone.tokens + 1, from: 0)
            #expect(rendered != nil, "milestone at \(milestone.tokens) did not render")
            #expect(rendered?.contains("{") == false, "unsubstituted placeholder")
        }
    }

    // MARK: The nil contract

    @Test(arguments: [0.0, -1.0, -999_999.0, .nan, .infinity, -.infinity])
    func `no comparison for non-positive or non-finite input`(value: Double) throws {
        #expect(try makeEngine().comparison(tokens: value) == nil)
    }

    @Test func `zero cost yields nothing rather than a zero multiplier`() throws {
        #expect(try makeEngine().comparison(cost: Nanodollars(raw: 0)) == nil)
    }

    // MARK: Magnitude coverage

    @Test(arguments: [50_000.0, 1_000_000, 36_000_000, 1_200_000_000,
                      250_000_000_000, 25_000_000_000_000])
    func `plausible token totals produce a clean line`(tokens: Double) throws {
        let comparison = try #require(try makeEngine().comparison(tokens: tokens))
        #expect(!comparison.text.isEmpty)
        #expect(!comparison.text.contains("{"), "unsubstituted placeholder")
        #expect(!comparison.text.contains("countless x"))
        if let ratio = comparison.ratio { #expect(ratio >= 1) }
    }

    @Test(arguments: [1.0, 20.0, 184.20, 12_500.0])
    func `plausible spend produces a clean line`(dollars: Double) throws {
        let engine = try makeEngine()
        if let comparison = engine.comparison(cost: Nanodollars(dollars: dollars)) {
            #expect(!comparison.text.contains("{"))
        }
    }

    // MARK: Composites

    @Test func `composites stay unreachable without their required context`() throws {
        let engine = try makeEngine()
        // No context supplied, so every composite is ineligible by declaration.
        for _ in 0..<300 {
            if let c = engine.comparison(tokens: 36_000_000) {
                #expect(c.kind != .composite, "\(c.unitID) rendered without context")
            }
        }
    }

    @Test func `composites become reachable once context is supplied`() throws {
        let engine = try makeEngine()
        let context = ComparisonContext(
            tokensPerHour: 1_400_000, quotaPercentPerHour: 11.4,
            exhaustionLeadTime: 52 * 60, cachedInputTokens: 1_080_000_000,
            cacheSavings: Nanodollars(dollars: 4_479.47))

        var seen = Set<String>()
        for _ in 0..<600 {
            // Each composite answers for its own metric: cache savings in
            // money only for spend, the rest only for tokens.
            for c in [engine.comparison(tokens: 36_000_000, context: context),
                      engine.comparison(cost: Nanodollars(dollars: 3), context: context)]
            where c?.kind == .composite {
                seen.insert(c!.unitID)
                #expect(c?.text.contains("{") == false)
            }
        }
        #expect(seen == ["burn.dune-rate", "burn.quota-pace",
                         "cache.savings-books", "cache.savings-cost"])
    }

    @Test func `a count of one is said plainly, not as a plural`() throws {
        // About one lorem ipsum passage, where a frame would count "one lorem ipsum passages".
        let engine = try makeEngine()
        for _ in 0..<50 {
            let text = try #require(engine.comparison(tokens: 90, tone: .nerd)?.text)
            #expect(text.hasPrefix("About as many tokens as") || text.hasPrefix("Roughly the length of"), "\(text)")
        }
    }

    // MARK: Sentences

    @Test func `multipliers are said the way a person says them`() {
        #expect(Spoken.times(2.02, discrete: false) == "twice")
        #expect(Spoken.times(1.8, discrete: false) == "nearly twice")
        #expect(Spoken.times(8.5, discrete: false) == "eight and a half times")
        #expect(Spoken.times(8.2, discrete: false) == "a little more than eight times")
        #expect(Spoken.times(33.4, discrete: false) == "33 times")
        #expect(Spoken.count(8.8, discrete: false) == "nearly nine")
        #expect(Spoken.count(8.8, discrete: true) == "eight")
        #expect(Spoken.count(1_234, discrete: false) == "about 1,200")
        #expect(Spoken.count(1_200, discrete: true) == "1,200")
        #expect(Spoken.count(4_160_000, discrete: false) == "about 4.2 million")
    }

    /// Every frame with every unit it can take, in every tone: a whole
    /// sentence with nothing left unfilled, never a decimal count of things,
    /// never an invented plural like "War and Peaces".
    @Test(arguments: ComparisonTone.allCases)
    func `every unit reads as a sentence in every frame`(tone: ComparisonTone) throws {
        let corpus = try ComparisonCorpus.load(from: Self.corpusURL)
        // "7.5 Moby-Dicks" is a decimal count; "4.4 million words" is a size.
        let decimalCount = /\d\.\d+x? (?!million|billion)[a-z]/
        for unit in corpus.units where unit.kind == .unit {
            let metric = try #require(unit.metric)
            let value = try #require(unit.tokenValue ?? unit.costValue.map { Double($0.raw) })
            for ratio in [1.3, 2, 2.6, 7.5, 8.8, 33, 1_240] {
                let engine = ComparisonEngine(corpus: corpus, recents: InMemoryRecentStore(), rng: SeededRNG(seed: 1))
                let text = try #require(metric == .tokens
                    ? engine.comparison(tokens: value * ratio, tone: tone, categories: [unit.category], allowFormulaic: false)?.text
                    : engine.comparison(cost: Nanodollars(raw: Int64(value * ratio)), tone: tone,
                                        categories: [unit.category], allowFormulaic: false)?.text)
                #expect(text.first?.isLowercase == false && (text.hasSuffix(".") || text.hasSuffix("?")), "\(text)")
                #expect(!text.contains("{") && !text.contains("over over") && !text.contains("  "), "\(text)")
                #expect(text.firstMatch(of: decimalCount) == nil, "\(text)")
                #expect(text.count <= 150, "\(text)")
            }
        }
        for unit in corpus.units {
            for line in unit.lines.values.joined() { #expect(!line.contains("{"), "\(unit.id): \(line)") }
        }
    }

    @Test(arguments: ComparisonScope.allCases)
    func `a line for a period says which period it means`(scope: ComparisonScope) throws {
        let corpus = try ComparisonCorpus.load(from: Self.corpusURL)
        let phrase = try #require(corpus.scopes[scope])
        let engine = try makeEngine()
        for _ in 0..<40 {
            for comparison in [engine.comparison(tokens: 40_000_000, scope: scope),
                               engine.comparison(cost: Nanodollars(dollars: 950), scope: scope)] {
                let text = try #require(comparison?.text).lowercased()
                #expect(text.contains(phrase.lead.lowercased()) || text.contains(phrase.tail.lowercased()), "\(text)")
            }
        }
    }

    @Test func `the dry tone adds the unit's own size, from the figure it compared with`() throws {
        let engine = try makeEngine()
        let dune = 187_240 * 1.3
        for _ in 0..<20 {
            let text = try #require(engine.comparison(tokens: dune * 8, tone: .dry, categories: ["literature"],
                                                      allowFormulaic: false)?.text)
            // Grouped as the user's region groups numbers, like every figure in the app.
            if text.contains("Dune") {
                #expect(text.hasSuffix("For scale: Dune, about \(187_000.formatted()) words."), "\(text)")
            }
        }
        let spend = try #require(engine.comparison(cost: Nanodollars(dollars: 3_000), tone: .dry,
                                                   categories: ["everyday"], allowFormulaic: false)?.text)
        #expect(spend.contains("For reference, "), "\(spend)")
    }

    @Test func `the live pace is a book or codebase every so often`() throws {
        let engine = try makeEngine()
        for rate in [400_000.0, 6_000_000, 90_000_000] {
            let text = try #require(engine.pace(tokensPerHour: rate)?.text)
            #expect(text.contains(" every ") && !text.contains("{"), "\(text)")
        }
        #expect(engine.pace(tokensPerHour: 0) == nil)
    }

    @Test func `the same pace said again names different things`() throws {
        let engine = try makeEngine()
        let lines = Set((0..<20).compactMap { _ in engine.pace(tokensPerHour: 6_000_000, tone: .roast)?.text })
        #expect(lines.count > 1, "\(lines)")
    }

    @Test func `a spend comparison talks about money, never tokens`() throws {
        let engine = try makeEngine()
        let context = ComparisonContext(tokensPerHour: 1_400_000, cachedInputTokens: 1_080_000_000,
                                        cacheSavings: Nanodollars(dollars: 8_567.47))
        for dollars in [40.0, 950, 3_255, 12_000] {
            for _ in 0..<60 {
                let text = try #require(engine.comparison(cost: Nanodollars(dollars: dollars), context: context)?.text)
                #expect(!text.contains("tokens of") && !text.contains("cache served"), "\(text)")
                #expect(!text.contains(".00"), "\(text)")
            }
        }
    }

    @Test(arguments: ComparisonTone.allCases)
    func `composite lines read as sentences across their range`(tone: ComparisonTone) throws {
        let engine = try makeEngine()
        for rate in [9_000.0, 10_142, 1_400_000, 90_000_000] {
            for dollars in [40.0, 1_350, 90_000] {
                let context = ComparisonContext(tokensPerHour: rate, cachedInputTokens: 1_080_000_000,
                                                cacheSavings: Nanodollars(dollars: dollars))
                for _ in 0..<40 {
                    guard let c = engine.comparison(tokens: 36_000_000, tone: tone, context: context),
                          c.kind == .composite else { continue }
                    #expect(!c.text.contains("every 1 ") && !c.text.contains("every under"), "\(c.text)")
                    #expect(!c.text.contains("months of a ") && !c.text.contains("months of the "), "\(c.text)")
                    #expect(!c.text.contains(" 1 re-reads"), "\(c.text)")
                }
            }
        }
    }

    // MARK: Determinism and rotation

    @Test func `the same seed produces the same sequence`() throws {
        func run() throws -> [String] {
            let engine = try makeEngine(seed: 7)
            return (0..<10).compactMap { _ in engine.comparison(tokens: 5_000_000)?.unitID }
        }
        #expect(try run() == run())
    }

    @Test func `a unit never repeats back to back`() throws {
        let engine = try makeEngine(seed: 3)
        let ids = (0..<40).compactMap { _ in engine.comparison(tokens: 8_000_000)?.unitID }
        #expect(zip(ids, ids.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test func `rotation history survives a new engine over the same store`() throws {
        let corpus = try ComparisonCorpus.load(from: Self.corpusURL)
        let store = InMemoryRecentStore()
        let first = ComparisonEngine(corpus: corpus, recents: store, rng: SeededRNG(seed: 11))
        _ = first.comparison(tokens: 5_000_000)
        #expect(!store.recentIDs.isEmpty)

        let second = ComparisonEngine(corpus: corpus, recents: store, rng: SeededRNG(seed: 11))
        let next = second.comparison(tokens: 5_000_000)
        #expect(next?.unitID != store.recentIDs.first)
    }

    // MARK: Milestones

    @Test func `only a crossed milestone fires, and only the highest one`() throws {
        let engine = try makeEngine()
        #expect(engine.milestone(crossing: 1_050_000, from: 1_000_000) == nil)
        #expect(engine.milestone(crossing: 500, from: 0) == nil)
        let big = engine.milestone(crossing: 1_100_000_000, from: 0)
        #expect(big == "A billion tokens: nearly three times the length of the entire Linux kernel.")
        #expect(engine.milestone(crossing: 1_000_001, from: 0)
                    == "One million tokens: about the length of the King James Bible.")
    }

    // MARK: Loading failures are distinguishable

    @Test func `a missing corpus reports as unreadable, not as empty`() {
        #expect(throws: ComparisonCorpus.LoadError.self) {
            try ComparisonCorpus.load(from: URL(fileURLWithPath: "/nonexistent/x.json"))
        }
    }

    // MARK: Money

    @Test func `nanodollars round-trip without floating point drift`() {
        #expect(Nanodollars(dollars: 184.20).raw == 184_200_000_000)
        #expect(Nanodollars(dollars: 0.01).raw == 10_000_000)
        #expect(Nanodollars(raw: 4_479_470_000_000).decimalDollars == Decimal(string: "4479.47")!)
    }
}
