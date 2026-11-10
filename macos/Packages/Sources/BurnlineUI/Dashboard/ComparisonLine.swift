//
//  ComparisonLine.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import SwiftUI

/// One quiet line at the top of the Overview: the figure on screen said as
/// comparisons, a different one every `interval`. It follows the page: the
/// range's cost on Cost, its tokens on Tokens, and while usage is arriving
/// the live pace joins the token lines. Hidden when comparisons are off.
struct ComparisonLine: View {
    let model: DashboardModel
    let scope: ScopeModel
    let status: StatusModel

    /// How long each comparison stays before the next takes its place.
    static let interval: TimeInterval = 25
    /// Comparisons drawn for one figure; they take turns.
    static let variety = 6

    @AppStorage(ActivityPreferences.showComparisonsKey) private var show = true
    @AppStorage(ActivityPreferences.comparisonToneKey) private var tone = ActivityPreferences.mix
    @State private var lines: [String] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A stack, so the line has a place to come and go from, and its task
        // runs while there is nothing yet to say.
        VStack(alignment: .leading) {
            if show, !lines.isEmpty {
                ComparisonTicker(lines: lines, font: .callout, alignment: .leading, interval: Self.interval)
                    .id(key)
                    .transition(.opacity)
            }
        }
        .animation(Motion.standard(reduced: reduceMotion), value: key)
        .task(id: key) { lines = draw() }
    }

    private var totals: UsageTotals? { scope.data?.summary.totals }
    private var live: LiveActivity? { model.metric == .tokens ? status.live : nil }

    /// What the lines are drawn from, at the precision a comparison shows:
    /// a new range, measure, tone or a figure that moves its first two
    /// digits draws them again; a reading that changes nothing visible does not.
    private var key: String {
        let figure = totals.map { model.metric.value($0) } ?? 0
        let pace = live.map { Int(log2(max($0.tokensPerMinute, 1))) } ?? -1
        return "\(model.range)|\(model.metric)|\(tone)|\(String(format: "%.2g", figure))|\(pace)"
    }

    /// Up to `variety` different lines for the figure on screen, then the
    /// live pace's, so the two take turns.
    private func draw() -> [String] {
        guard let engine = model.comparisons, let totals else { return [] }
        let tone = ActivityPreferences.tone(tone)
        let range = scope.data?.range.scope
        func distinct(_ make: () -> String?) -> [String] {
            var drawn: [String] = []
            // More draws than lines, since two draws can land on one unit.
            for _ in 0..<(Self.variety * 3) where drawn.count < Self.variety {
                if let text = make(), !drawn.contains(text) { drawn.append(text) }
            }
            return drawn
        }
        let figure = switch model.metric {
        case .cost: distinct { engine.comparison(cost: totals.cost, tone: tone, scope: range)?.text }
        case .tokens: distinct { engine.comparison(tokens: Double(totals.tokens.processed), tone: tone, scope: range)?.text }
        }
        let pace = live.map { live in distinct { engine.pace(tokensPerHour: live.tokensPerMinute * 60, tone: tone)?.text } } ?? []
        // Interleaved, so a pace line comes round between the range's.
        return (0..<max(figure.count, pace.count)).flatMap { index in
            [figure[safe: index], pace[safe: index]].compactMap { $0 }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
