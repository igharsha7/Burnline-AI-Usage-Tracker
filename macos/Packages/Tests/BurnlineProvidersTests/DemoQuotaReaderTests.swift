//
//  DemoQuotaReaderTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

// The reader exists only in debug builds; the performance job builds the
// tests in release.
#if DEBUG
import BurnlineCore
@testable import BurnlineProviders
import BurnlineTestSupport
import Foundation
import Testing

/// The invented quota a demo store shows: read from a file, with reset times
/// counted from the moment of reading so a demo stays current.
struct DemoQuotaReaderTests {
    static let now = Timestamp(epochSeconds: 1_793_541_600)

    func reader(_ provider: ProviderKey, json: String) throws -> DemoQuotaReader {
        let file = TestDirectory.file("demo-quota.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return DemoQuotaReader(provider: provider, file: file, clock: ManualClock(Self.now))
    }

    @Test func `windows and banked resets are read with their times counted from now`() async throws {
        let reader = try reader(.codex, json: """
            {"codex": {"plan": "pro",
                       "windows": [{"key": "five_hour", "name": "5-hour", "percent": 23,
                                    "resetsIn": 12600, "windowSeconds": 18000}],
                       "banked": [{"id": "r1", "appliesTo": "weekly", "expiresIn": 518400}]}}
            """)
        let reading = try await reader.read()

        #expect(reading.provider == .codex && reading.plan == "pro" && reading.source == "demo")
        #expect(reading.observedAt == Self.now)
        #expect(reading.windows == [QuotaWindowReading(key: "five_hour", name: "5-hour", percentUsed: 23,
                                                       resetAt: Self.now.adding(seconds: 12_600),
                                                       windowSeconds: 18_000)])
        #expect(reading.bankedResets == [BankedReset(provider: .codex, sourceResetID: "r1", appliesToQuotaKey: "weekly",
                                                     grantedAt: nil, expiresAt: Self.now.adding(seconds: 518_400),
                                                     consumedAt: nil, status: .held, source: "demo",
                                                     observedAt: Self.now)])
    }

    @Test func `a provider missing from the file reads as not signed in, and no banked list as unknown`() async throws {
        let json = #"{"claude_code": {"windows": []}}"#
        await #expect(throws: QuotaReadError.notSignedIn("No demo quota for this provider.")) {
            try await reader(.codex, json: json).read()
        }
        #expect(try await reader(.claudeCode, json: json).read().bankedResets == nil)
    }

    @Test func `a file that is not demo quota fails as unreachable`() async throws {
        await #expect(throws: QuotaReadError.unreachable("The demo quota file could not be read.")) {
            try await reader(.codex, json: "not json").read()
        }
    }
}
#endif
