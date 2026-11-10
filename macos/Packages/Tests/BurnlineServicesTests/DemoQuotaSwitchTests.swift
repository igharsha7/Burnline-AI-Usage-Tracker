//
//  DemoQuotaSwitchTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineProviders
@testable import BurnlineServices
import BurnlineTestSupport
import Testing

/// Invented quota replaces every real reader only when a demo asks for it.
struct DemoQuotaSwitchTests {
    let clock = ManualClock(Timestamp(epochSeconds: 1_793_541_600))

    @Test func `without BURNLINE_DEMO_QUOTA the real readers are kept`() {
        #expect(LiveIngestion.demoQuotaReaders(clock: clock, environment: [:]) == nil)
    }

    // The demo reader exists only in debug builds; the performance job builds
    // the tests in release.
    #if DEBUG
    @Test func `with BURNLINE_DEMO_QUOTA every provider reads the demo file instead`() throws {
        let readers = try #require(LiveIngestion.demoQuotaReaders(
            clock: clock, environment: ["BURNLINE_DEMO_QUOTA": "/tmp/demo-quota.json"]))
        #expect(readers.map(\.provider) == [.claudeCode, .codex])
        #expect(readers.allSatisfy { $0 is DemoQuotaReader })
    }
    #endif
}
