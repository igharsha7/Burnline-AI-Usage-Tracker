//
//  RepositoryTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineStore
import Foundation
import Testing

struct UsageRepositoryTests {
    @Test func `EC-I re-inserting the same events stores nothing new`() throws {
        let database = try StoreFixture().open()
        let events = try [StoreFixture.event("a"), StoreFixture.event("b")]
        #expect(try database.usage.insert(events) == 2)
        #expect(try database.usage.insert(events) == 0)
        #expect(try database.usage.count() == 2)
    }

    @Test func `the same source id from two providers is two events`() throws {
        let database = try StoreFixture().open()
        try database.usage.insert([StoreFixture.event("x", provider: .codex),
                                   StoreFixture.event("x", provider: .claudeCode)])
        #expect(try database.usage.count() == 2)
    }

    @Test func `an event round-trips with its tokens, cost, and provenance`() throws {
        let database = try StoreFixture().open()
        let model = try StoreFixture.insertModel("claude-opus-5", into: database)
        let version = try database.pricing.append(
            modelID: model, validFrom: Timestamp(epochSeconds: 0), validUntil: nil,
            rates: TokenRates(input: Nanodollars(decimalString: "15")), source: "test", confidence: .exact)
        let event = try StoreFixture.event(
            "priced", modelID: model,
            cost: .priced(Nanodollars(raw: 1_500), pricingVersionID: version.id, confidence: .exact))
        try database.usage.insert([event])

        let window = TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: .max))
        #expect(try database.usage.events(in: window) == [event])
    }

    @Test func `unpriced events come back with the reason they are unpriced`() throws {
        let database = try StoreFixture().open()
        let known = try StoreFixture.insertModel("claude-opus-5", into: database)
        let unpricedModel = try StoreFixture.insertModel("claude-new-release", into: database)
        let synthetic = try StoreFixture.insertModel("<synthetic>", kind: "non_model", into: database)
        // Priced only later, so an event before then falls in a gap.
        try database.pricing.append(modelID: known, validFrom: Timestamp(epochSeconds: 100), validUntil: nil,
                                    rates: TokenRates(), source: "test", confidence: .exact)
        try database.usage.insert([
            StoreFixture.event("unknown", at: 1, modelID: nil),
            StoreFixture.event("gap", at: 2, modelID: known),
            StoreFixture.event("synthetic", at: 3, modelID: synthetic),
            StoreFixture.event("never-priced", at: 4, modelID: unpricedModel),
        ])
        let window = TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: 10))
        #expect(try database.usage.events(in: window).map(\.cost) == [
            .unpriced(.unknownModel), .unpriced(.noPricingVersion), .unpriced(.nonModel), .unpriced(.unknownModel),
        ])
    }

    @Test func `unpriced is stored as NULL, never as zero`() throws {
        let database = try StoreFixture().open()
        try database.usage.insert([StoreFixture.event("u")])
        let cost = try database.read { try Int64?.fetchOne($0, sql: "SELECT cost_nanos FROM usage_events") }
        #expect(cost == .some(nil))
    }

    @Test func `events are selected by window and provider, start inclusive and end exclusive`() throws {
        let database = try StoreFixture().open()
        try database.usage.insert([
            StoreFixture.event("before", at: 99), StoreFixture.event("start", at: 100),
            StoreFixture.event("codex", at: 150, provider: .codex), StoreFixture.event("end", at: 200),
        ])
        let window = TimeWindow(start: Timestamp(epochSeconds: 100), end: Timestamp(epochSeconds: 200))
        #expect(try database.usage.events(in: window).map(\.source.eventID) == ["start", "codex"])
        #expect(try database.usage.events(in: window, provider: .codex).map(\.source.eventID) == ["codex"])
    }

    @Test func `EC-D5 a shorter retention reports what it would remove`() throws {
        let database = try StoreFixture().open()
        try database.usage.insert([StoreFixture.event("old", at: 10), StoreFixture.event("new", at: 1_000)])
        #expect(try database.usage.countBefore(Timestamp(epochSeconds: 500)) == 1)
        #expect(try database.usage.count() == 2)
    }
}

