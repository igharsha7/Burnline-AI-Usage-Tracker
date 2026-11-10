//
//  OverviewSections.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import SwiftUI

/// The top of the dashboard: the range's figure, how it compares with the
/// period before, and how the providers split it. A provider's row also
/// shows or hides its line in the chart.
struct Hero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let data: DashboardData
    let metric: Metric
    let rangeLabel: String
    let previousLabel: String?
    let hidden: Set<ProviderKey>
    /// Each provider's health, so one that stopped being read mid-range is
    /// flagged beside the history it kept.
    var health: [ProviderKey: ProviderHealth] = [:]
    let wide: Bool
    let toggle: (ProviderKey) -> Void

    var body: some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 56))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
        layout {
            figure.frame(maxWidth: .infinity, alignment: .leading)
            ProviderSpectrum(providers: data.providers, metric: metric, whole: data.summary.totals,
                             hidden: hidden, health: health, toggle: toggle)
                .frame(maxWidth: wide ? 400 : .infinity)
        }
    }

    private var figure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(metric == .cost ? "Equivalent cost" : "Processed tokens") · \(rangeLabel)")
                .font(.callout.weight(.medium))
                .foregroundStyle(Palette.textSecondary)
            Text(metric.text(data.summary.totals))
                .font(Typography.display(58))
                .tracking(Typography.tracking(58))
                .rollingNumber(metric.value(data.summary.totals))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 10) {
                if let delta { delta }
                HStack(spacing: 4) {
                    Text(subtitle)
                    if metric == .cost { CostInfo(coverage: data.summary.totals.costCoverage) }
                }
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var subtitle: String {
        let sessions = "\(data.summary.sessions) session\(data.summary.sessions == 1 ? "" : "s")"
        guard metric == .cost else { return sessions }
        // Every headline cost says how much of it is priced.
        if let coverage = data.summary.totals.costCoverage, coverage < 1 {
            return "\(sessions) · \(Int((coverage * 100).rounded(.down)))% of events priced"
        }
        return sessions
    }

    /// "↘ 35% vs the previous 30 days", as a pill. Not coloured good or bad:
    /// spending more can mean getting more done.
    private var delta: DeltaPill? {
        guard let previous = data.previous, let previousLabel else { return nil }
        let before = metric.value(previous.totals), now = metric.value(data.summary.totals)
        guard before > 0 else { return nil }
        return DeltaPill(change: (now - before) / before, against: previousLabel)
    }
}

/// The ⓘ beside the cost: what "equivalent cost" means, and what share of
/// the usage it covers. A button, so a click opens it as well as a hover.
struct CostInfo: View {
    let coverage: Double?
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            // The symbol is small; the target around it is not.
            Image(systemName: "info.circle").padding(6).contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .padding(-6)
        .help("What this cost means")
        .accessibilityLabel("About equivalent cost")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Equivalent cost").font(.headline)
                Text("What this usage would cost at each model's API prices on the day it was used. "
                     + "Subscription plans are not billed this way, so this is a measure of value, not a bill.")
                if let coverage, coverage < 1 {
                    Text("\(Int((coverage * 100).rounded(.down)))% of usage events have a known price. The rest are from "
                         + "models with no known price: their tokens are counted, their cost is left out rather than guessed.")
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .font(.callout)
            .frame(width: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
        }
    }
}

struct DeltaPill: View {
    let change: Double
    let against: String

