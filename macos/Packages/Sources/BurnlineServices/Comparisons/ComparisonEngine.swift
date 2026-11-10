//  ComparisonEngine.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU Affero General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or (at your
//  option) any later version. See the LICENSE and NOTICE files.

import BurnlineCore
import Foundation

// MARK: - Money

extension Nanodollars {
    /// For the corpus's hand-authored constants only, read once at load time.
    /// Never for a figure that came from a usage event: the cost path stays in
    /// integers, and the core type deliberately has no `Double` initialiser.
    init(dollars: Double) {
        self.init(raw: Int64((dollars * Double(Self.perDollar)).rounded()))
    }

    /// Unitless ratio for display. Dividing money by money yields a count, not
    /// money, so leaving the integer domain here is correct.
    func ratio(to other: Nanodollars) -> Double? {
        guard other.raw > 0 else { return nil }
        return Double(raw) / Double(other.raw)
    }
}

// MARK: - Corpus vocabulary

public enum ComparisonTone: String, Codable, Sendable, CaseIterable {
    case dry, nerd, roast
}

public enum ComparisonMetric: String, Codable, Sendable {
    case tokens, cost
}

/// The period a figure covers, so a line can say "Today alone, …". Nil
/// where the surroundings already say it, as a section headed "All time".
public enum ComparisonScope: String, Codable, Sendable, CaseIterable {
    case today, week, month, quarter, yearToDate, year, allTime
}

/// Extra signals a composite unit needs before it can say anything true.
/// Declared per unit in the corpus as `requires`, and checked before a unit is
/// ever considered — so a unit is never selected and then silently dropped.
public enum ContextKey: String, Codable, Sendable {
    case tokensPerHour, quotaPercentPerHour, exhaustionLeadTime
    case cachedInputTokens, cacheSavings
}

public struct ComparisonContext: Sendable {
    public var tokensPerHour: Double?
    public var quotaPercentPerHour: Double?
    public var exhaustionLeadTime: TimeInterval?
    public var cachedInputTokens: Double?
    public var cacheSavings: Nanodollars?

    public init(tokensPerHour: Double? = nil,
                quotaPercentPerHour: Double? = nil,
                exhaustionLeadTime: TimeInterval? = nil,
                cachedInputTokens: Double? = nil,
                cacheSavings: Nanodollars? = nil) {
        self.tokensPerHour = tokensPerHour
        self.quotaPercentPerHour = quotaPercentPerHour
        self.exhaustionLeadTime = exhaustionLeadTime
        self.cachedInputTokens = cachedInputTokens
        self.cacheSavings = cacheSavings
    }

    func value(for key: ContextKey) -> Double? {
        switch key {
        case .tokensPerHour:        tokensPerHour
        case .quotaPercentPerHour:  quotaPercentPerHour
        case .exhaustionLeadTime:   exhaustionLeadTime
        case .cachedInputTokens:    cachedInputTokens
        case .cacheSavings:         cacheSavings.map { Double($0.raw) }
        }
    }

    func satisfies(_ keys: [ContextKey]) -> Bool {
        keys.allSatisfy { key in (value(for: key)).map { $0.isFinite && $0 > 0 } ?? false }
    }
}

public struct ComparisonLandmark: Codable, Sendable {
    public let name: String
    public let meters: Double
}

// MARK: - Unit

public struct ComparisonUnit: Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case unit, derived, composite }
    public enum Confidence: String, Codable, Sendable { case verified, approx, volatile }

    /// Resolved at load from `words` / `codeLines` / `tokens` / `dollars`.
    /// The corpus stores the underlying quantity, never a precomputed token
    /// count, so the conversion ratio lives in exactly one place.
    public enum Magnitude: Sendable {
        case tokens(Double)
        case cost(Nanodollars)
        case formulaic
    }

    public let id: String
    public let kind: Kind
    public let metric: ComparisonMetric?
    public let referenceMetric: ComparisonMetric?
    public let requires: [ContextKey]
    public let category: String
    /// The unit as a noun phrase with its article: "the King James Bible".
    public let label: String
    /// Its plural for counting: "copies of Dune", never "Dunes". Frames that
    /// count are used only for units that have one.
    public let many: String?
    public let basis: String
    public let confidence: Confidence
    public let discrete: Bool
    public let landmarks: [ComparisonLandmark]
    public let magnitude: Magnitude
    /// The quantity as the corpus states it, for the dry tone's aside:
    /// `words`, `codeLines`, `tokens` or `dollars`, and how many.
    public let quantity: (kind: String, amount: Double)?
    /// A plain unit's punchlines per tone, said after the frame.
    public let lines: [ComparisonTone: [String]]
    /// A derived or composite unit's whole sentences per tone.
    public let templates: [ComparisonTone: [String]]

    public var tokenValue: Double? {
        if case .tokens(let v) = magnitude { return v }
        return nil
    }
    public var costValue: Nanodollars? {
        if case .cost(let v) = magnitude { return v }
        return nil
    }

    /// Falls back to `.dry` so a missing tone never silently drops a card.
    func templates(for tone: ComparisonTone) -> [String] {
        templates[tone] ?? templates[.dry] ?? []
    }
}

// MARK: - Corpus

public struct ComparisonCorpus: Sendable {
    public static let supportedSchemaVersion = 4

    public struct Conversions: Sendable {
        public let tokensPerWord: Double
        public let tokensPerCodeLine: Double
    }
    public struct Milestone: Sendable {
        public let tokens: Double
        public let text: String
    }

