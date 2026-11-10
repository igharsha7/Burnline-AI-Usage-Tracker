//
//  ChildProcessTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineProviders
import BurnlineTestSupport
import Foundation
import Testing

/// Starts real processes and keeps them, so a test can check none outlives
/// its read.
final class KeepingLauncher: ProcessLauncher, @unchecked Sendable {
    // @unchecked: `kept` is only touched under `lock`.
    private let lock = NSLock()
    private var kept: [RunningProcess] = []

    var launched: [RunningProcess] { lock.withLock { kept } }

    func launch(_ executable: URL, arguments: [String], workingDirectory: URL) throws -> any LineProcess {
        let process = try RunningProcess(executable, arguments: arguments, workingDirectory: workingDirectory)
        lock.withLock { kept.append(process) }
        return process
    }
}

/// The quota readers against real child processes: fake `codex` scripts in a
/// scratch directory. Each read must leave no process behind, however the
/// tool behaves.
@Suite(.timeLimit(.minutes(1)))
struct ChildProcessTests {
    /// How long a real child may take to answer: a bound, not an expectation.
    /// Answers take milliseconds here, but a shared CI runner, starved by the
    /// whole suite running at once, once took over five seconds to start one.
    static let answerWithin = 30.0

    /// A `codex` that runs `script`, and a reader that starts it.
    static func reader(_ script: String, timeout: Double = answerWithin) throws -> (CodexAppServerReader, KeepingLauncher) {
        let directory = TestDirectory.make("FakeCodex")
        let tool = directory.appending(path: "codex")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let launcher = KeepingLauncher()
        let reader = CodexAppServerReader(
            launcher: launcher, locator: ExecutableLocator(environment: ["PATH": directory.path], installDirectories: []),
            clock: ManualClock(Timestamp(epochSeconds: 1_793_541_600)), workingDirectory: directory, timeout: timeout)
        return (reader, launcher)
    }

    /// `launcher` started the tool, and every process it started has exited.
    static func allExited(_ launcher: KeepingLauncher) -> Bool {
        for process in launcher.launched { process.waitUntilExit() }
        return !launcher.launched.isEmpty && launcher.launched.allSatisfy { kill($0.processIdentifier, 0) != 0 }
    }

