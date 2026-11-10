//
//  TokenMix.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import SwiftUI

/// The four kinds of token a total splits into, in the order they are
/// drawn: cache reads first, since they are nearly all of it.
enum TokenKind: CaseIterable, Identifiable {
    case cacheRead, input, cacheWrite, output

    var id: Self { self }

    var name: String {
        switch self {
        case .cacheRead: "Cache read"
        case .input: "Uncached input"
        case .cacheWrite: "Cache write"
        case .output: "Output"
        }
    }

    var note: String {
        switch self {
        case .cacheRead: "Read back from the cache"
        case .input: "Sent fresh"
        case .cacheWrite: "Stored for reuse"
        case .output: "Generated"
        }
    }

    var color: Color {
        switch self {
        case .cacheRead: Palette.tokenCacheRead
        case .input: Palette.tokenInput
        case .cacheWrite: Palette.tokenCacheWrite
        case .output: Palette.tokenOutput
        }
    }

    func count(_ tokens: TokenCounts) -> Int64 {
        switch self {
        case .cacheRead: tokens.cachedInput
        case .input: tokens.input
        case .cacheWrite: tokens.cacheWrite
        case .output: tokens.output
        }
    }

    /// Segment widths for `counts` across `width`: every non-zero kind gets
    /// at least `least`, so a sliver stays visible and can be pointed at.
    static func widths(_ counts: [Int64], in width: CGFloat, gap: CGFloat, least: CGFloat) -> [CGFloat] {
        let shown = counts.filter { $0 > 0 }.count
        let room = max(0, width - gap * CGFloat(max(shown - 1, 0)))
        let total = Double(counts.reduce(0, +))
        guard total > 0 else { return counts.map { _ in 0 } }
        let raw = counts.map { CGFloat(Double($0) / total) * room }
        let small = raw.filter { $0 > 0 && $0 < least }
        let large = raw.filter { $0 >= least }.reduce(0, +)
        let scale = large > 0 ? max(0, room - least * CGFloat(small.count)) / large : 1
        return raw.map { $0 == 0 ? 0 : $0 < least ? least : $0 * scale }
    }
}

/// Where the tokens went. A bar split by kind, then the kinds other than
/// cache reads enlarged beneath it, since cache reads are usually so much
/// of the whole that the rest would be slivers. Pointing at a kind, in the
/// bar or its tile, picks it out everywhere and splits it by provider.
struct TokenMixCard: View {
    let totals: UsageTotals
    let providers: [ProviderFigures]

    @State private var focus: TokenKind?
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var counts: [Int64] { TokenKind.allCases.map { $0.count(totals.tokens) } }

    var body: some View {
        let counts = counts
        let sum = max(counts.reduce(0, +), 1)
        Card {
            VStack(alignment: .leading, spacing: 20) {
                // Cache writes are not processed tokens, so where there are any
                // the tiles add up to more than the processed figure.
                SectionHeader(title: "Where the tokens went",
                              detail: sum == totals.tokens.processed
                                  ? "\(Format.figure(sum)) processed"
                                  : "\(Format.figure(sum)) tokens · \(Format.figure(totals.tokens.processed)) processed")
                    .help("Processed tokens are input, cache reads and output. Cache writes are counted apart.")
                MixGraphic(counts: counts, focus: $focus, grown: grown)
                    // The tiles carry the same split as text.
                    .accessibilityHidden(true)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading),
                                         count: TokenKind.allCases.count),
                          alignment: .leading, spacing: 10) {
                    ForEach(Array(TokenKind.allCases.enumerated()), id: \.element) { index, kind in
                        KindTile(kind: kind, count: counts[index], share: Double(counts[index]) / Double(sum),
                                 providers: providers, focus: $focus)
                    }
                }
                Divider().overlay(Palette.separator.opacity(0.6))
                SavingsComparison(totals: totals, grown: grown)
            }
        }
        .animation(Motion.standard(reduced: reduceMotion), value: counts)
        .onAppear {
            guard !grown else { return }
            if reduceMotion { grown = true } else { withAnimation(Motion.reveal) { grown = true } }
        }
    }
}

