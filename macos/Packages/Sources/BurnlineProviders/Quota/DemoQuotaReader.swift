//
//  DemoQuotaReader.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

#if DEBUG
import BurnlineCore
import Foundation

/// Invented quota for a demo store, read from a JSON file instead of any
/// account, so screenshots can show healthy limits without a login. Debug
/// builds only, chosen by `BURNLINE_DEMO_QUOTA`; see docs/development.md.
///
/// Reset times are given in seconds from now, so the figures stay current
/// however long after the file was written the demo runs:
///
///     {"claude_code": {"plan": "max",
///                      "windows": [{"key": "five_hour", "name": "5-hour", "percent": 62,
///                                   "resetsIn": 7200, "windowSeconds": 18000}],
///                      "banked": [{"id": "r1", "appliesTo": "weekly", "expiresIn": 432000}]}}
public struct DemoQuotaReader: QuotaReader {
    struct File: Decodable {
        struct Window: Decodable {
            let key: String
            let name: String
            let percent: Double
            let resetsIn: Int64?
            let windowSeconds: Int64?
        }
        struct Banked: Decodable {
            let id: String
            let appliesTo: String?
            let expiresIn: Int64?
        }
        let plan: String?
        let windows: [Window]
        let banked: [Banked]?
    }

    public let provider: ProviderKey
    let file: URL
    let clock: any WallClock

    public init(provider: ProviderKey, file: URL, clock: any WallClock) {
        self.provider = provider
        self.file = file
        self.clock = clock
    }

    public func read() async throws(QuotaReadError) -> QuotaReading {
        let providers: [String: File]
        do {
            providers = try JSONDecoder().decode([String: File].self, from: Data(contentsOf: file))
        } catch {
            throw .unreachable("The demo quota file could not be read.")
        }
        guard let entry = providers[provider.rawValue] else { throw .notSignedIn("No demo quota for this provider.") }
        let now = clock.now
        return QuotaReading(
            provider: provider, observedAt: now, source: "demo", scope: .account, plan: entry.plan,
            windows: entry.windows.map {
                QuotaWindowReading(key: $0.key, name: $0.name, percentUsed: $0.percent,
                                   resetAt: $0.resetsIn.map(now.adding(seconds:)), windowSeconds: $0.windowSeconds)
            },
            bankedResets: entry.banked.map { banked in
                banked.map {
                    BankedReset(provider: provider, sourceResetID: $0.id, appliesToQuotaKey: $0.appliesTo,
                                grantedAt: nil, expiresAt: $0.expiresIn.map(now.adding(seconds:)), consumedAt: nil,
                                status: .held, source: "demo", observedAt: now)
                }
            })
    }
}
#endif
