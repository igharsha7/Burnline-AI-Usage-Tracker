//
//  TokenMixTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

@testable import BurnlineUI
import CoreGraphics
import Testing

struct TokenMixTests {
    @Test func `a sliver keeps its least width and the bar still fits`() {
        let widths = TokenKind.widths([970, 20, 9, 1], in: 400, gap: 2, least: 4)
        #expect(widths[3] == 4)
        #expect(abs(widths.reduce(0, +) + 6 - 400) < 0.001)
        #expect(widths[0] > widths[1] && widths[1] > widths[2])
    }

    @Test func `a kind with no tokens takes no width and no gap`() {
        let widths = TokenKind.widths([50, 0, 50, 0], in: 102, gap: 2, least: 4)
        #expect(widths == [50, 0, 50, 0])
    }

    @Test func `nothing at all draws nothing`() {
        #expect(TokenKind.widths([0, 0, 0, 0], in: 300, gap: 2, least: 4) == [0, 0, 0, 0])
    }
}
