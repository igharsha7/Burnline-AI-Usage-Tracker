//
//  NotificationServiceTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineServices
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import os
import Testing

/// Records what would have been shown.
final class RecordingPoster: NotificationPoster, @unchecked Sendable {
    // @unchecked: every field is only touched under `lock`.
    private let lock = NSLock()
    private var current: NotificationPermission
    private let grants: Bool
    private var shown: [String] = []
    private var asked = 0

    init(_ permission: NotificationPermission, grants: Bool = true) {
        current = permission
        self.grants = grants
    }

    var titles: [String] { lock.withLock { shown } }
    var requests: Int { lock.withLock { asked } }

    func permission() async -> NotificationPermission { lock.withLock { current } }

    func requestPermission() async -> Bool {
        lock.withLock {
            asked += 1
            current = grants ? .allowed : .denied
            return grants
        }
    }

    func post(title: String, body: String, identifier: String) async throws {
        lock.withLock { shown.append(title) }
    }
}

struct NotificationServiceTests {
    static let start = QuotaActorTests.start
    /// The 5-hour window began five minutes before the first reading: too
    /// little of it has passed for its average to be a pace, so only the
    /// alerts each test is about are raised.
    static let reset = start.adding(seconds: 5 * 3_600 - 5 * 60)
    static let calendar = LocalCalendar(timeZone: .gmt, firstWeekday: .monday)

    static func service(_ database: BurnlineDatabase, _ poster: RecordingPoster, _ clock: ManualClock)
        -> NotificationService {
        NotificationService(database: database, poster: poster,
                            aggregation: AggregationService(database: database, calendar: calendar, clock: clock),
                            calendar: calendar, clock: clock)
    }

    /// A Codex quota actor whose updates go to a new notification service.
    static func pipeline(_ database: BurnlineDatabase, _ poster: RecordingPoster, _ clock: ManualClock,
                         rates: QuotaActorTests.UpdateLog = .init()) -> (QuotaActor, QueuedReader) {
        let service = service(database, poster, clock)
        let reader = QueuedReader(.codex, [])
        let actor = QuotaActor(database: database, readers: [reader], clock: clock, power: FixedPower(onBattery: false),
                               onUpdate: {
                                   rates.append($0)
                                   await service.handle($0)
                               })
        return (actor, reader)
    }

    /// Reads `percent` at `minutes` past the start.
    static func read(_ percent: Double, at minutes: Int64, reset: Timestamp = reset,
                     _ pipeline: (QuotaActor, QueuedReader), clock: ManualClock) async {
        let time = start.adding(seconds: minutes * 60)
        clock.set(time)
        pipeline.1.enqueue(.success(QuotaReading(
            provider: .codex, observedAt: time, source: "test", scope: .account, plan: "plus",
            windows: [QuotaWindowReading(key: "five_hour", name: "5-hour", percentUsed: percent, resetAt: reset,
                                         windowSeconds: 5 * 3_600)],
            bankedResets: nil)))
        await pipeline.0.refresh(.codex)
    }

    @Test func `EC-Q1 a fired 90% alert does not repeat, a banked reset's drop raises nothing, and it re-arms`()
        async throws {
        let clock = ManualClock(Self.start)
        let database = try QuotaActorTests.database(clock)
        let poster = RecordingPoster(.allowed)
        let log = QuotaActorTests.UpdateLog()
        let pipeline = Self.pipeline(database, poster, clock, rates: log)

        await Self.read(70, at: 0, pipeline, clock: clock)
        await Self.read(91, at: 5, pipeline, clock: clock)
        #expect(poster.titles == ["Codex 5-hour usage reached 90%"])
        await Self.read(94, at: 10, pipeline, clock: clock)
        // Fast enough to run out long before the reset, but the 90% alert stays sent.
        #expect(poster.titles == ["Codex 5-hour usage reached 90%", "Codex usage is rising quickly"])

        // A banked reset: the window starts again at 0%, early.
        let early = Self.start.adding(seconds: 15 * 60 + 5 * 3_600)
        await Self.read(0, at: 15, reset: early, pipeline, clock: clock)
        #expect(poster.titles.count == 2)
        await Self.read(91, at: 20, reset: early, pipeline, clock: clock)
        #expect(poster.titles.last == "Codex 5-hour usage reached 90%" && poster.titles.count == 3)
        // The drop never produced a negative rate.
        let rates = log.all.flatMap { $0.state.burnRates.values.compactMap { try? $0.get().percentPerHour } }
        #expect(!rates.isEmpty && rates.allSatisfy { $0 >= 0 })
    }

