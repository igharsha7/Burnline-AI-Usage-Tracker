//
//  UsageProviderAdapter.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import Foundation

/// One provider's local history: where it lives and how to read it.
///
/// Adapters only read and parse. They never write: ingestion owns the
/// database, so one adapter misbehaving cannot corrupt another's data, and a
/// throwing adapter is recorded as that provider's health rather than
/// propagated. Provider-specific structure stops here; what leaves is
/// `IncomingUsage`.
public protocol UsageProviderAdapter: Sendable {
    var provider: ProviderKey { get }

    /// Clears filesystem-derived context before a new scan.
    func prepareForSync()

    func detect() -> ProviderDetection

    /// The directories to watch for changes: every place this provider's
    /// history lives that exists now.
    func watchedDirectories() -> [URL]

    /// Every history file, in a stable order.
    func sourceFiles() throws -> [URL]

    /// Parses `file` from byte `offset` to its last complete line. `state` is
    /// the `endState` of the earlier pass that ended at `offset`, or nil when
    /// starting from the beginning. An adapter that needs state to resume and
    /// is given none starts the file over, which costs time but never counts.
    func parse(_ file: URL, from offset: Int64, state: String?) throws -> ParseOutput
}

extension UsageProviderAdapter {
    public func prepareForSync() {}

    public func watchedDirectories() -> [URL] {
        guard case .installed(let directory) = detect() else { return [] }
        return [directory]
    }
}

/// What one pass over a file produced.
public struct ParseOutput: Sendable {
    public var records: [IncomingUsage] = []
    public var issues: [ParseIssue] = []
    /// Lines that failed or were patched, including those beyond the issue
    /// cap, so the total is honest even when the details are not all kept.
    public var issueCount = 0
    public var linesRead = 0
    /// Just past the last complete line, where the next pass resumes. A final
    /// line without its newline may still be being written, so it is left for
    /// the next pass rather than read half-finished.
    public var endOffset: Int64 = 0
    /// What the adapter needs to resume at `endOffset`, such as the model in
    /// force there. Stored with the offset and handed back unchanged.
    public var endState: String?

    /// Most issues recorded in detail per file. A file of a million bad lines
    /// must not become a million rows.
    public static let issueCap = 20

    public init() {}

    mutating func record(_ reason: String, file: URL, line: Int) {
        issueCount += 1
        guard issues.count < Self.issueCap else { return }
        issues.append(ParseIssue(file: file.path, line: line, reason: reason))
    }

    /// A token count as a fact: an absent or negative value becomes zero and
    /// is recorded.
    mutating func count(_ value: Int64?, _ name: String, file: URL, line: Int) -> Int64 {
        guard let value else {
            record("\(name) absent; counted as zero", file: file, line: line)
            return 0
        }
        guard value >= 0 else {
            record("\(name) negative; counted as zero", file: file, line: line)
            return 0
        }
        return value
    }
}
