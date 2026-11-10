//
//  SourceTree.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// The Swift sources the fitness tests read, located from this file so the
/// tests run from any working directory.
enum SourceTree {
    static let macosRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()   // ArchitectureTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // macos

    static let modules = ["BurnlineCore", "BurnlineStore", "BurnlineProviders",
                          "BurnlineServices", "BurnlineUI", "Burnline"]

    /// `Burnline` is the app target; the rest are package modules.
    static func directory(for module: String) -> URL {
        module == "Burnline"
            ? macosRoot.appending(path: "Burnline")
            : macosRoot.appending(path: "Packages/Sources/\(module)")
    }

    static func swiftFiles(under directory: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Every app and module source file.
    static var allSwiftFiles: [URL] {
        modules.flatMap { swiftFiles(under: directory(for: $0)) }
    }

    /// The file with comments and string contents blanked out.
    static func code(of file: URL) throws -> String {
        SwiftSource.code(try String(contentsOf: file, encoding: .utf8))
    }
}
