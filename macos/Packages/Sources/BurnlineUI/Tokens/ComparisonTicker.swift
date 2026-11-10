//
//  ComparisonTicker.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import SwiftUI

/// A few comparisons said one after another, each rising in as the last
/// one leaves. It only wakes to turn the line while it is on screen, and
/// holds the first line under Reduce Motion.
struct ComparisonTicker: View {
    let lines: [String]
    var font: Font = .callout
    var alignment: Alignment = .center

    /// How long each line stays.
    var interval: TimeInterval = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Every line, hidden, holds the room the tallest needs, so the
        // ticker keeps its height as lines of different lengths take turns.
        ZStack {
            ForEach(lines, id: \.self) { line($0).hidden() }
            if lines.count > 1, !reduceMotion {
                TimelineView(.periodic(from: .distantPast, by: interval)) { context in
                    let index = Int(context.date.timeIntervalSinceReferenceDate / interval) % lines.count
                    line(lines[index])
                        .id(index)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                        .animation(.smooth(duration: 0.5), value: index)
                }
            } else if let first = lines.first {
                line(first)
            }
        }
        .clipped()
    }

    private func line(_ text: String) -> some View {
        Label(text, systemImage: "sparkles")
            .font(font)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment)
            .help(text)
            .copyable(text)
    }

    /// Up to `count` different comparisons for `tokens`, in `tone`.
    static func lines(_ engine: ComparisonEngine?, tokens: Int64, tone: ComparisonTone?, scope: ComparisonScope?,
                      count: Int = 4) -> [String] {
        guard let engine, tokens > 0 else { return [] }
        var lines: [String] = []
        // A few more draws than lines, since two draws can land on one unit.
        for _ in 0..<(count * 2) where lines.count < count {
            if let text = engine.comparison(tokens: Double(tokens), tone: tone, scope: scope)?.text,
               !lines.contains(text) {
                lines.append(text)
            }
        }
        return lines
    }
}
