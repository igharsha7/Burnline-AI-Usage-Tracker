//
//  QuotaActorTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineProviders
@testable import BurnlineServices
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import Testing

/// A reader that answers from a queue, one result per read.
final class QueuedReader: QuotaReader, @unchecked Sendable {
    // @unchecked: `queue` is only touched under `lock`.
    private let lock = NSLock()
    private var queue: [Result<QuotaReading, QuotaReadError>]
    let provider: ProviderKey

    init(_ provider: ProviderKey, _ results: [Result<QuotaReading, QuotaReadError>]) {
        self.provider = provider
        queue = results
    }

    func enqueue(_ result: Result<QuotaReading, QuotaReadError>) { lock.withLock { queue.append(result) } }

    func read() async throws(QuotaReadError) -> QuotaReading {
        let next = lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
        guard let next else { throw .unreachable("no scripted answer") }
        return try next.get()
    }
}

struct FixedPower: PowerSource {
    let onBattery: Bool
}

struct QuotaActorTests {
    static let start = Timestamp(epochSeconds: 1_793_541_600)
    static let hour: Int64 = 3_600

    static func database(_ clock: ManualClock) throws -> BurnlineDatabase {
        try BurnlineDatabase.open(
            at: StoreLocation(directory: TestDirectory.make("Quota")),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")),
            clock: clock)
    }

    static func reading(_ provider: ProviderKey = .codex, at time: Timestamp,
                        _ windows: [(String, Double, Timestamp)], resets: [BankedReset]? = nil) -> QuotaReading {
        QuotaReading(provider: provider, observedAt: time, source: "test", scope: .account, plan: "plus",
                     windows: windows.map { QuotaWindowReading(key: $0.0, name: $0.0, percentUsed: $0.1, resetAt: $0.2,
                                                               windowSeconds: 5 * hour) },
                     bankedResets: resets)
    }

    static func held(_ id: String, expires: Timestamp) -> BankedReset {
        BankedReset(provider: .codex, sourceResetID: id, appliesToQuotaKey: "codex", grantedAt: nil, expiresAt: expires,
                    consumedAt: nil, status: .held, source: "test", observedAt: start)
    }

    /// The events of every update `log` was handed.
    final class UpdateLog: @unchecked Sendable {
        // @unchecked: `updates` is only touched under `lock`.
        private let lock = NSLock()
        private var updates: [QuotaUpdate] = []
        func append(_ update: QuotaUpdate) { lock.withLock { updates.append(update) } }
        var events: [QuotaEvent] { lock.withLock { updates.flatMap(\.events) } }
        var all: [QuotaUpdate] { lock.withLock { updates } }
    }

