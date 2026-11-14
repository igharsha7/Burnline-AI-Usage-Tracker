//
//  RealQuotaTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineProviders
import Foundation
import Testing

/// Checks every quota source against this Mac's real accounts, to confirm
/// their answers still have the shape the readers expect. Opt-in: it starts
/// Codex and Claude Code, may ask to read Claude Code's login from the
/// Keychain, and makes the same usage requests those tools make.
///
/// It prints shapes only: key names, value types, counts and statuses. No
/// value, no percentage, and never a token.
///
///     BURNLINE_REAL_QUOTA=1 swift test --filter RealQuotaTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_REAL_QUOTA"] != nil), .serialized)
struct RealQuotaTests {
    @Test func `Codex's app-server`() async {
        await Self.probe("codex app-server", raw: { try await CodexAppServerReader().rawResponse() },
                         read: { try await CodexAppServerReader().read() })
    }

    @Test func `Codex's rollout files`() async {
        await Self.probe("codex rollouts", raw: nil, read: { try await CodexRolloutQuotaReader().read() })
    }

    @Test func `Claude's usage endpoint`() async {
        let reader = ClaudeUsageEndpointReader(
            credentials: KeychainClaudeCredentials(access: ClaudeLoginAccess(enabled: true, mayAsk: true)))
        await Self.probe("claude usage endpoint", raw: { try await reader.rawResponse(at: SystemClock().now).data },
                         read: { try await reader.read() })
    }

    @Test func `Claude Code's get_usage`() async {
        await Self.probe("claude code get_usage", raw: { try await ClaudeCodeUsageReader().rawResponse() },
                         read: { try await ClaudeCodeUsageReader().read() })
    }

    static func probe(_ name: String, raw: (@Sendable () async throws -> Data)?,
                      read: @Sendable () async throws -> QuotaReading) async {
        if let raw {
            do {
                let data = try await raw()
                let object = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
                print("QUOTA \(name) shape:\n" + shape(object).map { "  " + $0 }.joined(separator: "\n"))
            } catch {
                print("QUOTA \(name) failed: \(reason(error))")
                return
            }
        }
        do {
            let reading = try await read()
            let resets = reading.bankedResets.map { resets in
                "\(resets.count) banked (\(Dictionary(grouping: resets, by: \.status.rawValue).mapValues(\.count)))"
            } ?? "banked resets not visible"
            print("QUOTA \(name) parsed: windows \(reading.windows.map(\.key)), "
                  + "\(reading.windows.filter { $0.resetAt != nil }.count) with reset times, "
                  + "plan \(reading.plan == nil ? "absent" : "present"), \(resets)")
        } catch {
            print("QUOTA \(name) parse failed: \(reason(error))")
        }
    }

    static func reason(_ error: any Error) -> String {
        (error as? QuotaReadError)?.reason ?? "an unexpected error"
    }

    /// Every key path with its type, values left out. Arrays show their
    /// length and their first element's shape.
    static func shape(_ value: Any, path: String = "") -> [String] {
        switch value {
        case let object as [String: Any]:
            if object.isEmpty { return ["\(path.isEmpty ? "." : path): {}"] }
            return object.keys.sorted().flatMap { key in shape(object[key]!, path: path.isEmpty ? key : "\(path).\(key)") }
        case let array as [Any]:
            return ["\(path): array of \(array.count)"] + (array.first.map { shape($0, path: "\(path)[0]") } ?? [])
        case is NSNull: return ["\(path): null"]
        case let number as NSNumber:
            return ["\(path): \(CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number")"]
        case is String: return ["\(path): string"]
        default: return ["\(path): \(type(of: value))"]
        }
    }
}