    public let schemaVersion: Int
    public let conversions: Conversions
    /// Opening sentences per metric, saying what a figure is in terms of a unit.
    public let frames: [ComparisonMetric: [String]]
    /// For a figure between one and two of a unit.
    public let singles: [ComparisonMetric: [String]]
    /// How each period is said, opening a sentence and inside one.
    public let scopes: [ComparisonScope: (lead: String, tail: String)]
    /// The dry tone's aside per kind of quantity, with {label} and {amount}.
    public let facts: [String: String]
    public let units: [ComparisonUnit]
    public let milestones: [Milestone]

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(URL, underlying: any Error)
        case malformed(underlying: any Error)
        case unsupportedSchema(found: Int, supported: Int)
        case empty

        public var description: String {
            switch self {
            case .unreadable(let url, let e):
                "Comparison corpus could not be read at \(url.lastPathComponent): \(e)"
            case .malformed(let e):
                "Comparison corpus is not valid JSON for this schema: \(e)"
            case .unsupportedSchema(let found, let supported):
                "Comparison corpus is schema v\(found); this build understands v\(supported)."
            case .empty:
                "Comparison corpus contains no units."
            }
        }
    }

    /// Throws rather than returning nil, so provider health can distinguish a
    /// missing file from a corrupt one from a version mismatch.
    public static func load(from url: URL) throws -> ComparisonCorpus {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw LoadError.unreadable(url, underlying: error) }

        let dto: CorpusDTO
        do { dto = try JSONDecoder().decode(CorpusDTO.self, from: data) }
        catch { throw LoadError.malformed(underlying: error) }

        guard dto.schemaVersion == supportedSchemaVersion else {
            throw LoadError.unsupportedSchema(found: dto.schemaVersion,
                                              supported: supportedSchemaVersion)
        }

        let conversions = Conversions(tokensPerWord: dto.conversions.tokensPerWord,
                                      tokensPerCodeLine: dto.conversions.tokensPerCodeLine)
        let units = dto.units.compactMap { $0.resolved(using: conversions) }
        guard !units.isEmpty else { throw LoadError.empty }

        let byMetric = { (lists: [String: [String]]) in
            Dictionary(uniqueKeysWithValues: lists.compactMap { key, list in
                ComparisonMetric(rawValue: key).map { ($0, list) }
            })
        }
        return ComparisonCorpus(
            schemaVersion: dto.schemaVersion,
            conversions: conversions,
            frames: byMetric(dto.frames),
            singles: byMetric(dto.singles),
            scopes: Dictionary(uniqueKeysWithValues: (dto.scopes ?? [:]).compactMap { key, phrase in
                ComparisonScope(rawValue: key).map { ($0, (phrase.lead, phrase.tail)) }
            }),
            facts: dto.facts ?? [:],
            units: units,
            milestones: dto.milestones?.map { Milestone(tokens: $0.tokens, text: $0.text) } ?? []
        )
    }

    public init(schemaVersion: Int, conversions: Conversions,
                frames: [ComparisonMetric: [String]], singles: [ComparisonMetric: [String]],
                scopes: [ComparisonScope: (lead: String, tail: String)] = [:], facts: [String: String] = [:],
                units: [ComparisonUnit], milestones: [Milestone]) {
        self.schemaVersion = schemaVersion
        self.conversions = conversions
        self.frames = frames
        self.singles = singles
        self.scopes = scopes
        self.facts = facts
        self.units = units
        self.milestones = milestones
    }
}

// MARK: - JSON transport

private struct CorpusDTO: Decodable {
    struct ConversionsDTO: Decodable {
        let tokensPerWord: Double
        let tokensPerCodeLine: Double
    }
    struct MilestoneDTO: Decodable {
        let tokens: Double
        let text: String
    }
    let schemaVersion: Int
    let conversions: ConversionsDTO
    struct ScopeDTO: Decodable {
        let lead: String
        let tail: String
    }
    let frames: [String: [String]]
    let singles: [String: [String]]
    let scopes: [String: ScopeDTO]?
    let facts: [String: String]?
    let units: [UnitDTO]
    let milestones: [MilestoneDTO]?
}

private struct UnitDTO: Decodable {
    let id: String
    let kind: ComparisonUnit.Kind
    let metric: ComparisonMetric?
    let referenceMetric: ComparisonMetric?
    let requires: [ContextKey]?
    let category: String
    let label: String
    let many: String?
    let basis: String
    let confidence: ComparisonUnit.Confidence
    let discrete: Bool?
    let landmarks: [ComparisonLandmark]?
    let lines: [String: [String]]?
    let templates: [String: [String]]?

    let words: Double?
    let codeLines: Double?
    let tokens: Double?
    let dollars: Double?

    func resolved(using c: ComparisonCorpus.Conversions) -> ComparisonUnit? {
        let magnitude: ComparisonUnit.Magnitude
        switch kind {
        case .derived, .composite:
            magnitude = .formulaic
        case .unit:
            if let words {                magnitude = .tokens(words * c.tokensPerWord) }
            else if let codeLines {       magnitude = .tokens(codeLines * c.tokensPerCodeLine) }
            else if let tokens {          magnitude = .tokens(tokens) }
            else if let dollars {         magnitude = .cost(Nanodollars(dollars: dollars)) }
            else { return nil }           // a valueless plain unit is corrupt; drop it
        }

        let byTone = { (lists: [String: [String]]?) in
            Dictionary(uniqueKeysWithValues: (lists ?? [:]).compactMap { key, list in
                ComparisonTone(rawValue: key).flatMap { list.isEmpty ? nil : ($0, list) }
            })
        }
        let templates = byTone(self.templates)
        // A formula with nothing to say it with is corrupt; a plain unit
        // speaks through the frames, so it needs no lines of its own.
        if kind != .unit, templates.isEmpty { return nil }

        return ComparisonUnit(
            id: id, kind: kind, metric: metric, referenceMetric: referenceMetric,
            requires: requires ?? [], category: category, label: label,
            many: many, basis: basis,
            confidence: confidence, discrete: discrete ?? false,
            landmarks: landmarks ?? [], magnitude: magnitude,
            quantity: words.map { ("words", $0) } ?? codeLines.map { ("codeLines", $0) }
                ?? tokens.map { ("tokens", $0) } ?? dollars.map { ("dollars", $0) },
            lines: byTone(lines), templates: templates
        )
    }
}