    @Test func `a read is shown, recorded, and labelled as the account's`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let reset = Self.start.adding(seconds: 3 * Self.hour)
        let reader = QueuedReader(.codex, [.success(Self.reading(at: Self.start, [("five_hour", 40, reset)]))])
        let actor = QuotaActor(database: database, readers: [reader], clock: clock, power: FixedPower(onBattery: false))
        let state = await actor.refresh(.codex)
        #expect(state.health == .ok && state.plan == "plus" && !state.isStale(at: Self.start))
        #expect(state.windows.map(\.percentageUsed) == [40])
        // Every figure says whose usage it is.
        #expect(state.windows.allSatisfy { $0.scope == .account })
        #expect(try database.quota.latest(provider: .codex).map(\.percentageUsed) == [40])
    }

    @Test func `EC-T6 a read during reset grace keeps the confirmation deadline`() async throws {
        let clock = ManualClock(Self.start)
        let reset = Self.start.adding(seconds: 10)
        let reader = QueuedReader(.codex, [
            .success(Self.reading(at: Self.start, [("five_hour", 40, reset)])),
            .success(Self.reading(at: reset.adding(seconds: 5), [("five_hour", 40, reset)])),
        ])
        let actor = QuotaActor(database: try Self.database(clock), readers: [reader], clock: clock,
                               power: FixedPower(onBattery: false))
        await actor.refresh(.codex)
        clock.set(reset.adding(seconds: 5))
        await actor.refresh(.codex)
        #expect(await actor.nextRefresh(.codex) == reset.adding(seconds: QuotaSchedule.resetGrace))
    }

    @Test func `an unchanged figure is recorded once an hour, not at every read`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let reset = Self.start.adding(seconds: 4 * Self.hour)
        let reader = QueuedReader(.codex, [])
        let actor = QuotaActor(database: database, readers: [reader], clock: clock, power: FixedPower(onBattery: false))
        for minutes: Int64 in [0, 15, 30, 61] {
            let time = Self.start.adding(seconds: minutes * 60)
            clock.set(time)
            reader.enqueue(.success(Self.reading(at: time, [("five_hour", 40, reset)])))
            await actor.refresh(.codex)
        }
        let rows = try database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM quota_snapshots") }
        #expect(rows == 2)
    }

    @Test func `EC-Q3 an unreachable provider keeps its last figures, stale, never zero`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let reset = Self.start.adding(seconds: 3 * Self.hour)
        let reader = QueuedReader(.codex, [.success(Self.reading(at: Self.start, [("five_hour", 72, reset)])),
                                           .failure(.unreachable("offline"))])
        let actor = QuotaActor(database: database, readers: [reader], clock: clock, power: FixedPower(onBattery: false))
        await actor.refresh(.codex)
        clock.advance(seconds: 18 * 60)
        let state = await actor.refresh(.codex)
        #expect(state.windows.map(\.percentageUsed) == [72])
        #expect(state.isStale(at: clock.now) && state.age(at: clock.now) == 18 * 60)
        guard case .degraded(let reason, let since) = state.health else { Issue.record("not degraded"); return }
        #expect(reason.contains("offline") && since == clock.now)
    }

    @Test func `EC-Q3 an older fallback cannot rewind quota or invent a reset`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let reset = Self.start.adding(seconds: 3 * Self.hour)
        let reader = QueuedReader(.codex, [
            .success(Self.reading(at: Self.start, [("five_hour", 95, reset)])),
            .success(Self.reading(at: Self.start.adding(seconds: -600), [("five_hour", 0, reset)])),
        ])
        let log = UpdateLog()
        let actor = QuotaActor(database: database, readers: [reader], clock: clock,
                               power: FixedPower(onBattery: false), onUpdate: { log.append($0) })
        await actor.refresh(.codex)
        let state = await actor.refresh(.codex)
        #expect(state.windows.map(\.percentageUsed) == [95])
        #expect(state.isStale(at: clock.now))
        #expect(log.all.count == 1 && log.events.isEmpty)
        #expect(try database.quota.history(provider: .codex, key: "five_hour", since: Self.start.adding(seconds: -600)).count == 1)
    }

    @Test func `EC-Q4 an expired login degrades quota and nothing else`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let claude = QueuedReader(.claudeCode, [.failure(.credentialExpired)])
        let codex = QueuedReader(.codex, [.success(Self.reading(at: Self.start,
                                                                [("five_hour", 10, Self.start.adding(seconds: Self.hour))]))])
        let actor = QuotaActor(database: database, readers: [claude, codex], clock: clock,
                               power: FixedPower(onBattery: false))
        await actor.refreshAll()
        let states = await actor.states()
        #expect(states[0].health == .degraded(reason: QuotaReadError.credentialExpired.reason, since: Self.start))
        #expect(states[1].health == .ok && states[1].windows.count == 1)
    }

    @Test func `an untracked provider's quota is never read, until it is tracked`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let claude = QueuedReader(.claudeCode, [.success(Self.reading(.claudeCode, at: Self.start,
                                                                      [("five_hour", 10, Self.start.adding(seconds: Self.hour))]))])
        let actor = QuotaActor(database: database, readers: [claude], tracked: [], clock: clock,
                               power: FixedPower(onBattery: false))
        await actor.refreshAll()
        #expect(await actor.states().isEmpty)
        #expect(await actor.state(of: .claudeCode).windows.isEmpty)

        await actor.track(.claudeCode)
        #expect(await actor.states().first?.windows.count == 1)
    }

    @Test func `an account without limits is unavailable, not failing`() async throws {
        let clock = ManualClock(Self.start)
        let reader = QueuedReader(.claudeCode, [.failure(.unsupported("API key"))])
        let actor = QuotaActor(database: try Self.database(clock), readers: [reader], clock: clock,
                               power: FixedPower(onBattery: false))
        #expect(await actor.refresh(.claudeCode).health == .unavailable(reason: "API key"))
    }

    @Test func `EC-Q1 EC-Q7 a banked reset and a scheduled one in the same read are separate events`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let fiveHourReset = Self.start.adding(seconds: 3 * Self.hour)
        let weeklyReset = Self.start.adding(seconds: -60)
        let reader = QueuedReader(.codex, [
            .success(Self.reading(at: Self.start.adding(seconds: -120),
                                  [("five_hour", 94, fiveHourReset), ("weekly", 80, weeklyReset)])),
        ])
        let log = UpdateLog()
        let actor = QuotaActor(database: database, readers: [reader], clock: clock, power: FixedPower(onBattery: false),
                               onUpdate: { log.append($0) })
        await actor.refresh(.codex)
        reader.enqueue(.success(Self.reading(at: Self.start, [
            ("five_hour", 0, Self.start.adding(seconds: 5 * Self.hour)),
            ("weekly", 1, weeklyReset.adding(seconds: 7 * 86_400)),
        ])))
        await actor.refresh(.codex)
        let events = log.events
        let resets = events.compactMap { event -> (String, Bool)? in
            if case .windowReset(_, let key, _, let cause) = event { return (key, cause == .scheduled) }
            return nil
        }
        #expect(resets.map(\.0) == ["five_hour", "weekly"] && resets.map(\.1) == [false, true])
    }

    static func causes(_ log: UpdateLog) -> [ResetCause] {
        log.events.compactMap { event -> ResetCause? in
            if case .windowReset(_, _, _, let cause) = event { return cause }
            return nil
        }
    }

    /// Reads 80% with a banked reset held, then 0% at each of `later`
    /// (minutes, and whether the banked reset is still listed).
    static func earlyReset(then later: [(Int64, Bool)]) async throws -> (UpdateLog, [QuotaUpdate]) {
        let clock = ManualClock(start)
        let database = try database(clock)
        let reset = start.adding(seconds: 3 * hour)
        let held = held("rc_1", expires: start.adding(seconds: 86_400))
        let log = UpdateLog()
        let reader = QueuedReader(.codex, [.success(reading(at: start, [("five_hour", 80, reset)], resets: [held]))])
        let actor = QuotaActor(database: database, readers: [reader], clock: clock, power: FixedPower(onBattery: false),
                               onUpdate: { log.append($0) })
        await actor.refresh(.codex)
        for (minutes, listed) in later {
            let time = start.adding(seconds: minutes * 60)
            clock.set(time)
            reader.enqueue(.success(reading(at: time, [("five_hour", 0, reset)], resets: listed ? [held] : [])))
            await actor.refresh(.codex)
        }
        return (log, log.all)
    }

    @Test func `a banked reset spent in the same read explains an early reset at once`() async throws {
        let (log, _) = try await Self.earlyReset(then: [(5, false)])
        #expect(Self.causes(log) == [.bankedReset])
    }

    @Test func `a banked reset that shows as spent a read late still explains the reset`() async throws {
        let (log, updates) = try await Self.earlyReset(then: [(5, true), (10, false)])
        #expect(Self.causes(log) == [.bankedReset])
        // Nothing was said until it was explained.
        #expect(updates[1].events.allSatisfy { if case .windowReset = $0 { false } else { true } })
    }

    @Test func `with no banked reset spent within the grace, the provider reset usage itself`() async throws {
        let (log, updates) = try await Self.earlyReset(then: [(5, true), (10, true), (15, true)])
        #expect(Self.causes(log) == [.provider])
        // Explained at the read ten minutes after the reset was seen, with the
        // figure from before the reset.
        #expect(!updates[2].events.contains { if case .windowReset = $0 { true } else { false } })
        #expect(updates[3].events.contains { if case .windowReset = $0 { true } else { false } })
        #expect(updates[3].previous["five_hour"]?.percentageUsed == 80)
    }

    @Test func `a source blind to banked resets leaves an early reset unexplained`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let reset = Self.start.adding(seconds: 3 * Self.hour)
        let log = UpdateLog()
        let reader = QueuedReader(.codex, [.success(Self.reading(at: Self.start, [("five_hour", 80, reset)])),
                                           .success(Self.reading(at: Self.start, [("five_hour", 0, reset)]))])
        let actor = QuotaActor(database: database, readers: [reader], clock: clock, power: FixedPower(onBattery: false),
                               onUpdate: { log.append($0) })
        await actor.refresh(.codex)
        await actor.refresh(.codex)
        guard case .windowReset(_, _, _, .early) = log.events.first else {
            Issue.record("\(log.events)"); return
        }
    }

    @Test(arguments: [false, true])
    func `EC-Q1 a pending reset survives restart and is explained only once`(spent: Bool) async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let reset = Self.start.adding(seconds: 3 * Self.hour)
        let held = Self.held("rc_restart", expires: Self.start.adding(seconds: 86_400))
        let reader = QueuedReader(.codex, [])
        let first = QuotaActor(database: database, readers: [reader], clock: clock, power: FixedPower(onBattery: false))
        for (minutes, percent): (Int64, Double) in [(0, 80), (5, 0)] {
            clock.set(Self.start.adding(seconds: minutes * 60))
            reader.enqueue(.success(Self.reading(at: clock.now, [("five_hour", percent, reset)], resets: [held])))
            await first.refresh(.codex)
        }
        clock.set(Self.start.adding(seconds: 15 * 60))
        let log = UpdateLog()
        let resumed = QuotaActor(database: database, readers: [reader], clock: clock,
                                 power: FixedPower(onBattery: false), onUpdate: { log.append($0) })
        reader.enqueue(.success(Self.reading(at: clock.now, [("five_hour", 0, reset)], resets: spent ? [] : [held])))
        await resumed.refresh(.codex)
        #expect(Self.causes(log) == [spent ? .bankedReset : .provider])
        #expect(log.all.last?.previous["five_hour"]?.percentageUsed == 80)

        let again = QuotaActor(database: database, readers: [reader], clock: clock,
                               power: FixedPower(onBattery: false), onUpdate: { log.append($0) })
        reader.enqueue(.success(Self.reading(at: clock.now, [("five_hour", 0, reset)], resets: spent ? [] : [held])))
        await again.refresh(.codex)
        #expect(Self.causes(log).count == 1)
    }

    @Test func `EC-Q7 an obsolete pending reset cannot overwrite a later scheduled reset`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let reset = Self.start.adding(seconds: 600)
        let log = UpdateLog()
        let reader = QueuedReader(.codex, [])
        let actor = QuotaActor(database: database, readers: [reader], clock: clock,
                               power: FixedPower(onBattery: false), onUpdate: { log.append($0) })
        for (seconds, percent, end): (Int64, Double, Timestamp) in [
            (0, 100, reset), (300, 0, reset), (900, 1, reset.adding(seconds: 5 * Self.hour)),
        ] {
            clock.set(Self.start.adding(seconds: seconds))
            reader.enqueue(.success(Self.reading(at: clock.now, [("five_hour", percent, end)], resets: [])))
            await actor.refresh(.codex)
        }
        let last = try #require(log.all.last)
        #expect(Self.causes(log) == [.scheduled])
        #expect(last.previous["five_hour"]?.percentageUsed == 0)
    }

    @Test func `EC-Q6 banked resets are kept, and one that vanishes becomes unknown`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let reset = Self.start.adding(seconds: Self.hour)
        let held = Self.held("rc_1", expires: Self.start.adding(seconds: 86_400))
        let reader = QueuedReader(.codex, [.success(Self.reading(at: Self.start, [("five_hour", 50, reset)], resets: [held])),
                                           .success(Self.reading(at: Self.start, [("five_hour", 50, reset)], resets: []))])
        let actor = QuotaActor(database: database, readers: [reader], clock: clock, power: FixedPower(onBattery: false))
        #expect(await actor.refresh(.codex).heldResets.map(\.sourceResetID) == ["rc_1"])
        let state = await actor.refresh(.codex)
        #expect(state.bankedResets.map(\.status) == [.unknown] && state.heldResets.isEmpty)
        #expect(try database.quota.bankedResets(for: .codex).map(\.status) == [.unknown])
    }

    @Test func `EC-T5 after a restart the last figures are stale until a read confirms them`() async throws {
        let clock = ManualClock(Self.start)
        let database = try Self.database(clock)
        let reset = Self.start.adding(seconds: Self.hour)
        let first = QuotaActor(database: database, readers: [QueuedReader(.codex, [
            .success(Self.reading(at: Self.start, [("five_hour", 88, reset)]))])],
                               clock: clock, power: FixedPower(onBattery: false))
        await first.refresh(.codex)

        // Asleep past the reset time.
        clock.advance(seconds: 2 * Self.hour)
        let reader = QueuedReader(.codex, [])
        let log = UpdateLog()
        let second = QuotaActor(database: database, readers: [reader], clock: clock, power: FixedPower(onBattery: false),
                                onUpdate: { log.append($0) })
        let resumed = await second.state(of: .codex)
        #expect(resumed.isStale(at: clock.now) && resumed.windows.map(\.percentageUsed) == [88])
        #expect(resumed.windows.first?.status(at: clock.now) == .resetPending)
        reader.enqueue(.success(Self.reading(at: clock.now, [("five_hour", 3, reset.adding(seconds: 5 * Self.hour))])))
        await second.refreshAll()
        let events = log.events
        guard case .windowReset(_, "five_hour", _, .scheduled) = events.first else {
            Issue.record("no scheduled reset: \(events)"); return
        }
    }

    @Test func `no token reaches the database or anything Burnline could log`() async throws {
        let sentinel = "sk-ant-oat01-BURNLINE-SENTINEL-NEVER-STORED"
        let clock = ManualClock(Self.start)
        let directory = TestDirectory.make("QuotaSecrets")
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: directory),
            schema: Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema")), clock: clock)
        let body = Data("""
            {"five_hour":{"utilization":42,"resets_at":"2026-11-02T17:00:00Z"},
             "cedar_ember":{"eligible":true,"grants":[{"id":"g1","resets_left":1,"ends_at":"2026-11-09T00:00:00Z"}]}}
            """.utf8)
        let endpoint = ClaudeUsageEndpointReader(credentials: SentinelCredentials(token: sentinel),
                                                 transport: StaticTransport(status: 200, body: body), clock: clock)
        let refused = ClaudeUsageEndpointReader(credentials: SentinelCredentials(token: sentinel),
                                                transport: StaticTransport(status: 401, body: Data(sentinel.utf8)),
                                                clock: clock)
        let actor = QuotaActor(database: database, readers: [endpoint], clock: clock, power: FixedPower(onBattery: false))
        let good = await actor.refresh(.claudeCode)
        let failing = QuotaActor(database: database, readers: [refused], clock: clock, power: FixedPower(onBattery: false))
        let bad = await failing.refresh(.claudeCode)
        #expect(good.windows.count == 1 && good.heldResets.count == 1)

        // Everything Burnline could print about quota: states, health reasons and events.
        var printed = "\(good) \(bad) \(String(reflecting: good)) \(String(reflecting: bad))"
        for case .degraded(let reason, _) in [good.health, bad.health] { printed += reason }
        #expect(!printed.contains(sentinel))

        try await database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let bytes = try? Data(contentsOf: file) else { continue }
            #expect(bytes.range(of: Data(sentinel.utf8)) == nil, "\(file.lastPathComponent)")
        }
    }
}

