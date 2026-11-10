//
//  StreakCardTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
@testable import BurnlineUI
import Foundation
import SwiftUI
import Testing

/// The Streaks card's flame, story and sprite.
@MainActor
struct StreakCardTests {
    static let now = DashboardTests.now
    static let calendar = DashboardTests.india

    /// Days ending today, active where `active` says so, oldest first.
    static func history(_ active: [Bool]) -> [ActivityDay] {
        zip(calendar.days(endingWith: now, count: active.count), active).map { day, active in
            ActivityDay(day: day, window: calendar.window(for: day),
                        totals: UsageTotals(events: active ? 1 : 0, tokens: .zero, cost: Nanodollars(raw: 0),
                                            unpricedEvents: 0, cacheSavings: CacheSavings()),
                        sessions: active ? 1 : 0, providers: [:],
                        activeQuarterHours: active ? StreakRule.baseQuarterHours : 0)
        }
    }

    @Test func `every tier has its own flame and a chapter, and the chapters run in order`() {
        #expect(FlameLook.tiers.count == StreakTier.all.count)
        #expect(FlameLook.tiers.map(\.isMajor) == StreakTier.all.map(\.isMajor))
        let chapters = StreakTier.all.indices.map { StoryChapter.of(tierIndex: $0).rawValue }
        #expect(chapters == chapters.sorted() && Set(chapters).count == StoryChapter.allCases.count)
        #expect(StoryChapter.of(tierIndex: nil) == .camp)
        #expect(FlameLook.at(nil).colours == .unlit)
    }

    @Test func `the fire loads in every tier's colours, and unlit`() {
        for colours in FlameLook.tiers.map(\.colours) + [.unlit] {
            #expect(FireAnimation.animation(colours) != nil, "\(colours)")
        }
    }

    @Test func `turning the fire takes its own orange to the tier's body colour and keeps a pale core pale`() {
        let channels = { (rgb: UInt32) in (Double(rgb >> 16 & 0xFF) / 255, Double(rgb >> 8 & 0xFF) / 255, Double(rgb & 0xFF) / 255) }
        let source = channels(FireAnimation.sourceBody)
        for colours in FlameLook.tiers.map(\.colours) + [.unlit] {
            let turned = FireAnimation.Turn(from: FireAnimation.sourceBody, to: colours.body).apply(source.0, source.1, source.2)
            let target = channels(colours.body)
            #expect(abs(turned.0 - target.0) < 0.01 && abs(turned.1 - target.1) < 0.01 && abs(turned.2 - target.2) < 0.01,
                    "\(colours)")
        }
        // The violet tier: a near-white stop stays near white.
        let violet = FireAnimation.Turn(from: FireAnimation.sourceBody, to: 0x7A4DFF).apply(1, 0.97, 0.85)
        #expect(min(violet.0, violet.1, violet.2) > 0.8)
    }

    @Test func `Bot-7's sprite is whole: every row the same width, mirrored about its middle`() {
        #expect(BotSeven.sprite.count == 30)
        #expect(BotSeven.sprite.allSatisfy { $0.count == 22 })
        let outlines = BotSeven.sprite.map { row in row.map { $0 == "o" } }
        #expect(outlines.allSatisfy { $0 == $0.reversed() })
    }

    @Test func `a story frame depends only on the tier and the time`() {
        for tier in [nil] + StreakTier.all.indices.map(Optional.some) {
            let painter = StoryPainter(tierIndex: tier)
            #expect(painter.frame(t: 3.25).bytes == painter.frame(t: 3.25).bytes, "tier \(String(describing: tier))")
            #expect(painter.frame(t: 3.25).image() != nil)
        }
        #expect(StoryPainter(tierIndex: 2).frame(t: 1).bytes != StoryPainter(tierIndex: 3).frame(t: 1).bytes)
    }

    @Test func `a streak waiting on today dims the story`() {
        let brightness = { (frame: PixelBuffer) in frame.bytes.reduce(0) { $0 + Int($1) } }
        #expect(brightness(StoryPainter(tierIndex: 4, lit: false).frame(t: 2))
                    < brightness(StoryPainter(tierIndex: 4).frame(t: 2)))
    }

    /// Renders the card at several streak lengths, for review:
    /// BURNLINE_STREAKS_RENDER=/dir swift test --filter StreakCardTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_STREAKS_RENDER"] != nil))
    func `render the card`() throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["BURNLINE_STREAKS_RENDER"]!)
        let gap = [true, true, true, false]
        let cases: [(String, [Bool], CGFloat)] = [
            ("none", [true, false, false], 900),
            ("ten", Array(repeating: true, count: 49) + [false] + Array(repeating: true, count: 10), 900),
            ("waiting", Array(repeating: true, count: 40) + [false], 900),
            ("forge", gap + Array(repeating: true, count: 85), 900),
            ("launch", gap + Array(repeating: true, count: 210), 900),
            ("sun", Array(repeating: true, count: 320), 900),
            ("cosmos", Array(repeating: true, count: 720), 900),
            ("narrow", gap + Array(repeating: true, count: 120), 600),
        ]
        for (name, active, width) in cases {
            let card = Card { StreakCard(streaks: Streaks(days: Self.history(active)), calendar: Self.calendar, now: Self.now) }
                .frame(width: width)
                .padding(20)
                .background(Palette.background)
                .environment(\.colorScheme, .dark)
                .environment(\.stillFrames, true)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 2
            let tiff = try #require(renderer.nsImage?.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try data.write(to: directory.appending(path: "streaks-\(name).png"))
        }
    }
}
