//
//  TestDirectoryTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

@testable import BurnlineTestSupport
import Foundation
import Testing

/// The tests' scratch cleanup removes run folders and nothing else.
struct TestDirectoryTests {
    @Test func `scratch directories live inside this run's folder`() {
        let directory = TestDirectory.make("probe")
        #expect(directory.deletingLastPathComponent().path == TestDirectory.root.path)
        #expect(TestDirectory.root.lastPathComponent == "BurnlineTests-\(getpid())")
    }

    @Test func `removal refuses anything but a run folder in the temporary directory`() throws {
        // Decoys of our own: one outside the run-folder name, and one nested
        // a level down with the run-folder name.
        let decoy = TestDirectory.temporary.appending(path: "NotBurnline-\(UUID().uuidString)")
        let nested = TestDirectory.make("nested").appending(path: "BurnlineTests-1")
        for directory in [decoy, nested] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            TestDirectory.remove(directory)
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
        try FileManager.default.removeItem(at: decoy)
    }

    @Test func `a finished run's folder is swept, a live one is kept`() throws {
        // Process 1 is launchd, always alive; a pid this large is never in use.
        let live = TestDirectory.temporary.appending(path: "BurnlineTests-1")
        let finished = TestDirectory.temporary.appending(path: "BurnlineTests-99999999")
        let liveExisted = FileManager.default.fileExists(atPath: live.path)
        for directory in [live, finished] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        TestDirectory.sweepFinishedRuns()
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(!FileManager.default.fileExists(atPath: finished.path))
        if !liveExisted { try FileManager.default.removeItem(at: live) }
    }
}
