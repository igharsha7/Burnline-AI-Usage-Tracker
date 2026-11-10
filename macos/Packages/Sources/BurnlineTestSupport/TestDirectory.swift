//
//  TestDirectory.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// Scratch directories for tests, all inside one folder per test run that is
/// removed when the run ends. A run that crashed leaves its folder behind,
/// and the next run removes it, so the temporary directory never accumulates.
///
/// Only folders named `BurnlineTests-<pid>` directly inside the system
/// temporary directory are ever removed, so a mistake here cannot reach a
/// provider's real history or anything else of the user's.
public enum TestDirectory {
    static let prefix = "BurnlineTests-"

    /// A new, empty directory, removed with the rest of the run.
    public static func make(_ name: String) -> URL {
        let directory = root.appending(path: "\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A path in a new directory, for a test that writes one file.
    public static func file(_ name: String) -> URL {
        make("file").appending(path: name)
    }

    static let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()

    static let root: URL = {
        sweepFinishedRuns()
        let root = temporary.appending(path: "\(prefix)\(getpid())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        atexit { TestDirectory.remove(TestDirectory.temporary.appending(path: "\(TestDirectory.prefix)\(getpid())")) }
        return root
    }()

    /// Removes the folders of earlier runs whose process has exited.
    static func sweepFinishedRuns() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            guard let pid = Int32(name.dropFirst(prefix.count)), pid != getpid(),
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            remove(temporary.appending(path: name))
        }
    }

    /// Removes `directory` only if it is a run folder directly inside the
    /// system temporary directory.
    static func remove(_ directory: URL) {
        let resolved = directory.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent().path == temporary.path,
              resolved.lastPathComponent.hasPrefix(prefix) else { return }
        try? FileManager.default.removeItem(at: resolved)
    }
}
