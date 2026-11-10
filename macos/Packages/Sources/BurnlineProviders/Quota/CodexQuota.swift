//
//  CodexQuota.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// Codex's rate limits as both of its sources describe them: the app-server
/// in camel case, rollout files in snake case. Field names follow the
/// protocol schema `codex app-server generate-json-schema` prints.
struct CodexLimits: Sendable {
    struct Window: Sendable {
        let usedPercent: Double
        let resetsAt: Int64?
        let windowMinutes: Int64?
    }

    let limitID: String?
    let limitName: String?
    let plan: String?
    let primary: Window?
    let secondary: Window?
    /// A spend-control limit set on the account, reported as what remains.
    let individualRemainingPercent: Double?
    let individualResetsAt: Int64?

    static let fiveHourMinutes: Int64 = 5 * 60
    static let weekMinutes: Int64 = 7 * 24 * 60
    static let monthMinutes: Int64 = 30 * 24 * 60

    /// The windows, keyed by what they measure. `primary` and `secondary` are
    /// positions, not meanings, so a window's duration decides what it is.
    /// Without one, paid plans use 5-hour and weekly windows and the free
    /// plans a monthly one, but not every paid plan has a 5-hour window: Pro
    /// has only the weekly one, so a primary window that resets more than five
    /// hours after `now` is taken as weekly. A limit other than the main
    /// `codex` one, such as a model's own, is kept apart under its id.
    func windows(at now: Timestamp) -> [QuotaWindowReading] {
        let monthlyPlan = plan == "free" || plan == "go"
        let positions = [(primary, monthlyPlan ? Self.monthMinutes : Self.fiveHourMinutes),
                         (secondary, Self.weekMinutes)]
        let prefix = limitID.flatMap { $0 == "codex" ? nil : $0 }
        var windows: [QuotaWindowReading] = []
        for (window, fallback) in positions {
            guard let window, window.usedPercent.isFinite else { continue }
            var minutes = window.windowMinutes ?? fallback
            if window.windowMinutes == nil, minutes == Self.fiveHourMinutes, let resetsAt = window.resetsAt,
               resetsAt - now.epochSeconds > Self.fiveHourMinutes * 60 {
                minutes = Self.weekMinutes
            }
            let duration = minutes.multipliedReportingOverflow(by: 60)
            guard minutes > 0, !duration.overflow else { continue }
            let (key, name) = Self.kind(minutes: minutes)
            // Two windows read as one kind: the first stands.
            guard !windows.contains(where: { $0.key == (prefix.map { "\($0).\(key)" } ?? key) }) else { continue }
            windows.append(QuotaWindowReading(
                key: prefix.map { "\($0).\(key)" } ?? key,
                name: (limitName ?? prefix).map { "\(name) · \($0)" } ?? name,
                percentUsed: Self.clamped(window.usedPercent),
                resetAt: window.resetsAt.flatMap { $0 > 0 ? Timestamp(epochSeconds: $0) : nil },
                windowSeconds: duration.partialValue))
        }
        if let remaining = individualRemainingPercent, remaining.isFinite {
            windows.append(QuotaWindowReading(
                key: "monthly_credit", name: "Monthly credit limit", percentUsed: Self.clamped(100 - remaining),
                resetAt: individualResetsAt.map(Timestamp.init(epochSeconds:)), windowSeconds: nil))
        }
        return windows
    }

    static func kind(minutes: Int64) -> (key: String, name: String) {
        switch minutes {
        case monthMinutes...: ("monthly", "Monthly")
        case weekMinutes...: ("weekly", "Weekly")
        case fiveHourMinutes: ("five_hour", "5-hour")
        default: ("window_\(minutes)m", "\(minutes)-minute")
        }
    }

    static func clamped(_ percent: Double) -> Double { min(max(percent, 0), 100) }
}

// MARK: The app-server

/// Reads Codex's quota by asking its own app-server, which makes the
/// authenticated request with the login Codex keeps. Burnline never sees
/// that login. This is also the only source that reports banked resets.
public struct CodexAppServerReader: QuotaReader {
    public let provider = ProviderKey.codex
    let launcher: any ProcessLauncher
    let locator: ExecutableLocator
    let clock: any WallClock
    let workingDirectory: URL
    let timeout: Double

    static let source = "codex_app_server"

