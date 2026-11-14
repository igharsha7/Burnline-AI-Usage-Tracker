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
/// Reads are silent unless `access` allows a prompt: Claude Code rewrites its
/// Keychain item whenever it renews its login, which makes macOS ask again,
/// and a prompt the user did not cause is a surprise every few hours. A read
/// macOS refuses reports that permission is needed, and quota is read
/// through Claude Code instead until the user allows it again.
public final class KeychainClaudeCredentials: ClaudeCredentialSource, Sendable {
    let service: String
    let files: [URL]
    let access: ClaudeLoginAccess
    let lookup: Lookup

    static let service = "Claude Code-credentials"

    /// A Keychain search for a generic password by service, allowed to show
    /// macOS's prompt or not: its status, and the item's data when found.
    /// Replaced in tests.
    typealias Lookup = @Sendable (_ service: String, _ mayPrompt: Bool) -> (OSStatus, Data?)

    public init(access: ClaudeLoginAccess,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        service = Self.service
        files = ProviderHomes.claude(environment: environment).map { $0.appending(path: ".credentials.json") }
        lookup = Self.keychain
        #if DEBUG
        // A debug build is signed anew on every build, so the Keychain would
        // ask each launch. `BURNLINE_SKIP_KEYCHAIN` turns reading off.
        if environment["BURNLINE_SKIP_KEYCHAIN"] != nil { access.setEnabled(false) }
        #endif
        self.access = access
    }

    init(service: String = KeychainClaudeCredentials.service, files: [URL], access: ClaudeLoginAccess,
         lookup: @escaping Lookup) {
        self.service = service
        self.files = files
        self.access = access
        self.lookup = lookup
    }

    /// Whether the Keychain may show its prompts: one switch for the whole
    /// process. Replaced in tests.
    struct Interaction: Sendable {
        let isAllowed: @Sendable () -> Bool
        let allow: @Sendable (Bool) -> Void

        static let system = Interaction(
            isAllowed: {
                var allowed: DarwinBoolean = true
                SecKeychainGetUserInteractionAllowed(&allowed)
                return allowed.boolValue
            },
            allow: { SecKeychainSetUserInteractionAllowed($0) })
    }

    /// Silent searches take turns, since they share the one switch.
    private static let interactionLock = NSLock()

    static let keychain: Lookup = { service, mayPrompt in
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = search(mayPrompt: mayPrompt, interaction: .system) { SecItemCopyMatching(query as CFDictionary, &item) }
        return (status, item as? Data)
    }

    /// Runs `copy`, a Keychain search, with prompts turned off unless
    /// `mayPrompt`, and puts the switch back as it was.
    /// `kSecUseAuthenticationUIFail` does not stop the prompt for a
    /// login-keychain item's access list; turning interaction off does, and
    /// macOS then refuses at once.
    static func search(mayPrompt: Bool, interaction: Interaction, _ copy: () -> OSStatus) -> OSStatus {
        if mayPrompt { return copy() }
        return interactionLock.withLock {
            let allowed = interaction.isAllowed()
            interaction.allow(false)
            defer { interaction.allow(allowed) }
            return copy()
        }
    }

    public func login(at now: Timestamp) throws(QuotaReadError) -> ClaudeLogin {
        if let file = files.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let data = try? Data(contentsOf: file) {
            return try ClaudeStoredLogin.login(from: data, at: now)
        }
        guard access.isEnabled else {
            throw .notSignedIn("Reading Claude Code's login is turned off in Settings.")
        }
        let mayPrompt = access.takePrompt()
        let (status, item) = lookup(service, mayPrompt)
        switch status {
        case errSecSuccess:
            guard let data = item else { throw .malformed("Claude Code's stored login") }
            access.record(.allowed)
            return try ClaudeStoredLogin.login(from: data, at: now)
        case errSecItemNotFound:
            throw .notSignedIn("Claude Code is not signed in.")
        default:
            if mayPrompt {
                access.record(.declined)
                throw .notSignedIn("Burnline was not allowed to read Claude Code's login.")
            }
            // Refused without asking: macOS wants the user's say again.
            access.record(.needsPermission)
            throw .notSignedIn("Claude Code renewed its login, so Burnline needs permission to read it again.")
        }
    }
}