/// The full bar, and the enlarged remainder joined to it by a funnel.
private struct MixGraphic: View {
    let counts: [Int64]
    @Binding var focus: TokenKind?
    let grown: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let bar: CGFloat = 16
    static let funnel: CGFloat = 34
    static let gap: CGFloat = 2

    /// Enlarge the rest only when cache reads leave it too thin to read.
    private var enlarges: Bool {
        let total = counts.reduce(0, +), rest = total - counts[0]
        return total > 0 && rest > 0 && Double(counts[0]) / Double(total) > 0.6
    }

    var body: some View {
        let enlarges = enlarges
        GeometryReader { geometry in
            let width = geometry.size.width
            let top = TokenKind.widths(counts, in: width, gap: Self.gap, least: 4)
            let restStart = top[0] > 0 ? top[0] + Self.gap : 0
            VStack(alignment: .leading, spacing: 0) {
                segments(TokenKind.allCases, top)
                if enlarges {
                    let rest = Array(counts.dropFirst())
                    let total = Double(counts.reduce(0, +))
                    ZStack {
                        Funnel(start: restStart / max(width, 1))
                            .fill(LinearGradient(colors: [Palette.textPrimary.opacity(0.13), Palette.textPrimary.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom))
                        Text("The other \(Format.share(Double(rest.reduce(0, +)) / total)), enlarged")
                            .font(.caption).foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 8)
                            .background(Palette.surface.opacity(0.9), in: Capsule())
                    }
                    .frame(height: Self.funnel)
                    segments(Array(TokenKind.allCases.dropFirst()),
                             TokenKind.widths(rest, in: width, gap: Self.gap, least: 6))
                }
            }
            // Wipes in from the leading edge, so the split reads as filling up.
            .mask(alignment: .leading) {
                Rectangle().frame(width: grown ? width : 0)
            }
        }
        .frame(height: enlarges ? Self.bar * 2 + Self.funnel : Self.bar)
    }

    private func segments(_ kinds: [TokenKind], _ widths: [CGFloat]) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                if widths[index] > 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(kind.color)
                        .opacity(focus == nil || focus == kind ? 1 : 0.22)
                        .frame(width: widths[index], height: Self.bar)
                        .onHover { inside in
                            withAnimation(Motion.standard(reduced: reduceMotion)) {
                                if inside { focus = kind } else if focus == kind { focus = nil }
                            }
                        }
                        .help(kind.name)
                }
            }
        }
        .frame(height: Self.bar)
    }
}

/// Joins the part of the top bar after cache reads to the full width
/// below, as a lens would.
private struct Funnel: Shape {
    /// Where the enlarged part starts along the top edge, from 0 to 1.
    var start: CGFloat

    var animatableData: CGFloat {
        get { start }
        set { start = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset: CGFloat = 3
        path.move(to: CGPoint(x: rect.width * start, y: inset))
        path.addLine(to: CGPoint(x: rect.width, y: inset))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - inset))
        path.addLine(to: CGPoint(x: 0, y: rect.height - inset))
        path.closeSubpath()
        return path
    }
}

/// One kind's figure, share, and on hover its split by provider.
private struct KindTile: View {
    let kind: TokenKind
    let count: Int64
    let share: Double
    let providers: [ProviderFigures]
    @Binding var focus: TokenKind?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var split: [(provider: ProviderKey, count: Int64)] {
        providers.map { ($0.provider, kind.count($0.totals.tokens)) }.filter { $0.count > 0 }
    }

