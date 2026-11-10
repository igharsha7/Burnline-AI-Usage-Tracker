//
//  QuotaReader.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// One way of reading a provider's quota. The rest of Burnline does not care
/// whether it asks the provider's own tool or its usage endpoint.
///
/// Quota reading is more fragile than reading history: every source here is
/// one the provider may change without notice, so each is isolated behind
/// this protocol and fails as a reason to show, never a crash.
public protocol QuotaReader: Sendable {
    var provider: ProviderKey { get }
    func read() async throws(QuotaReadError) -> QuotaReading
}

/// Why a read failed, in words fit to show. None carries a credential or a
/// response body, so any of them can be logged.
public enum QuotaReadError: Error, Hashable, Sendable {
    /// The provider's tool is not on this Mac.
    case notInstalled(String)
    /// Not signed in, or Burnline was not allowed to read the login.
    case notSignedIn(String)
    /// The login has expired. The provider's tool renews it when next used;
    /// Burnline never does.
    case credentialExpired
    /// No answer: offline, timed out, or the service failed.
    case unreachable(String)
    /// The provider asked Burnline to slow down.
    case rateLimited
    /// The account has no subscription limits, such as one using an API key.
    case unsupported(String)
    /// The answer was not in a shape Burnline understands, so the provider
    /// has likely changed it.
    case malformed(String)

    public var reason: String {
        switch self {
        case .notInstalled(let tool): "\(tool) is not installed."
        case .notSignedIn(let detail): detail
        case .credentialExpired: "The login has expired. Using the tool again renews it."
        case .unreachable(let detail): "Could not reach the provider: \(detail)."
        case .rateLimited: "The provider asked Burnline to check less often."
        case .unsupported(let detail): detail
        case .malformed(let detail): "The provider's answer was not understood: \(detail)."
        }
    }

    /// Whether trying another source could help. An account without limits
    /// has none to find.
    var worthFallingBack: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

/// Tries each reader in turn and returns the first answer, so a source that
/// fails or is withheld has a fallback. If every reader fails, the first one's
/// error is the one reported, since it is the preferred source.
public struct FallbackQuotaReader: QuotaReader {
    public let provider: ProviderKey
    let readers: [any QuotaReader]

    public init(_ readers: [any QuotaReader]) {
        precondition(!readers.isEmpty && Set(readers.map(\.provider)).count == 1,
                     "a fallback chain reads one provider")
        provider = readers[0].provider
        self.readers = readers
    }

    public func read() async throws(QuotaReadError) -> QuotaReading {
        var first: QuotaReadError?
        for reader in readers {
            do {
                return try await reader.read()
            } catch {
                first = first ?? error
                if !error.worthFallingBack { break }
            }
        }
        throw first!
    }
}