struct PricingRepositoryTests {
    @Test func `the version is chosen by its validity window, with gaps left unpriced`() throws {
        let database = try StoreFixture().open()
        let model = try StoreFixture.insertModel("m", into: database)
        let first = try database.pricing.append(
            modelID: model, validFrom: Timestamp(epochSeconds: 100), validUntil: Timestamp(epochSeconds: 200),
            rates: TokenRates(), source: "test", confidence: .exact)
        let second = try database.pricing.append(
            modelID: model, validFrom: Timestamp(epochSeconds: 300), validUntil: nil,
            rates: TokenRates(), source: "test", confidence: .estimated)

        #expect(try database.pricing.version(for: model, at: Timestamp(epochSeconds: 99)) == nil)
        #expect(try database.pricing.version(for: model, at: Timestamp(epochSeconds: 100)) == first)
        #expect(try database.pricing.version(for: model, at: Timestamp(epochSeconds: 250)) == nil)
        #expect(try database.pricing.version(for: model, at: Timestamp(epochSeconds: 300)) == second)
    }

    @Test func `an event exactly on a price change takes the newer price`() throws {
        let database = try StoreFixture().open()
        let model = try StoreFixture.insertModel("m", into: database)
        try database.pricing.append(
            modelID: model, validFrom: Timestamp(epochSeconds: 0), validUntil: Timestamp(epochSeconds: 500),
            rates: TokenRates(), source: "test", confidence: .exact)
        let newer = try database.pricing.append(
            modelID: model, validFrom: Timestamp(epochSeconds: 500), validUntil: nil,
            rates: TokenRates(input: Nanodollars(raw: 1)), source: "test", confidence: .exact)
        #expect(try database.pricing.version(for: model, at: Timestamp(epochSeconds: 500)) == newer)
    }
}

struct QuotaRepositoryTests {
    static func snapshot(at seconds: Int64, percentage: Double?, start: Int64? = 0,
                         reset: Int64? = 604_800) -> QuotaSnapshot {
        QuotaSnapshot(provider: .codex, key: "weekly", name: "Weekly", scope: .account,
                      observedAt: Timestamp(epochSeconds: seconds), used: nil, remaining: nil, limit: nil,
                      unit: "percent", percentageUsed: percentage,
                      windowStartedAt: start.map(Timestamp.init(epochSeconds:)),
                      resetAt: reset.map(Timestamp.init(epochSeconds:)),
                      status: .healthy, source: "test")
    }

    @Test func `the latest snapshot is the most recently observed`() throws {
        let database = try StoreFixture().open()
        try database.quota.append(Self.snapshot(at: 20, percentage: 60))
        try database.quota.append(Self.snapshot(at: 10, percentage: 30))
        #expect(try database.quota.latest(provider: .codex, key: "weekly") == Self.snapshot(at: 20, percentage: 60))
        #expect(try database.quota.latest(provider: .codex, key: "five_hour") == nil)
    }

    @Test func `a banked reset is one row whose status moves`() throws {
        let database = try StoreFixture().open()
        let held = BankedReset(provider: .codex, sourceResetID: "r1", appliesToQuotaKey: "weekly",
                               grantedAt: Timestamp(epochSeconds: 0), expiresAt: Timestamp(epochSeconds: 900),
                               consumedAt: nil, status: .held, source: "test",
                               observedAt: Timestamp(epochSeconds: 10))
        let consumed = BankedReset(provider: .codex, sourceResetID: "r1", appliesToQuotaKey: "weekly",
                                   grantedAt: Timestamp(epochSeconds: 0), expiresAt: Timestamp(epochSeconds: 900),
                                   consumedAt: Timestamp(epochSeconds: 50), status: .consumed, source: "test",
                                   observedAt: Timestamp(epochSeconds: 60))
        try database.quota.save(held)
        try database.quota.save(consumed)
        #expect(try database.quota.bankedResets(for: .codex) == [consumed])
    }

