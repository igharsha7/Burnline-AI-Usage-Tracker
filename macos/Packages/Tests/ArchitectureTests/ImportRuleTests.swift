//
//  ImportRuleTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation
import Testing

/// Fitness tests for the module import rule. They read the source tree rather
/// than the build graph, so a forbidden import fails here whether or not the
/// compiler happened to let it through.
struct ImportRuleTests {
    @Test(arguments: ImportRule.all.map(\.module))
    func `module imports only what the dependency rule allows`(module: String) throws {
        let rule = try #require(ImportRule.all.first { $0.module == module })
        let files = SourceTree.swiftFiles(under: SourceTree.directory(for: module))
        try #require(!files.isEmpty, "no sources found for \(module); the tree has moved")

        for file in files {
            let violations = rule.violations(in: try String(contentsOf: file, encoding: .utf8))
            #expect(violations.isEmpty,
                    "\(file.lastPathComponent) in \(module) imports \(violations.joined(separator: ", "))")
        }
    }

    @Test(arguments: [
        ("BurnlineUI", "import BurnlineStore"),
        ("BurnlineUI", "@testable import BurnlineStore"),
        ("BurnlineUI", "import struct BurnlineStore.Anything"),
        ("BurnlineUI", "public import BurnlineStore"),
        ("BurnlineUI", "import Foundation; import BurnlineStore"),
        ("BurnlineUI", "/* note */ import BurnlineStore"),
        ("BurnlineUI", "import GRDB"),
        ("BurnlineServices", "import\nGRDB"),
        ("BurnlineProviders", "@_spi(Testing) import GRDB"),
        ("BurnlineCore", "import BurnlineStore"),
        ("BurnlineCore", "import SwiftUI"),
        ("BurnlineCore", "import OSLog"),
        ("BurnlineServices", "import SwiftUI"),
        ("Burnline", "import BurnlineStore"),
    ])
    func `forbidden imports are caught`(module: String, line: String) throws {
        let rule = try #require(ImportRule.all.first { $0.module == module })
        #expect(!rule.violations(in: "import Foundation\n\(line)\n").isEmpty)
    }

    @Test func `imports named in comments or strings are ignored`() throws {
        let ui = try #require(ImportRule.all.first { $0.module == "BurnlineUI" })
        let source = "/*\nimport BurnlineStore\n*/\nlet s = \"\"\"\nimport GRDB\n\"\"\"\n// import BurnlineStore\n"
        #expect(ui.violations(in: source).isEmpty)
    }

    @Test func `permitted imports pass`() throws {
        let ui = try #require(ImportRule.all.first { $0.module == "BurnlineUI" })
        let source = "import SwiftUI\nimport Charts\nimport BurnlineCore\n@preconcurrency import BurnlineServices\n"
        #expect(ui.violations(in: source).isEmpty)
    }
}
