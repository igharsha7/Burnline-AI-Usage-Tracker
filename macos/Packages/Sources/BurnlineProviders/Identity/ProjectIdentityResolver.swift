//
//  ProjectIdentityResolver.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import CryptoKit
import Foundation

/// Turns a working directory into a project identity, in the contract's order:
/// git remote, then git root, then the directory itself.
///
/// Reads `.git` directly instead of running `git`, because history import
/// resolves thousands of records and spawning a process for each is slow.
/// Results are cached per directory within a sync.
public final class ProjectIdentityResolver: @unchecked Sendable {
    // @unchecked: `cache` is only touched while holding `lock`.
    private let lock = NSLock()
    private var cache: [String: ProjectCandidate] = [:]

    public init() {}

    public func clearCache() {
        lock.withLock { cache.removeAll() }
    }

    public func candidate(forWorkingDirectory path: String) -> ProjectCandidate {
        if let cached = lock.withLock({ cache[path] }) { return cached }
        let candidate = Self.resolve(path)
        lock.withLock { cache[path] = candidate }
        return candidate
    }

    static func resolve(_ path: String) -> ProjectCandidate {
        let directory = canonicalPath(path)
        let exists = FileManager.default.fileExists(atPath: directory)
        guard let repository = GitRepository.containing(directory) else {
            // Outside any repository.
            return ProjectCandidate(identity: .path(pathHash: hash(directory)),
                                    displayName: lastComponent(directory), path: directory,
                                    directoryExists: exists)
        }
        if let url = repository.remoteURL, let remote = GitRemote.normalise(url) {
            // Survives the directory moving, and two clones of one
            // repository agree.
            return ProjectCandidate(identity: .gitRemote(remote),
                                    displayName: GitRemote.name(url) ?? lastComponent(remote), path: repository.root,
                                    directoryExists: exists)
        }
        // No remote: the root path, so a move splits it until merged.
        return ProjectCandidate(identity: .gitRoot(pathHash: hash(repository.root)),
                                displayName: lastComponent(repository.root), path: repository.root,
                                directoryExists: exists)
    }

    /// Absolute, with `.` and `..` removed and symlinks resolved where the path
    /// still exists, so `/tmp/x` and `/private/tmp/x` agree.
    static func canonicalPath(_ path: String) -> String {
        let url = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        let result = url.path(percentEncoded: false)
        return result.count > 1 && result.hasSuffix("/") ? String(result.dropLast()) : result
    }

    static func hash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// The parts of a git repository's layout that identify it.
struct GitRepository {
    /// The working tree root. For a linked worktree, the main repository's
    /// root, so every worktree is one project. A monorepo is one
    /// project at its root, because sub-packages have no `.git`.
    let root: String
    let remoteURL: String?

    /// Walks up from `directory` to the nearest `.git`. Directories that no
    /// longer exist are walked too, so a deleted subdirectory of a repository
    /// that still exists resolves to that repository.
    static func containing(_ directory: String) -> GitRepository? {
        var current = URL(filePath: directory)
        while true {
            let dotGit = current.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue
                    ? GitRepository(root: current.path, gitDirectory: dotGit)
                    : linked(from: dotGit, workingTree: current)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    private init(root: String, gitDirectory: URL) {
        self.root = root
        self.remoteURL = Self.remote(inConfig: gitDirectory.appending(path: "config"))
    }

    /// A `.git` file points elsewhere: `gitdir: <path>`. A linked worktree's
    /// git directory has a `commondir` leading back to the main repository; a
    /// submodule's does not, and it is a repository of its own.
    private static func linked(from dotGitFile: URL, workingTree: URL) -> GitRepository? {
        guard let contents = try? String(contentsOf: dotGitFile, encoding: .utf8),
              let match = contents.firstMatch(of: /gitdir:\s*(.+)/) else { return nil }
        let gitDirectory = resolve(String(match.1), against: workingTree)

        if let common = try? String(contentsOf: gitDirectory.appending(path: "commondir"), encoding: .utf8) {
            let commonDirectory = resolve(common, against: gitDirectory)
            let mainRoot = commonDirectory.lastPathComponent == ".git"
                ? commonDirectory.deletingLastPathComponent().path
                : commonDirectory.path
            return GitRepository(root: ProjectIdentityResolver.canonicalPath(mainRoot), gitDirectory: commonDirectory)
        }
        return GitRepository(root: workingTree.path, gitDirectory: gitDirectory)
    }

    /// A path from a git pointer file: absolute as written, or relative to
    /// `directory` itself (not to its parent).
    private static func resolve(_ pointer: String, against directory: URL) -> URL {
        let path = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
        return url.standardizedFileURL
    }

    /// The `origin` URL from a git config file, or the first remote's when
    /// there is no `origin`.
    static func remote(inConfig config: URL) -> String? {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        var section: String?
        var urls: [(remote: String, url: String)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let header = line.wholeMatch(of: /\[\s*remote\s+"([^"]+)"\s*\]/) {
                section = String(header.1)
            } else if line.hasPrefix("[") {
                section = nil
            } else if let remote = section, let entry = line.wholeMatch(of: /url\s*=\s*(.+)/) {
                urls.append((remote, String(entry.1)))
            }
        }
        return urls.first { $0.remote == "origin" }?.url ?? urls.first?.url
    }
}
