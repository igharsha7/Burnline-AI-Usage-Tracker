//
//  QuotaLoopTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineProviders
@testable import BurnlineServices
import BurnlineTestSupport
import Foundation
import Testing

/// A reader that answers at the clock's time and records when it was asked.
/// Its first `failures` reads fail as if the provider were unreachable.
final class CountingReader: QuotaReader, @unchecked Sendable {
    // @unchecked: `asked` is only touched under `lock`.
    private let lock = NSLock()
    private var asked: [Timestamp] = []
    let provider: ProviderKey
    let clock: ManualClock
    let percentUsed: Double
    let failures: Int

    init(_ provider: ProviderKey, clock: ManualClock, percentUsed: Double = 30, failures: Int = 0) {
        self.provider = provider
        self.clock = clock
        self.percentUsed = percentUsed
        self.failures = failures
    }

    var reads: Int { lock.withLock { asked.count } }
    /// Seconds after `QuotaActorTests.start` of each read.
    var readTimes: [Int64] { lock.withLock { asked.map { $0.seconds(since: QuotaActorTests.start) } } }

    func read() async throws(QuotaReadError) -> QuotaReading {
        let attempt = lock.withLock { asked.append(clock.now); return asked.count }
        if attempt <= failures { throw .unreachable("offline") }
        // A reset far beyond any test's span, so it never pulls a read forward.
        return QuotaActorTests.reading(provider, at: clock.now,
                                       [("weekly", percentUsed, QuotaActorTests.start.adding(seconds: 7 * 86_400))])
    }
}

/// The quota loop: how often each provider is read while the app runs. Reads
/// are never more frequent than the schedule allows, so a provider is never
/// hammered, and never rarer, so limits stay current.
struct QuotaLoopTests {
    static func stepper(_ clock: ManualClock, sleeps: Int) -> SteppingClock {
        SteppingClock(sleeps: sleeps) { clock.advance(seconds: $0.components.seconds) }
    }

    @Test func `an idle provider is read at once, then every 15 minutes`() async throws {
        let clock = ManualClock(QuotaActorTests.start)
        let reader = CountingReader(.codex, clock: clock)
        let quota = QuotaActor(database: try QuotaActorTests.database(clock), readers: [reader], clock: clock,
                               power: FixedPower(onBattery: false))
        let stepper = Self.stepper(clock, sleeps: 3)

        await quota.run(clock: stepper)

        #expect(reader.readTimes == [0, 900, 1_800, 2_700])
        #expect(stepper.waits == Array(repeating: .seconds(900), count: 4))
    }

    @Test func `usage speeds reads to every 5 minutes, and they slow again once it stops`() async throws {
        let clock = ManualClock(QuotaActorTests.start)
        let reader = CountingReader(.codex, clock: clock)
        let quota = QuotaActor(database: try QuotaActorTests.database(clock), readers: [reader], clock: clock,
                               power: FixedPower(onBattery: false))
        await quota.noteUsage(.codex)
        let stepper = Self.stepper(clock, sleeps: 3)

        await quota.run(clock: stepper)

        // Reads at 0, 5 and 10 minutes while usage is recent; at 15 minutes it
        // is not, so the next read waits for the idle interval from the last.
        #expect(reader.readTimes == [0, 300, 600])
        #expect(stepper.waits == [.seconds(300), .seconds(300), .seconds(300), .seconds(600)])
    }

    @Test func `a window near its limit is read every 2 minutes, even on battery`() async throws {
        let clock = ManualClock(QuotaActorTests.start)
        let reader = CountingReader(.codex, clock: clock, percentUsed: 95)
        let quota = QuotaActor(database: try QuotaActorTests.database(clock), readers: [reader], clock: clock,
                               power: FixedPower(onBattery: true))
        let stepper = Self.stepper(clock, sleeps: 2)

        await quota.run(clock: stepper)

        #expect(reader.readTimes == [0, 120, 240])
        #expect(stepper.waits == Array(repeating: .seconds(120), count: 3))
    }

    @Test func `EC-Q3 a provider that keeps failing is retried ever more slowly, up to every 30 minutes`() async throws {
        let clock = ManualClock(QuotaActorTests.start)
        let failing = CountingReader(.codex, clock: clock, failures: .max)
        let quota = QuotaActor(database: try QuotaActorTests.database(clock), readers: [failing], clock: clock,
                               power: FixedPower(onBattery: false))
        let stepper = Self.stepper(clock, sleeps: 8)

        await quota.run(clock: stepper)

        // Retries 1, 2, 4, 8, 16 and then 30 minutes apart. The loop never
        // sleeps longer than 15 minutes at once, so new usage is noticed.
        let times = failing.readTimes
        #expect(zip(times.dropFirst(), times).map { $0 - $1 } == [60, 120, 240, 480, 960, 1_800])
        #expect(stepper.waits.allSatisfy { $0 <= .seconds(900) })
        if case .degraded = await quota.state(of: .codex).health {} else {
            Issue.record("a provider whose reads fail is shown as degraded")
        }
    }