// MARK: - Result

public struct Comparison: Sendable, Identifiable {
    public var id: String { unitID }
    public let unitID: String
    public let text: String
    /// nil where the comparison expresses a quantity rather than a multiplier.
    public let ratio: Double?
    /// Dashboard card footnote. Omit in notifications.
    public let basis: String
    public let confidence: ComparisonUnit.Confidence
    public let kind: ComparisonUnit.Kind
}

// MARK: - Recency

/// Rotation history outlives a launch, so a user who quits often does not see
/// the same line every morning.
@MainActor public protocol RecentComparisonStore: AnyObject {
    var recentIDs: [String] { get set }
}

@MainActor public final class InMemoryRecentStore: RecentComparisonStore {
    public var recentIDs: [String] = []
    public init() {}
}

@MainActor public final class UserDefaultsRecentStore: RecentComparisonStore {
    private let key = "burnline.comparisons.recent"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var recentIDs: [String] {
        get { defaults.stringArray(forKey: key) ?? [] }
        set { defaults.set(newValue, forKey: key) }
    }
}

// MARK: - Engine

/// Main-actor isolated on purpose. This is string formatting with no contention,
/// so an `actor` would only force `await` on every trivial call. Being isolated
/// makes the mutable rotation history safe without locks.
@MainActor
public final class ComparisonEngine {

    /// Below this a multiplier reads as noise ("1.2x Dune").
    private let minRatio: Double = 2
    /// Above this it stops meaning anything ("4,812x Dune").
    private let maxRatio: Double = 60
    /// The multiplier that reads best; scoring falls off logarithmically either side.
    private let idealRatio: Double = 9
    /// Derived units scale without bound, so they carry the extremes — but stay
    /// in rotation even when fixed units are plentiful.
    private let derivedProbability: [Int: Double] = [0: 1.0, 1: 0.75, 2: 0.6, 3: 0.45, 4: 0.35]
    private let derivedProbabilityFloor: Double = 0.25
    /// Burn and cache lines describe something beside the figure asked about,
    /// so they are an occasional extra, never the usual answer.
    private let compositeProbability: Double = 0.2
    /// Past this a frame and a punchline crowd two lines; the frame stands alone.
    private let maxLength = 130
    /// Below this the formulas produce "0 days" and "0.1 pages".
    private let derivedFloorTokens: Double = 50_000
    /// An interval that reads well for a burn-rate line.
    private let burnIntervalBounds: ClosedRange<TimeInterval> = 600...(30 * 86_400)
    /// References a pace is said against, nearest a day first.
    private let burnReferenceChoices = 5
    private let recentWindow = 8

    /// Units this build knows how to render. Eligibility is checked *before*
    /// selection, so a corpus entry with no renderer is never chosen and then
    /// silently dropped — the failure mode the previous version had.
    private static let renderableDerived: Set<String> = [
        "derived.read-aloud", "derived.typing", "derived.novelist",
        "derived.pages", "derived.paper-stack",
    ]
    private static let renderableComposite: Set<String> = [
        "burn.dune-rate", "burn.quota-pace",
        "cache.savings-books", "cache.savings-cost",
    ]

    private let corpus: ComparisonCorpus
    private let maths: DerivedComparisons
    private let recents: any RecentComparisonStore
    private var rng: any RandomNumberGenerator
    private var lastFrame: String?

    public init(corpus: ComparisonCorpus,
                recents: any RecentComparisonStore = InMemoryRecentStore(),
                rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.corpus = corpus
        self.maths = DerivedComparisons(tokensPerWord: corpus.conversions.tokensPerWord)
        self.recents = recents
        self.rng = rng
    }

    /// Unrenderable corpus entries, for a diagnostics pane. Empty is the healthy state.
    public var unrenderableUnitIDs: [String] {
        corpus.units.filter { unit in
            switch unit.kind {
            case .unit:      false
            case .derived:   !Self.renderableDerived.contains(unit.id)
            case .composite: !Self.renderableComposite.contains(unit.id)
            }
        }.map(\.id)
    }

    // MARK: Entry points

    /// - Returns: nil when no honest comparison exists. Callers must hide the
    ///   card entirely rather than render a placeholder.
    /// - Parameter scope: the period the figure covers, said in the line.
    public func comparison(tokens: Double,
                           tone: ComparisonTone? = nil,
                           scope: ComparisonScope? = nil,
                           categories: Set<String>? = nil,
                           context: ComparisonContext = .init(),
                           allowFormulaic: Bool = true) -> Comparison? {
        // A fresh install sits at zero and must show nothing at all, not "0x Dune".
        guard tokens.isFinite, tokens > 0 else { return nil }
        return pick(value: tokens, metric: .tokens, tone: tone, scope: scope,
                    categories: categories, context: context, allowFormulaic: allowFormulaic)
    }

