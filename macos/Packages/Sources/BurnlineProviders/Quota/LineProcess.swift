//
//  LineProcess.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// A child process spoken to one line of JSON at a time, as the Codex
/// app-server and Claude Code's stream-json mode both are.
public protocol LineProcess: Sendable {
    func send(_ line: String) throws
    /// Lines from the process's standard output, ending when it exits.
    var lines: AsyncThrowingStream<String, any Error> { get }
    func terminate()
}

/// Starts processes, so tests can supply scripted ones.
public protocol ProcessLauncher: Sendable {
    func launch(_ executable: URL, arguments: [String], workingDirectory: URL) throws -> any LineProcess
}

/// Waits for a line `matching`, skipping every other, for at most `seconds`.
/// Nil when the process ends first.
func firstLine(of process: any LineProcess, within seconds: Double,
               matching: @escaping @Sendable (String) -> Bool) async throws(QuotaReadError) -> String? {
    do {
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for try await line in process.lines where matching(line) { return line }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw QuotaReadError.unreachable("no answer within \(Int(seconds)) seconds")
            }
            let line = try await group.next() ?? nil
            group.cancelAll()
            return line
        }
    } catch let error as QuotaReadError {
        throw error
    } catch {
        throw .unreachable("the tool stopped answering")
    }
}

/// Runs real processes. Standard error is discarded: it can carry anything
/// the tool chooses to print, and none of it is needed.
public struct SystemProcessLauncher: ProcessLauncher {
    public init() {}

    public func launch(_ executable: URL, arguments: [String], workingDirectory: URL) throws -> any LineProcess {
        try RunningProcess(executable, arguments: arguments, workingDirectory: workingDirectory)
    }
}

final class RunningProcess: LineProcess, @unchecked Sendable {
    // @unchecked: `process` and the pipes are set once in init; Process and
    // FileHandle are safe to use from any thread for what is done here.
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    let lines: AsyncThrowingStream<String, any Error>

    init(_ executable: URL, arguments: [String], workingDirectory: URL) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.environment(for: executable)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let handle = output.fileHandleForReading
        lines = AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in handle.bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        // A child can exit between a response and the next request. Keep
        // EPIPE local to this descriptor instead of terminating the app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try process.run()
    }

    func send(_ line: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Closes its input and asks it to stop, then kills its process group
    /// after `killGrace`: neither the tool nor its stdout-holding helpers
    /// may outlive the read.
    func terminate() {
        try? input.fileHandleForWriting.close()
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if process.isRunning { process.terminate() }
        // The leader may exit on EOF or SIGTERM while a helper still holds
        // stdout. Its process group must be stopped even after that exit.
        nonisolated(unsafe) let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
            // Foundation launches the tool in its own process group.
            kill(-pid, SIGKILL)
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    static let killGrace: Double = 2

    var processIdentifier: Int32 { process.processIdentifier }

    /// Blocks until the process has exited, for tests.
    func waitUntilExit() { process.waitUntilExit() }

    deinit { terminate() }

    /// The user's environment, with the tool's own directory and the usual
    /// install locations on `PATH`: an app started from the Dock inherits only
    /// the system's, and a tool may start helpers by name.
    static func environment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = [executable.deletingLastPathComponent().path] + ExecutableLocator.commonDirectories.map(\.path)
            + (environment["PATH"].map { [$0] } ?? [])
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }
}

/// Finds a provider's command-line tool where its installers put it.
public struct ExecutableLocator: Sendable {
    let environment: [String: String]
    let installDirectories: [URL]
    let extraCandidates: [URL]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                installDirectories: [URL] = Self.commonDirectories, extraCandidates: [URL] = []) {
        self.environment = environment
        self.installDirectories = installDirectories
        self.extraCandidates = extraCandidates
    }

    public static var commonDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appending(path: ".local/bin"), URL(filePath: "/opt/homebrew/bin"),
                URL(filePath: "/usr/local/bin"), home.appending(path: ".npm-global/bin"),
                home.appending(path: ".bun/bin"), home.appending(path: ".volta/bin")]
    }

    /// The first executable called `name` on `PATH`, in the usual install
    /// locations, or among `extraCandidates`.
    public func find(_ name: String) -> URL? {
        let onPath = (environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0)) }
        let candidates = (onPath + installDirectories).map { $0.appending(path: name) } + extraCandidates
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
