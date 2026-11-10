//
//  Pricing.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// How much to trust a price. Travels with every figure computed from it.
public enum PricingConfidence: String, Sendable, CaseIterable, Codable {
    case exact, reconstructed, estimated, unknown
}

/// Per-million-token rates for each token component. A nil rate means the
/// price of that component is not known, which is different from free.
public struct TokenRates: Hashable, Sendable {
    public let input: Nanodollars?
    public let cachedInput: Nanodollars?
    /// The five-minute cache-write rate.
    public let cacheWrite: Nanodollars?
    public let cacheWriteOneHour: Nanodollars?
    public let output: Nanodollars?
    public let reasoning: Nanodollars?

    public init(input: Nanodollars? = nil, cachedInput: Nanodollars? = nil,
                cacheWrite: Nanodollars? = nil, cacheWriteOneHour: Nanodollars? = nil,
                output: Nanodollars? = nil, reasoning: Nanodollars? = nil) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.cacheWriteOneHour = cacheWriteOneHour
        self.output = output
        self.reasoning = reasoning
    }
}

/// The billing tier a request ran at. Providers charge some tiers a multiple
/// of the standard rate (OpenAI's priority processing, Anthropic's fast mode)
/// and others less (OpenAI's flex).
public enum ServiceTier: String, Sendable, CaseIterable, Codable {
    case standard, priority, flex, ultrafast, fast

    /// The tier a recorded value bills at, or nil for a value Burnline does not
    /// know, which prices at standard rates with estimated confidence. Absent
    /// and the providers' names for their default tier are standard. Codex
    /// calls OpenAI's priority processing "fast"; Claude's "fast" is
    /// Anthropic's own fast mode.
    public init?(recorded: String?, provider: ProviderKey) {
        switch recorded?.lowercased() {
        case nil, "", "default", "standard", "auto": self = .standard
        case "priority": self = .priority
        case "fast": self = provider == .codex ? .priority : .fast
        case "flex": self = .flex
        case "ultrafast": self = .ultrafast
        default: return nil
        }
    }
}

/// One row of the append-only pricing history. A price change adds a version;
/// it never edits one, so historical cost never moves.
///
/// A model's price is several rows: one per service tier, and for models that
/// charge more for long prompts, one per prompt-length band. A band row
/// applies to requests whose prompt exceeds `abovePromptTokens`.
public struct PricingVersion: Hashable, Sendable, Identifiable {
    public let id: Int64
    public let modelID: Int64
    /// Inclusive.
    public let validFrom: Timestamp
    /// Exclusive. Nil while this is the current price.
    public let validUntil: Timestamp?
    public let serviceTier: ServiceTier
    /// Zero for the base band.
    public let abovePromptTokens: Int64
    public let rates: TokenRates
    public let source: String
    public let confidence: PricingConfidence

    /// The source of a price the user entered. It outranks every other source
    /// for the time it covers.
    public static let userSource = "user"

    public init(id: Int64, modelID: Int64, validFrom: Timestamp, validUntil: Timestamp?,
                serviceTier: ServiceTier = .standard, abovePromptTokens: Int64 = 0,
                rates: TokenRates, source: String, confidence: PricingConfidence) {
        self.id = id
        self.modelID = modelID
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.serviceTier = serviceTier
        self.abovePromptTokens = abovePromptTokens
        self.rates = rates
        self.source = source
        self.confidence = confidence
    }

    /// Whether this version priced events at `instant`. An event exactly on a
    /// price change belongs to the newer version.
    public func applies(at instant: Timestamp) -> Bool {
        validFrom <= instant && validUntil.map { instant < $0 } ?? true
    }
}

/// Why an event has no cost.
public enum UnpricedReason: String, Sendable, CaseIterable {
    /// The model field was empty, or named a model Burnline has no prices
    /// for at all, such as a release newer than the bundled manifest.
    case unknownModel
    /// The model has prices, but none covering the event's time. Never filled
    /// in from the current price.
    case noPricingVersion
    /// The model field held something that is not a model, such as
    /// `<synthetic>`. Never priced.
    case nonModel
}

/// An event's cost, or the reason it has none. An enum rather than an optional
/// so "unpriced" always says why; that reason is what Settings shows.
public enum CostAttribution: Hashable, Sendable {
    case priced(Nanodollars, pricingVersionID: Int64, confidence: PricingConfidence)
    case unpriced(UnpricedReason)

    public var amount: Nanodollars? {
        if case .priced(let amount, _, _) = self { amount } else { nil }
    }
}