    public func comparison(cost: Nanodollars,
                           tone: ComparisonTone? = nil,
                           scope: ComparisonScope? = nil,
                           categories: Set<String>? = nil,
                           context: ComparisonContext = .init(),
                           allowFormulaic: Bool = true) -> Comparison? {
        guard cost.raw > 0 else { return nil }
        return pick(value: Double(cost.raw), metric: .cost, tone: tone, scope: scope,
                    categories: categories, context: context, allowFormulaic: allowFormulaic)
    }

    /// The pace of live usage as a book or codebase every so often: "Current
    /// pace: Dune's worth of tokens every 3 hours". Nil when no unit gives a
    /// readable interval.
    public func pace(tokensPerHour: Double, tone: ComparisonTone? = nil) -> Comparison? {
        guard tokensPerHour.isFinite, tokensPerHour > 0,
              let unit = corpus.units.first(where: { $0.id == "burn.dune-rate" }) else { return nil }
        let tone = tone ?? ComparisonTone.allCases.randomElement(using: &rng)!
        return render(formulaic: unit, value: tokensPerHour, metric: .tokens, tone: tone, scope: nil,
                      context: ComparisonContext(tokensPerHour: tokensPerHour))
    }

    /// Highest milestone strictly crossed by this update, or nil.
    public func milestone(crossing newTotal: Double, from oldTotal: Double) -> String? {
        corpus.milestone(crossing: newTotal, from: oldTotal)
    }

    /// How many of a unit `tokens` comes to, with the unit's label and its
    /// plural for counting; nil for a unit not in the corpus or not measured
    /// in tokens.
    public func count(of unitID: String, tokens: Double) -> (count: Double, label: String, many: String?)? {
        guard let unit = corpus.units.first(where: { $0.id == unitID }), let value = unit.tokenValue, value > 0 else {
            return nil
        }
        return (tokens / value, unit.label, unit.many)
    }

    /// Every unit a token count can be said in as a number of things, such
    /// as copies of Dune, with its plural and its lines in each tone; in
    /// corpus order.
    public var countableTokenUnits: [ComparisonUnit] {
        corpus.units.filter { $0.kind == .unit && $0.many != nil && ($0.tokenValue ?? 0) > 0 }
    }

    /// The corpus's conversions from tokens to words, pages and time.
    public var derived: DerivedComparisons { maths }

    // MARK: Selection

    private func pick(value: Double,
                      metric: ComparisonMetric,
                      tone: ComparisonTone?,
                      scope: ComparisonScope?,
                      categories: Set<String>?,
                      context: ComparisonContext,
                      allowFormulaic: Bool) -> Comparison? {

        let chosenTone = tone ?? ComparisonTone.allCases.randomElement(using: &rng)!
        let inBand = fixedCandidates(value: value, metric: metric, categories: categories)

        if allowFormulaic {
            let formulaic = formulaicCandidates(metric: metric, context: context,
                                                categories: categories)
            let composites = formulaic.filter { $0.kind == .composite }
            // With nothing plain to say, a composite is the only line there is.
            if !composites.isEmpty,
               inBand.isEmpty || Double.random(in: 0...1, using: &rng) < compositeProbability,
               let rendered = render(formulaic: choose(from: composites), value: value, metric: metric,
                                     tone: chosenTone, scope: scope, context: context) {
                return rendered
            }
            let derived = formulaic.filter { $0.kind == .derived }
            if !derived.isEmpty {
                let p = derivedProbability[inBand.count] ?? derivedProbabilityFloor
                if Double.random(in: 0...1, using: &rng) < p,
                   let rendered = render(formulaic: choose(from: derived),
                                         value: value, metric: metric,
                                         tone: chosenTone, scope: scope, context: context) {
                    return rendered
                }
            }
        }

        var pool = inBand.isEmpty
            ? nearestFallback(value: value, metric: metric, categories: categories)
            : inBand

        // At the top of the range the pool can be three units wide, where the
        // soft recency penalty is not enough on its own.
        if pool.count > 1, let last = recents.recentIDs.last {
            let filtered = pool.filter { $0.id != last }
            if !filtered.isEmpty { pool = filtered }
        }

        guard let best = pool.max(by: { score(value: value, unit: $0) < score(value: value, unit: $1) }),
              let unitValue = magnitudeValue(of: best, metric: metric), unitValue > 0
        else { return nil }

        var ratio = value / unitValue
        if best.discrete { ratio = ratio.rounded(.down) }
        guard ratio.isFinite, ratio >= 1,
              let text = sentence(for: best, ratio: ratio, metric: metric, tone: chosenTone, scope: scope)
        else { return nil }

        note(shown: best.id)
        return Comparison(unitID: best.id, text: text, ratio: ratio,
                          basis: best.basis, confidence: best.confidence, kind: .unit)
    }

