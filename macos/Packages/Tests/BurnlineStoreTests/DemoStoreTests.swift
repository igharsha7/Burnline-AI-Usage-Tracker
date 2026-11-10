//
//  DemoStoreTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import Testing

/// Writes a demo store: half a year of invented Claude Code and Codex use
/// shaped like a working developer's (busier on weekdays and in the
/// afternoon, a week off, a long current streak, newer models over time),
/// a week of quota history, and `demo-quota.json` for `BURNLINE_DEMO_QUOTA`.
/// For screenshots and trying the app without real history. Off unless
/// `BURNLINE_DEMO_STORE` names the directory to write; the history ends at
/// `BURNLINE_DEMO_END` (seconds since 1970, normally now), on this Mac's
/// time zone. See docs/development.md for running the app on it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_DEMO_STORE"] != nil))
struct DemoStoreTests {
    static let days = 180
    /// Every day this recent is active, for a streak worth showing.
    static let streakDays = 74
    /// Days ago of a week with nothing in it.
    static let holiday = 96...102

    static let projects: [(name: String, weight: Double)] = [
        ("burnline", 9), ("orbit-notes", 6), ("pixel-garden", 4), ("trailmap", 3), ("recipe-box", 2),
        ("weather-cli", 1.5), ("portfolio", 1), ("dotfiles", 0.6),
    ]

