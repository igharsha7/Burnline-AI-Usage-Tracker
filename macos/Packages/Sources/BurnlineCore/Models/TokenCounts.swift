//
//  TokenCounts.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// Token counts for one usage event. These are facts: everything else about an
/// event is derived from them.
///
/// Construction validates, so every value in circulation is non-negative and
/// its processed total fits in 64 bits.
public struct TokenCounts: Hashable, Sendable {
    public let input: Int64
    public let cachedInput: Int64
    public let cacheWrite: Int64
    /// The part of `cacheWrite` cached for an hour rather than five minutes.
    /// A subset, never added to `cacheWrite`, because the two durations are
    /// priced differently.
    public let cacheWriteOneHour: Int64
    public let output: Int64
    public let reasoning: Int64

    /// input + cached input + output. Cached reads are counted. Reasoning is
    /// reported separately and not added, because some providers already fold
    /// it into output and double-counting would be invisible.
    public let processed: Int64

    public static let zero = try! TokenCounts()

    public init(input: Int64 = 0, cachedInput: Int64 = 0, cacheWrite: Int64 = 0,
                cacheWriteOneHour: Int64 = 0, output: Int64 = 0,
                reasoning: Int64 = 0) throws(TokenCountError) {
        let fields = [("input", input), ("cachedInput", cachedInput), ("cacheWrite", cacheWrite),
                      ("cacheWriteOneHour", cacheWriteOneHour), ("output", output), ("reasoning", reasoning)]
        if let (name, _) = fields.first(where: { $0.1 < 0 }) { throw .negative(field: name) }
        guard cacheWriteOneHour <= cacheWrite else { throw .oneHourExceedsCacheWrite }

        let (partial, overflowA) = input.addingReportingOverflow(cachedInput)
        let (total, overflowB) = partial.addingReportingOverflow(output)
        guard !overflowA, !overflowB else { throw .overflow }

        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.cacheWriteOneHour = cacheWriteOneHour
        self.output = output
        self.reasoning = reasoning
        self.processed = total
    }
}

public enum TokenCountError: Error, Equatable, Sendable {
    case negative(field: String)
    case overflow
    case oneHourExceedsCacheWrite
}