    /// A frame saying what the figure is in terms of the unit, then an
    /// aside: one of the unit's punchlines, or in the dry tone the unit's own
    /// size. Under two of a unit a multiplier reads as noise, so the figure
    /// is said plainly instead. With a period, only frames that say it.
    private func sentence(for unit: ComparisonUnit, ratio: Double, metric: ComparisonMetric,
                          tone: ComparisonTone, scope: ComparisonScope?) -> String? {
        let counting = ["{count}", "{many}"]
        let frames = (ratio < minRatio ? corpus.singles[metric] ?? [] : corpus.frames[metric] ?? [])
            .filter { frame in unit.many != nil || !counting.contains(where: frame.contains) }
            .filter { frame in scope == nil || Self.saysPeriod(frame) }
        guard let frame = chooseFrame(from: frames) else { return nil }

        var text = fillPeriod(frame, scope)
            .replacingOccurrences(of: "{times}", with: Spoken.times(ratio, discrete: unit.discrete))
            .replacingOccurrences(of: "{count}", with: Spoken.count(ratio, discrete: unit.discrete))
            .replacingOccurrences(of: "{many}", with: unit.many ?? "")
            .replacingOccurrences(of: "{label}", with: unit.label)
        let aside = tone == .dry ? fact(about: unit) : unit.lines[tone]?.randomElement(using: &rng)
        if let aside, text.count + 1 + aside.count <= maxLength {
            text += " " + aside
        }
        text = Spoken.capitalisingFirst(text)
        return text.contains("{") ? nil : text
    }

    private static func saysPeriod(_ text: String) -> Bool {
        text.contains("{lead}") || text.contains("{tail}")
    }

    /// The period in its place, or nothing where none was given.
    private func fillPeriod(_ text: String, _ scope: ComparisonScope?) -> String {
        let phrase = scope.flatMap { corpus.scopes[$0] }
        return text
            .replacingOccurrences(of: "{lead}", with: phrase?.lead ?? "")
            .replacingOccurrences(of: "{tail}", with: phrase?.tail ?? "")
    }

    /// The unit's own size, from the quantity the comparison was made with:
    /// "For scale: Dune, about 187,000 words."
    private func fact(about unit: ComparisonUnit) -> String? {
        guard let quantity = unit.quantity, let template = corpus.facts[quantity.kind] else { return nil }
        let amount = quantity.kind == "dollars"
            ? formatMoney(Nanodollars(dollars: quantity.amount))
            : Spoken.figure(quantity.amount)
        return Spoken.capitalisingFirst(template
            .replacingOccurrences(of: "{label}", with: unit.label)
            .replacingOccurrences(of: "{amount}", with: amount))
    }

    /// A frame other than the last one used, so consecutive lines open differently.
    private func chooseFrame(from frames: [String]) -> String? {
        let fresh = frames.filter { $0 != lastFrame }
        let frame = (fresh.isEmpty ? frames : fresh).randomElement(using: &rng)
        if let frame { lastFrame = frame }
        return frame
    }

    private func magnitudeValue(of unit: ComparisonUnit, metric: ComparisonMetric) -> Double? {
        switch metric {
        case .tokens: unit.tokenValue
        case .cost:   unit.costValue.map { Double($0.raw) }
        }
    }

    private func fixedCandidates(value: Double,
                                 metric: ComparisonMetric,
                                 categories: Set<String>?) -> [ComparisonUnit] {
        corpus.units.filter { unit in
            guard unit.kind == .unit, unit.metric == metric,
                  let unitValue = magnitudeValue(of: unit, metric: metric), unitValue > 0
            else { return false }
            if let categories, !categories.contains(unit.category) { return false }
            let ratio = value / unitValue
            guard ratio.isFinite else { return false }
            if unit.discrete { return ratio.rounded(.down) >= minRatio && ratio <= maxRatio }
            return ratio >= minRatio && ratio <= maxRatio
        }
    }

    /// Derived and composite units eligible right now. A composite is eligible
    /// only when the context supplies everything it declares in `requires`.
    private func formulaicCandidates(metric: ComparisonMetric,
                                     context: ComparisonContext,
                                     categories: Set<String>?) -> [ComparisonUnit] {
        corpus.units.filter { unit in
            if let categories, !categories.contains(unit.category) { return false }
            switch unit.kind {
            case .unit:
                return false
            case .derived:
                return Self.renderableDerived.contains(unit.id) && unit.metric == metric
            case .composite:
                return Self.renderableComposite.contains(unit.id) && unit.metric == metric
                    && context.satisfies(unit.requires)
            }
        }
    }

    private func nearestFallback(value: Double,
                                 metric: ComparisonMetric,
                                 categories: Set<String>?) -> [ComparisonUnit] {
        let all = corpus.units.filter { unit in
            guard unit.kind == .unit, unit.metric == metric,
                  let v = magnitudeValue(of: unit, metric: metric), v > 0 else { return false }
            if let categories, !categories.contains(unit.category) { return false }
            return true
        }
        let scored = all.compactMap { unit -> (ComparisonUnit, Double)? in
            guard let v = magnitudeValue(of: unit, metric: metric), v > 0 else { return nil }
            return (unit, abs(log(value / v) - log(idealRatio)))
        }
        guard let nearest = scored.min(by: { $0.1 < $1.1 })?.0,
              let v = magnitudeValue(of: nearest, metric: metric), v > 0 else { return [] }
        let ratio = value / v
        // Accept only if it is not absurd; otherwise let a formulaic unit take over.
        return (ratio >= 1 && ratio <= 5_000) ? [nearest] : []
    }

    private func score(value: Double, unit: ComparisonUnit) -> Double {
        guard let unitValue = magnitudeValue(of: unit, metric: unit.metric ?? .tokens),
              unitValue > 0 else { return -.infinity }
        let ratio = value / unitValue
        guard ratio.isFinite, ratio > 0 else { return -.infinity }

        // Log-space distance from the ideal, so 3x and 27x score symmetrically around 9x.
        var s = -abs(log(ratio) - log(idealRatio))
        s -= recencyPenalty(for: unit.id)

        // "12x" reads better than "11.7x".
        let rounded = ratio.rounded()
        if rounded > 0, abs(ratio - rounded) / ratio < 0.03 { s += 0.15 }
        if unit.confidence == .verified { s += 0.1 }

        return s + Double.random(in: 0...0.35, using: &rng)
    }