    @Test func `write a demo store of invented usage`() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(filePath: try #require(environment["BURNLINE_DEMO_STORE"]))
        let end = Timestamp(epochSeconds: try #require(environment["BURNLINE_DEMO_END"].flatMap(Int64.init)))
        let fixture = try StoreFixture(keepingIn: directory)
        let database = try fixture.open()
        try database.models.sync(ModelAliasManifest.load(from: IngestionTests.manifestURL))
        try database.pricing.apply(PricingManifest.load(from: PricingStoreTests.shippedURL))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var rng = SplitMix64(seed: 0xB0B)
        var written = 0
        for daysAgo in stride(from: Self.days - 1, through: 0, by: -1) {
            let day = calendar.startOfDay(for: end.date.addingTimeInterval(-Double(daysAgo) * 86_400))
            let weekend = calendar.isDateInWeekend(day)
            guard !Self.holiday.contains(daysAgo) else { continue }
            if daysAgo >= Self.streakDays, rng.chance(weekend ? 0.45 : 0.9) == false { continue }
            // Use grows over the half year; weekends are lighter.
            let intensity = (0.45 + 0.55 * (1 - Double(daysAgo) / Double(Self.days))) * (weekend ? 0.5 : 1)
            let sessions = max(1, Int((2 + Double(rng.next(upTo: 5))) * intensity))
            for _ in 0..<sessions {
                let start = Int64(day.timeIntervalSince1970) + Self.startOfSession(&rng)
                guard start < end.epochSeconds - 1_800 else { continue }
                let records = Self.session(start: start, end: end.epochSeconds, daysAgo: daysAgo,
                                           intensity: intensity, rng: &rng)
                guard let first = records.first else { continue }
                let provider: ProviderKey = first.sourceType == SyntheticHistory.claudeType ? .claudeCode : .codex
                written += try database.ingest(records, issues: [], provider: provider).eventsWritten
            }
        }

        try writeQuota(database, end: end, to: directory.appending(path: "demo-quota.json"))
        print("DEMO wrote \(written) events to \(directory.path)")
        #expect(written > 0)
    }

    /// Seconds after midnight a session starts: mornings, a long afternoon
    /// and an evening, rarely after midnight.
    static func startOfSession(_ rng: inout SplitMix64) -> Int64 {
        let hours: [(Int64, Double)] = [(9, 2), (10, 4), (11, 4), (12, 1), (14, 5), (15, 5), (16, 4), (17, 3),
                                        (20, 2), (21, 3), (22, 2), (23, 1)]
        let total = hours.reduce(0) { $0 + $1.1 }
        var pick = Double(rng.next(upTo: 1_000_000)) / 1_000_000 * total
        for (hour, weight) in hours {
            pick -= weight
            if pick <= 0 { return hour * 3_600 + Int64(rng.next(upTo: 3_600)) }
        }
        return 15 * 3_600
    }

    static func session(start: Int64, end: Int64, daysAgo: Int, intensity: Double,
                        rng: inout SplitMix64) -> [IncomingUsage] {
        let claude = rng.chance(0.58)
        let model: String = claude
            ? (daysAgo < 60 ? rng.pick(["claude-opus-5-5": 7, "claude-sonnet-5-5": 2, "claude-haiku-4-5": 1])
                            : rng.pick(["claude-opus-5": 6, "claude-sonnet-5-5": 3, "claude-haiku-4-5": 1]))
            : (daysAgo < 45 ? rng.pick(["gpt-6.1-sol": 6, "gpt-5.5": 2, "gpt-5.4-mini": 1])
                            : daysAgo < 110 ? rng.pick(["gpt-5.6-sol": 5, "gpt-5.5": 3, "gpt-5.4-mini": 1])
                                            : rng.pick(["gpt-5.5": 5, "gpt-5.4": 3, "gpt-5.4-mini": 1]))
        let name = rng.pick(Dictionary(uniqueKeysWithValues: projects.map { ($0.name, $0.weight) }))
        let project = ProjectCandidate(identity: .gitRemote("github.com/demo/\(name)"), displayName: name,
                                       path: "/Users/demo/Developer/\(name)")
        let sessionID = claude ? rng.uuid() : rng.uuid(at: Timestamp(epochSeconds: start))
        let file = claude
            ? "/Users/demo/.claude/projects/-Users-demo-Developer-\(name)/\(sessionID).jsonl"
            : "/Users/demo/.codex/sessions/rollout-\(sessionID).jsonl"
        let events = 60 + Int(Double(rng.next(upTo: 300)) * intensity)

        var time = start
        var total: Int64 = 0
        var records: [IncomingUsage] = []
        for offset in 0..<events {
            time += Int64(rng.next(upTo: 50)) + 6
            guard time < end - 60 else { break }
            let output = Int64(rng.next(upTo: 1_500)) + 40
            let cached = Int64(rng.next(upTo: 160_000)) + 15_000
            total += output + cached
            let tokens = try! claude
                ? TokenCounts(input: Int64(rng.next(upTo: 6)), cachedInput: cached,
                              cacheWrite: Int64(rng.next(upTo: 8_000)), output: output)
                : TokenCounts(input: Int64(rng.next(upTo: 8_000)) + 400, cachedInput: cached,
                              output: output, reasoning: Int64(rng.next(upTo: 400)))
            let id = claude
                ? "msg_01\(rng.base62(22))"
                : "\(sessionID):\(Timestamp(epochSeconds: time).date.ISO8601Format()):\(total)"
            records.append(IncomingUsage(
                sourceEventID: id, sessionSourceID: sessionID, project: project, rawModel: model,
                timestamp: Timestamp(epochSeconds: time), tokens: tokens,
                serviceTier: claude ? "standard" : "default",
                sourceType: claude ? SyntheticHistory.claudeType : SyntheticHistory.codexType, file: file,
                schemaVersion: claude ? "2.1.0" : nil, offset: Int64(offset) * 4_096))
        }
        return records
    }

    /// The windows the demo shows now, and a week of history leading to them.
    struct Window {
        let provider: ProviderKey
        let key: String
        let name: String
        let seconds: Int64
        /// Percent used now, and seconds until the window resets.
        let now: Double
        let resetsIn: Int64
    }

    static let windows = [
        Window(provider: .claudeCode, key: "five_hour", name: "5-hour", seconds: 18_000, now: 62, resetsIn: 7_920),
        Window(provider: .claudeCode, key: "seven_day", name: "Weekly", seconds: 604_800, now: 41, resetsIn: 273_600),
        Window(provider: .claudeCode, key: "seven_day_opus", name: "Weekly · Opus", seconds: 604_800, now: 28,
               resetsIn: 273_600),
        Window(provider: .codex, key: "five_hour", name: "5-hour", seconds: 18_000, now: 23, resetsIn: 12_600),
        Window(provider: .codex, key: "weekly", name: "Weekly", seconds: 604_800, now: 58, resetsIn: 165_600),
    ]

    func writeQuota(_ database: BurnlineDatabase, end: Timestamp, to file: URL) throws {
        // Every half hour for a week: each window fills from its start and
        // empties at its reset. Earlier windows peak somewhere short of the
        // limit; the current one arrives at today's figure now.
        var rng = SplitMix64(seed: 0x51A7)
        for window in Self.windows {
            let reset = end.epochSeconds + window.resetsIn
            var peaks: [Int64: Double] = [:]
            for step in stride(from: end.epochSeconds - 7 * 86_400, through: end.epochSeconds, by: 1_800) {
                var windowEnd = reset
                while windowEnd - window.seconds > step { windowEnd -= window.seconds }
                let elapsed = Double(step - (windowEnd - window.seconds))
                let percent: Double
                if windowEnd == reset {
                    percent = elapsed * window.now / Double(window.seconds - window.resetsIn)
                } else {
                    if peaks[windowEnd] == nil { peaks[windowEnd] = 35 + Double(rng.next(upTo: 58)) }
                    percent = elapsed / Double(window.seconds) * peaks[windowEnd]!
                }
                try database.quota.append(QuotaSnapshot(
                    provider: window.provider, key: window.key, name: window.name, scope: .account,
                    observedAt: Timestamp(epochSeconds: step), used: nil, remaining: nil, limit: nil, unit: nil,
                    percentageUsed: percent, windowStartedAt: Timestamp(epochSeconds: windowEnd - window.seconds),
                    resetAt: Timestamp(epochSeconds: windowEnd), status: QuotaStatus(percentUsed: percent),
                    source: "demo"))
            }
        }

        func entry(_ provider: ProviderKey, plan: String, banked: [[String: Any]]) -> [String: Any] {
            ["plan": plan, "banked": banked,
             "windows": Self.windows.filter { $0.provider == provider }.map {
                 ["key": $0.key, "name": $0.name, "percent": $0.now, "resetsIn": $0.resetsIn,
                  "windowSeconds": $0.seconds] as [String: Any]
             }]
        }
        let quota: [String: Any] = [
            ProviderKey.claudeCode.rawValue: entry(.claudeCode, plan: "max", banked: []),
            ProviderKey.codex.rawValue: entry(.codex, plan: "pro",
                                              banked: [["id": "demo-reset", "appliesTo": "weekly",
                                                        "expiresIn": 6 * 86_400]]),
        ]
        try JSONSerialization.data(withJSONObject: quota, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
}

extension SplitMix64 {
    mutating func chance(_ probability: Double) -> Bool {
        Double(next(upTo: 1_000_000)) / 1_000_000 < probability
    }

    /// One of `weights`' keys, in proportion to its weight. Sorted first, so
    /// a seed always picks the same.
    mutating func pick(_ weights: [String: Double]) -> String {
        let sorted = weights.sorted { $0.key < $1.key }
        var draw = Double(next(upTo: 1_000_000)) / 1_000_000 * sorted.reduce(0) { $0 + $1.value }
        for (key, weight) in sorted {
            draw -= weight
            if draw <= 0 { return key }
        }
        return sorted[sorted.count - 1].key
    }
}
