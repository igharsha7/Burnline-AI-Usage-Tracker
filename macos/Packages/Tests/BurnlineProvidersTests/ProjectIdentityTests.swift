//
//  ProjectIdentityTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineProviders
import BurnlineTestSupport
import Foundation
import Testing

/// Builds minimal git layouts on disk: only the files the resolver reads.
struct GitFixture {
    let root: URL

    init() throws {
        root = TestDirectory.make("GitFixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func repository(_ name: String, remote: String?) throws -> URL {
        let directory = root.appending(path: name)
        let git = directory.appending(path: ".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        var config = "[core]\n\tbare = false\n"
        if let remote { config += "[remote \"origin\"]\n\turl = \(remote)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n" }
        try config.write(to: git.appending(path: "config"), atomically: true, encoding: .utf8)
        return directory
    }

    func path(_ url: URL) -> String { ProjectIdentityResolver.canonicalPath(url.path) }
}

struct GitRemoteTests {
    @Test(arguments: [
        ("git@github.com:igharsha7/Burnline.git", "github.com/igharsha7/burnline"),
        ("https://github.com/igharsha7/Burnline", "github.com/igharsha7/burnline"),
        ("https://github.com/igharsha7/Burnline.git/", "github.com/igharsha7/burnline"),
        ("ssh://git@github.com:22/igharsha7/Burnline.git", "github.com/igharsha7/burnline"),
        ("https://user:ghp_secret@GitHub.com/igharsha7/Burnline.git", "github.com/igharsha7/burnline"),
        ("git://gitlab.example.com/group/sub/repo.git", "gitlab.example.com/group/sub/repo"),
    ])
    func `EC-P8 every form of a remote normalises to host, owner, repository`(url: String, expected: String) {
        #expect(GitRemote.normalise(url) == expected)
    }

    @Test(arguments: ["/srv/git/repo.git", "../sibling", "file:///srv/git/repo.git", "C:\\repos\\x", "", "https://github.com/"])
    func `local or empty remotes are not identities`(url: String) {
        #expect(GitRemote.normalise(url) == nil)
    }

    @Test func `the repository's name keeps the case its remote gives it`() {
        #expect(GitRemote.name("https://github.com/igharsha7/Burnline-AI-Usage-Tracker.git") == "Burnline-AI-Usage-Tracker")
        #expect(GitRemote.name("git@github.com:vidh-co/vidh-medha.git") == "vidh-medha")
    }

    @Test func `credentials never survive normalisation`() {
        #expect(GitRemote.normalise("https://user:ghp_secret@github.com/a/b")?.contains("secret") == false)
    }
}

struct ProjectIdentityTests {
    @Test func `EC-P1 a repository with a remote keeps its identity when moved`() throws {
        let fixture = try GitFixture()
        let original = try fixture.repository("before", remote: "git@github.com:me/app.git")
        let first = ProjectIdentityResolver.resolve(original.appending(path: "src").path)

        let moved = fixture.root.appending(path: "renamed-elsewhere")
        try FileManager.default.moveItem(at: original, to: moved)
        let second = ProjectIdentityResolver.resolve(moved.path)

        #expect(first.identity == .gitRemote("github.com/me/app"))
        #expect(second.identity == first.identity)
        #expect(second.path == fixture.path(moved))
    }

    @Test func `EC-P2 a repository without a remote is identified by its root`() throws {
        let fixture = try GitFixture()
        let repository = try fixture.repository("local-only", remote: nil)
        let candidate = ProjectIdentityResolver.resolve(repository.appending(path: "deep/inside").path)
        #expect(candidate.identity == .gitRoot(pathHash: ProjectIdentityResolver.hash(fixture.path(repository))))
        #expect(candidate.displayName == "local-only")
    }

    @Test func `EC-P3 two clones of one repository are one project`() throws {
        let fixture = try GitFixture()
        let ssh = try fixture.repository("clone-a", remote: "git@github.com:me/app.git")
        let https = try fixture.repository("clone-b", remote: "https://github.com/me/app")
        #expect(ProjectIdentityResolver.resolve(ssh.path).identity
            == ProjectIdentityResolver.resolve(https.path).identity)
    }

    @Test func `EC-P4 a linked worktree resolves to the main repository`() throws {
        let fixture = try GitFixture()
        let main = try fixture.repository("main", remote: "git@github.com:me/app.git")
        let worktreeGit = main.appending(path: ".git/worktrees/feature")
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try "../..\n".write(to: worktreeGit.appending(path: "commondir"), atomically: true, encoding: .utf8)
        let worktree = fixture.root.appending(path: "feature-checkout")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGit.path)\n".write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)

        let candidate = ProjectIdentityResolver.resolve(worktree.path)
        #expect(candidate.identity == .gitRemote("github.com/me/app"))
        #expect(candidate.path == fixture.path(main))
    }