    @Test func `EC-Q3 once a failing provider answers, it returns to the ordinary schedule`() async throws {
        let clock = ManualClock(QuotaActorTests.start)
        let reader = CountingReader(.codex, clock: clock, failures: 2)
        let quota = QuotaActor(database: try QuotaActorTests.database(clock), readers: [reader], clock: clock,
                               power: FixedPower(onBattery: false))
        let stepper = Self.stepper(clock, sleeps: 3)

        await quota.run(clock: stepper)

        // Fails at 0 and 60, answers at 180, then idles 15 minutes.
        #expect(reader.readTimes == [0, 60, 180, 1_080])
        #expect(stepper.waits == [60, 120, 900, 900].map { .seconds($0) })
        #expect(await quota.state(of: .codex).health == .ok)
    }

    @Test func `only providers whose read is due are read`() async throws {
        let clock = ManualClock(QuotaActorTests.start)
        let codex = CountingReader(.codex, clock: clock)
        let claude = CountingReader(.claudeCode, clock: clock)
        let quota = QuotaActor(database: try QuotaActorTests.database(clock), readers: [codex, claude], clock: clock,
                               power: FixedPower(onBattery: false))
        await quota.refreshAll()
        await quota.noteUsage(.codex)

        clock.advance(seconds: 300)
        await quota.refreshDue()

        #expect(codex.reads == 2)
        #expect(claude.reads == 1)
    }

    @Test func `an untracked provider is never read by the loop`() async throws {
        let clock = ManualClock(QuotaActorTests.start)
        let reader = CountingReader(.claudeCode, clock: clock)
        let quota = QuotaActor(database: try QuotaActorTests.database(clock), readers: [reader], tracked: [],
                               clock: clock, power: FixedPower(onBattery: false))

        await quota.run(clock: Self.stepper(clock, sleeps: 2))

        #expect(reader.reads == 0)
    }
}

/// A reader whose reads wait until `open` is called, so a test can act while
/// one is in progress.
final class GatedReader: QuotaReader, @unchecked Sendable {
    // @unchecked: `count` is only touched under `lock`; the stream is thread-safe.
    private let lock = NSLock()
    private var count = 0
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation
    let provider: ProviderKey
    let clock: ManualClock

    init(_ provider: ProviderKey, clock: ManualClock) {
        self.provider = provider
        self.clock = clock
        (gate, opener) = AsyncStream<Void>.makeStream()
    }

    var reads: Int { lock.withLock { count } }
    func open() { opener.finish() }

    func read() async throws(QuotaReadError) -> QuotaReading {
        lock.withLock { count += 1 }
        for await _ in gate {}
        return QuotaActorTests.reading(provider, at: clock.now,
                                       [("weekly", 30, QuotaActorTests.start.adding(seconds: 7 * 86_400))])
    }
}

/// Reads that overlap, and a loop that is stopped.
struct QuotaConcurrencyTests {
    @Test(.timeLimit(.minutes(1)))
    func `a refresh asked for while one is in progress does not read the provider again`() async throws {
        let clock = ManualClock(QuotaActorTests.start)
        let reader = GatedReader(.codex, clock: clock)
        let quota = QuotaActor(database: try QuotaActorTests.database(clock), readers: [reader], clock: clock,
                               power: FixedPower(onBattery: false))
        let first = Task { await quota.refresh(.codex) }
        #expect(await eventually { reader.reads == 1 })

        // Answers at once with what is known, which is nothing yet. A second
        // read would wait at the gate, so this gives up rather than hanging.
        let overlapping = await within { await quota.refresh(.codex) }
        #expect(overlapping?.windows.isEmpty == true)

        reader.open()
        let settled = await first.value
        #expect(reader.reads == 1)
        #expect(settled.windows.map(\.percentageUsed) == [30])
        #expect(await quota.state(of: .codex).windows.map(\.percentageUsed) == [30])
    }

    @Test(.timeLimit(.minutes(1)))
    func `cancelling the running loop ends it while it sleeps`() async throws {
        let clock = ManualClock(QuotaActorTests.start)
        let reader = CountingReader(.codex, clock: clock)
        let quota = QuotaActor(database: try QuotaActorTests.database(clock), readers: [reader], clock: clock,
                               power: FixedPower(onBattery: false))
        // The real clock: the loop sleeps 15 minutes after its first read.
        let loop = Task { await quota.run() }
        #expect(await eventually { reader.reads == 1 })

        loop.cancel()

        #expect(await within(seconds: 5) { await loop.value; return true } == true)
        #expect(reader.reads == 1)
    }
}
