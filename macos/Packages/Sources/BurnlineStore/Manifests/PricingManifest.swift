//
//  PricingManifest.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// `shared/pricing/pricing.json`: the append-only history of model prices.
///
/// Generated from LiteLLM's public price list by `shared/pricing/tools`, which
/// only ever appends, and shipped with the app; a newer copy may be fetched.
/// Rates are decimal strings in US dollars per million tokens, so no price
/// passes through floating point on its way to nanodollars.
public struct PricingManifest: Sendable, Decodable {
    public static let supportedSchemaVersion = 1

    public struct Rates: Sendable, Decodable, Hashable {
        public let input: String?
        public let cachedInput: String?
        public let cacheWrite: String?
        public let cacheWriteOneHour: String?
        public let output: String?
    }

    public struct Version: Sendable, Decodable, Hashable {
        /// A `ProviderKey` raw value.
        public let provider: String
        /// A canonical model name, as models are named in `model_aliases.json`
        /// or, for models it does not list, as the provider writes them.
        public let model: String
        /// ISO 8601. Inclusive.
        public let validFrom: Date
        /// ISO 8601. Exclusive; absent while current.
        public let validUntil: Date?
        public let tier: ServiceTier
        /// Absent for the base band.
        public let abovePromptTokens: Int64?
        public let source: String
        public let confidence: PricingConfidence
        public let perMillion: Rates

        /// What identifies a version across copies of the manifest: the
        /// generator never changes a version once written, only adds new ones.
        public struct Identity: Hashable, Sendable {
            let provider: String, model: String, tier: ServiceTier, band: Int64, validFrom: Date, source: String
        }

        public var identity: Identity {
            Identity(provider: provider, model: model, tier: tier, band: abovePromptTokens ?? 0,
                     validFrom: validFrom, source: source)
        }

        /// The rates in nanodollars per million tokens. Throws on a rate that
        /// is not a non-negative decimal.
        func tokenRates() throws(LoadError) -> TokenRates {
            func parse(_ text: String?, _ field: String) throws(LoadError) -> Nanodollars? {
                guard let text else { return nil }
                guard let value = Nanodollars(decimalString: text), value.raw >= 0 else {
                    throw .malformed("\(model) \(field): not a decimal rate")
                }
                return value
            }
            return TokenRates(
                input: try parse(perMillion.input, "input"),
                cachedInput: try parse(perMillion.cachedInput, "cachedInput"),
                cacheWrite: try parse(perMillion.cacheWrite, "cacheWrite"),
                cacheWriteOneHour: try parse(perMillion.cacheWriteOneHour, "cacheWriteOneHour"),
                output: try parse(perMillion.output, "output"))
        }
    }

    public let schemaVersion: Int
    public let generatedAt: Date?
    public let versions: [Version]

    public enum LoadError: Error, Equatable, Sendable {
        case missing(String)
        case malformed(String)
        case unsupportedSchemaVersion(found: Int, supported: Int)
    }

    public static func load(from url: URL) throws(LoadError) -> PricingManifest {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw .missing(url.path) }
        return try decode(data)
    }

    /// Decodes and validates, so a manifest that loads can be applied whole.
    public static func decode(_ data: Data) throws(LoadError) -> PricingManifest {
        // The version is read on its own first, so a future file reports as
        // unsupported rather than as malformed.
        struct Versioned: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version: Int
        do { version = try decoder.decode(Versioned.self, from: data).schemaVersion }
        catch { throw .malformed(String(describing: error)) }
        guard version == supportedSchemaVersion else {
            throw .unsupportedSchemaVersion(found: version, supported: supportedSchemaVersion)
        }
        let manifest: PricingManifest
        do { manifest = try decoder.decode(PricingManifest.self, from: data) }
        catch { throw .malformed(String(describing: error)) }

        for entry in manifest.versions {
            guard entry.abovePromptTokens ?? 0 >= 0 else {
                throw .malformed("\(entry.model): negative prompt-length band")
            }
            guard ProviderKey(rawValue: entry.provider) != nil else {
                throw .malformed("\(entry.model): unknown provider \(entry.provider)")
            }
            if let until = entry.validUntil, until <= entry.validFrom {
                throw .malformed("\(entry.model): validUntil is not after validFrom")
            }
            _ = try entry.tokenRates()
        }
        guard Set(manifest.versions.map(\.identity)).count == manifest.versions.count else {
            throw .malformed("a version appears twice")
        }
        return manifest
    }

    /// Whether this manifest keeps every version of `older` exactly as it was.
    /// A fetched copy that rewrote history, rather than adding to it, is
    /// refused: historical cost must not move because a file changed.
    public func preserves(_ older: PricingManifest) -> Bool {
        let mine = Dictionary(versions.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        return older.versions.allSatisfy { mine[$0.identity] == $0 }
    }
}
