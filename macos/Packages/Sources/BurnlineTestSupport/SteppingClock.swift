//
//  SteppingClock.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// A clock for driving a `run` loop in a test without waiting. Every sleep
/// returns at once: it is recorded, handed to `onSleep` (which typically
/// advances a `ManualClock` by the same amount), and after `sleeps` of them
/// the next one throws `CancellationError`, which ends the loop.
///
///     let stepper = SteppingClock(sleeps: 3) { clock.advance(seconds: $0.components.seconds) }
///     await quota.run(clock: stepper)
///     #expect(stepper.waits == [.seconds(300), …])
public final class SteppingClock: Clock, @unchecked Sendable {
    // @unchecked: `recorded` and `current` are only touched under `lock`.
    public typealias Duration = Swift.Duration
    public typealias Instant = ContinuousClock.Instant

    private let lock = NSLock()
    private let limit: Int
    private let onSleep: @Sendable (Duration) -> Void
    private var recorded: [Duration] = []
    private var current: Instant

    public init(sleeps limit: Int, onSleep: @escaping @Sendable (Duration) -> Void = { _ in }) {
        self.limit = limit
        self.onSleep = onSleep
        current = ContinuousClock().now
    }

    /// Every wait asked for, in order, including the one that ended the loop.
    public var waits: [Duration] { lock.withLock { recorded } }

    public var now: Instant { lock.withLock { current } }
    public var minimumResolution: Duration { .nanoseconds(1) }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let (wait, stop) = lock.withLock {
            let wait = current.duration(to: deadline)
            recorded.append(wait)
            current = deadline
            return (wait, recorded.count > limit)
        }
        if stop { throw CancellationError() }
        onSleep(wait)
    }
}
