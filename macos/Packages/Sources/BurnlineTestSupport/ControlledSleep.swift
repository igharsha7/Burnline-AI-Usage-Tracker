//
//  ControlledSleep.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// A sleep that ends only when the test says so, for code that takes its
/// waiting as a closure. Each wait is recorded, and stays pending until
/// `release` ends it; a cancelled wait throws `CancellationError` at once.
///
///     let sleeper = ControlledSleep()
///     let model = StatusModel(clock: clock, sleep: sleeper.sleep)
///     #expect(await eventually { sleeper.isWaiting(.seconds(60)) })
///     clock.advance(seconds: 60)
///     sleeper.release(.seconds(60))
public final class ControlledSleep: @unchecked Sendable {
    // @unchecked: every stored property is only touched under `lock`.
    private let lock = NSLock()
    private var asked: [Duration] = []
    private var pending: [UUID: (wait: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var cancelled: Set<UUID> = []

    public init() {}

    public var sleep: @Sendable (Duration) async throws -> Void { { [self] in try await wait($0) } }

    /// Every wait asked for, in order.
    public var waits: [Duration] { lock.withLock { asked } }

    /// Whether a wait of `duration` is pending.
    public func isWaiting(_ duration: Duration) -> Bool {
        lock.withLock { pending.values.contains { $0.wait == duration } }
    }

    /// Ends every pending wait of `duration`, and says how many there were.
    @discardableResult
    public func release(_ duration: Duration) -> Int {
        let due = lock.withLock {
            let due = pending.filter { $0.value.wait == duration }
            for id in due.keys { pending[id] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
        return due.count
    }

    private func wait(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let wasCancelled = lock.withLock {
                    asked.append(duration)
                    if cancelled.remove(id) != nil { return true }
                    pending[id] = (duration, continuation)
                    return false
                }
                if wasCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock {
                guard let entry = pending.removeValue(forKey: id) else {
                    cancelled.insert(id)
                    return nil as CheckedContinuation<Void, any Error>?
                }
                return entry.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