    @Test func `EC-Q2 a moved reset time does not split one quota cycle, and ends it at the latest reset`() throws {
        let database = try StoreFixture().open()
        try database.quota.append(Self.snapshot(at: 100, percentage: 60, start: 0, reset: 2_000))
        try database.quota.append(Self.snapshot(at: 200, percentage: 80, start: 0, reset: 1_000))
        let cycles = try database.quota.cycles()
        #expect(cycles.count == 1)
        #expect(cycles.first?.peak == 80 && cycles.first?.end == Timestamp(epochSeconds: 1_000))
    }

    @Test func `EC-Q2 a later observation without a reset retains the last reported cycle end`() throws {
        let database = try StoreFixture().open()
        try database.quota.append(Self.snapshot(at: 100, percentage: 60, start: 0, reset: 1_000))
        try database.quota.append(QuotaSnapshot(
            provider: .codex, key: "weekly", name: "Weekly", scope: .account,
            observedAt: Timestamp(epochSeconds: 200), used: nil, remaining: nil, limit: nil,
            unit: "percent", percentageUsed: 80, windowStartedAt: Timestamp(epochSeconds: 0),
            resetAt: nil, status: .healthy, source: "test"))
        let cycles = try database.quota.cycles()
        #expect(cycles.count == 1)
        #expect(cycles.first?.end == Timestamp(epochSeconds: 1_000))
        #expect(cycles.first?.peak == 80)
        // A known reset is still reported even if usage is temporarily unknown.
        try database.quota.append(Self.snapshot(at: 300, percentage: nil, start: 0, reset: 2_000))
        #expect(try database.quota.cycles().first?.end == Timestamp(epochSeconds: 2_000))
        // A start-only window has no known end and cannot be judged closed.
        try database.quota.append(Self.snapshot(at: 400, percentage: 50, start: 3_000, reset: nil))
        #expect(try database.quota.cycles().count == 1)
    }

    @Test func `EC-T6 elapsed reset times do not confirm a pacing medal window closed`() throws {
        let database = try StoreFixture().open()
        try database.quota.append(Self.snapshot(at: 100, percentage: 80, start: nil, reset: 1_000))
        let stale = try database.quota.cycles()
        #expect(stale.first?.isConfirmedClosed == false)
        let calendar = LocalCalendar(timeZone: .gmt, firstWeekday: .monday)
        let history = AchievementHistory(days: [], sessions: [], weeklyCycles: stale, calendar: calendar,
                                         now: Timestamp(epochSeconds: 2_000))
        #expect(!Achievement.earned(history).contains { $0.kind == .underTheLine })
        try database.quota.append(Self.snapshot(at: 1_100, percentage: 10, start: nil, reset: 2_000))
        let confirmed = try database.quota.cycles()
        #expect(confirmed.map(\.isConfirmedClosed) == [true, false])
        let refreshed = AchievementHistory(days: [], sessions: [], weeklyCycles: confirmed, calendar: calendar,
                                           now: Timestamp(epochSeconds: 2_000))
        #expect(Achievement.earned(refreshed).filter { $0.kind == .underTheLine }.count == 1)
    }

    @Test func `windows from a source with no start stay apart, one per reset`() throws {
        let database = try StoreFixture().open()
        try database.quota.append(Self.snapshot(at: 100, percentage: 60, start: nil, reset: 604_800))
        try database.quota.append(Self.snapshot(at: 700_000, percentage: 30, start: nil, reset: 1_209_600))
        #expect(try database.quota.cycles().map(\.peak) == [60, 30])
    }
}

struct SourceStateRepositoryTests {
    @Test func `an ingestion offset is saved and updated in place`() throws {
        let database = try StoreFixture().open()
        var state = SourceState(provider: .claudeCode, identifier: "/x.jsonl", inode: 42, fileSize: 100,
                                lastOffset: 100)
        try database.sourceStates.save(state)
        state.lastOffset = 250
        state.fileSize = 250
        try database.sourceStates.save(state)
        #expect(try database.sourceStates.state(provider: .claudeCode, identifier: "/x.jsonl") == state)
        #expect(try database.sourceStates.state(provider: .codex, identifier: "/x.jsonl") == nil)
    }
}