    public init(launcher: any ProcessLauncher = SystemProcessLauncher(), locator: ExecutableLocator = ExecutableLocator(
                    extraCandidates: [URL(filePath: "/Applications/Codex.app/Contents/Resources/codex")]),
                clock: any WallClock = SystemClock(),
                workingDirectory: URL = FileManager.default.temporaryDirectory, timeout: Double = 15) {
        self.launcher = launcher
        self.locator = locator
        self.clock = clock
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public func read() async throws(QuotaReadError) -> QuotaReading {
        let response = try await rawResponse()
        return try Self.reading(from: response, observedAt: clock.now)
    }

    /// The `account/rateLimits/read` result, undecoded, for the opt-in probe
    /// that prints its shape.
    func rawResponse() async throws(QuotaReadError) -> Data {
        guard let codex = locator.find("codex") else { throw .notInstalled("Codex") }
        let process: any LineProcess
        do {
            process = try launcher.launch(codex, arguments: ["app-server"], workingDirectory: workingDirectory)
        } catch {
            throw .notInstalled("Codex")
        }
        defer { process.terminate() }
        do {
            try process.send(Self.message(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "burnline", "title": "Burnline", "version": "1"]]]))
            _ = try await response(1, from: process)
            try process.send(Self.message(["method": "initialized"]))
            try process.send(Self.message(["id": 2, "method": "account/rateLimits/read"]))
        } catch let error as QuotaReadError {
            throw error
        } catch {
            throw .unreachable("Codex stopped answering")
        }
        return try await response(2, from: process)
    }

    /// The `result` of the response to request `id`. Notifications, which
    /// carry no id, are skipped.
    private func response(_ id: Int, from process: any LineProcess) async throws(QuotaReadError) -> Data {
        let line = try await firstLine(of: process, within: timeout) { line in
            (try? JSONDecoder().decode(Envelope.self, from: Data(line.utf8)))?.id == id
        }
        guard let line, let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(line.utf8)) else {
            throw .unreachable("Codex closed before answering")
        }
        if let error = envelope.error { throw Self.error(error.message ?? "") }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let result = object["result"], !(result is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: result) else {
            throw .malformed("no result")
        }
        return data
    }

    /// An error from the app-server, in Burnline's terms. Its text is only
    /// matched, never passed on: it may echo a request URL or response.
    static func error(_ message: String) -> QuotaReadError {
        let text = message.lowercased()
        if text.contains("401") || text.contains("unauthorized") { return .credentialExpired }
        if text.contains("429") { return .rateLimited }
        if text.contains("not logged in") || text.contains("login") || text.contains("auth") {
            return .notSignedIn("Codex is not signed in with ChatGPT.")
        }
        return .unreachable("Codex could not read usage")
    }

    private struct Envelope: Decodable {
        struct Failure: Decodable { let message: String? }
        let id: Int?
        let error: Failure?
    }

    static func message(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: Decoding

    struct Response: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let resetsAt: Int64?
            let windowDurationMins: Int64?
        }
        struct Individual: Decodable {
            let remainingPercent: Double
            let resetsAt: Int64?
        }
        struct Snapshot: Decodable {
            var limitId: String?
            let limitName: String?
            let planType: String?
            let primary: Window?
            let secondary: Window?
            let individualLimit: Individual?
        }
        struct Credit: Decodable {
            let id: String
            let grantedAt: Int64?
            let expiresAt: Int64?
            let resetType: String?
            let status: String?
        }
        struct Credits: Decodable {
            let availableCount: Int?
            let credits: [Credit]?
        }
        let rateLimits: Snapshot?
        let rateLimitsByLimitId: [String: Snapshot]?
        let rateLimitResetCredits: Credits?
    }

    static func reading(from data: Data, observedAt: Timestamp) throws(QuotaReadError) -> QuotaReading {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch {
            throw .malformed("rate limits")
        }
        // The multi-limit view, when given, is the newer and fuller one.
        var snapshots: [Response.Snapshot] = response.rateLimitsByLimitId.map { limits in
            limits.map { key, value in
                var snapshot = value
                if snapshot.limitId == nil { snapshot.limitId = key }
                return snapshot
            }
        } ?? []
        if snapshots.isEmpty, let single = response.rateLimits { snapshots = [single] }
        snapshots.sort { ($0.limitId == "codex" ? 0 : 1, $0.limitId ?? "") < ($1.limitId == "codex" ? 0 : 1, $1.limitId ?? "") }
        let windows = snapshots.flatMap { snapshot in
            CodexLimits(limitID: snapshot.limitId, limitName: snapshot.limitName, plan: snapshot.planType,
                        primary: snapshot.primary.map { .init(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt,
                                                              windowMinutes: $0.windowDurationMins) },
                        secondary: snapshot.secondary.map { .init(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt,
                                                                  windowMinutes: $0.windowDurationMins) },
                        individualRemainingPercent: snapshot.individualLimit?.remainingPercent,
                        individualResetsAt: snapshot.individualLimit?.resetsAt).windows(at: observedAt)
        }
        guard !windows.isEmpty else { throw .unsupported("This Codex account reports no usage limits.") }
        let plan = snapshots.first { $0.limitId == "codex" || $0.limitId == nil }?.planType ?? snapshots.first?.planType
        return QuotaReading(provider: .codex, observedAt: observedAt, source: source, scope: .account, plan: plan,
                            windows: windows,
                            bankedResets: response.rateLimitResetCredits.map { resets(from: $0, observedAt: observedAt) })
    }

    /// One `BankedReset` per credit. A credit of type `codexRateLimits` clears
    /// the main Codex limit's windows, recorded as `codex`; any other type is
    /// recorded as not known.
    static func resets(from credits: Response.Credits, observedAt: Timestamp) -> [BankedReset] {
        (credits.credits ?? []).map { credit in
            BankedReset(provider: .codex, sourceResetID: credit.id,
                        appliesToQuotaKey: credit.resetType == "codexRateLimits" ? "codex" : nil,
                        grantedAt: credit.grantedAt.map(Timestamp.init(epochSeconds:)),
                        expiresAt: credit.expiresAt.map(Timestamp.init(epochSeconds:)), consumedAt: nil,
                        status: status(credit.status), source: source, observedAt: observedAt)
        }
    }

    /// `redeeming` is still held: it is spent only once the provider says so.
    static func status(_ value: String?) -> BankedResetStatus {
        switch value {
        case "available", "redeeming": .held
        case "redeemed": .consumed
        default: .unknown
        }
    }
}

