//
//  ProviderLogoTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineUI
import CoreGraphics
import SwiftUI
import Testing

@MainActor
struct ProviderLogoTests {
    @Test(arguments: ProviderKey.allCases)
    func `every provider's mark is bundled, reads, and fills its view box`(_ provider: ProviderKey) throws {
        let mark = try #require(ProviderLogo.marks[provider])
        let box = mark.cgPath.boundingBoxOfPath
        #expect(box.minX >= -0.01 && box.minY >= -0.01)
        #expect(box.maxX <= ProviderLogo.viewBox + 0.01 && box.maxY <= ProviderLogo.viewBox + 0.01)
        #expect(max(box.width, box.height) > ProviderLogo.viewBox * 0.8)
    }

    @Test func `compact numbers, relative moves and implicit lines read as SVG means them`() throws {
        let path = try #require(SVGPathReader.path("m1 1 2 0 0 2-2 0z"))
        #expect(path.cgPath.boundingBoxOfPath == CGRect(x: 1, y: 1, width: 2, height: 2))
        let compact = try #require(SVGPathReader.path("M.5.5L2.5.5"))
        #expect(compact.cgPath.boundingBoxOfPath == CGRect(x: 0.5, y: 0.5, width: 2, height: 0))
    }

    @Test func `an arc keeps to its circle and the side its sweep picks`() throws {
        // A half circle of radius 10 from (0, 10) to (20, 10); sweep 1 runs
        // clockwise on screen, so over the top.
        let path = try #require(SVGPathReader.path("M0 10A10 10 0 0 1 20 10"))
        let box = path.cgPath.boundingBoxOfPath
        #expect(abs(box.minY) < 0.05 && abs(box.maxY - 10) < 0.05 && abs(box.width - 20) < 0.05)
    }

    @Test func `data it cannot read gives no shape rather than part of one`() {
        #expect(SVGPathReader.path("M1 1L") == nil)
        #expect(SVGPathReader.path("M1 1X2 2") == nil)
    }
}
