//
//  ClaudeCredentials.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import Security

/// Where Claude Code's login is read from, at the moment it is needed.
///
/// The token is read for one request and dropped. Burnline never stores,
/// logs or renews it: renewing would write to Claude Code's own login, and
/// Burnline is read-only toward providers. An expired token is reported as
/// such, and Claude Code renews it the next time it runs.
public protocol ClaudeCredentialSource: Sendable {
    func login(at now: Timestamp) throws(QuotaReadError) -> ClaudeLogin
}

/// What one read of Claude Code's login gives: the token for one request,
/// and the plan it belongs to, which Claude's usage endpoint does not report.
public struct ClaudeLogin: Sendable {
    public let token: SecretString
    /// Claude Code's own name for the plan, such as `max` or `pro`.
    public let plan: String?

    public init(token: SecretString, plan: String? = nil) {
        self.token = token
        self.plan = plan
    }
}

/// The shape Claude Code stores its login in, in the Keychain on macOS and
/// in `.credentials.json` elsewhere. Only the fields Burnline needs are
/// decoded; the refresh token is never read into memory as a value.
struct ClaudeStoredLogin: Decodable {
    struct OAuth: Decodable {
        let accessToken: String?
        /// Epoch milliseconds.
        let expiresAt: Int64?
        let subscriptionType: String?
    }
    let claudeAiOauth: OAuth?

    static func login(from data: Data, at now: Timestamp) throws(QuotaReadError) -> ClaudeLogin {
        guard let login = try? JSONDecoder().decode(Self.self, from: data) else {
            throw .malformed("Claude Code's stored login")
        }
        guard let token = login.claudeAiOauth?.accessToken, !token.isEmpty else {
            throw .notSignedIn("Claude Code is not signed in with a Claude account.")
        }
        if let expiresAt = login.claudeAiOauth?.expiresAt, expiresAt / 1_000 <= now.epochSeconds {
            throw .credentialExpired
        }
        let plan = login.claudeAiOauth?.subscriptionType.flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeLogin(token: SecretString(token), plan: plan)
    }
}

/// Claude Code's login from the macOS Keychain, falling back to the
/// `.credentials.json` Claude Code writes where it has no Keychain.
///
/// The first read asks the user to allow it. If they decline, Burnline stops
/// asking for the rest of the session rather than prompting at every
/// refresh, and quota is read through Claude Code instead.
public final class KeychainClaudeCredentials: ClaudeCredentialSource, @unchecked Sendable {
    // @unchecked: `declined` is only read and written under `lock`.
    private let lock = NSLock()
    private var declined = false
    let service: String
    let files: [URL]
    let lookup: Lookup

    static let service = "Claude Code-credentials"

    /// A Keychain search for a generic password by service: its status, and
    /// the item's data when found. Replaced in tests.
    typealias Lookup = @Sendable (_ service: String) -> (OSStatus, Data?)

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        service = Self.service
        files = ProviderHomes.claude(environment: environment).map { $0.appending(path: ".credentials.json") }
        lookup = Self.keychain
        #if DEBUG
        // A debug build is signed anew on every build, so the Keychain asks
        // again each launch. `BURNLINE_SKIP_KEYCHAIN` behaves as a decline.
        declined = environment["BURNLINE_SKIP_KEYCHAIN"] != nil
        #endif
    }

    init(service: String = KeychainClaudeCredentials.service, files: [URL], lookup: @escaping Lookup) {
        self.service = service
        self.files = files
        self.lookup = lookup
    }

    static let keychain: Lookup = { service in
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    public func login(at now: Timestamp) throws(QuotaReadError) -> ClaudeLogin {
        if let file = files.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let data = try? Data(contentsOf: file) {
            return try ClaudeStoredLogin.login(from: data, at: now)
        }
        if lock.withLock({ declined }) {
            throw .notSignedIn("Burnline was not allowed to read Claude Code's login.")
        }
        let (status, item) = lookup(service)
        switch status {
        case errSecSuccess:
            guard let data = item else { throw .malformed("Claude Code's stored login") }
            return try ClaudeStoredLogin.login(from: data, at: now)
        case errSecItemNotFound:
            throw .notSignedIn("Claude Code is not signed in.")
        default:
            // Declined, cancelled, or not allowed without the user present.
            lock.withLock { declined = true }
            throw .notSignedIn("Burnline was not allowed to read Claude Code's login.")
        }
    }
}