    private func recencyPenalty(for id: String) -> Double {
        let recent = recents.recentIDs
        guard let index = recent.firstIndex(of: id), !recent.isEmpty else { return 0 }
        return 2.5 * (Double(recent.count - index) / Double(recent.count))
    }

    private func choose(from options: [ComparisonUnit]) -> ComparisonUnit {
        var pool = options
        if pool.count > 1, let last = recents.recentIDs.last {
            let filtered = pool.filter { $0.id != last }
            if !filtered.isEmpty { pool = filtered }
        }
        let ranked = pool.map { unit in
            (unit, Double.random(in: 0...1, using: &rng) - recencyPenalty(for: unit.id))
        }
        return ranked.max { $0.1 < $1.1 }!.0
    }

    private func note(shown id: String) {
        var recent = recents.recentIDs
        recent.append(id)
        if recent.count > recentWindow { recent.removeFirst(recent.count - recentWindow) }
        recents.recentIDs = recent
    }

    // MARK: Rendering formulaic units

    private func render(formulaic unit: ComparisonUnit,
                        value: Double,
                        metric: ComparisonMetric,
                        tone: ComparisonTone,
                        scope: ComparisonScope?,
                        context: ComparisonContext) -> Comparison? {
        // With a period, only templates that say it; a unit without one sits out.
        let templates = unit.templates(for: tone).filter { scope == nil || Self.saysPeriod($0) }
        guard let picked = templates.randomElement(using: &rng) else { return nil }
        let template = fillPeriod(picked, scope)

        let rendered: String? = switch unit.kind {
        case .derived:   renderDerived(unit, template: template, tokens: value)
        case .composite: renderComposite(unit, template: template, context: context)
        case .unit:      nil
        }

        // Any surviving placeholder means a template/engine mismatch. Drop the
        // card rather than ship "{duration}" to a notification centre.
        guard let rendered, !rendered.contains("{") else { return nil }
        let text = Spoken.capitalisingFirst(rendered)

        note(shown: unit.id)
        return Comparison(unitID: unit.id, text: text, ratio: nil,
                          basis: unit.basis, confidence: unit.confidence, kind: unit.kind)
    }

    private func renderDerived(_ unit: ComparisonUnit,
                               template: String,
                               tokens: Double) -> String? {
        guard tokens.isFinite, tokens >= derivedFloorTokens else { return nil }
        switch unit.id {
        case "derived.read-aloud":
            return template.replacingOccurrences(
                of: "{duration}", with: formatDuration(maths.readAloudDuration(tokens: tokens)))
        case "derived.typing":
            return template.replacingOccurrences(
                of: "{duration}", with: formatDuration(maths.typingDuration(tokens: tokens)))
        case "derived.novelist":
            // "19.2 million days" is unreadable; "52,600 years" is not.
            return template.replacingOccurrences(
                of: "{span}", with: formatDuration(maths.novelistDays(tokens: tokens) * 86_400))
        case "derived.pages":
            return template
                .replacingOccurrences(of: "{pages}", with: formatCount(maths.printedPages(tokens: tokens)))
                .replacingOccurrences(of: "{stackHeight}", with: formatHeight(maths.stackHeightMeters(tokens: tokens)))
        case "derived.paper-stack":
            let meters = maths.stackHeightMeters(tokens: tokens)
            return template
                .replacingOccurrences(of: "{height}", with: formatHeight(meters))
                .replacingOccurrences(of: "{landmarkComparison}",
                                      with: landmarkPhrase(meters: meters, landmarks: unit.landmarks))
        default:
            return nil
        }
    }

    private func renderComposite(_ unit: ComparisonUnit,
                                 template: String,
                                 context: ComparisonContext) -> String? {
        switch unit.id {
        case "burn.dune-rate":
            guard let rate = context.tokensPerHour, rate > 0,
                  let reference = burnReferenceUnit(tokensPerHour: rate),
                  let refTokens = reference.tokenValue else { return nil }
            let interval = refTokens / rate * 3_600
            // "every day", not "every 1 day".
            var span = formatDuration(interval)
            if span.hasPrefix("1 ") { span.removeFirst(2) }
            if span == "under a minute" { span = "minute or less" }
            return template
                .replacingOccurrences(of: "{interval}", with: span)
                .replacingOccurrences(of: "{label}", with: reference.label)

        case "burn.quota-pace":
            guard let rate = context.quotaPercentPerHour, rate > 0,
                  let lead = context.exhaustionLeadTime, lead > 0 else { return nil }
            return template
                .replacingOccurrences(of: "{rate}", with: formatPercent(rate))
                .replacingOccurrences(of: "{delta}", with: formatDuration(lead))

        case "cache.savings-books":
            guard let cached = context.cachedInputTokens, cached > 0,
                  let reference = referenceUnit(driving: cached, metric: .tokens),
                  let refValue = reference.tokenValue, refValue > 0 else { return nil }
            // "Twice" is the least a multiplier says anything at.
            let ratio = cached / refValue
            guard ratio >= minRatio else { return nil }
            return template
                .replacingOccurrences(of: "{times}", with: Spoken.times(ratio, discrete: reference.discrete))
                .replacingOccurrences(of: "{label}", with: reference.label)

        case "cache.savings-cost":
            guard let saved = context.cacheSavings, saved.raw > 0,
                  let reference = referenceUnit(driving: Double(saved.raw), metric: .cost),
                  let refCost = reference.costValue, let many = reference.many,
                  let ratio = saved.ratio(to: refCost), ratio.rounded(.down) >= minRatio else { return nil }
            return template
                .replacingOccurrences(of: "{amount}", with: formatMoney(saved))
                .replacingOccurrences(of: "{count}", with: Spoken.count(ratio, discrete: true))
                .replacingOccurrences(of: "{many}", with: many)

        default:
            return nil
        }
    }