    /// Whether `pid` is gone within a few seconds. Closed output alone does not
    /// prove a descendant exited; this does.
    static func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<Int(RunningProcess.killGrace + 3) * 10 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return kill(pid, 0) != 0
    }

    @Test func `sending after a child exits throws instead of terminating Burnline`() throws {
        let directory = TestDirectory.make("ExitedChild")
        let process = try RunningProcess(URL(filePath: "/bin/sh"), arguments: ["-c", "exit 0"],
                                         workingDirectory: directory)
        let launched = Self.identity(of: process.inputDescriptor)
        process.waitUntilExit()
        do {
            try process.send("request")
            // This once passed on a busy CI runner. Say what the pipe was, so
            // the next time explains itself.
            Issue.record("""
                The send to an exited child succeeded. Running: \(process.isRunning), \
                exit status: \(process.terminationStatus.map(String.init) ?? "none yet"), descriptor \(process.inputDescriptor) \
                at launch: \(launched), now: \(Self.identity(of: process.inputDescriptor)), \
                flags: \(fcntl(process.inputDescriptor, F_GETFD)), status flags: \(fcntl(process.inputDescriptor, F_GETFL)).
                Holders of this pipe:
                \(Self.holders(of: process.inputDescriptor))
                """)
        } catch {}
    }

    /// A descriptor's file type, device and inode, or why it has none.
    static func identity(of descriptor: Int32) -> String {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return "fstat failed, errno \(errno)" }
        let type = info.st_mode & S_IFMT == S_IFIFO ? "pipe" : "type \(info.st_mode & S_IFMT)"
        return "\(type) dev \(info.st_dev) inode \(info.st_ino)"
    }

    /// Every process holding either end of the pipe behind `descriptor`, from
    /// lsof: this process's line names the pipe, and each holder's line names it too.
    static func holders(of descriptor: Int32) -> String {
        func lsof(_ arguments: [String]) -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(filePath: "/usr/sbin/lsof")
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let own = lsof(["-n", "-a", "-p", "\(getpid())", "-d", "\(descriptor)"])
        let addresses = own.matches(of: /0x[0-9a-f]+/).map { String($0.output) }
        guard !addresses.isEmpty else { return own.isEmpty ? "lsof found nothing" : own }
        return lsof(["-n"]).split(separator: "\n").filter { line in addresses.contains { line.contains($0) } }
            .joined(separator: "\n")
    }

    @Test func `a tool ignoring SIGTERM cannot leave its stdout-holding child behind`() async throws {
        let directory = TestDirectory.make("ToolDescendant")
        let process = try RunningProcess(URL(filePath: "/bin/sh"), arguments: ["-c", """
            trap '' TERM
            /bin/sleep 30 &
            child=$!
            echo "$child"
            while IFS= read -r line; do :; done
            wait "$child"
            """], workingDirectory: directory)
        let line = try #require(try await firstLine(of: process, within: Self.answerWithin) { _ in true })
        let child = try #require(Int32(line))
        defer {
            if getpgid(child) == process.processIdentifier { kill(child, SIGKILL) }
            process.terminate()
        }
        process.terminate()
        process.waitUntilExit()
        #expect(try await firstLine(of: process, within: RunningProcess.killGrace + 3) { _ in true } == nil)
        #expect(await Self.gone(child))
    }

    @Test(arguments: [false, true])
    func `an exited tool cannot leave a SIGTERM-ignoring helper holding stdout`(exitsOnItsOwn: Bool) async throws {
        let directory = TestDirectory.make("ExitedToolDescendant")
        let process = try RunningProcess(URL(filePath: "/bin/sh"), arguments: ["-c", """
            /bin/sh -c 'trap "" TERM; echo ready; exec /bin/sleep 30' &
            child=$!
            echo "$child"
            trap 'exit 0' TERM
            \(exitsOnItsOwn ? "exit 0" : "wait \"$child\"")
            """], workingDirectory: directory)
        let line = try #require(try await firstLine(of: process, within: Self.answerWithin) { Int32($0) != nil })
        let child = try #require(Int32(line))
        defer { kill(child, SIGKILL); process.terminate() }
        #expect(try await firstLine(of: process, within: Self.answerWithin) { $0 == "ready" } == "ready")
        if exitsOnItsOwn { process.waitUntilExit() }
        process.terminate()
        process.waitUntilExit()
        #expect(try await firstLine(of: process, within: RunningProcess.killGrace + 3) { _ in true } == nil)
        #expect(await Self.gone(child))
    }

    @Test func `a tool that answers is stopped once the read is done`() async throws {
        // Answers both requests, then waits for more input, as the app-server does.
        let (reader, launcher) = try Self.reader(#"""
            while IFS= read -r line; do
              case "$line" in
                *'"id":1'*) echo '{"id":1,"result":{}}' ;;
                *'"id":2'*) echo '{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":1793555131}}}}' ;;
              esac
            done
            """#)
        let reading = try await reader.read()
        #expect(reading.windows.map(\.key) == ["five_hour"])
        #expect(launcher.launched.count == 1 && Self.allExited(launcher))
    }

    @Test func `EC-Q3 a tool that never answers is stopped when the read times out`() async throws {
        let (reader, launcher) = try Self.reader("while IFS= read -r line; do :; done\n", timeout: 1)
        await #expect(throws: QuotaReadError.unreachable("no answer within 1 seconds")) { try await reader.read() }
        #expect(Self.allExited(launcher))
    }

    @Test func `a tool that ignores the request to stop is killed`() async throws {
        // Never answers, never reads, and ignores SIGTERM.
        let (reader, launcher) = try Self.reader("trap '' TERM\nwhile :; do sleep 1; done\n", timeout: 1)
        await #expect(throws: QuotaReadError.self) { try await reader.read() }
        #expect(Self.allExited(launcher))
    }
}
