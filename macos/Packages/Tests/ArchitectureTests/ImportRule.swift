//
//  ImportRule.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// The module dependency rule from the architecture document, as data.
///
/// Burnline modules may import only the Burnline modules listed for them. The
/// core is stricter still: Foundation and nothing else. GRDB belongs to the
/// store alone, and the UI frameworks, Sparkle among them, belong to the UI
/// and the app.
struct ImportRule {
    let module: String
    let allowedBurnline: Set<String>
    /// When set, every import must be in it. Used for the core.
    let onlyExternal: Set<String>?

    static let burnlineModules: Set<String> = [
        "BurnlineCore", "BurnlineStore", "BurnlineProviders", "BurnlineServices", "BurnlineUI",
    ]
    static let storeOnly: Set<String> = ["GRDB"]
    static let interfaceOnly: Set<String> = ["SwiftUI", "AppKit", "Charts", "Sparkle"]

    static let all: [ImportRule] = [
        ImportRule(module: "BurnlineCore", allowedBurnline: [], onlyExternal: ["Foundation"]),
        ImportRule(module: "BurnlineStore", allowedBurnline: ["BurnlineCore"], onlyExternal: nil),
        ImportRule(module: "BurnlineProviders",
                   allowedBurnline: ["BurnlineCore", "BurnlineStore"], onlyExternal: nil),
        ImportRule(module: "BurnlineServices",
                   allowedBurnline: ["BurnlineCore", "BurnlineStore", "BurnlineProviders"],
                   onlyExternal: nil),
        ImportRule(module: "BurnlineUI",
                   allowedBurnline: ["BurnlineCore", "BurnlineServices"], onlyExternal: nil),
        // The app target is the composition root, but it still never reaches
        // the store directly: services hand it everything it needs.
        ImportRule(module: "Burnline",
                   allowedBurnline: ["BurnlineCore", "BurnlineServices", "BurnlineUI"],
                   onlyExternal: nil),
    ]

    /// Every import in `source` that this rule forbids.
    func violations(in source: String) -> [String] {
        Self.imports(in: source).filter { !permits($0) }
    }

    private func permits(_ imported: String) -> Bool {
        if imported == module { return true }
        if let onlyExternal { return onlyExternal.contains(imported) }
        if Self.burnlineModules.contains(imported) { return allowedBurnline.contains(imported) }
        if Self.storeOnly.contains(imported) { return module == "BurnlineStore" }
        if Self.interfaceOnly.contains(imported) { return module == "BurnlineUI" || module == "Burnline" }
        return true
    }

    /// Module names imported by `source`. Covers attributes (`@testable`,
    /// `@preconcurrency`), access levels (`public import`), declaration imports
    /// (`import struct Foo.Bar`), and several statements on one line.
    static func imports(in source: String) -> [String] {
        let pattern = /^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)/
            .anchorsMatchLineEndings()
        return SwiftSource.code(source)
            .split(separator: ";")
            .flatMap { statement in statement.matches(of: pattern).map { String($0.1) } }
    }
}
