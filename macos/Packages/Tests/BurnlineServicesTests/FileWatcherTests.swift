//
//  FileWatcherTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

@testable import BurnlineServices
import BurnlineTestSupport
import Foundation
import Testing

/// FSEvents, as the watcher reports it. The stream is running once `init`
/// returns, so a write after that is always seen.
struct FileWatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func `a write in a watched directory is reported within seconds`() async throws {
        let directory = TestDirectory.make("Watched")
        let watcher = try #require(FileWatcher(directory: directory))
        let changes = watcher.changes

        let written = ContinuousClock.now
        try Data("{}\n".utf8).write(to: directory.appending(path: "session.jsonl"))

        #expect(await within(seconds: 10) { await changes.first { _ in true } } != nil)
        // The latency is a second; leave room for a busy machine.
        #expect(ContinuousClock.now - written < .seconds(10))
    }

    @Test func `a directory that does not exist is not watched, and the sweep covers it`() {
        #expect(FileWatcher(directory: TestDirectory.make("Watched").appending(path: "missing")) == nil)
    }
}