    @Test func `EC-Q3 a failed read alerts nothing`() async throws {
        let clock = ManualClock(Self.start)
        let database = try QuotaActorTests.database(clock)
        let poster = RecordingPoster(.allowed)
        let pipeline = Self.pipeline(database, poster, clock)
        pipeline.1.enqueue(.failure(.unreachable("offline")))
        await pipeline.0.refresh(.codex)
        #expect(poster.titles.isEmpty)
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM notification_events") } == 0)
    }

    @Test func `denied permission degrades to silence and leaves no backlog`() async throws {
        let clock = ManualClock(Self.start)
        let database = try QuotaActorTests.database(clock)
        let poster = RecordingPoster(.denied)
        await Self.read(95, at: 0, Self.pipeline(database, poster, clock), clock: clock)
        #expect(poster.titles.isEmpty && poster.requests == 0)
        // Recorded anyway, so allowing notifications later brings no flood.
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM notification_events") } == 2)
        #expect(await Self.service(database, poster, clock).sendTest() == .denied && poster.requests == 0)
    }

    @Test func `never asked, the first alert asks once and is shown if allowed`() async throws {
        let clock = ManualClock(Self.start)
        let database = try QuotaActorTests.database(clock)
        let poster = RecordingPoster(.notDetermined)
        let pipeline = Self.pipeline(database, poster, clock)
        // Nothing to say yet, so nothing is asked.
        await Self.read(40, at: 0, pipeline, clock: clock)
        #expect(poster.requests == 0)
        await Self.read(91, at: 10, pipeline, clock: clock)
        // Asked once for everything that reading earned, all of it shown.
        #expect(poster.requests == 1 && poster.titles.contains("Codex 5-hour usage reached 90%"))
    }

    @Test func `refused at the first alert, nothing asks again`() async throws {
        let clock = ManualClock(Self.start)
        let database = try QuotaActorTests.database(clock)
        let poster = RecordingPoster(.notDetermined, grants: false)
        let pipeline = Self.pipeline(database, poster, clock)
        await Self.read(80, at: 0, pipeline, clock: clock)
        await Self.read(95, at: 10, pipeline, clock: clock)
        #expect(poster.requests == 1 && poster.titles.isEmpty)
    }

    @Test func `the test button asks when nothing has yet`() async throws {
        let clock = ManualClock(Self.start)
        let database = try QuotaActorTests.database(clock)
        let poster = RecordingPoster(.notDetermined)
        #expect(await Self.service(database, poster, clock).sendTest() == .allowed)
        #expect(poster.requests == 1 && poster.titles == ["Burnline notifications are on"])
    }

    /// A milestone service over an activity store, with the real corpus.
    static func milestones(_ database: BurnlineDatabase, _ poster: RecordingPoster,
                           settings: AlertSettings = AlertSettings()) async throws -> NotificationService {
        let clock = ManualClock(ActivityServiceTests.now)
        let service = NotificationService(
            database: database, poster: poster,
            aggregation: AggregationService(database: database, calendar: ActivityServiceTests.calendar, clock: clock),
            settings: settings, calendar: ActivityServiceTests.calendar, clock: clock)
        await service.use(milestones: try ComparisonCorpus.load(from: ComparisonEngineTests.corpusURL))
        return service
    }

    @Test func `crossing a lifetime milestone announces it once`() async throws {
        let database = try ActivityServiceTests.open()
        try ActivityServiceTests.ingest(database, daysAgo: [5], tokens: 60_000)
        let poster = RecordingPoster(.allowed)
        let service = try await Self.milestones(database, poster)
        try ActivityServiceTests.ingest(database, daysAgo: [3], tokens: 50_000)
        await service.noteUsage()
        #expect(poster.titles == ["Milestone"])
        try ActivityServiceTests.ingest(database, daysAgo: [2], tokens: 10)
        await service.noteUsage()
        #expect(poster.titles == ["Milestone"])
    }

