//
//  ProviderHomes.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// Every place a provider's tool keeps history on this Mac. The command-line
/// tools and their VS Code and desktop front ends share one home each, but
/// Xcode's coding assistant runs its own copies of Claude Code and Codex with
/// separate homes, so a lifetime total has to read both. Events carry the
/// provider's own ids, so one seen from two homes is still stored once.
enum ProviderHomes {
    static var user: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var xcodeAssistant: URL { user.appending(path: "Library/Developer/Xcode/CodingAssistant") }

    /// `$CLAUDE_CONFIG_DIR` or `~/.claude`, then Xcode's.
    static func claude(environment: [String: String]) -> [URL] {
        [environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0) } ?? user.appending(path: ".claude"),
         xcodeAssistant.appending(path: "ClaudeAgentConfig")]
    }

    /// `$CODEX_HOME` or `~/.codex`, then Xcode's.
    static func codex(environment: [String: String]) -> [URL] {
        [environment["CODEX_HOME"].map { URL(filePath: $0) } ?? user.appending(path: ".codex"),
         xcodeAssistant.appending(path: "codex")]
    }

    /// The directories in `candidates` that exist.
    static func existing(_ candidates: [URL]) -> [URL] {
        candidates.filter { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}
