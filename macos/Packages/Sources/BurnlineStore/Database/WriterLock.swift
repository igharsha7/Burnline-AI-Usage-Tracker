//
//  WriterLock.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// An advisory lock that keeps a second Burnline process from writing to the
/// same database. Readers do not take it.
///
/// `flock` locks belong to the open file, not the process, so the lock is
/// released by the kernel if Burnline crashes; there is no stale lock file to
/// clean up.
final class WriterLock: Sendable {
    private let descriptor: Int32

    /// Nil when another process already holds the lock.
    init?(path: URL) throws(StoreError) {
        let descriptor = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw .sqlite("cannot open lock file \(path.path): \(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
