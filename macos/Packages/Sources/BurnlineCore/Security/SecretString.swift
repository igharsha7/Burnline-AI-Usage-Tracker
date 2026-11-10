//
//  SecretString.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// A credential held only for as long as it is being used.
///
/// Burnline reads provider tokens at the point of use and never retains them.
/// This type makes the accidental paths to retention hard: it prints as
/// `<redacted>` through `description`, `debugDescription`, string interpolation
/// and `dump`, it is not `Codable`, so it cannot be written to the database or a
/// log by mistake, and its bytes are zeroed when it is released.
///
/// Zeroing is best effort. The bytes are copied once into memory this type
/// owns, but whatever the caller read the secret from, and any `String` built
/// inside `withValue`, are outside its control.
public final class SecretString: Sendable, CustomStringConvertible,
                                 CustomDebugStringConvertible, CustomReflectable {
    private static let redacted = "<redacted>"

    // Written once in init and zeroed in deinit; never mutated in between,
    // which is what makes sharing across isolation domains safe.
    nonisolated(unsafe) private let storage: UnsafeMutableRawBufferPointer

    public init(_ value: String) {
        let bytes = Array(value.utf8)
        storage = .allocate(byteCount: bytes.count, alignment: 1)
        storage.copyBytes(from: bytes)
    }

    deinit {
        if let base = storage.baseAddress {
            _ = memset_s(base, storage.count, 0, storage.count)
        }
        storage.deallocate()
    }

    public var isEmpty: Bool { storage.isEmpty }

    /// Lends the secret out for a single use, such as building one request
    /// header. Do not let the string escape the closure.
    public func withValue<Result>(_ body: (String) throws -> Result) rethrows -> Result {
        try body(String(decoding: UnsafeRawBufferPointer(storage), as: UTF8.self))
    }

    public var description: String { Self.redacted }
    public var debugDescription: String { Self.redacted }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