struct ProjectRepositoryTests {
    @Test func `EC-P7 remerging a redirected project into its descendant refuses a cycle`() throws {
        let database = try StoreFixture().open()
        let ids = try ["a", "b", "c"].map { name in
            try database.projects.findOrCreate(identity: .path(pathHash: name), displayName: name,
                                                path: nil, seenAt: Timestamp(epochSeconds: 1)).id
        }
        try database.projects.merge(ids[0], into: ids[1])
        try database.projects.merge(ids[2], into: ids[0])
        #expect(throws: StoreError.self) { try database.projects.merge(ids[0], into: ids[2]) }
        #expect(try database.projects.resolve(ids[2]) == ids[1])
    }

    @Test func `a project is found again by its identity, not duplicated`() throws {
        let database = try StoreFixture().open()
        let identity = ProjectIdentity.gitRemote("github.com/igharsha7/burnline")
        let first = try database.projects.findOrCreate(identity: identity, displayName: "burnline",
                                                       path: "/a", seenAt: Timestamp(epochSeconds: 10))
        let again = try database.projects.findOrCreate(identity: identity, displayName: "Burnline",
                                                       path: "/b", seenAt: Timestamp(epochSeconds: 20))
        let earlier = try database.projects.findOrCreate(identity: identity, displayName: "old-name",
                                                         path: "/c", seenAt: Timestamp(epochSeconds: 5))
        #expect(again.id == first.id)
        // The latest sighting names it; an older one read late does not.
        #expect(again.displayName == "Burnline")
        #expect(earlier.displayName == "Burnline")
        #expect(again.lastKnownPath == "/b")
        #expect(again.firstSeenAt == Timestamp(epochSeconds: 10))
        #expect(again.lastSeenAt == Timestamp(epochSeconds: 20))
    }

    @Test func `a merge redirects without rewriting and can be undone`() throws {
        let database = try StoreFixture().open()
        let a = try database.projects.findOrCreate(identity: .path(pathHash: "a"), displayName: "a",
                                                   path: nil, seenAt: Timestamp(epochSeconds: 1)).id
        let b = try database.projects.findOrCreate(identity: .path(pathHash: "b"), displayName: "b",
                                                   path: nil, seenAt: Timestamp(epochSeconds: 1)).id
        let c = try database.projects.findOrCreate(identity: .path(pathHash: "c"), displayName: "c",
                                                   path: nil, seenAt: Timestamp(epochSeconds: 1)).id
        try database.projects.merge(a, into: b)
        try database.projects.merge(b, into: c)
        #expect(try database.projects.resolve(a) == c)

        #expect(throws: StoreError.self) { try database.projects.merge(c, into: a) }
        #expect(throws: StoreError.self) { try database.projects.merge(a, into: a) }

        try database.projects.unmerge(a)
        #expect(try database.projects.resolve(a) == a)
    }

    @Test func `a session widens its span as it is seen again`() throws {
        let database = try StoreFixture().open()
        _ = try database.sessions.findOrCreate(provider: .codex, sourceSessionID: "s", projectID: nil,
                                               seenAt: Timestamp(epochSeconds: 100))
        _ = try database.sessions.findOrCreate(provider: .codex, sourceSessionID: "s", projectID: nil,
                                               seenAt: Timestamp(epochSeconds: 50))
        let session = try database.sessions.findOrCreate(provider: .codex, sourceSessionID: "s", projectID: nil,
                                                         seenAt: Timestamp(epochSeconds: 300))
        #expect(session.startedAt == Timestamp(epochSeconds: 50))
        #expect(session.endedAt == Timestamp(epochSeconds: 300))
    }

    @Test func `EC-P7 merged project identities count as one first use`() throws {
        let database = try StoreFixture().open()
        let ids = try ["a", "b"].map { name in
            try database.projects.findOrCreate(identity: .path(pathHash: name), displayName: name,
                                                path: nil, seenAt: Timestamp(epochSeconds: 1)).id
        }
        let events = try ids.enumerated().map { index, projectID in
            UsageEvent(provider: .claudeCode, modelID: nil, sessionID: nil, projectID: projectID,
                       timestamp: Timestamp(epochSeconds: Int64(index + 1) * 900),
                       tokens: try TokenCounts(input: 1), cost: .unpriced(.unknownModel),
                       source: SourceReference(sourceType: "test", file: nil, eventID: "project-\(index)",
                                               schemaVersion: nil, offset: 0))
        }
        try database.usage.insert(events)
        try database.projects.merge(ids[0], into: ids[1])
        #expect(try database.aggregation.firstUses().projects.count == 1)
    }

