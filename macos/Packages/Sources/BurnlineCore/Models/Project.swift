//
//  Project.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// How a project was identified. The cases have different stability: a git
/// remote survives the directory moving, a path hash does not, which is why
/// resolution tries them in this order.
public enum ProjectIdentity: Hashable, Sendable {
    /// Normalised to `host/owner/repo`.
    case gitRemote(String)
    /// SHA-256 of the repository root, for repositories without a remote.
    case gitRoot(pathHash: String)
    /// SHA-256 of the working directory, outside any repository.
    case path(pathHash: String)

    /// The `projects.identity_kind` column.
    public var kind: String {
        switch self {
        case .gitRemote: "git_remote"
        case .gitRoot: "git_root"
        case .path: "path"
        }
    }

    /// The `projects.identity_key` column.
    public var key: String {
        switch self {
        case .gitRemote(let remote): remote
        case .gitRoot(let hash), .path(let hash): hash
        }
    }
}

public struct Project: Hashable, Sendable, Identifiable {
    public let id: Int64
    public let identity: ProjectIdentity
    public let displayName: String
    public let userAlias: String?
    public let lastKnownPath: String?
    /// Set when the user merged this project into another. Rows are never
    /// rewritten; readers follow the redirect, so a merge can be undone.
    public let mergedIntoID: Int64?
    public let firstSeenAt: Timestamp
    public let lastSeenAt: Timestamp

    public init(id: Int64, identity: ProjectIdentity, displayName: String, userAlias: String?,
                lastKnownPath: String?, mergedIntoID: Int64?,
                firstSeenAt: Timestamp, lastSeenAt: Timestamp) {
        self.id = id
        self.identity = identity
        self.displayName = displayName
        self.userAlias = userAlias
        self.lastKnownPath = lastKnownPath
        self.mergedIntoID = mergedIntoID
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    /// What the interface shows: the user's alias when they set one.
    public var name: String { userAlias ?? derivedName }

    /// The name its identity gave it, made readable.
    public var derivedName: String { ProjectName.readable(displayName, path: lastKnownPath) }
}

/// Turns a project's derived name, a repository or folder slug such as
/// `Burnline-AI-Usage-Tracker` or `crop_recommendation`, into one to read:
/// `Burnline AI Usage Tracker`, `Crop Recommendation`.
///
/// Only the stored name is touched; a name the user gave is shown as typed.
public enum ProjectName {
    /// `name` as stored, from a project last seen at `path`. A name with a
    /// space in it was written as prose and is kept. Hyphens between digits
    /// stay, so a date reads as one.
    public static func readable(_ name: String, path: String?) -> String {
        let name = withCase(name, path: path)
        guard !name.contains(" ") else { return name }
        var words: [String] = [], word = "", separator = ""
        for character in name {
            if character == "-" || character == "_" {
                separator.append(character)
                continue
            }
            if !separator.isEmpty, !word.isEmpty {
                if separator == "-", word.last!.isNumber, character.isNumber {
                    word += separator
                } else {
                    words.append(word)
                    word = ""
                }
            }
            separator = ""
            word.append(character)
        }
        if !word.isEmpty { words.append(word) }
        guard !words.isEmpty else { return name }
        // An all-lowercase slug gets capitals; one that has any keeps its own.
        let lowercase = name == name.lowercased()
        return words.map { word in
            lowercase && word.allSatisfy(\.isLetter) ? word.prefix(1).uppercased() + word.dropFirst() : word
        }.joined(separator: " ")
    }

    /// Projects stored before names kept their case hold a lowercased
    /// remote name. The folder they were last seen in is the same name with
    /// the case the user gave it, when the two agree but for case and
    /// separators.
    private static func withCase(_ name: String, path: String?) -> String {
        guard name == name.lowercased(),
              let folder = path?.split(separator: "/").last.map(String.init) else { return name }
        let letters = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return letters(folder) == letters(name) ? folder : name
    }
}

public struct Session: Hashable, Sendable, Identifiable {
    public let id: Int64
    public let provider: ProviderKey
    public let sourceSessionID: String
    public let projectID: Int64?
    public let startedAt: Timestamp
    public let endedAt: Timestamp?

    public init(id: Int64, provider: ProviderKey, sourceSessionID: String, projectID: Int64?,
                startedAt: Timestamp, endedAt: Timestamp?) {
        self.id = id
        self.provider = provider
        self.sourceSessionID = sourceSessionID
        self.projectID = projectID
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}
