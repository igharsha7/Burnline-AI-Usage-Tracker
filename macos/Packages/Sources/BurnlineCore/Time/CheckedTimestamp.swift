//
//  CheckedTimestamp.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// A provider timestamp checked against the local clock.
///
/// The provider's value is kept as recorded: it is the fact, and the local
/// clock may be the one that is wrong. A value from the future is clamped to
/// now only for placement in buckets and charts, and flagged so the interface
/// can say so.
public struct CheckedTimestamp: Hashable, Sendable {
    /// How far ahead of the local clock a timestamp may be before it is treated
    /// as from the future. Absorbs ordinary drift between machines.
    public static let futureTolerance: Int64 = 5 * 60

    public let recorded: Timestamp
    /// Where the event is placed. Equal to `recorded` unless that is in the future.
    public let effective: Timestamp

    public var isFromFuture: Bool { recorded != effective }

    public init(_ recorded: Timestamp, now: Timestamp, tolerance: Int64 = futureTolerance) {
        precondition(tolerance >= 0, "a negative tolerance would flag the present as future")
        self.recorded = recorded
        // Compared as a bound on `now` rather than by subtracting, which can
        // overflow on a corrupt timestamp.
        let limit = now.epochSeconds.addingReportingOverflow(tolerance)
        let isFromFuture = !limit.overflow && recorded.epochSeconds > limit.partialValue
        self.effective = isFromFuture ? now : recorded
    }
}