    var body: some View {
        let focused = focus == kind
        let split = split
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(kind.color).frame(width: 9, height: 9)
                Text(kind.name).font(.callout).foregroundStyle(Palette.textSecondary)
            }
            Text(Format.figure(count)).font(Typography.figure)
                .rollingNumber(Double(count))
            // One line or the other, never both mid-fade, so they cannot overlap.
            ZStack(alignment: .leading) {
                Text("\(Format.share(share)) · \(kind.note)").opacity(focused && split.count > 1 ? 0 : 1)
                Text(splitText(split)).opacity(focused && split.count > 1 ? 1 : 0)
            }
            .font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
            if split.count > 1 {
                ProviderSplit(split: split, total: count)
                    .opacity(focused ? 1 : 0.55)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? Palette.control.opacity(0.55) : Palette.control.opacity(0.0001),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(kind.color.opacity(focused ? 0.45 : 0), lineWidth: 1))
        .opacity(focus == nil || focused ? 1 : 0.5)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Motion.standard(reduced: reduceMotion)) {
                if inside { focus = kind } else if focused { focus = nil }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.name), \(Format.figure(count)) tokens, \(Format.share(share)). \(kind.note).")
        .accessibilityValue(split.count > 1 ? splitText(split) : "")
    }

    private func splitText(_ split: [(provider: ProviderKey, count: Int64)]) -> String {
        split.map { "\($0.provider.displayName) \(Format.share(Double($0.count) / Double(max(count, 1))))" }
            .joined(separator: " · ")
    }
}

/// A kind's tokens by provider, as a thin bar in the providers' colours.
private struct ProviderSplit: View {
    let split: [(provider: ProviderKey, count: Int64)]
    let total: Int64

    var body: some View {
        GeometryReader { geometry in
            let widths = TokenKind.widths(split.map(\.count), in: geometry.size.width, gap: 1.5, least: 2)
            HStack(spacing: 1.5) {
                ForEach(Array(split.enumerated()), id: \.element.provider) { index, part in
                    Capsule().fill(Palette.accent(part.provider)).frame(width: widths[index])
                }
            }
        }
        .frame(height: 3)
    }
}

/// What caching saved, as the bill without it beside the bill with it.
private struct SavingsComparison: View {
    let totals: UsageTotals
    let grown: Bool

    var body: some View {
        let saved = totals.cacheSavings.saved
        let without = (try? totals.cost.adding(saved)) ?? totals.cost
        // Cache writes cost more than plain input, so where they outweigh the
        // reads caching added to the bill, and says so rather than a negative saving.
        let added = saved.raw < 0
        let amount = Nanodollars(raw: abs(saved.raw))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(added ? "Caching added" : "Caching saved").foregroundStyle(Palette.textSecondary)
                Text(Format.cost(amount)).font(Typography.figure).foregroundStyle(Palette.tokenCacheRead)
                    .rollingNumber(Double(saved.raw))
                if without.raw > 0 {
                    Text(added
                         ? "\(Format.share(Double(amount.raw) / Double(without.raw))) more than without caching, at API prices"
                         : "\(Format.share(Double(amount.raw) / Double(without.raw))) of the bill, at API prices")
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 8)
                if let coverage = totals.cacheSavings.coverage, coverage < 1 {
                    Text("Covers \(Int((coverage * 100).rounded(.down)))% of cached tokens")
                        .font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            .font(.callout)
            if saved.raw > 0 {
                VStack(spacing: 6) {
                    bar("Without caching", without, of: without, color: Palette.textSecondary.opacity(0.45))
                    bar("With caching", totals.cost, of: without, color: Palette.tokenCacheRead)
                }
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(_ label: String, _ amount: Nanodollars, of whole: Nanodollars, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(Palette.textSecondary)
                .frame(width: 104, alignment: .leading)
            GeometryReader { geometry in
                let fraction = whole.raw > 0 ? CGFloat(Double(amount.raw) / Double(whole.raw)) : 0
                Capsule().fill(color)
                    .frame(width: grown ? max(4, geometry.size.width * fraction) : 0)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 8)
            Text(Format.cost(amount)).font(.caption.monospacedDigit())
                .frame(width: 84, alignment: .trailing)
                .rollingNumber(Double(amount.raw))
        }
    }
}
