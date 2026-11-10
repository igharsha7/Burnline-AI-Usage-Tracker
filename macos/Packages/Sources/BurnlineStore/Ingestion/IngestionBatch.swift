//
//  IngestionBatch.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import GRDB

/// A project as an adapter sees it, before it has a database row.
public struct ProjectCandidate: Hashable, Sendable {
    public let identity: ProjectIdentity
    public let displayName: String
    public let path: String?
    /// False when the working directory is gone, as for an old transcript of
    /// a repository that has since moved. Its identity is then only a guess
    /// from the path, and a session that already has a project keeps it.
    public let directoryExists: Bool

    public init(identity: ProjectIdentity, displayName: String, path: String?, directoryExists: Bool = true) {
        self.identity = identity
        self.displayName = displayName
        self.path = path
        self.directoryExists = directoryExists
    }
}

/// One usage record as parsed, with identities still raw. Everything a
/// provider adapter knows, and nothing provider-specific.
public struct IncomingUsage: Hashable, Sendable {
    public let sourceEventID: String
    /// The provider's session id, or one synthesised from the file.
    public let sessionSourceID: String
    /// Nil when the record had no working directory.
    public let project: ProjectCandidate?
    /// Nil or empty when the record had no model.
    public let rawModel: String?
    public let timestamp: Timestamp
    public let tokens: TokenCounts
    /// The provider's billing tier, as written; nil when the record is silent.
    public let serviceTier: String?
    public let sourceType: String
    public let file: String
    public let schemaVersion: String?
    public let offset: Int64

    public init(sourceEventID: String, sessionSourceID: String, project: ProjectCandidate?, rawModel: String?,
                timestamp: Timestamp, tokens: TokenCounts, serviceTier: String? = nil, sourceType: String,
                file: String, schemaVersion: String?, offset: Int64) {
        self.sourceEventID = sourceEventID
        self.sessionSourceID = sessionSourceID
        self.project = project
        self.rawModel = rawModel
        self.timestamp = timestamp
        self.tokens = tokens
        self.serviceTier = serviceTier
        self.sourceType = sourceType
        self.file = file
        self.schemaVersion = schemaVersion
        self.offset = offset
    }
}

/// Why a line was skipped or patched. A reason only: the line itself may hold
/// prompt text or source code, which Burnline never stores.
public struct ParseIssue: Hashable, Sendable {
    public let file: String
    /// One-based.
    public let line: Int
    public let reason: String

    public init(file: String, line: Int, reason: String) {
        self.file = file
        self.line = line
        self.reason = reason
    }
}

public struct IngestionOutcome: Hashable, Sendable {
    /// Events added, or replaced by a more complete copy.
    public let eventsWritten: Int
    public let issuesRecorded: Int
}