struct SentinelCredentials: ClaudeCredentialSource {
    let token: String
    func login(at now: Timestamp) throws(QuotaReadError) -> ClaudeLogin { ClaudeLogin(token: SecretString(token)) }
}

struct StaticTransport: HTTPTransport {
    let status: Int
    let body: Data
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// When quota is read: conservative, slower when idle or on battery, and
/// backing off after failures.
struct QuotaScheduleTests {
    static let now = Timestamp(epochSeconds: 1_793_541_600)
    typealias Inputs = QuotaSchedule.Inputs

    static func wait(_ inputs: Inputs) -> Int64 {
        QuotaSchedule.next(inputs, now: now).seconds(since: inputs.lastAttempt ?? now)
    }

    @Test func `the first read is immediate`() {
        #expect(QuotaSchedule.next(Inputs(), now: Self.now) == Self.now)
    }

    @Test func `idle, in use, on battery and near a limit each set the interval`() {
        let last = Self.now.adding(seconds: -10)
        #expect(Self.wait(Inputs(lastAttempt: last)) == QuotaSchedule.idleInterval)
        #expect(Self.wait(Inputs(lastAttempt: last, lastUsage: Self.now)) == QuotaSchedule.activeInterval)
        #expect(Self.wait(Inputs(lastAttempt: last, onBattery: true)) == 2 * QuotaSchedule.idleInterval)
        #expect(Self.wait(Inputs(lastAttempt: last, nearLimit: true, onBattery: true)) == QuotaSchedule.criticalInterval)
    }

    @Test func `failures back off by doubling, up to half an hour`() {
        let waits = (1...8).map { Self.wait(Inputs(lastAttempt: Self.now, consecutiveFailures: $0)) }
        #expect(waits == [60, 120, 240, 480, 960, 1_800, 1_800, 1_800])
    }

    @Test func `EC-T6 a reset before the next read brings the read forward`() {
        let reset = Self.now.adding(seconds: 120)
        #expect(QuotaSchedule.next(Inputs(lastAttempt: Self.now, nextReset: reset), now: Self.now)
                == reset.adding(seconds: QuotaSchedule.resetGrace))
    }
}
