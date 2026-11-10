//
//  GitRemote.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// Normalises a git remote URL to `host/owner/repo`, so that every form of
/// the same remote identifies the same project:
///
///     git@github.com:owner/repo.git        → github.com/owner/repo
///     ssh://git@github.com:22/owner/repo   → github.com/owner/repo
///     https://user:token@github.com/owner/repo.git/ → github.com/owner/repo
///
/// Credentials are dropped, never stored. A local path or `file://` remote
/// returns nil: it names a directory on this machine, which is no more stable
/// than the repository's own path.
enum GitRemote {
    static func normalise(_ url: String) -> String? {
        repository(url).map { "\($0.host)/\($0.path)".lowercased() }
    }

    /// The repository's own name, in the case its remote gives it, so
    /// `Burnline-AI-Usage-Tracker` is not shown as `burnline-ai-usage-tracker`.
    static func name(_ url: String) -> String? {
        repository(url)?.path.split(separator: "/").last.map(String.init)
    }

    private static func repository(_ url: String) -> (host: String, path: String)? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let host: String
        let path: String
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  components.scheme?.lowercased() != "file",
                  let parsedHost = components.host, !parsedHost.isEmpty else { return nil }
            host = parsedHost
            path = components.path
        } else if let match = trimmed.wholeMatch(of: /(?:[^@\/]+@)?([^:\/]+):(.+)/) {
            // scp-like syntax, `user@host:path`. A Windows drive letter would
            // also match, so a one-letter host is treated as a local path.
            guard match.1.count > 1 else { return nil }
            host = String(match.1)
            path = String(match.2)
        } else {
            return nil
        }

        var repository = path
        while repository.hasPrefix("/") { repository.removeFirst() }
        while repository.hasSuffix("/") { repository.removeLast() }
        if repository.lowercased().hasSuffix(".git") { repository.removeLast(4) }
        guard !repository.isEmpty else { return nil }
        // Hosts are case-insensitive, and the major forges treat owner and
        // repository names the same way, so `normalise` lowercases both and
        // two clones typed differently agree.
        return (host, repository)
    }
}
