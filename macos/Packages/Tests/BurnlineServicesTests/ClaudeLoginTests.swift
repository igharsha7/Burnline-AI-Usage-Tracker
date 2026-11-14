//
//  ClaudeLoginTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineProviders
@testable import BurnlineServices
import BurnlineStore
import BurnlineTestSupport
import Foundation
import Testing

/// Reading Claude Code's login through the assembled app: refused silently
/// after Claude Code renews it, allowed again by the user, or turned off,
/// with banked resets coming back once it can be read.
struct ClaudeLoginTests {
    /// A Keychain that refuses silent searches, as after Claude Code renews
    /// its login, and answers one that may prompt, as when the user allows it.
    final class RenewedKeychain: @unchecked Sendable {
        // @unchecked: `asked` is only touched under `lock`.
        private let lock = NSLock()
        private var asked: [Bool] = []
        var prompts: [Bool] { lock.withLock { asked } }
        func lookup(_ service: String, _ mayPrompt: Bool) -> (OSStatus, Data?) {
            lock.withLock { asked.append(mayPrompt) }
            guard mayPrompt else { return (errSecInteractionNotAllowed, nil) }
            return (errSecSuccess, Data(#"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"max"}}"#.utf8))
        }
    }

    static let body = Data("""
        {"five_hour":{"utilization":42,"resets_at":"2026-11-02T17:00:00Z"},
         "cedar_ember":{"eligible":true,"grants":[{"id":"g1","resets_left":1,"ends_at":"2026-11-09T00:00:00Z"}]}}
        """.utf8)

    @Test func `after Claude Code renews its login, allowing it again brings banked resets back, and turning reading off keeps them`() async throws {
        let clock = ManualClock(QuotaActorTests.start)
        let keychain = RenewedKeychain()
        let access = ClaudeLoginAccess(enabled: true)
        let endpoint = ClaudeUsageEndpointReader(
            credentials: KeychainClaudeCredentials(files: [], access: access, lookup: keychain.lookup),
            transport: StaticTransport(status: 200, body: Self.body), clock: clock)
        let fallback = CountingReader(.claudeCode, clock: clock)
        let live = try LiveIngestion(
            resources: IngestionActorTests.repositoryRoot.appending(path: "shared"), pricingUpdates: false,
            retention: .default, history: .default, alerts: AlertSettings(), weekStart: .monday, tracked: [],
            claudeLogin: access, location: StoreLocation(directory: TestDirectory.make("ClaudeLogin")),
            clock: clock, poster: RecordingPoster(.denied), readers: [FallbackQuotaReader([endpoint, fallback])],
            adapters: [])

        await live.quota.track(.claudeCode)
        #expect(access.status == .needsPermission && fallback.reads == 1)
        #expect(await live.quota.state(of: .claudeCode).heldResets.isEmpty)

        await live.allowClaudeLogin()
        #expect(access.status == .allowed && fallback.reads == 1)
        #expect(await live.quota.state(of: .claudeCode).heldResets.map(\.sourceResetID) == ["g1#1"])

        await live.readClaudeLogin(false)
        #expect(access.status == .off && fallback.reads == 2)
        #expect(await live.quota.state(of: .claudeCode).heldResets.map(\.sourceResetID) == ["g1#1"])
        #expect(keychain.prompts == [false, true])
    }
}