    @Test func `a history imported into a fresh store announces no milestone`() async throws {
        let database = try ActivityServiceTests.open()
        let poster = RecordingPoster(.allowed)
        let service = try await Self.milestones(database, poster)
        try ActivityServiceTests.ingest(database, daysAgo: [9], tokens: 2_000_000)
        await service.noteUsage()
        #expect(poster.titles.isEmpty)
        // From there on, crossings are announced.
        try ActivityServiceTests.ingest(database, daysAgo: [1], tokens: 9_000_000)
        await service.noteUsage()
        #expect(poster.titles == ["Milestone"])
    }

    @Test func `milestones turned off announce nothing`() async throws {
        let database = try ActivityServiceTests.open()
        try ActivityServiceTests.ingest(database, daysAgo: [5], tokens: 60_000)
        let poster = RecordingPoster(.allowed)
        let service = try await Self.milestones(database, poster, settings: AlertSettings(milestones: false))
        try ActivityServiceTests.ingest(database, daysAgo: [3], tokens: 50_000)
        await service.noteUsage()
        #expect(poster.titles.isEmpty)
    }

    @Test func `a medal earned after the first awards is announced by name, once`() async throws {
        let database = try ActivityServiceTests.open()
        let clock = ManualClock(ActivityServiceTests.now)
        let poster = RecordingPoster(.allowed)
        let service = Self.service(database, poster, clock)
        try ActivityServiceTests.ingest(database, daysAgo: [3], tokens: 30_000_000)
        await service.noteUsage()
        // A new store's first awards are its backfill.
        #expect(poster.titles.isEmpty)
        try ActivityServiceTests.ingest(database, daysAgo: [0], tokens: 25_000_000)
        clock.advance(seconds: NotificationService.achievementInterval)
        await service.noteUsage()
        #expect(poster.titles == ["New medal: 50M Tokens"])
        clock.advance(seconds: NotificationService.achievementInterval)
        await service.noteUsage()
        #expect(poster.titles.count == 1)
    }

    @Test func `usage inside the medal throttle is checked even when imports stop`() async throws {
        let updates = OSAllocatedUnfairLock(initialState: 0)
        let database = try ActivityServiceTests.open()
        let clock = ManualClock(ActivityServiceTests.now)
        let poster = RecordingPoster(.allowed)
        let service = NotificationService(
            database: database, poster: poster,
            aggregation: AggregationService(database: database, calendar: Self.calendar, clock: clock),
            calendar: Self.calendar, clock: clock, achievementSleep: { _ in
                clock.advance(seconds: NotificationService.achievementInterval)
            }, onAchievements: { updates.withLock { $0 += 1 } })
        try ActivityServiceTests.ingest(database, daysAgo: [3], tokens: 30_000_000)
        await service.noteUsage()
        try ActivityServiceTests.ingest(database, daysAgo: [0], tokens: 25_000_000)
        await service.noteUsage()
        await service.achievementCheck?.value
        #expect(poster.titles == ["New medal: 50M Tokens"])
        #expect(updates.withLock { $0 } == 2)
        #expect(try database.achievements.all().contains { $0.kind == .lifetimeTokens })
    }

    @Test func `a medal for old usage imported late is not announced`() async throws {
        let database = try ActivityServiceTests.open()
        let clock = ManualClock(ActivityServiceTests.now)
        let poster = RecordingPoster(.allowed)
        let service = Self.service(database, poster, clock)
        try ActivityServiceTests.ingest(database, daysAgo: [3])
        await service.noteUsage()
        try ActivityServiceTests.ingest(database, daysAgo: [20], tokens: 20_000_000)
        clock.advance(seconds: NotificationService.achievementInterval)
        await service.noteUsage()
        #expect(poster.titles.isEmpty)
    }

    @Test func `medals turned off announce nothing`() async throws {
        let database = try ActivityServiceTests.open()
        let clock = ManualClock(ActivityServiceTests.now)
        let poster = RecordingPoster(.allowed)
        let service = NotificationService(
            database: database, poster: poster,
            aggregation: AggregationService(database: database, calendar: Self.calendar, clock: clock),
            settings: AlertSettings(achievements: false), calendar: Self.calendar, clock: clock)
        try ActivityServiceTests.ingest(database, daysAgo: [3], tokens: 30_000_000)
        await service.noteUsage()
        try ActivityServiceTests.ingest(database, daysAgo: [0], tokens: 25_000_000)
        clock.advance(seconds: NotificationService.achievementInterval)
        await service.noteUsage()
        #expect(poster.titles.isEmpty)
    }

