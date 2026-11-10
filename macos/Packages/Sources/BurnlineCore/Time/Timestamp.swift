//
//  Timestamp.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// A moment as whole epoch seconds in UTC, the representation the contracts
/// document fixes for storage.
///
/// Used instead of `Date` throughout the domain so a value read from the
/// database and a value about to be written are the same thing. `Date` carries
/// sub-second floating point that the schema would silently drop.
public struct Timestamp: Hashable, Comparable, Sendable {
    public let epochSeconds: Int64

    public init(epochSeconds: Int64) { self.epochSeconds = epochSeconds }

    /// Truncates toward the past, so a millisecond timestamp never lands in the
    /// following second's bucket. Nil for a date that whole epoch seconds cannot
    /// hold, which only corrupt provider data produces.
    public init?(_ date: Date) {
        guard let seconds = Int64(exactly: date.timeIntervalSince1970.rounded(.down)) else { return nil }
        self.epochSeconds = seconds
    }

    /// Millisecond epoch values, as several providers write them, floored.
    public init(epochMilliseconds: Int64) {
        let (quotient, remainder) = epochMilliseconds.quotientAndRemainder(dividingBy: 1_000)
        self.epochSeconds = remainder < 0 ? quotient - 1 : quotient
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(epochSeconds)) }

    public func adding(seconds: Int64) -> Timestamp {
        Timestamp(epochSeconds: epochSeconds + seconds)
    }

    /// Seconds from `other` to `self`; negative when `self` is earlier.
    public func seconds(since other: Timestamp) -> Int64 {
        epochSeconds - other.epochSeconds
    }

    public static func < (a: Self, b: Self) -> Bool { a.epochSeconds < b.epochSeconds }
}

/// A span of time: `start` inclusive, `end` exclusive, matching the validity
/// windows in the pricing contract so an instant on a boundary belongs to
/// exactly one window.
public struct TimeWindow: Hashable, Sendable {
    public let start: Timestamp
    public let end: Timestamp

    public init(start: Timestamp, end: Timestamp) {
        precondition(start <= end, "a window cannot end before it starts")
        self.start = start
        self.end = end
    }

    public var durationSeconds: Int64 { end.seconds(since: start) }

    public func contains(_ instant: Timestamp) -> Bool {
        start <= instant && instant < end
    }
}