    var body: some View {
        let level = abs(change) < 0.005
        HStack(spacing: 5) {
            Image(systemName: level ? "equal" : change > 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption.weight(.bold))
            Text(level ? "Level" : "\(Int((abs(change) * 100).rounded()))%").fontWeight(.semibold).monospacedDigit()
            Text("vs \(against)").foregroundStyle(Palette.textSecondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Palette.control.opacity(0.7), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level ? "Level with \(against)"
                            : "\(change > 0 ? "Up" : "Down") \(Int((abs(change) * 100).rounded())) percent from \(against)")
    }
}

/// How the providers split the whole: one bar in their colours, then a row
/// each with its figure and share.
struct ProviderSpectrum: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let providers: [ProviderFigures]
    let metric: Metric
    let whole: UsageTotals
    let hidden: Set<ProviderKey>
    var health: [ProviderKey: ProviderHealth] = [:]
    let toggle: (ProviderKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GeometryReader { geometry in
                let total = max(metric.value(whole), .leastNonzeroMagnitude)
                let gaps = CGFloat(max(providers.count - 1, 0)) * 3
                HStack(spacing: 3) {
                    ForEach(providers, id: \.provider) { figures in
                        Capsule()
                            .fill(Palette.accent(figures.provider).opacity(hidden.contains(figures.provider) ? 0.25 : 0.9))
                            // Every provider with usage keeps a visible sliver.
                            .frame(width: max(6, (geometry.size.width - gaps) * metric.value(figures.totals) / total))
                    }
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            VStack(spacing: 4) {
                ForEach(providers, id: \.provider) { figures in
                    ProviderRow(figures: figures, metric: metric, whole: whole,
                                hidden: hidden.contains(figures.provider), health: health[figures.provider]) {
                        withAnimation(Motion.standard(reduced: reduceMotion)) { toggle(figures.provider) }
                    }
                }
            }
        }
    }
}

struct ProviderRow: View {
    let figures: ProviderFigures
    let metric: Metric
    let whole: UsageTotals
    let hidden: Bool
    var health: ProviderHealth?
    let toggle: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                key.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // Dot for the chart, mark for the provider, as the reference has them.
                        ProviderLogo(provider: figures.provider, size: 16)
                        Text(figures.provider.displayName).font(.body.weight(.medium))
                        if hidden {
                            // Hidden is said with a symbol too, not by fading alone.
                            Image(systemName: "eye.slash").font(.caption).foregroundStyle(Palette.textSecondary)
                                .transition(Motion.icon)
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(metric.text(figures.totals)).font(.body.weight(.semibold)).monospacedDigit()
                    Text(share).font(.caption).monospacedDigit().foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? Palette.control.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .opacity(hidden ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -10)
        .onHover { hovering = $0 }
        .help(hidden ? "Show \(figures.provider.displayName) in the chart" : "Hide \(figures.provider.displayName) from the chart")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(figures.provider.displayName), \(metric.text(figures.totals)), \(share) of \(metric.noun), \(detail)")
        .accessibilityValue(hidden ? "Hidden from the chart" : "Shown in the chart")
        .accessibilityHint("Shows or hides this provider in the chart")
        .accessibilityAddTraits(.isButton)
    }

    /// The provider's dot, or, without colour, a sample of its chart line.
    @ViewBuilder private var key: some View {
        if differentiate {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 18, y: 4))
            }
            .stroke(Palette.accent(figures.provider),
                    style: StrokeStyle(lineWidth: 2.25, lineCap: .round, dash: Palette.dash(figures.provider)))
            .frame(width: 18, height: 8)
        } else {
            Circle().fill(Palette.accent(figures.provider)).frame(width: 8, height: 8)
        }
    }

    private var share: String {
        let total = metric.value(whole)
        return total > 0 ? Format.share(metric.value(figures.totals) / total) : "0%"
    }

    private var detail: String {
        let other: Metric = metric == .cost ? .tokens : .cost
        let sessions = "\(figures.sessions) session\(figures.sessions == 1 ? "" : "s")"
        let text = "\(sessions) · \(other.text(figures.totals))\(other == .tokens ? " tokens" : "")"
        return flag.map { "\(text) · \($0)" } ?? text
    }

    /// Why no more usage is arriving, for a provider with history that can
    /// no longer be read; nothing for one that is up to date.
    private var flag: String? {
        switch health {
        case .degraded, .notInstalled, .unavailable: health.map(HealthText.short)
        case .healthy, nil: nil
        }
    }
}
