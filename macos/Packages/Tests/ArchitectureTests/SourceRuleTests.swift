//
//  SourceRuleTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation
import Testing

/// Rules from the architecture's testing section that the compiler cannot
/// check: where the wall clock may be read, and where floating point may not
/// appear.
struct SourceRuleTests {
    /// The one folder allowed to read the current time.
    static let clockFolder = "/BurnlineCore/Time/"
    /// The folder that must stay in integers.
    static let moneyFolder = "/BurnlineCore/Money/"

    // Computed, because Regex is not Sendable and so cannot be a stored static.
    // Both run over whole files, so a call split across lines is still found.
    static var readsWallClock: Regex<Substring> {
        /\bDate\s*(?:\.\s*init\s*)?\(\s*(?:timeIntervalSinceNow\s*:[^)]*)?\)|\bDate\s*\.\s*now\b|\.\s*timeIntervalSinceNow\b/
    }
    /// Floating-point types, and literals that would infer one.
    static var floatingPoint: Regex<Substring> {
        /\b(?:Double|Float|Float16|Float32|Float64|Float80|CGFloat|TimeInterval)\b|\b[0-9][0-9_]*\.[0-9][0-9_]*|\b[0-9][0-9_]*[eE][+-]?[0-9]+\b/
    }

    /// `file:line` for every match of `pattern`.
    static func matches(of pattern: Regex<Substring>, in files: [URL]) throws -> [String] {
        try files.flatMap { file in
            let code = try SourceTree.code(of: file)
            return code.matches(of: pattern).map {
                "\(file.lastPathComponent):\(SwiftSource.line(of: $0.range.lowerBound, in: code))"
            }
        }
    }

    @Test func `the wall clock is read only inside Time`() throws {
        let files = SourceTree.allSwiftFiles.filter { !$0.path.contains(Self.clockFolder) }
        try #require(!files.isEmpty)
        let offenders = try Self.matches(of: Self.readsWallClock, in: files)
        #expect(offenders.isEmpty, "read the time through an injected WallClock: \(offenders)")
    }

    @Test func `the money code has no floating point`() throws {
        let files = SourceTree.allSwiftFiles.filter { $0.path.contains(Self.moneyFolder) }
        try #require(!files.isEmpty, "no money sources found; the tree has moved")
        let offenders = try Self.matches(of: Self.floatingPoint, in: files)
        #expect(offenders.isEmpty, "money stays in integers: \(offenders)")
    }

    @Test(arguments: ["let t = Date()", "let t = Date ( )", "let t = Date(\n)", "let t = Date.init()",
                      "x = Date.now", "x = Date .now", "Date(timeIntervalSinceNow: 5)",
                      "Date (timeIntervalSinceNow: -60)", "start.timeIntervalSinceNow",
                      "let url = \"https://example.com\"; let t = Date()"])
    func `clock reads are recognised`(source: String) {
        #expect(SwiftSource.code(source).contains(Self.readsWallClock))
    }

    @Test(arguments: ["Date(timeIntervalSince1970: 0)", "Timestamp(date)", "let nowish = clock.now",
                      "// Date() is forbidden here", "/* Date.now */", "let s = \"Date()\"",
                      "let s = \"\"\"\nDate()\n\"\"\"", "/* outer /* Date() */ still comment */"])
    func `conversions, injected clocks, comments and strings are not clock reads`(source: String) {
        #expect(!SwiftSource.code(source).contains(Self.readsWallClock))
    }

    @Test(arguments: ["let x: Double = 1", "let price = 0.1", "let big = 1e9", "let r = 1_000.5",
                      "func f(_ t: TimeInterval)"])
    func `floating point is recognised`(source: String) {
        #expect(SwiftSource.code(source).contains(Self.floatingPoint))
    }

    @Test(arguments: ["let n: Int64 = 1_000_000", "for i in 1...5 {}", "/// a Double rate", "let s = \"0.5\"",
                      "x.raw"])
    func `integers, ranges, comments and strings are not floating point`(source: String) {
        #expect(!SwiftSource.code(source).contains(Self.floatingPoint))
    }
}
