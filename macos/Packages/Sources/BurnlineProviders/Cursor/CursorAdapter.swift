//
//  CursorAdapter.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// Cursor keeps no token usage on this machine: its local databases hold code
/// attribution and auth keys, and metering happens on Cursor's servers. The
/// adapter exists so Cursor appears in provider health with that reason, and is
/// absent from token and cost series rather than drawn at zero, which would
/// read as "no usage" instead of "not measurable".
public struct CursorAdapter: UsageProviderAdapter {
    public static let unavailableReason = "Cursor does not keep token usage on this Mac."

    public let provider = ProviderKey.cursor

    public init() {}

    public func detect() -> ProviderDetection { .unavailable(reason: Self.unavailableReason) }
    public func sourceFiles() throws -> [URL] { [] }
    public func parse(_ file: URL, from offset: Int64, state: String?) throws -> ParseOutput { ParseOutput() }
}