    /// A plain unit to pair a composite with, chosen for a readable multiplier.
    private func referenceUnit(driving value: Double, metric: ComparisonMetric) -> ComparisonUnit? {
        let band = fixedCandidates(value: value, metric: metric, categories: nil)
        let pool = band.isEmpty ? nearestFallback(value: value, metric: metric, categories: nil) : band
        guard !pool.isEmpty else { return nil }
        return pool.max { score(value: value, unit: $0) < score(value: value, unit: $1) }
    }

    /// For a burn line, pick the unit whose production interval reads best —
    /// not "a Dune every 4 seconds", not "a Dune every 9 years".
    private func burnReferenceUnit(tokensPerHour: Double) -> ComparisonUnit? {
        // "one full {label}" only works when the label names a thing, so
        // restrict to categories whose labels are concrete noun phrases.
        let objectCategories: Set<String> = ["literature", "code", "meme"]
        let candidates = corpus.units.filter { unit in
            guard unit.kind == .unit, unit.metric == .tokens,
                  objectCategories.contains(unit.category),
                  let v = unit.tokenValue, v > 0 else { return false }
            return burnIntervalBounds.contains(v / tokensPerHour * 3_600)
        }
        let target = 86_400.0    // roughly one a day reads best
        func distance(_ unit: ComparisonUnit) -> Double {
            abs(log(unit.tokenValue! / tokensPerHour * 3_600) - log(target))
        }
        // One of the few nearest a day, so a pace said again names a new thing.
        return candidates.sorted { distance($0) < distance($1) }
            .prefix(burnReferenceChoices)
            .randomElement(using: &rng)
    }

    /// The tallest landmark the stack reaches: "nine times the height of the
    /// Eiffel Tower", "higher than the Statue of Liberty", or the bare height.
    private func landmarkPhrase(meters: Double, landmarks: [ComparisonLandmark]) -> String {
        guard let best = landmarks.filter({ $0.meters > 0 && meters >= $0.meters })
            .max(by: { $0.meters < $1.meters }) else { return formatHeight(meters) }
        let ratio = meters / best.meters
        return ratio >= minRatio
            ? "\(Spoken.times(ratio, discrete: false)) the height of \(best.name)"
            : "higher than \(best.name)"
    }

    // MARK: Formatting

    private func formatCount(_ value: Double) -> String {
        guard value.isFinite else { return "countless" }
        if value >= 1_000_000_000 { return String(format: "%.1f billion", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f million", value / 1_000_000) }
        // "62,000 pages", not "61,538": the figure is an estimate.
        if value >= 1_000 { return decimal(Spoken.significant(value, digits: 2), fractionDigits: 0) }
        return decimal(value, fractionDigits: value < 10 ? 1 : 0)
    }

    private func decimal(_ value: Double, fractionDigits: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = fractionDigits
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    private func formatPercent(_ percentPerHour: Double) -> String {
        decimal(percentPerHour, fractionDigits: percentPerHour < 10 ? 1 : 0) + "%"
    }

    private func formatMoney(_ amount: Nanodollars) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        // "$8,567" and "$5", not "$8,567.00" and "$5.00": cents say nothing
        // at that size, or when there are none.
        if amount.raw >= 100 * Nanodollars.perDollar || amount.raw % Nanodollars.perDollar == 0 {
            f.maximumFractionDigits = 0
        }
        return f.string(from: amount.decimalDollars as NSDecimalNumber)
            ?? "$\(amount.decimalDollars)"
    }

    /// "3 hours", "6 days", "244 years" — never "8,760.0 hours".
    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "no time at all" }
        let minute = 60.0, hour = 3_600.0, day = 86_400.0
        let month = day * 30.44, year = day * 365.25
        func plural(_ v: Double, _ noun: String) -> String {
            "\(formatCount(v)) \(noun)\(abs(v - 1) < 0.05 ? "" : "s")"
        }
        switch seconds {
        case ..<minute: return "under a minute"
        case ..<hour:   return plural((seconds / minute).rounded(), "minute")
        case ..<day:    return plural((seconds / hour).rounded(), "hour")
        case ..<month:  return plural((seconds / day).rounded(), "day")
        case ..<year:   return plural((seconds / month).rounded(), "month")
        default:        return plural((seconds / year).rounded(), "year")
        }
    }

    /// "40 cm", "3.8 km", "1,200 km".
    private func formatHeight(_ meters: Double) -> String {
        guard meters.isFinite, meters > 0 else { return "nothing" }
        if meters < 0.01 { return "under a centimetre" }
        if meters < 1 { return String(format: "%.0f cm", meters * 100) }
        if meters < 1_000 { return String(format: "%.0f m", meters) }
        return "\(formatCount(meters / 1_000)) km"
    }
}

// MARK: - Milestones

