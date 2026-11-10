//
//  UsageEvent.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// Where an event came from, kept so its cost can be recomputed and its origin
/// audited without re-reading provider files.
public struct SourceReference: Hashable, Sendable {
    public let sourceType: String
    public let file: String?
    /// Unique per provider. The deduplication key.
    public let eventID: String
    public let schemaVersion: String?
    /// Byte offset in `file`, for incremental reading.
    public let offset: Int64?

    public init(sourceType: String, file: String?, eventID: String,
                schemaVersion: String?, offset: Int64?) {
        self.sourceType = sourceType
        self.file = file
        self.eventID = eventID
        self.schemaVersion = schemaVersion
        self.offset = offset
    }
}

/// The canonical usage event every adapter normalises into. Provider-specific
/// structure stops at the adapter and never reaches storage or charts.
///
/// Model, session, and project are resolved identities, and any of them may be
/// unknown. Token counts are facts; `cost` is derived and recomputable.
public struct UsageEvent: Hashable, Sendable, Identifiable {
    /// Deduplication identity, `(provider, source_event_id)`. Re-reading a
    /// rotated or rewritten file yields the same keys, so it is safe.
    public struct Key: Hashable, Sendable {
        public let provider: ProviderKey
        public let sourceEventID: String
    }

    public let provider: ProviderKey
    public let modelID: Int64?
    public let sessionID: Int64?
    public let projectID: Int64?
    public let timestamp: Timestamp
    public let tokens: TokenCounts
    /// The provider's billing tier, as written. Nil when unstated, which
    /// prices as standard.
    public let serviceTier: String?
    public let cost: CostAttribution
    public let source: SourceReference

    public var id: Key { Key(provider: provider, sourceEventID: source.eventID) }

    public init(provider: ProviderKey, modelID: Int64?, sessionID: Int64?, projectID: Int64?,
                timestamp: Timestamp, tokens: TokenCounts, serviceTier: String? = nil,
                cost: CostAttribution, source: SourceReference) {
        self.provider = provider
        self.modelID = modelID
        self.sessionID = sessionID
        self.projectID = projectID
        self.timestamp = timestamp
        self.tokens = tokens
        self.serviceTier = serviceTier
        self.cost = cost
        self.source = source
    }
}