    @Test func `EC-P4 a worktree of a repository without a remote shares its root identity`() throws {
        let fixture = try GitFixture()
        let main = try fixture.repository("main", remote: nil)
        let worktreeGit = main.appending(path: ".git/worktrees/wt")
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try "../..".write(to: worktreeGit.appending(path: "commondir"), atomically: true, encoding: .utf8)
        let worktree = fixture.root.appending(path: "wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGit.path)".write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)

        #expect(ProjectIdentityResolver.resolve(worktree.path).identity
            == ProjectIdentityResolver.resolve(main.path).identity)
    }

    @Test func `a submodule is a project of its own`() throws {
        let fixture = try GitFixture()
        let parent = try fixture.repository("parent", remote: "git@github.com:me/parent.git")
        let moduleGit = parent.appending(path: ".git/modules/lib")
        try FileManager.default.createDirectory(at: moduleGit, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = https://github.com/me/lib.git\n"
            .write(to: moduleGit.appending(path: "config"), atomically: true, encoding: .utf8)
        let submodule = parent.appending(path: "vendor/lib")
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        try "gitdir: ../../.git/modules/lib".write(to: submodule.appending(path: ".git"), atomically: true, encoding: .utf8)

        #expect(ProjectIdentityResolver.resolve(submodule.path).identity == .gitRemote("github.com/me/lib"))
    }

    @Test func `EC-P5 a monorepo package is the repository at its root`() throws {
        let fixture = try GitFixture()
        let repository = try fixture.repository("mono", remote: "git@github.com:me/mono.git")
        let package = repository.appending(path: "packages/web")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(ProjectIdentityResolver.resolve(package.path).identity == .gitRemote("github.com/me/mono"))
    }

    @Test func `EC-P6 a directory outside any repository is a normalised path hash`() throws {
        let fixture = try GitFixture()
        let plain = fixture.root.appending(path: "notes")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let direct = ProjectIdentityResolver.resolve(plain.path)
        let roundabout = ProjectIdentityResolver.resolve(plain.path + "/./sub/..")

        #expect(direct.identity == .path(pathHash: ProjectIdentityResolver.hash(fixture.path(plain))))
        #expect(roundabout.identity == direct.identity)
    }

    @Test func `a deleted directory inside a surviving repository resolves to it`() throws {
        let fixture = try GitFixture()
        let repository = try fixture.repository("kept", remote: "git@github.com:me/kept.git")
        let gone = repository.appending(path: "removed/long/ago").path
        #expect(ProjectIdentityResolver.resolve(gone).identity == .gitRemote("github.com/me/kept"))
    }

    @Test func `origin is preferred, and any remote is used without it`() throws {
        let config = TestDirectory.file("config")
        try "[remote \"upstream\"]\n\turl = git@a.com:x/up.git\n[remote \"origin\"]\n\turl = git@a.com:x/mine.git\n"
            .write(to: config, atomically: true, encoding: .utf8)
        #expect(GitRepository.remote(inConfig: config) == "git@a.com:x/mine.git")
        try "[remote \"upstream\"]\n\turl = git@a.com:x/up.git\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(GitRepository.remote(inConfig: config) == "git@a.com:x/up.git")
    }
}