extension ComparisonCorpus {
    /// The highest milestone strictly crossed going from `oldTotal` to
    /// `newTotal` tokens, worded, or nil. Pure, so the notification service
    /// can word one off the main actor.
    public func milestone(crossing newTotal: Double, from oldTotal: Double) -> String? {
        guard newTotal.isFinite, oldTotal.isFinite, newTotal > oldTotal,
              let crossed = milestones.filter({ $0.tokens > oldTotal && $0.tokens <= newTotal })
                .max(by: { $0.tokens < $1.tokens }) else { return nil }
        var text = crossed.text
        let pattern = /\{compare:([A-Za-z0-9._-]+)\}/
        while let match = text.firstMatch(of: pattern) {
            let unitID = String(match.1)
            guard let unit = units.first(where: { $0.id == unitID }),
                  let unitValue = unit.tokenValue, unitValue > 0 else { return nil }
            let ratio = crossed.tokens / unitValue
            guard ratio.isFinite, ratio >= 0.5 else { return nil }
            text.replaceSubrange(match.range, with: Spoken.length(ratio, of: unit.label))
        }
        return text.contains("{") ? nil : Spoken.capitalisingFirst(text)
    }
}

// MARK: - Spoken numbers

/// Multipliers as a person says them: "twice", "eight and a half times",
/// "nearly nine", "about 1,200". A count of things is never a decimal, and a
/// big one is never more precise than the estimate behind it.
enum Spoken {
    private static let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    /// How many of a unit: "eight and a half", "nearly nine", "41". A discrete
    /// unit counts whole things, floored.
    static func count(_ ratio: Double, discrete: Bool) -> String {
        if discrete { return number(ratio.rounded(.down)) }
        guard ratio < 10 else { return number(ratio.rounded()) }
        let whole = ratio.rounded(.down)
        switch ratio - whole {
        case ..<0.1:  return number(whole)
        case ..<0.35: return "a little more than \(number(whole))"
        case ..<0.65: return "\(number(whole)) and a half"
        case ..<0.9:  return "nearly \(number(whole + 1))"
        default:      return number(whole + 1)
        }
    }

    /// The multiplier as an adverb: "twice", "nearly three times".
    static func times(_ ratio: Double, discrete: Bool) -> String {
        let count = count(ratio, discrete: discrete)
        for (spoken, adverb) in [("two", "twice"), ("one", "once")] where count == spoken || count.hasSuffix(" \(spoken)") {
            return String(count.dropLast(spoken.count)) + adverb
        }
        return count + " times"
    }

    /// A milestone's length against a unit, near one or many times over.
    static func length(_ ratio: Double, of label: String) -> String {
        switch ratio {
        case ..<0.95: "nearly the length of \(label)"
        case ..<1.15: "about the length of \(label)"
        case ..<1.6:  "a little longer than \(label)"
        default:      "\(times(ratio, discrete: false)) the length of \(label)"
        }
    }

    /// Words under ten, then digits; from a hundred, two significant figures
    /// with "about" when that rounded anything away.
    static func number(_ value: Double) -> String {
        if value < 10, value >= 0 { return words[Int(value)] }
        if value >= 1_000_000 {
            return "about \(significant(value / 1_000_000, digits: 2).formatted()) million"
        }
        guard value >= 100 else { return Int(value).formatted() }
        let rounded = significant(value, digits: 2)
        return (rounded == value ? "" : "about ") + Int(rounded).formatted()
    }

    /// A stated size: "187,000", "4.4 million", "1.2 billion".
    static func figure(_ value: Double) -> String {
        if value >= 1_000_000_000 {
            return "\(significant(value / 1_000_000_000, digits: 2).formatted()) billion"
        }
        if value >= 1_000_000 { return "\(significant(value / 1_000_000, digits: 2).formatted()) million" }
        return Int(significant(value, digits: 3)).formatted()
    }

    static func significant(_ value: Double, digits: Int) -> Double {
        guard value > 0, value.isFinite else { return value }
        let scale = pow(10, Double(digits) - (log10(value)).rounded(.down) - 1)
        return (value * scale).rounded() / scale
    }

    static func capitalisingFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

// MARK: - Derived maths

public struct DerivedComparisons: Sendable {
    public let tokensPerWord: Double

    public func words(from tokens: Double) -> Double { tokens / max(tokensPerWord, 0.0001) }
    /// Continuous reading aloud at 150 wpm.
    public func readAloudDuration(tokens: Double) -> TimeInterval { words(from: tokens) / 150 * 60 }
    /// Sustained typing at 60 wpm.
    public func typingDuration(tokens: Double) -> TimeInterval { words(from: tokens) / 60 * 60 }
    /// A working novelist at 1,000 words a day.
    public func novelistDays(tokens: Double) -> Double { words(from: tokens) / 1_000 }
    public func printedPages(tokens: Double) -> Double { words(from: tokens) / 500 }
    /// 80gsm paper is ~0.1 mm a sheet.
    public func stackHeightMeters(tokens: Double) -> Double { printedPages(tokens: tokens) * 0.0001 }
}

// MARK: - Usage
//
//   let corpus = try ComparisonCorpus.load(from: url)       // throws, typed errors
//   let engine = ComparisonEngine(corpus: corpus, recents: UserDefaultsRecentStore())
//
//   engine.comparison(tokens: 7_000_000, tone: settings.tone)
//   engine.comparison(cost: Nanodollars(dollars: 184.20), tone: .roast)
//   engine.comparison(tokens: 0)                             // nil — hide the card
//
//   engine.comparison(tokens: total, context: .init(
//       tokensPerHour: burnRate, cachedInputTokens: cached, cacheSavings: saved))
//
//   engine.milestone(crossing: newLifetime, from: oldLifetime)
//
//   // Deterministic in tests:
//   ComparisonEngine(corpus: corpus, recents: InMemoryRecentStore(), rng: SeededRNG(seed: 42))
