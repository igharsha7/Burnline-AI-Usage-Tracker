//
//  ChangeFeed.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// What changed, for the interface to redraw. Pushed by ingestion and quota,
/// so no view polls.
public enum StatusChange: Sendable {
    case usage(ProviderKey)
    /// Medals were judged after an import, including a throttled trailing check.
    case achievements
    case quota(ProviderQuotaState)
    /// Saving usage started failing, with why, or recovered, with nil.
    case storage(StoreFailure?)
}

/// Sends every change to every subscriber, each on its own stream.
public final class ChangeFeed: Sendable {
    private let subscribers = Subscribers()

    public init() {}

    /// A stream of changes from now on. It ends when the caller stops reading.
    public func changes() -> AsyncStream<StatusChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: StatusChange.self,
                                                           bufferingPolicy: .bufferingNewest(64))
        let id = subscribers.add(continuation)
        continuation.onTermination = { [subscribers] _ in subscribers.remove(id) }
        return stream
    }

    public func send(_ change: StatusChange) {
        for continuation in subscribers.all { continuation.yield(change) }
    }

    private final class Subscribers: @unchecked Sendable {
        // @unchecked: every field is only touched under `lock`.
        private let lock = NSLock()
        private var continuations: [Int: AsyncStream<StatusChange>.Continuation] = [:]
        private var nextID = 0

        func add(_ continuation: AsyncStream<StatusChange>.Continuation) -> Int {
            lock.withLock {
                nextID += 1
                continuations[nextID] = continuation
                return nextID
            }
        }

        func remove(_ id: Int) { _ = lock.withLock { continuations.removeValue(forKey: id) } }

        var all: [AsyncStream<StatusChange>.Continuation] { lock.withLock { Array(continuations.values) } }
    }
}
