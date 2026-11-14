//
//  ClaudeQuota.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation

/// Claude's plan limits as both of its sources describe them: the claude.ai
/// usage endpoint, and Claude Code's `get_usage`, which relays the same
/// endpoint. Percentages are 0 to 100; reset times ISO 8601.
struct ClaudeLimits: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey { case utilization, resetsAt = "resets_at" }
    }
    struct Scoped: Decodable, Sendable {
        let displayName: String
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case displayName = "display_name", utilization, resetsAt = "resets_at"
        }
    }
    struct Extra: Decodable, Sendable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Double?
        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled", monthlyLimit = "monthly_limit", usedCredits = "used_credits", utilization
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let sevenDayOAuthApps: Window?
    let modelScoped: [Scoped]?
    let extraUsage: Extra?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour", sevenDay = "seven_day", sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet", sevenDayOAuthApps = "seven_day_oauth_apps"
        case modelScoped = "model_scoped", extraUsage = "extra_usage"
    }

    static let fiveHourSeconds: Int64 = 5 * 3_600
    static let weekSeconds: Int64 = 7 * 86_400

    func windows() -> [QuotaWindowReading] {
        var windows: [QuotaWindowReading] = []
        func add(_ window: Window?, _ key: String, _ name: String, _ seconds: Int64?) {
            guard let percent = window?.utilization, percent.isFinite else { return }
            windows.append(QuotaWindowReading(key: key, name: name, percentUsed: Self.clamped(percent),
                                              resetAt: window?.resetsAt.flatMap(JSONLines.timestamp),
                                              windowSeconds: seconds))
        }
        add(fiveHour, "five_hour", "5-hour", Self.fiveHourSeconds)
        add(sevenDay, "seven_day", "Weekly", Self.weekSeconds)
        add(sevenDayOpus, "seven_day_opus", "Weekly · Opus", Self.weekSeconds)
        add(sevenDaySonnet, "seven_day_sonnet", "Weekly · Sonnet", Self.weekSeconds)
        add(sevenDayOAuthApps, "seven_day_oauth_apps", "Weekly · connected apps", Self.weekSeconds)
        for scoped in modelScoped ?? [] {
            add(Window(utilization: scoped.utilization, resetsAt: scoped.resetsAt),
                "seven_day_" + scoped.displayName.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .joined(separator: "_"),
                "Weekly · \(scoped.displayName)", Self.weekSeconds)
        }
        if let extra = extraUsage, extra.isEnabled == true {
            let percent = extra.usedCredits.flatMap { used in
                extra.monthlyLimit.flatMap { $0 > 0 ? used / $0 * 100 : nil }
            } ?? extra.utilization
            if let percent, percent.isFinite {
                windows.append(QuotaWindowReading(key: "extra_usage", name: "Extra usage",
                                                  percentUsed: Self.clamped(percent), resetAt: nil, windowSeconds: nil))
            }
        }
        // A model's weekly window can repeat a named one; the named one wins.
        var seen = Set<String>()
        return windows.filter { seen.insert($0.key).inserted }
    }

    static func clamped(_ percent: Double) -> Double { min(max(percent, 0), 100) }
}

/// Claude's banked resets: grants, each holding some number of resets to
/// use before it ends.
struct ClaudeResetGrants: Decodable, Sendable {
    struct Grant: Decodable, Sendable {
        let id: String
        let resetsLeft: Int
        let endsAt: String?
        enum CodingKeys: String, CodingKey { case id, resetsLeft = "resets_left", endsAt = "ends_at" }
    }
    let eligible: Bool
    let grants: [Grant]?

    /// One `BankedReset` per reset a grant holds, numbered within it, so a
    /// count that falls leaves the missing ones to the ledger's rules. A
    /// grant clears Claude's windows rather than one of them, recorded as
    /// `claude`.
    func resets(observedAt: Timestamp) -> [BankedReset] {
        guard eligible else { return [] }
        return (grants ?? []).flatMap { grant -> [BankedReset] in
            guard grant.resetsLeft > 0 else { return [] }
            return (1...grant.resetsLeft).map { index in
                BankedReset(provider: .claudeCode, sourceResetID: "\(grant.id)#\(index)", appliesToQuotaKey: "claude",
                            grantedAt: nil, expiresAt: grant.endsAt.flatMap(JSONLines.timestamp), consumedAt: nil,
                            status: .held, source: ClaudeUsageEndpointReader.source, observedAt: observedAt)
            }
        }
    }
}

// MARK: The usage endpoint

/// Sends one HTTPS request, so tests can answer without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// A session that keeps nothing: no cache, no cookies, no credential store,
/// so a request's Authorization header lives only as long as the request.
public struct EphemeralHTTPTransport: HTTPTransport {
    let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Reads Claude's limits and banked resets from the claude.ai usage endpoint
/// Claude Code itself uses, with Claude Code's login read at the moment of
/// the request. The only source of Claude's banked resets.
public struct ClaudeUsageEndpointReader: QuotaReader {
    public let provider = ProviderKey.claudeCode
    let credentials: any ClaudeCredentialSource
    let transport: any HTTPTransport
    let clock: any WallClock

    static let source = "claude_usage_endpoint"
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    /// Burnline names itself rather than posing as Claude Code.
    static let userAgent = "Burnline (+https://github.com/igharsha7/Burnline-AI-Usage-Tracker)"

    public init(credentials: any ClaudeCredentialSource,
                transport: any HTTPTransport = EphemeralHTTPTransport(), clock: any WallClock = SystemClock()) {
        self.credentials = credentials
        self.transport = transport
        self.clock = clock
    }

