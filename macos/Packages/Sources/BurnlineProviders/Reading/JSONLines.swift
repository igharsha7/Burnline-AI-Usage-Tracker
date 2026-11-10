//
//  JSONLines.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// What every JSONL transcript parser shares: timestamps in the providers'
/// common format, and decoding failures reduced to reasons that quote nothing.
enum JSONLines {
    /// `2026-10-30T12:34:56.789Z`, with or without the fraction.
    static func timestamp(_ text: String) -> Timestamp? {
        let date = (try? withFraction.parse(text)) ?? (try? withoutFraction.parse(text))
        return date.flatMap(Timestamp.init)
    }

    /// The same, in epoch milliseconds, for gaps finer than a second.
    static func milliseconds(_ text: String) -> Int64? {
        let date = (try? withFraction.parse(text)) ?? (try? withoutFraction.parse(text))
        return date.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) }
    }

    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    /// A decoding failure as a short reason, naming the field but quoting no
    /// content.
    static func describe(_ error: any Error) -> String {
        guard let decodingError = error as? DecodingError else { return "unreadable JSON" }
        switch decodingError {
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
             .keyNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "unreadable JSON" : "unexpected value at \(path)"
        @unknown default:
            return "unreadable JSON"
        }
    }
}
