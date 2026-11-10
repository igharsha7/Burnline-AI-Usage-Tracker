//
//  WallClock.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// The only way Burnline reads the current time. Injected everywhere time
/// matters, so no test depends on the real clock.
///
/// Named `WallClock` rather than `Clock` because the standard library already
/// has a `Clock` protocol, for durations, and a module-level type with the same
/// name would shadow it in every file that imports this module.
public protocol WallClock: Sendable {
    var now: Timestamp { get }
}

/// The real clock. This file is the one place `Date()` may appear, which
/// `ArchitectureTests` enforces.
public struct SystemClock: WallClock {
    public init() {}
    // The system clock is always within range, so the conversion cannot fail.
    public var now: Timestamp { Timestamp(Date())! }
}

/// A clock that only moves when told to, for tests and previews.
public final class ManualClock: WallClock, @unchecked Sendable {
    // @unchecked: every access to `current` goes through `lock`.
    private let lock = NSLock()
    private var current: Timestamp

    public init(_ start: Timestamp) { current = start }

    public var now: Timestamp {
        lock.withLock { current }
    }

    public func set(_ instant: Timestamp) {
        lock.withLock { current = instant }
    }

    public func advance(seconds: Int64) {
        lock.withLock { current = current.adding(seconds: seconds) }
    }
}