    public func read() async throws(QuotaReadError) -> QuotaReading {
        let now = clock.now
        let (data, plan) = try await rawResponse(at: now)
        return try Self.reading(from: data, plan: plan, observedAt: now)
    }

    /// The response, and the plan named by the login it was read with.
    func rawResponse(at now: Timestamp) async throws(QuotaReadError) -> (data: Data, plan: String?) {
        let login = try credentials.login(at: now)
        let request = login.token.withValue { token in
            var request = URLRequest(url: Self.endpoint)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            return request
        }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw .unreachable("claude.ai did not answer")
        }
        switch response.statusCode {
        case 200: return (data, login.plan)
        case 401, 403: throw .credentialExpired
        case 429: throw .rateLimited
        default: throw .unreachable("claude.ai answered \(response.statusCode)")
        }
    }

    private struct Response: Decodable {
        let cedarEmber: ClaudeResetGrants?
        enum CodingKeys: String, CodingKey { case cedarEmber = "cedar_ember" }
    }

    static func reading(from data: Data, plan: String? = nil, observedAt: Timestamp)
        throws(QuotaReadError) -> QuotaReading {
        guard let limits = try? JSONDecoder().decode(ClaudeLimits.self, from: data),
              let extra = try? JSONDecoder().decode(Response.self, from: data) else {
            throw .malformed("usage")
        }
        let windows = limits.windows()
        guard !windows.isEmpty else { throw .unsupported("This Claude account reports no plan limits.") }
        // A missing block means none were reported, not that none are held.
        return QuotaReading(provider: .claudeCode, observedAt: observedAt, source: source, scope: .account,
                            plan: plan, windows: windows, bankedResets: extra.cedarEmber?.resets(observedAt: observedAt))
    }
}

// MARK: Claude Code's get_usage

/// Reads Claude's limits by asking Claude Code itself, which uses its own
/// login and renews it when it has expired. The fallback when the Keychain
/// read is declined or the token has expired; it cannot see banked resets.
///
/// Claude Code is started in its stream-json mode with no prompt, tools,
/// hooks, MCP servers or saved session, asked one control request, and
/// stopped. No model turn runs. Anthropic marks `get_usage` experimental, so
/// this may break with a Claude Code release, and is isolated here for that.
public struct ClaudeCodeUsageReader: QuotaReader {
    public let provider = ProviderKey.claudeCode
    let launcher: any ProcessLauncher
    let locator: ExecutableLocator
    let clock: any WallClock
    let workingDirectory: URL
    let timeout: Double

    static let source = "claude_code_get_usage"
    static let arguments = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--no-session-persistence", "--setting-sources", "user", "--settings", #"{"disableAllHooks":true}"#,
        "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--tools", "",
    ]

    public init(launcher: any ProcessLauncher = SystemProcessLauncher(),
                locator: ExecutableLocator = ExecutableLocator(extraCandidates: [
                    FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/local/claude")]),
                clock: any WallClock = SystemClock(),
                workingDirectory: URL = FileManager.default.temporaryDirectory, timeout: Double = 20) {
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

    func rawResponse() async throws(QuotaReadError) -> Data {
        guard let claude = locator.find("claude") else { throw .notInstalled("Claude Code") }
        let process: any LineProcess
        do {
            process = try launcher.launch(claude, arguments: Self.arguments, workingDirectory: workingDirectory)
        } catch {
            throw .notInstalled("Claude Code")
        }
        defer { process.terminate() }
        _ = try await request(["subtype": "initialize"], id: "burnline-init", on: process)
        return try await request(["subtype": "get_usage", "skip_behaviors": true], id: "burnline-usage", on: process)
    }

    /// Sends one control request and returns the `response` of its answer.
    private func request(_ body: [String: Any], id: String, on process: any LineProcess) async throws(QuotaReadError)
        -> Data {
        do {
            let message = try JSONSerialization.data(
                withJSONObject: ["type": "control_request", "request_id": id, "request": body], options: [.sortedKeys])
            try process.send(String(decoding: message, as: UTF8.self))
        } catch {
            throw .unreachable("Claude Code stopped answering")
        }
        let line = try await firstLine(of: process, within: timeout) { line in
            line.contains(#""control_response""#) && line.contains(id)
        }
        guard let line,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let answer = object["response"] as? [String: Any] else {
            throw .unreachable("Claude Code closed before answering")
        }
        guard answer["subtype"] as? String == "success" else {
            throw .unreachable("Claude Code could not read usage")
        }
        let response = answer["response"] ?? [String: Any]()
        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            throw .malformed("get_usage")
        }
        return data
    }

    private struct Response: Decodable {
        let rateLimitsAvailable: Bool?
        let rateLimits: ClaudeLimits?
        let subscriptionType: String?
        enum CodingKeys: String, CodingKey {
            case rateLimitsAvailable = "rate_limits_available", rateLimits = "rate_limits"
            case subscriptionType = "subscription_type"
        }
    }

    static func reading(from data: Data, plan: String? = nil, observedAt: Timestamp)
        throws(QuotaReadError) -> QuotaReading {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw .malformed("get_usage")
        }
        guard response.rateLimitsAvailable == true, let limits = response.rateLimits else {
            throw .unsupported("This Claude Code login has no plan limits, as with an API key.")
        }
        let windows = limits.windows()
        guard !windows.isEmpty else { throw .unsupported("This Claude account reports no plan limits.") }
        return QuotaReading(provider: .claudeCode, observedAt: observedAt, source: source, scope: .account,
                            plan: response.subscriptionType, windows: windows, bankedResets: nil)
    }
}
