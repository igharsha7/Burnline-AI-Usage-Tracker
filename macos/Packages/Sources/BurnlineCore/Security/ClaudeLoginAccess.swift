//
//  ClaudeLoginAccess.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// Whether Burnline may read Claude Code's login from the Keychain, and how
/// the last read went. Shared by the reader that uses the login and the
/// interface that lets the user turn reading off or allow it again.
///
/// Claude Code rewrites its Keychain item each time it renews its login, and
/// macOS then forgets that Burnline was allowed to read it. Reads made on
/// schedule are therefore silent: when macOS would ask, the read is refused,
/// quota comes through Claude Code itself, and the status says permission is
/// needed. macOS's prompt appears only when the user asks for it, through
/// `requestPrompt()`, or on the very first read on this Mac.
public final class ClaudeLoginAccess: @unchecked Sendable {
    // @unchecked: every stored property is read and written under `lock`.

    public enum Status: Sendable, Equatable {
        /// Not read yet this session.
        case unknown
        /// The last read succeeded.
        case allowed
        /// macOS would have asked, so the read was refused without asking,
        /// as after Claude Code renews its login.
        case needsPermission
        /// The user declined macOS's prompt.
        case declined
        /// Reading the login is turned off in Settings.
        case off
    }

    private let lock = NSLock()
    private var enabled: Bool
    private var prompt: Bool
    private var current: Status

    /// `mayAsk` lets the first read show macOS's prompt, for a Mac where
    /// Burnline has never asked.
    public init(enabled: Bool, mayAsk: Bool = false) {
        self.enabled = enabled
        prompt = mayAsk
        current = enabled ? .unknown : .off
    }

    public var isEnabled: Bool { lock.withLock { enabled } }
    public var status: Status { lock.withLock { current } }

    /// Turns reading on or off. Turning it off withdraws a pending prompt.
    public func setEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            if !enabled { prompt = false }
            current = enabled ? .unknown : .off
        }
    }

    /// Lets the next read show macOS's prompt, because the user asked.
    public func requestPrompt() {
        lock.withLock { if enabled { prompt = true } }
    }

    /// Whether this read may ask, consuming the request so that only one
    /// read does.
    public func takePrompt() -> Bool {
        lock.withLock {
            defer { prompt = false }
            return prompt && enabled
        }
    }

    /// The outcome of a read, for the interface to show. A silent refusal
    /// after the user declined still reads as declined.
    public func record(_ status: Status) {
        lock.withLock {
            guard enabled, !(current == .declined && status == .needsPermission) else { return }
            current = status
        }
    }
}
