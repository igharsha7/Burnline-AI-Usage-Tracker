//
//  SyntheticHistory.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import Foundation

/// A seeded, deterministic usage history shaped like real Claude Code and
/// Codex use, for measuring the store at sizes no real machine has yet.
///
/// The shape comes from this machine's lifetime history (1 November 2026):
/// sessions of a few hundred events, a few seconds apart, in one file each;
/// a long tail of projects where a few take most of the work; event ids and
/// file paths of the real formats and lengths; token counts dominated by cache
/// reads. The same seed always yields the same history.
struct SyntheticHistory {
    struct Shape {
        var events: Int
        /// The span the sessions are spread over, ending at `end`.
        var years: Int = 5
        var end = Timestamp(epochSeconds: 1_793_491_200)   // 1 November 2026
        var projects = 200
        var meanSessionEvents = 300
        var seed: UInt64 = 0x5EED
    }

    /// One session's records, all from one provider, in batches of `batchSize`
    /// as the ingestion actor writes them.
    struct Batch {
        let provider: ProviderKey
        let records: [IncomingUsage]
    }

    static let claudeModels = ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-haiku-4-5"]
    static let codexModels = ["gpt-5.6-sol", "gpt-6.1-sol", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini"]
    static let batchSize = 1_000

    let shape: Shape

    /// Every batch, oldest session first.
    func batches() -> AnySequence<Batch> {
        AnySequence { () -> AnyIterator<Batch> in
            var rng = SplitMix64(seed: shape.seed)
            let span = Int64(shape.years) * 365 * 86_400
            let sessionCount = max(1, shape.events / shape.meanSessionEvents)
            let spacing = span / Int64(sessionCount)
            var remaining = shape.events
            var session = 0
            var pending: [Batch] = []
            return AnyIterator {
                while pending.isEmpty {
                    guard remaining > 0 else { return nil }
                    let count = session == sessionCount - 1
                        ? remaining
                        : min(remaining, Int(rng.next(upTo: UInt64(shape.meanSessionEvents * 2))) + 1)
                    let start = shape.end.epochSeconds - span + Int64(session) * spacing
                        + Int64(rng.next(upTo: UInt64(max(1, spacing / 2))))
                    let records = makeSession(session, events: count, start: start, rng: &rng)
                    pending = stride(from: 0, to: records.count, by: Self.batchSize).map {
                        Batch(provider: records[0].sourceType == Self.claudeType ? .claudeCode : .codex,
                              records: Array(records[$0..<min($0 + Self.batchSize, records.count)]))
                    }.reversed()
                    remaining -= count
                    session += 1
                }
                return pending.popLast()
            }
        }
    }

    static let claudeType = "claude_code_jsonl"
    static let codexType = "codex_rollout_jsonl"

    private func makeSession(_ index: Int, events: Int, start: Int64,
                             rng: inout SplitMix64) -> [IncomingUsage] {
        let claude = rng.next(upTo: 100) < 55
        // Squaring a uniform draw gives a few projects most of the sessions.
        let draw = Double(rng.next(upTo: 1_000_000)) / 1_000_000
        let projectIndex = Int(draw * draw * Double(shape.projects))
        let project = ProjectCandidate(identity: .gitRemote("github.com/burnline-synthetic/project-\(projectIndex)"),
                                       displayName: "project-\(projectIndex)",
                                       path: "/Users/someone/Developer/project-\(projectIndex)")
        let models = claude ? Self.claudeModels : Self.codexModels
        let model = models[Int(rng.next(upTo: UInt64(models.count)))]
        // Codex names sessions with time-ordered UUIDv7s; Claude Code with random v4s.
        let sessionID = claude ? rng.uuid() : rng.uuid(at: Timestamp(epochSeconds: start))
        let file = claude
            ? "/Users/someone/.claude/projects/-Users-someone-Developer-project-\(projectIndex)/\(sessionID).jsonl"
            : "/Users/someone/.codex/sessions/2026/02/03/rollout-2026-02-03T18-37-36-\(sessionID).jsonl.zst"

        var time = start
        var total: Int64 = 0
        return (0..<events).map { offset in
            time += Int64(rng.next(upTo: 55)) + 5
            let output = Int64(rng.next(upTo: 2_000)) + 1
            let cached = Int64(rng.next(upTo: 400_000))
            total += output + cached
            let tokens = try! claude
                ? TokenCounts(input: Int64(rng.next(upTo: 5)), cachedInput: cached,
                              cacheWrite: Int64(rng.next(upTo: 10_000)), output: output)
                : TokenCounts(input: Int64(rng.next(upTo: 12_000)), cachedInput: cached,
                              output: output, reasoning: Int64(rng.next(upTo: 300)))
            let id = claude
                ? "msg_01\(rng.base62(22))"
                : "\(sessionID):\(Timestamp(epochSeconds: time).date.ISO8601Format()):\(total)"
            return IncomingUsage(sourceEventID: id, sessionSourceID: sessionID, project: project, rawModel: model,
                                 timestamp: Timestamp(epochSeconds: time), tokens: tokens,
                                 serviceTier: claude ? "standard" : "default",
                                 sourceType: claude ? Self.claudeType : Self.codexType, file: file,
                                 schemaVersion: claude ? "2.1.0" : nil, offset: Int64(offset) * 4_096)
        }
    }
}

/// A small, fast generator with a fixed sequence for a given seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(upTo bound: UInt64) -> UInt64 { next() % bound }

    /// A random UUID, or with `instant`, one whose first 48 bits are its
    /// milliseconds, as a version 7 UUID's are.
    mutating func uuid(at instant: Timestamp? = nil) -> String {
        var high = next()
        if let instant { high = UInt64(instant.epochSeconds * 1_000) << 16 | (high & 0xFFFF) }
        let hex = String(format: "%016llx%016llx", high, next())
        let chars = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
    }

    mutating func base62(_ length: Int) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return String((0..<length).map { _ in alphabet[Int(next(upTo: 62))] })
    }
}