extension BurnlineDatabase {
    /// Writes one batch in a single transaction: model and project identities,
    /// sessions, events, parser errors, and how far the file has been read
    /// commit together or not at all. A crash can then never leave an
    /// offset past events that were not written, nor events whose offset was
    /// lost; at worst the next pass re-reads lines whose events are already
    /// stored, and the uniqueness constraint absorbs them.
    @discardableResult
    public func ingest(_ records: [IncomingUsage], issues: [ParseIssue], provider: ProviderKey,
                       sourceState: SourceState? = nil) throws(StoreError) -> IngestionOutcome {
        let now = clock.now.epochSeconds
        let providerID = providerID(provider)
        return try write { db in
            let records = try Self.admissible(records, providerID: providerID, in: db)
            var events: [UsageEvent] = []
            events.reserveCapacity(records.count)
            // A batch is nearly always one file: one session, one project, a
            // handful of models. Each is looked up once per batch, and each
            // model's pricing history read once, rather than once per event.
            var pricing: [Int64: [PricingVersion]] = [:]
            var models = ModelResolver(providerID: providerID, now: now)
            let identities = try Self.identities(of: records, providerID: providerID, in: db)
            for record in records {
                let model = try models.resolve(record.rawModel, at: record.timestamp, in: db)
                let identity = identities[SessionKey(record)]!
                events.append(UsageEvent(
                    provider: provider, modelID: model.modelID, sessionID: identity.sessionID,
                    projectID: identity.projectID,
                    timestamp: record.timestamp, tokens: record.tokens, serviceTier: record.serviceTier,
                    cost: try Self.cost(of: record, model: model, provider: provider, pricing: &pricing, in: db),
                    source: SourceReference(sourceType: record.sourceType, file: record.file,
                                            eventID: record.sourceEventID,
                                            schemaVersion: record.schemaVersion, offset: record.offset)))
            }
            let written = try UsageRepository.insert(events, in: db, database: self, createdAt: now)

            for issue in issues {
                try db.execute(
                    sql: """
                    INSERT INTO parser_errors (provider_id, source_file, line_number, reason, occurred_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [providerID, issue.file, issue.line, issue.reason, now])
            }
            if let sourceState {
                try SourceStateRepository.save(sourceState, providerID: providerID, in: db)
            }
            return IngestionOutcome(eventsWritten: written, issuesRecorded: issues.count)
        }
    }

    /// The records that may be stored, all of a file's at once so a reply is
    /// judged whole: `LateHistory` refuses a record in a quarter hour holding
    /// compacted history, and with it every record sharing its id. Claude
    /// Code writes one reply over several lines, each with its own time, so a
    /// reply crossing into the next quarter hour would otherwise count again
    /// from the line on the open side when its file is read again.
    public func admissible(_ records: [IncomingUsage], provider: ProviderKey) throws(StoreError) -> [IncomingUsage] {
        let providerID = providerID(provider)
        return try read { db in try Self.admissible(records, providerID: providerID, in: db) }
    }

    static func admissible(_ records: [IncomingUsage], providerID: Int64, in db: Database) throws -> [IncomingUsage] {
        var late = try LateHistory(in: db)
        var refused: Set<String> = []
        for record in records where !(try late.accepts(record.timestamp, providerID: providerID, in: db)) {
            refused.insert(record.sourceEventID)
        }
        return refused.isEmpty ? records : records.filter { !refused.contains($0.sourceEventID) }
    }

    /// The record's cost at the rates of its own time. Storage keeps NULL for
    /// an unpriced event and derives the reason on read.
    private static func cost(of record: IncomingUsage, model: ModelResolution, provider: ProviderKey,
                             pricing: inout [Int64: [PricingVersion]], in db: Database) throws -> CostAttribution {
        guard model.kind == .model else { return .unpriced(.nonModel) }
        guard let modelID = model.modelID else { return .unpriced(.unknownModel) }
        if pricing[modelID] == nil { pricing[modelID] = try PricingRepository.versions(for: modelID, in: db) }
        return Pricer.price(record.tokens, tier: ServiceTier(recorded: record.serviceTier, provider: provider),
                            at: record.timestamp, versions: pricing[modelID] ?? [])
    }

    /// A session and the project its records name. Records sharing one share
    /// both rows, so the rows are written once per batch.
    struct SessionKey: Hashable {
        let session: String
        let project: ProjectCandidate?

        init(_ record: IncomingUsage) {
            session = record.sessionSourceID
            project = record.project
        }
    }

    /// The session and project rows for every distinct session in `records`,
    /// created or extended to cover the records' time span. Writing the
    /// earliest and the latest time is what writing every record's time would
    /// leave, since the rows keep only the minimum and maximum.
    private static func identities(of records: [IncomingUsage], providerID: Int64,
                                   in db: Database) throws -> [SessionKey: (sessionID: Int64, projectID: Int64?)] {
        var spans: [SessionKey: (first: Timestamp, last: Timestamp)] = [:]
        var order: [SessionKey] = []
        for record in records {
            let key = SessionKey(record)
            if let span = spans[key] {
                spans[key] = (min(span.first, record.timestamp), max(span.last, record.timestamp))
            } else {
                spans[key] = (record.timestamp, record.timestamp)
                order.append(key)
            }
        }
        var identities: [SessionKey: (sessionID: Int64, projectID: Int64?)] = [:]
        for key in order {
            let span = spans[key]!
            var projectID: Int64?
            var sessionID: Int64 = 0
            for seenAt in span.first == span.last ? [span.first] : [span.first, span.last] {
                projectID = try Self.projectID(for: key.project, session: key.session, providerID: providerID,
                                               seenAt: seenAt, in: db)
                sessionID = try SessionRepository.findOrCreate(
                    db, providerID: providerID, sourceSessionID: key.session, projectID: projectID, seenAt: seenAt)
            }
            identities[key] = (sessionID, projectID)
        }
        return identities
    }

    /// The record's project. A record whose directory no longer exists joins
    /// its session's existing project instead of creating one from a stale
    /// path, so re-reading history after a repository moved does not split it.
    private static func projectID(for candidate: ProjectCandidate?, session: String, providerID: Int64,
                                  seenAt: Timestamp, in db: Database) throws -> Int64? {
        guard let candidate else { return nil }
        if !candidate.directoryExists,
           let existing = try Int64.fetchOne(
               db.cachedStatement(sql: "SELECT project_id FROM sessions WHERE provider_id = ? AND source_session_id = ?"),
               arguments: [providerID, session]) {
            try db.cachedStatement(sql: "UPDATE projects SET last_seen_at = max(last_seen_at, ?) WHERE id = ?")
                .execute(arguments: [seenAt.epochSeconds, existing])
            return existing
        }
        return try ProjectRepository.findOrCreate(db, candidate, seenAt: seenAt)
    }
}