    @Test func `an alert sent before a restart is not sent again`() async throws {
        let clock = ManualClock(Self.start)
        let database = try QuotaActorTests.database(clock)
        let poster = RecordingPoster(.allowed)
        await Self.read(91, at: 0, Self.pipeline(database, poster, clock), clock: clock)
        await Self.read(92, at: 5, Self.pipeline(database, poster, clock), clock: clock)
        #expect(poster.titles == ["Codex 5-hour usage reached 90%"])
    }

    @Test(arguments: ["UTC", "America/New_York", "Asia/Kolkata"])
    func `EC-T1 spend totals and alert keys use the same captured day across midnight`(zone: String) async throws {
        let calendar = LocalCalendar(timeZone: try #require(TimeZone(identifier: zone)), firstWeekday: .monday)
        let day = calendar.window(for: calendar.day(containing: Self.start))
        let clock = MidnightClock(before: day.end.adding(seconds: -1), after: day.end)
        let database = try QuotaActorTests.database(ManualClock(Self.start))
        let model = try #require(try database.models.resolve(provider: .codex, raw: "test-model", at: Self.start).modelID)
        let version = try database.pricing.append(modelID: model, validFrom: day.start, validUntil: nil,
                                                   rates: TokenRates(output: Nanodollars(raw: 20_000_000_000)),
                                                   source: "test", confidence: .exact)
        try database.usage.insert([UsageEvent(
            provider: .codex, modelID: model, sessionID: nil, projectID: nil,
            timestamp: day.end.adding(seconds: -60), tokens: try TokenCounts(output: 1_000_000),
            cost: .priced(Nanodollars(raw: 20_000_000_000), pricingVersionID: version.id, confidence: .exact),
            source: SourceReference(sourceType: "test", file: nil, eventID: "before-midnight", schemaVersion: nil, offset: 0))])
        let poster = RecordingPoster(.allowed)
        let service = NotificationService(
            database: database, poster: poster,
            aggregation: AggregationService(database: database, calendar: calendar, clock: clock),
            settings: AlertSettings(dailySpend: Nanodollars(raw: 10_000_000_000)),
            calendar: calendar, clock: clock)
        await service.noteUsage()
        #expect(poster.titles.count == 1)
        let fired = try database.notifications.fired(since: day.start)
        #expect(fired.map(\.cycleToken) == ["day:\(calendar.day(containing: day.start))"])
    }

    @Test func `a spend alert is recorded with no provider`() throws {
        let clock = ManualClock(Self.start)
        let database = try QuotaActorTests.database(clock)
        let key = AlertKey(provider: nil, quotaKey: nil, kind: .dailySpend, threshold: 2e10, cycleToken: "day:2026-11-01")
        let quota = AlertKey(provider: .codex, quotaKey: "five_hour", kind: .threshold, threshold: 90,
                             cycleToken: "codex:five_hour:1")
        try database.notifications.record(key, at: Self.start)
        try database.notifications.record(quota, at: Self.start)
        #expect(try database.notifications.fired(since: Self.start) == [key, quota])
        #expect(try database.notifications.fired(since: Self.start.adding(seconds: 1)).isEmpty)
    }

    @Test func `chosen thresholds are saved and read back, and nothing saved gives the defaults`() {
        let suite = "io.github.igharsha7.Burnline.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = AlertSettingsStore(suiteName: suite)
        #expect(store.load() == AlertSettings())
        let chosen = AlertSettings(thresholds: [.init(.codex, .weekly): [50, 95]], limitReached: false)
        store.save(chosen)
        #expect(store.load() == chosen)
    }
}

/// Advances once across midnight, exactly between capturing the alert's date
/// and resolving the aggregation range.
final class MidnightClock: WallClock, @unchecked Sendable {
    // @unchecked: `before` is only touched under `lock`.
    private let lock = NSLock()
    private var before: Timestamp?
    private let after: Timestamp

    init(before: Timestamp, after: Timestamp) {
        self.before = before
        self.after = after
    }

    var now: Timestamp {
        lock.withLock {
            let value = before ?? after
            before = nil
            return value
        }
    }
}