// MARK: Rollout files

/// Reads the rate limits Codex writes into its session files with each token
/// count. Free and offline, but only as current as the last Codex session,
/// and blind to banked resets; the fallback when the app-server cannot answer.
public struct CodexRolloutQuotaReader: QuotaReader {
    public let provider = ProviderKey.codex
    let sessionDirectories: [URL]

    static let source = "codex_rollout"
    /// Files to look through, newest first, before giving up.
    static let filesToSearch = 5

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        sessionDirectories = ProviderHomes.existing(ProviderHomes.codex(environment: environment))
            .map { $0.appending(path: "sessions") }
    }

    init(sessionDirectories: [URL]) { self.sessionDirectories = sessionDirectories }

    public func read() async throws(QuotaReadError) -> QuotaReading {
        let files = Self.newestRollouts(in: sessionDirectories)
        guard !files.isEmpty else { throw .notInstalled("Codex") }
        let latest = files.prefix(Self.filesToSearch).compactMap { Self.latestReading(in: $0) }
            .max { $0.observedAt < $1.observedAt }
        guard let latest else { throw .unreachable("no recent Codex session reports its limits") }
        return latest
    }

    static func newestRollouts(in directories: [URL]) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var files: [(URL, Date)] = []
        for directory in directories {
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)
            while let file = enumerator?.nextObject() as? URL {
                guard file.lastPathComponent.hasPrefix("rollout-"), file.pathExtension == "jsonl" else { continue }
                let modified = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                files.append((file, modified))
            }
        }
        return files.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The last token count in `file` that carries the main limit's windows.
    static func latestReading(in file: URL) -> QuotaReading? {
        var latest: QuotaReading?
        _ = try? LineReader.read(file, from: 0, containing: [#""rate_limits""#]) { line in
            guard let event = try? JSONDecoder().decode(Event.self, from: line.bytes),
                  event.payload.type == "token_count", let limits = event.payload.rateLimits,
                  limits.limitID == nil || limits.limitID == "codex",
                  let observed = event.timestamp.flatMap(JSONLines.timestamp) else { return }
            let codex = CodexLimits(
                limitID: limits.limitID, limitName: nil, plan: limits.planType,
                primary: limits.primary.map { .init(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt,
                                                    windowMinutes: $0.windowMinutes) },
                secondary: limits.secondary.map { .init(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt,
                                                        windowMinutes: $0.windowMinutes) },
                individualRemainingPercent: nil, individualResetsAt: nil)
            let windows = codex.windows(at: observed)
            guard !windows.isEmpty, latest.map({ observed >= $0.observedAt }) ?? true else { return }
            latest = QuotaReading(provider: .codex, observedAt: observed, source: source, scope: .account,
                                  plan: limits.planType, windows: windows, bankedResets: nil)
        }
        return latest
    }

    private struct Event: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let resetsAt: Int64?
            let windowMinutes: Int64?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent", resetsAt = "resets_at", windowMinutes = "window_minutes"
            }
        }
        struct Limits: Decodable {
            let limitID: String?
            let planType: String?
            let primary: Window?
            let secondary: Window?
            enum CodingKeys: String, CodingKey {
                case limitID = "limit_id", planType = "plan_type", primary, secondary
            }
        }
        struct Payload: Decodable {
            let type: String?
            let rateLimits: Limits?
            enum CodingKeys: String, CodingKey { case type, rateLimits = "rate_limits" }
        }
        let timestamp: String?
        let payload: Payload
    }
}
