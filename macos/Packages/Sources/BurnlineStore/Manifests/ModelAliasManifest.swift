//
//  ModelAliasManifest.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// `shared/pricing/model_aliases.json`: which raw model strings mean which
/// canonical model, and which strings are not models at all.
///
/// Shipped as data so a renamed model can be corrected without a release. The
/// schema version is checked on load, and a version from the future is refused
/// rather than read with its unknown fields ignored.
public struct ModelAliasManifest: Sendable, Decodable {
    public static let supportedSchemaVersion = 1

    public struct Alias: Sendable, Decodable {
        public let raw: String
        /// ISO 8601. Absent means "since forever" or "still current".
        public let validFrom: Date?
        public let validUntil: Date?
    }

    public struct Model: Sendable, Decodable {
        public let canonical: String
        public let display: String
        public let family: String?
        /// Raw strings beyond the canonical name itself, which always resolves.
        public let aliases: [Alias]?
    }

    public struct ProviderEntry: Sendable, Decodable {
        public let models: [Model]
        /// Values that occupy the model field without being a model.
        public let nonModels: [String]
    }

    public let schemaVersion: Int
    public let providers: [String: ProviderEntry]

    public enum LoadError: Error, Equatable, Sendable {
        case missing(String)
        case malformed(String)
        case unsupportedSchemaVersion(found: Int, supported: Int)
    }

    public static func load(from url: URL) throws(LoadError) -> ModelAliasManifest {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw .missing(url.path) }

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
        do { return try decoder.decode(ModelAliasManifest.self, from: data) }
        catch { throw .malformed(String(describing: error)) }
    }
}
