//
//  QuotaReaderTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineProviders
import BurnlineTestSupport
import Foundation
import Security
import Testing

/// A child process that answers from a script, so the readers' protocols are
/// tested without starting Codex or Claude Code.
final class ScriptedProcess: LineProcess, @unchecked Sendable {
    // @unchecked: `sent` is only touched under `lock`.
    private let lock = NSLock()
    private var sentLines: [String] = []
    private let reply: @Sendable (String) -> [String]
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    let lines: AsyncThrowingStream<String, any Error>

    init(greeting: [String] = [], reply: @escaping @Sendable (String) -> [String]) {
        self.reply = reply
        (lines, continuation) = AsyncThrowingStream.makeStream()
        greeting.forEach { continuation.yield($0) }
    }

    var sent: [String] { lock.withLock { sentLines } }

    func send(_ line: String) throws {
        lock.withLock { sentLines.append(line) }
        reply(line).forEach { continuation.yield($0) }
    }

    func terminate() { continuation.finish() }
}

struct ScriptedLauncher: ProcessLauncher {
    let process: ScriptedProcess
    let launched = Launches()

    final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String]] = []
        var arguments: [[String]] { lock.withLock { values } }
        func add(_ arguments: [String]) { lock.withLock { values.append(arguments) } }
    }

    func launch(_ executable: URL, arguments: [String], workingDirectory: URL) throws -> any LineProcess {
        launched.add(arguments)
        return process
    }
}

/// A transport that records the request and answers with `status` and `body`.
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    let status: Int
    let body: Data

    init(status: Int = 200, body: Data) {
        self.status = status
        self.body = body
    }

    var last: URLRequest? { lock.withLock { requests.last } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct FixedCredentials: ClaudeCredentialSource {
    let result: Result<String, QuotaReadError>
    var plan: String?
    func login(at now: Timestamp) throws(QuotaReadError) -> ClaudeLogin {
        switch result {
        case .success(let token): ClaudeLogin(token: SecretString(token), plan: plan)
        case .failure(let error): throw error
        }
    }
}

/// Fixtures that read from a fake executable in a scratch directory.
enum Tools {
    static func locator(_ name: String) throws -> ExecutableLocator {
        let directory = TestDirectory.make("Tools")
        let tool = directory.appending(path: name)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return ExecutableLocator(environment: ["PATH": directory.path], installDirectories: [])
    }

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }
}

struct QuotaReaderTests {
    static let now = Timestamp(epochSeconds: 1_793_541_600)
    static let clock = ManualClock(now)
    /// Stands in for a real access token in every request and assertion.
    static let token = "sk-ant-oat01-BURNLINE-SENTINEL-TOKEN"

    // MARK: Codex app-server

    /// What `account/rateLimits/read` answers, in the protocol schema's shape.
    static var codexResult: [String: Any] { [
        "rateLimits": ["limitId": "codex", "planType": "plus",
                       "primary": ["usedPercent": 8, "windowDurationMins": 300, "resetsAt": 1_793_555_131]],
        "rateLimitsByLimitId": [
            "codex": ["limitId": "codex", "planType": "plus",
                      "primary": ["usedPercent": 8, "windowDurationMins": 300, "resetsAt": 1_793_555_131],
                      "secondary": ["usedPercent": 57, "windowDurationMins": 10_080, "resetsAt": 1_793_805_156]],
            "premium": ["limitId": "premium", "limitName": "GPT-6.1 Sol",
                        "primary": ["usedPercent": 30, "windowDurationMins": 10_080, "resetsAt": 1_793_805_156]],
        ],
        "rateLimitResetCredits": ["availableCount": 1, "credits": [
            ["id": "rc_1", "grantedAt": 1_793_400_000, "expiresAt": 1_793_600_000, "resetType": "codexRateLimits",
             "status": "available"],
            ["id": "rc_0", "grantedAt": 1_793_000_000, "expiresAt": 1_793_300_000, "resetType": "codexRateLimits",
             "status": "redeemed"],
        ]],
    ] }

