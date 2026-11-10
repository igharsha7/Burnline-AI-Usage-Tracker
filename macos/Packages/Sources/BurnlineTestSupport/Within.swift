//
//  Within.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// Awaits `body`, giving up after `seconds` with nil, so a change a test is
/// waiting for that never comes fails the test instead of hanging the run.
/// `body` must stop when cancelled, as iterating an `AsyncStream` does.
///
///     let change = await within { await stream.first { _ in true } }
public func within<T: Sendable>(seconds: Double = 2, _ body: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Waits for `condition` to hold, as when a change lands on a task the code
/// under test owns. Gives up after `seconds` and returns false, so a change
/// that never arrives fails the test instead of hanging it.
public func eventually(within seconds: Int = 2, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<seconds * 100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