    @Test func `EC-P7 a day's tokens by project count a merged project under the one it joined`() throws {
        let database = try StoreFixture().open()
        let ids = try ["a", "b", "c"].map { name in
            try database.projects.findOrCreate(identity: .path(pathHash: name), displayName: name,
                                                path: nil, seenAt: Timestamp(epochSeconds: 1)).id
        }
        let events = try [(ids[0], 900), (ids[1], 1_800), (ids[2], 86_400 + 900)].enumerated().map { index, entry in
            UsageEvent(provider: .claudeCode, modelID: nil, sessionID: nil, projectID: entry.0,
                       timestamp: Timestamp(epochSeconds: Int64(entry.1)),
                       tokens: try TokenCounts(input: 10, cachedInput: 5, output: 1), cost: .unpriced(.unknownModel),
                       source: SourceReference(sourceType: "test", file: nil, eventID: "day-\(index)",
                                               schemaVersion: nil, offset: 0))
        }
        try database.usage.insert(events)
        try database.projects.merge(ids[0], into: ids[1])
        let days = [TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: 86_400)),
                    TimeWindow(start: Timestamp(epochSeconds: 86_400), end: Timestamp(epochSeconds: 172_800))]
        let tokens = try database.aggregation.projectTokens(in: days)
        #expect(tokens == [[ids[1]: 32], [ids[2]: 16]])
        #expect(try database.aggregation.modelCounts(in: days) == [0, 0])
    }
}

struct AchievementRepositoryTests {
    static func streak(_ days: Int64, at seconds: Int64) -> Achievement {
        Achievement(kind: .streak, tier: String(days), value: days, awardedAt: Timestamp(epochSeconds: seconds))
    }

    @Test func `each award is announced once and celebrated once, and the first awards are flagged`() throws {
        let database = try StoreFixture().open()
        let week = Self.streak(7, at: 100), month = Self.streak(30, at: 400)
        try database.achievements.award([week], at: Timestamp(epochSeconds: 200))
        let first = try database.achievements.takeUnannounced(at: Timestamp(epochSeconds: 300))
        #expect(first.achievements == [week] && first.firstEver)

        try database.achievements.award([month], at: Timestamp(epochSeconds: 500))
        let second = try database.achievements.takeUnannounced(at: Timestamp(epochSeconds: 600))
        #expect(second.achievements == [month] && !second.firstEver)
        #expect(try database.achievements.takeUnannounced(at: Timestamp(epochSeconds: 700)).achievements.isEmpty)

        #expect(try database.achievements.uncelebrated() == [week, month])
        try database.achievements.celebrate([week, month], at: Timestamp(epochSeconds: 800))
        #expect(try database.achievements.uncelebrated().isEmpty)
    }

    @Test func `a medal earned during an arrival remains uncelebrated`() throws {
        let database = try StoreFixture().open()
        let week = Self.streak(7, at: 100), month = Self.streak(30, at: 400)
        try database.achievements.award([week], at: Timestamp(epochSeconds: 200))
        let presented = try database.achievements.uncelebrated()
        #expect(presented == [week])
        try database.achievements.award([month], at: Timestamp(epochSeconds: 500))
        try database.achievements.celebrate(presented, at: Timestamp(epochSeconds: 600))
        #expect(try database.achievements.uncelebrated() == [month])
    }
}

struct AchievementFirstUseTests {
    @Test func `EC-M1 non-model usage does not advance model medals`() throws {
        let database = try StoreFixture().open()
        let model = try StoreFixture.insertModel("real-model", into: database)
        let synthetic = try StoreFixture.insertModel("<synthetic>", kind: "non_model", into: database)
        try database.usage.insert([
            StoreFixture.event("real", at: 900, modelID: model),
            StoreFixture.event("synthetic", at: 1_800, modelID: synthetic),
        ])
        #expect(try database.aggregation.firstUses().models == [Timestamp(epochSeconds: 900)])
    }
}