    static func codexServer(answer: @escaping @Sendable ([String: Any]) -> [String: Any]) -> ScriptedProcess {
        ScriptedProcess { line in
            let message = Tools.object(line)
            guard let id = message["id"] else { return [] }
            // A notification first, to be skipped.
            return [Tools.json(["method": "account/updated", "params": [:]]),
                    Tools.json(["id": id].merging(answer(message)) { $1 })]
        }
    }

    @Test func `Codex's app-server gives windows by what they measure, and banked resets`() async throws {
        let process = Self.codexServer { message in
            message["method"] as? String == "initialize" ? ["result": ["userAgent": "codex"]] : ["result": Self.codexResult]
        }
        let reader = CodexAppServerReader(launcher: ScriptedLauncher(process: process),
                                          locator: try Tools.locator("codex"), clock: Self.clock)
        let reading = try await reader.read()
        #expect(reading.windows.map(\.key) == ["five_hour", "weekly", "premium.weekly"])
        #expect(reading.windows.map(\.percentUsed) == [8, 57, 30])
        #expect(reading.windows[2].name == "Weekly · GPT-6.1 Sol")
        #expect(reading.windows[0].resetAt == Timestamp(epochSeconds: 1_793_555_131))
        #expect(reading.plan == "plus" && reading.scope == .account && reading.source == "codex_app_server")
        let resets = try #require(reading.bankedResets)
        #expect(resets.map(\.status) == [.held, .consumed])
        #expect(resets[0].appliesToQuotaKey == "codex" && resets[0].expiresAt == Timestamp(epochSeconds: 1_793_600_000))
        // The handshake, then one read; nothing else is asked of Codex.
        #expect(process.sent.map { Tools.object($0)["method"] as? String } == ["initialize", "initialized",
                                                                                "account/rateLimits/read"])
    }

    @Test func `EC-Q4 an unauthorised answer from Codex is an expired login`() async throws {
        let process = Self.codexServer { message in
            message["method"] as? String == "initialize" ? ["result": [:]] :
                ["error": ["code": -32603, "message": "GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized"]]
        }
        let reader = CodexAppServerReader(launcher: ScriptedLauncher(process: process),
                                          locator: try Tools.locator("codex"), clock: Self.clock)
        await #expect(throws: QuotaReadError.credentialExpired) { try await reader.read() }
    }

    @Test func `EC-Q3 a Codex that never answers times out`() async throws {
        let reader = CodexAppServerReader(launcher: ScriptedLauncher(process: ScriptedProcess { _ in [] }),
                                          locator: try Tools.locator("codex"), clock: Self.clock, timeout: 0.2)
        await #expect(throws: QuotaReadError.self) { try await reader.read() }
    }

    @Test func `a Mac without Codex reports it not installed`() async {
        let reader = CodexAppServerReader(launcher: ScriptedLauncher(process: ScriptedProcess { _ in [] }),
                                          locator: ExecutableLocator(environment: ["PATH": "/nonexistent"], installDirectories: []),
                                          clock: Self.clock)
        await #expect(throws: QuotaReadError.notInstalled("Codex")) { try await reader.read() }
    }

    @Test func `the free plan's first window is monthly`() throws {
        let data = Data(Tools.json(["rateLimits": ["planType": "free",
                                                   "primary": ["usedPercent": 40, "resetsAt": 1_795_000_000]]]).utf8)
        let reading = try CodexAppServerReader.reading(from: data, observedAt: Self.now)
        #expect(reading.windows.map(\.key) == ["monthly"] && reading.bankedResets == nil)
    }

    @Test func `a plan with only a weekly window is never read as a 5-hour one`() throws {
        // Pro: one window, reported with its duration or, from an older
        // source, without one but resetting days away.
        for primary: [String: Any] in [["usedPercent": 30, "windowDurationMins": 10_080, "resetsAt": 1_793_805_156],
                                       ["usedPercent": 30, "resetsAt": 1_793_805_156]] {
            let data = Data(Tools.json(["rateLimits": ["planType": "pro", "primary": primary]]).utf8)
            let reading = try CodexAppServerReader.reading(from: data, observedAt: Self.now)
            #expect(reading.windows.map(\.key) == ["weekly"])
        }
        // Without durations, the two windows of a weekly-only plan keep one key.
        let both = Data(Tools.json(["rateLimits": ["planType": "pro",
                                                   "primary": ["usedPercent": 30, "resetsAt": 1_793_805_156],
                                                   "secondary": ["usedPercent": 31, "resetsAt": 1_793_805_156]]]).utf8)
        #expect(try CodexAppServerReader.reading(from: both, observedAt: Self.now).windows.map(\.key) == ["weekly"])
    }

    @Test func `EC-Q7 multi-limit dictionary keys identify windows when limitId is absent`() throws {
        let data = Data(Tools.json(["rateLimitsByLimitId": [
            "codex": ["primary": ["usedPercent": 8, "windowDurationMins": 300]],
            "premium": ["primary": ["usedPercent": 91, "windowDurationMins": 300]],
        ]]).utf8)
        let reading = try CodexAppServerReader.reading(from: data, observedAt: Self.now)
        #expect(reading.windows.map(\.key) == ["five_hour", "premium.five_hour"])
        #expect(reading.windows.map(\.percentUsed) == [8, 91])
    }

    @Test(arguments: [Int64(0), -1, .max])
    func `invalid Codex durations cannot create windows or overflow`(minutes: Int64) throws {
        let data = Data(Tools.json(["rateLimits": ["primary": [
            "usedPercent": 8, "windowDurationMins": minutes,
        ]]]).utf8)
        #expect(throws: QuotaReadError.self) {
            try CodexAppServerReader.reading(from: data, observedAt: Self.now)
        }
    }

    // MARK: Codex rollouts

    @Test func `the newest rollout's last token count gives the windows`() async throws {
        let sessions = TestDirectory.make("CodexSessions")
        let day = sessions.appending(path: "2026/11/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        func tokenCount(_ at: String, _ primary: Double, limit: String = "codex") -> String {
            Tools.json(["timestamp": at, "type": "event_msg", "payload": [
                "type": "token_count", "rate_limits": [
                    "limit_id": limit, "plan_type": "plus",
                    "primary": ["used_percent": primary, "window_minutes": 300, "resets_at": 1_793_555_131],
                    "secondary": ["used_percent": 57, "window_minutes": 10_080, "resets_at": 1_793_805_156]]]])
        }
        let lines = [tokenCount("2026-11-01T10:00:00.000Z", 5), tokenCount("2026-11-01T10:05:00.000Z", 8),
                     tokenCount("2026-11-01T10:06:00.000Z", 99, limit: "premium")]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: day.appending(path: "rollout-2026-11-01T10-00-00-abc.jsonl"))
        let reading = try await CodexRolloutQuotaReader(sessionDirectories: [sessions]).read()
        #expect(reading.windows.map(\.percentUsed) == [8, 57])
        #expect(reading.observedAt == JSONLinesTimestamp.parse("2026-11-01T10:05:00.000Z"))
        #expect(reading.bankedResets == nil && reading.source == "codex_rollout")
    }

    @Test func `EC-Q3 rollout freshness follows observation time rather than file modification time`() async throws {
        let sessions = TestDirectory.make("RolloutFreshness")
        let old = sessions.appending(path: "rollout-old.jsonl")
        let recent = sessions.appending(path: "rollout-recent.jsonl")
        for (file, time, percent) in [(old, "2026-11-01T10:00:00Z", 5), (recent, "2026-11-01T11:00:00Z", 80)] {
            let line = Tools.json(["timestamp": time, "payload": ["type": "token_count", "rate_limits": [
                "primary": ["used_percent": percent, "window_minutes": 300],
            ]]])
            try Data((line + "\n").utf8).write(to: file)
        }
        try FileManager.default.setAttributes([.modificationDate: Self.now.date], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Self.now.adding(seconds: -60).date], ofItemAtPath: recent.path)
        let reading = try await CodexRolloutQuotaReader(sessionDirectories: [sessions]).read()
        #expect(reading.windows.map(\.percentUsed) == [80])
        #expect(reading.observedAt == JSONLinesTimestamp.parse("2026-11-01T11:00:00Z"))
    }

    // MARK: Claude's usage endpoint

    static var claudeBody: [String: Any] { [
        "five_hour": ["utilization": 42.0, "resets_at": "2026-11-02T17:00:00.123456+00:00"],
        "seven_day": ["utilization": 61.0, "resets_at": "2026-11-06T09:00:00+00:00"],
        "seven_day_opus": NSNull(),
        "model_scoped": [["display_name": "Opus 5.5", "utilization": 12.0, "resets_at": "2026-11-06T09:00:00Z"]],
        "extra_usage": ["is_enabled": true, "monthly_limit": 5_000, "used_credits": 1_250, "utilization": NSNull()],
        "cedar_ember": ["eligible": true, "next_grant_id": "g1",
                        "grants": [["id": "g1", "resets_left": 2, "ends_at": "2026-11-09T00:00:00Z", "usable_now": true]]],
    ] }

    @Test func `Claude's usage endpoint gives windows and banked resets in one request`() async throws {
        let transport = RecordingTransport(body: Data(Tools.json(Self.claudeBody).utf8))
        let reader = ClaudeUsageEndpointReader(credentials: FixedCredentials(result: .success(Self.token), plan: "max"),
                                               transport: transport, clock: Self.clock)
        let reading = try await reader.read()
        // The endpoint names no plan; the login it was read with does.
        #expect(reading.plan == "max")
        #expect(reading.windows.map(\.key) == ["five_hour", "seven_day", "seven_day_opus_5_5", "extra_usage"])
        #expect(reading.windows.map(\.percentUsed) == [42, 61, 12, 25])
        #expect(reading.windows[0].resetAt == JSONLinesTimestamp.parse("2026-11-02T17:00:00.123Z"))
        let resets = try #require(reading.bankedResets)
        #expect(resets.map(\.sourceResetID) == ["g1#1", "g1#2"] && resets.allSatisfy { $0.status == .held })

        let request = try #require(transport.last)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        // Burnline names itself rather than posing as Claude Code.
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Burnline") == true)
        #expect(request.url?.query?.contains("cedar_ember=1") == true)
    }

    @Test(arguments: [(401, QuotaReadError.credentialExpired), (403, .credentialExpired), (429, .rateLimited)])
    func `EC-Q4 the endpoint's refusals become reasons, never the response body`(status: Int, error: QuotaReadError)
        async throws {
        let transport = RecordingTransport(status: status, body: Data(#"{"error":"\#(Self.token)"}"#.utf8))
        let reader = ClaudeUsageEndpointReader(credentials: FixedCredentials(result: .success(Self.token)),
                                               transport: transport, clock: Self.clock)
        await #expect(throws: error) { try await reader.read() }
        #expect(!error.reason.contains(Self.token))
    }

    @Test func `a plan without a 5-hour window reports only its weekly ones`() throws {
        // Ultra: no 5-hour window, as an absent or empty block.
        for fiveHour: Any in [NSNull(), ["utilization": NSNull(), "resets_at": NSNull()]] {
            var body = Self.claudeBody
            body["five_hour"] = fiveHour
            let reading = try ClaudeUsageEndpointReader.reading(from: Data(Tools.json(body).utf8), observedAt: Self.now)
            #expect(!reading.windows.map(\.key).contains("five_hour") && reading.windows.map(\.key).contains("seven_day"))
        }
    }

    @Test func `an account without plan limits is unsupported, not empty`() throws {
        #expect(throws: QuotaReadError.unsupported("This Claude account reports no plan limits.")) {
            try ClaudeUsageEndpointReader.reading(from: Data("{}".utf8), observedAt: Self.now)
        }
    }

    @Test func `an ineligible account holds no banked resets, and a missing block says nothing`() throws {
        var body = Self.claudeBody
        body["cedar_ember"] = ["eligible": false]
        #expect(try ClaudeUsageEndpointReader.reading(from: Data(Tools.json(body).utf8), observedAt: Self.now)
            .bankedResets == [])
        body["cedar_ember"] = nil
        #expect(try ClaudeUsageEndpointReader.reading(from: Data(Tools.json(body).utf8), observedAt: Self.now)
            .bankedResets == nil)
    }

    // MARK: Claude Code's login

    @Test func `the stored login gives its access token and plan, and nothing else`() throws {
        let data = Data(Tools.json(["claudeAiOauth": ["accessToken": Self.token, "refreshToken": "refresh",
                                                      "expiresAt": (Self.now.epochSeconds + 3_600) * 1_000,
                                                      "subscriptionType": "max"]]).utf8)
        let login = try ClaudeStoredLogin.login(from: data, at: Self.now)
        #expect(login.token.withValue { $0 } == Self.token)
        #expect(login.plan == "max")
        #expect("\(login.token)" == "<redacted>" && !"\(login)".contains(Self.token))
    }

    @Test func `EC-Q4 an expired stored login is reported, not renewed`() {
        let data = Data(Tools.json(["claudeAiOauth": ["accessToken": Self.token,
                                                      "expiresAt": (Self.now.epochSeconds - 1) * 1_000]]).utf8)
        #expect(throws: QuotaReadError.credentialExpired) { try ClaudeStoredLogin.login(from: data, at: Self.now) }
    }

    @Test func `a credentials file is read before the Keychain`() throws {
        let file = TestDirectory.make("ClaudeHome").appending(path: ".credentials.json")
        try Data(Tools.json(["claudeAiOauth": ["accessToken": Self.token]]).utf8).write(to: file)
        let source = KeychainClaudeCredentials(files: [file], access: ClaudeLoginAccess(enabled: true)) { _, _ in
            Issue.record("the Keychain was searched although a credentials file exists")
            return (errSecItemNotFound, nil)
        }
        let login = try source.login(at: Self.now)
        #expect(login.token.withValue { $0 } == Self.token && login.plan == nil)
    }

    @Test func `the login is read from the credentials file in Claude Code's configured home`() throws {
        let home = TestDirectory.make("ClaudeConfig")
        try Data(Tools.json(["claudeAiOauth": ["accessToken": Self.token]]).utf8)
            .write(to: home.appending(path: ".credentials.json"))
        let access = ClaudeLoginAccess(enabled: true)
        let source = KeychainClaudeCredentials(access: access, environment: ["CLAUDE_CONFIG_DIR": home.path])
        #expect(try source.login(at: Self.now).token.withValue { $0 } == Self.token)
        #expect(access.isEnabled)
    }

    #if DEBUG
    @Test func `a debug build told to skip the Keychain treats reading as off`() {
        let access = ClaudeLoginAccess(enabled: true)
        let source = KeychainClaudeCredentials(access: access, environment: [
            "CLAUDE_CONFIG_DIR": TestDirectory.make("ClaudeEmpty").path, "BURNLINE_SKIP_KEYCHAIN": "1",
        ])
        #expect(throws: QuotaReadError.notSignedIn("Reading Claude Code's login is turned off in Settings.")) {
            try source.login(at: Self.now)
        }
        #expect(access.status == .off)
    }
    #endif

    /// A stand-in for the Keychain's prompt switch, recording every change.
    final class InteractionSwitch: @unchecked Sendable {
        // @unchecked: every stored property is touched only under `lock`.
        private let lock = NSLock()
        private var allowed: Bool
        private var changes: [Bool] = []
        init(allowed: Bool) { self.allowed = allowed }
        var isAllowed: Bool { lock.withLock { allowed } }
        var history: [Bool] { lock.withLock { changes } }
        var interaction: KeychainClaudeCredentials.Interaction {
            .init(isAllowed: { self.isAllowed },
                  allow: { value in self.lock.withLock { self.allowed = value; self.changes.append(value) } })
        }
    }

    @Test(arguments: [true, false])
    func `a silent search turns Keychain prompts off while it runs, then puts them back`(before: Bool) {
        let state = InteractionSwitch(allowed: before)
        var during: Bool?
        let status = KeychainClaudeCredentials.search(mayPrompt: false, interaction: state.interaction) {
            during = state.isAllowed
            return errSecInteractionNotAllowed
        }
        #expect(status == errSecInteractionNotAllowed && during == false)
        #expect(state.isAllowed == before && state.history == [false, before])
    }

    @Test func `a search the user asked for leaves Keychain prompts as they are`() {
        let state = InteractionSwitch(allowed: true)
        let status = KeychainClaudeCredentials.search(mayPrompt: true, interaction: state.interaction) { errSecSuccess }
        #expect(status == errSecSuccess && state.history == [])
    }

    /// Records each Keychain search and whether it could prompt, answering
    /// with `status` and `data`, which a test may change between reads.
    final class KeychainStub: @unchecked Sendable {
        // @unchecked: every stored property is touched only under `lock`.
        private let lock = NSLock()
        private var asked: [Bool] = []
        private var answer: (OSStatus, Data?)
        let access: ClaudeLoginAccess
        init(_ status: OSStatus, _ data: Data? = nil, access: ClaudeLoginAccess = ClaudeLoginAccess(enabled: true)) {
            answer = (status, data)
            self.access = access
        }
        /// Whether each search so far was allowed to show macOS's prompt.
        var prompts: [Bool] { lock.withLock { asked } }
        func answer(_ status: OSStatus, _ data: Data? = nil) { lock.withLock { answer = (status, data) } }
        func source() -> KeychainClaudeCredentials {
            KeychainClaudeCredentials(files: [], access: access) { _, mayPrompt in
                self.lock.withLock {
                    self.asked.append(mayPrompt)
                    return self.answer
                }
            }
        }
    }

    static let stored = Data(Tools.json(["claudeAiOauth": ["accessToken": token, "subscriptionType": "max"]]).utf8)

    @Test func `the login stored in the Keychain is read silently, with its plan`() throws {
        let keychain = KeychainStub(errSecSuccess, Self.stored)
        let login = try keychain.source().login(at: Self.now)
        #expect(login.token.withValue { $0 } == Self.token && login.plan == "max")
        #expect(keychain.prompts == [false])
        #expect(keychain.access.status == .allowed)
    }

    @Test func `no Keychain item means not signed in, and is asked again next time`() {
        let keychain = KeychainStub(errSecItemNotFound)
        let source = keychain.source()
        for _ in 0..<2 {
            #expect(throws: QuotaReadError.notSignedIn("Claude Code is not signed in.")) {
                try source.login(at: Self.now)
            }
        }
        #expect(keychain.prompts == [false, false])
    }

    @Test(arguments: [errSecAuthFailed, errSecInteractionNotAllowed])
    func `a login macOS would ask about is refused silently and reported as needing permission`(status: OSStatus) {
        let keychain = KeychainStub(status)
        let source = keychain.source()
        for _ in 0..<2 {
            #expect(throws: QuotaReadError.notSignedIn(
                "Claude Code renewed its login, so Burnline needs permission to read it again.")) {
                try source.login(at: Self.now)
            }
        }
        #expect(keychain.prompts == [false, false])
        #expect(keychain.access.status == .needsPermission)
    }

    @Test func `allowing again lets one read show macOS's prompt, then reads are silent once more`() throws {
        let keychain = KeychainStub(errSecAuthFailed)
        let source = keychain.source()
        _ = try? source.login(at: Self.now)
        keychain.answer(errSecSuccess, Self.stored)
        keychain.access.requestPrompt()
        _ = try source.login(at: Self.now)
        _ = try source.login(at: Self.now)
        #expect(keychain.prompts == [false, true, false])
        #expect(keychain.access.status == .allowed)
    }

    @Test func `a first launch lets the first read ask, and only the first`() throws {
        let keychain = KeychainStub(errSecSuccess, Self.stored, access: ClaudeLoginAccess(enabled: true, mayAsk: true))
        let source = keychain.source()
        _ = try source.login(at: Self.now)
        _ = try source.login(at: Self.now)
        #expect(keychain.prompts == [true, false])
    }

    @Test(arguments: [errSecUserCanceled, errSecAuthFailed])
    func `declining macOS's prompt is remembered while later reads stay silent`(status: OSStatus) {
        let keychain = KeychainStub(status)
        let source = keychain.source()
        keychain.access.requestPrompt()
        #expect(throws: QuotaReadError.notSignedIn("Burnline was not allowed to read Claude Code's login.")) {
            try source.login(at: Self.now)
        }
        _ = try? source.login(at: Self.now)
        #expect(keychain.prompts == [true, false])
        #expect(keychain.access.status == .declined)
    }

    @Test func `with reading turned off the Keychain is never searched`() {
        let keychain = KeychainStub(errSecSuccess, Self.stored, access: ClaudeLoginAccess(enabled: true, mayAsk: true))
        keychain.access.setEnabled(false)
        keychain.access.requestPrompt()
        #expect(throws: QuotaReadError.notSignedIn("Reading Claude Code's login is turned off in Settings.")) {
            try keychain.source().login(at: Self.now)
        }
        #expect(keychain.prompts == [])
        #expect(keychain.access.status == .off)
    }

    // MARK: Claude Code's get_usage

    static func claudeCode(usage: [String: Any]) -> ScriptedProcess {
        let usage = Tools.json(usage)
        return ScriptedProcess(greeting: [Tools.json(["type": "system", "subtype": "init"])]) { line in
            let message = Tools.object(line)
            guard message["type"] as? String == "control_request", let id = message["request_id"] as? String,
                  let request = message["request"] as? [String: Any] else { return [] }
            let response = request["subtype"] as? String == "get_usage" ? usage : "{}"
            return [#"{"response":{"request_id":"\#(id)","response":\#(response),"subtype":"success"},"type":"control_response"}"#]
        }
    }

    @Test func `Claude Code's get_usage gives the windows without running a turn`() async throws {
        let process = Self.claudeCode(usage: ["rate_limits_available": true, "subscription_type": "max",
                                              "rate_limits": Self.claudeBody])
        let launcher = ScriptedLauncher(process: process)
        let reader = ClaudeCodeUsageReader(launcher: launcher, locator: try Tools.locator("claude"), clock: Self.clock)
        let reading = try await reader.read()
        #expect(reading.windows.first?.percentUsed == 42 && reading.plan == "max")
        #expect(reading.bankedResets == nil && reading.source == "claude_code_get_usage")
        // Only control requests: no user message, so no model turn.
        #expect(process.sent.allSatisfy { Tools.object($0)["type"] as? String == "control_request" })
        let arguments = try #require(launcher.launched.arguments.first)
        #expect(arguments.contains("--no-session-persistence") && arguments.contains("--strict-mcp-config"))
    }

    @Test func `an API-key login has no plan limits`() async throws {
        let process = Self.claudeCode(usage: ["rate_limits_available": false, "rate_limits": NSNull()])
        let reader = ClaudeCodeUsageReader(launcher: ScriptedLauncher(process: process),
                                           locator: try Tools.locator("claude"), clock: Self.clock)
        await #expect(throws: QuotaReadError.self) { try await reader.read() }
    }

    // MARK: Falling back

    struct Fixed: QuotaReader {
        let provider = ProviderKey.claudeCode
        let result: Result<QuotaReading, QuotaReadError>
        func read() async throws(QuotaReadError) -> QuotaReading { try result.get() }
    }

    static let reading = QuotaReading(provider: .claudeCode, observedAt: now, source: "fallback", scope: .account,
                                      plan: nil, windows: [], bankedResets: nil)

    @Test func `a declined Keychain read falls back to Claude Code`() async throws {
        let reader = FallbackQuotaReader([Fixed(result: .failure(.notSignedIn("declined"))),
                                          Fixed(result: .success(Self.reading))])
        #expect(try await reader.read().source == "fallback")
    }

    @Test func `when every source fails, the preferred one's reason is given`() async {
        let reader = FallbackQuotaReader([Fixed(result: .failure(.credentialExpired)),
                                          Fixed(result: .failure(.unreachable("down")))])
        await #expect(throws: QuotaReadError.credentialExpired) { try await reader.read() }
    }

    @Test func `an account without limits does not fall back`() async {
        let reader = FallbackQuotaReader([Fixed(result: .failure(.unsupported("none"))),
                                          Fixed(result: .success(Self.reading))])
        await #expect(throws: QuotaReadError.unsupported("none")) { try await reader.read() }
    }
}

/// The providers' shared timestamp parser, reached from tests.
enum JSONLinesTimestamp {
    static func parse(_ text: String) -> Timestamp? { JSONLines.timestamp(text) }
}
