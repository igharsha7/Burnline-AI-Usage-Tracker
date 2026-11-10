//
//  UsageChart.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Charts
import SwiftUI

/// The usage chart: one smoothed line per provider over its area, a shaded
/// span where tracking had not begun, and a hover card. The lines draw in
/// from the left when the chart first appears, and again, quicker, when the
/// range or the measure changes: new dates cannot morph from old ones, and
/// left to themselves the new lines fade in over the old. The card, its rule
/// and its points live above the plot and glide from bucket to bucket rather
/// than being rebuilt at each one.
///
/// Monotone interpolation keeps the curve smooth without inventing values:
/// it never dips below zero or peaks above a bucket's real figure.
struct UsageChart: View {
    let buckets: [DashboardBucket]
    let width: BucketWidth
    let providers: [ProviderKey]
    let hidden: Set<ProviderKey>
    let metric: Metric
    let calendar: LocalCalendar
    let now: Timestamp

    @State private var selection: Date?
    /// The bucket the card shows: the hovered one, kept while the card
    /// fades out so it does not jump on its way.
    @State private var shown: DashboardBucket?
    @State private var cardSize = CGSize.zero
    @State private var drawn = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrames) private var stillFrames

    /// Worked out once per set of figures, not on every hover redraw.
    private let visible: [ProviderKey]
    private let tracked: [DashboardBucket]

    init(buckets: [DashboardBucket], width: BucketWidth, providers: [ProviderKey], hidden: Set<ProviderKey>,
         metric: Metric, calendar: LocalCalendar, now: Timestamp) {
        self.buckets = buckets
        self.width = width
        self.providers = providers
        self.hidden = hidden
        self.metric = metric
        self.calendar = calendar
        self.now = now
        visible = providers.filter { !hidden.contains($0) }
        tracked = buckets.filter(\.tracked)
    }

    var body: some View {
        // The nearest bucket, found once per hover frame.
        let selected = selected
        VStack(alignment: .leading, spacing: 12) {
            Text("\(BucketLabel.adjective(width)) \(metric == .cost ? "cost" : "processed tokens")")
                .font(.headline)
            Chart {
                if let untracked {
                    RectangleMark(xStart: .value("Time", untracked.lowerBound), xEnd: .value("Time", untracked.upperBound))
                        .foregroundStyle(Palette.textSecondary.opacity(0.08))
                        .annotation(position: .overlay, alignment: .center) {
                            Text("Not tracked yet").font(.caption).foregroundStyle(Palette.textSecondary)
                        }
                }
                ForEach(visible, id: \.self) { provider in
                    ForEach(tracked) { bucket in
                        let value = metric.value(bucket.providers[provider] ?? .zero)
                        AreaMark(x: .value("Time", bucket.window.start.date), yStart: .value("Value", 0),
                                 yEnd: .value("Value", value), series: .value("Provider", provider.displayName))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [Palette.accent(provider).opacity(0.22),
                                                                     Palette.accent(provider).opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", bucket.window.start.date), y: .value("Value", value),
                                 series: .value("Provider", provider.displayName))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: differentiate ? 2.25 : 1.75, lineCap: .round,
                                                   lineJoin: .round, dash: differentiate ? Palette.dash(provider) : []))
                            .foregroundStyle(Palette.accent(provider))
                    }
                }
                // Each line ends in an ember at its latest point: where it
                // has burned to now. The hover point replaces it.
                if selected == nil, let latest = tracked.last {
                    ForEach(visible, id: \.self) { provider in
                        PointMark(x: .value("Time", latest.window.start.date),
                                  y: .value("Value", metric.value(latest.providers[provider] ?? .zero)))
                            .symbol { Ember(color: Palette.accent(provider), size: 7) }
                    }
                }
            }
            .chartXSelection(value: $selection)
            .chartXScale(domain: domain)
            .chartPlotStyle { plot in
                // Revealed from the leading edge, so each line draws itself in.
                plot.mask(alignment: .leading) {
                    Rectangle().scaleEffect(x: drawn || stillFrames ? 1 : 0.001, anchor: .leading)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let frame = proxy.plotFrame, let shown {
                        hover(shown, proxy: proxy, plot: geometry[frame])
                    }
                }
                // The chart below keeps the pointer, for the selection.
                .allowsHitTesting(false)
            }
            .onChange(of: selected?.id) {
                if let selected { shown = selected }
            }
            .onAppear {
                guard !drawn else { return }
                if reduceMotion { drawn = true } else { withAnimation(Motion.draw.delay(0.1)) { drawn = true } }
            }
            .onChange(of: Drawing(width: width, domain: domain, metric: metric)) { redraw() }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.separator.opacity(0.6))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(metric == .cost ? Format.axisCost(number) : Format.figure(Int64(number)))
                                .font(.caption2).monospacedDigit().foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
            .chartXAxis {
                // Aligned, so the first and last labels stay inside the plot.
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: xFormat).font(.caption2).foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(height: 260)
            .accessibilityLabel("\(BucketLabel.adjective(width)) \(metric.noun) by provider")
            .accessibilityChartDescriptor(self)
        }
    }

    /// What, changing, starts the drawing again.
    private struct Drawing: Equatable {
        let width: BucketWidth
        let domain: ClosedRange<Date>
        let metric: Metric
    }

    /// Hides the lines at once, then draws them in from the left. The hide
    /// must land in a frame of its own, or it merges with the reveal.
    private func redraw() {
        shown = nil
        guard !reduceMotion, !stillFrames else { return }
        var hide = Transaction()
        hide.disablesAnimations = true
        withTransaction(hide) { drawn = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(Motion.redraw) { drawn = true }
        }
    }

    /// The rule, a point on each line, and the card beside them, all placed
    /// from the bucket so a move to the next one is a glide, not a jump.
    /// The card sits right of the rule, or left where it would not fit.
    private func hover(_ bucket: DashboardBucket, proxy: ChartProxy, plot: CGRect) -> some View {
        let x = plot.minX + (proxy.position(forX: bucket.window.start.date) ?? 0)
        let gap: CGFloat = 14
        let fitsRight = x + gap + cardSize.width <= plot.maxX
        let cardX = fitsRight ? x + gap + cardSize.width / 2 : x - gap - cardSize.width / 2
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.textSecondary.opacity(0.55))
                .frame(width: 1, height: plot.height)
                .position(x: x, y: plot.midY)
            ForEach(visible, id: \.self) { provider in
                if let y = proxy.position(forY: metric.value(bucket.providers[provider] ?? .zero)) {
                    Circle().fill(Palette.accent(provider)).frame(width: 7, height: 7)
                        .padding(2).background(Circle().fill(Palette.surface))
                        .position(x: x, y: plot.minY + y)
                }
            }
            ChartTooltip(bucket: bucket, providers: visible, metric: metric,
                         title: BucketLabel.row(bucket.window, width: width, calendar: calendar, now: now))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                .position(x: max(plot.minX + cardSize.width / 2, min(cardX, plot.maxX - cardSize.width / 2)),
                          y: plot.minY + cardSize.height / 2 + 4)
        }
        .opacity(selected == nil ? 0 : 1)
        .animation(Motion.standard(reduced: reduceMotion), value: bucket.id)
        .animation(.easeOut(duration: 0.15), value: selected == nil)
    }

    /// From the first bucket to the last, so a short range is not padded.
    private var domain: ClosedRange<Date> {
        let first = buckets.first?.window.start.date ?? now.date
        let last = buckets.last?.window.start.date ?? now.date
        return first...max(last, first.addingTimeInterval(1))
    }

    /// The buckets before tracking began, as one span.
    private var untracked: ClosedRange<Date>? {
        guard let firstTracked = buckets.firstIndex(where: \.tracked) else {
            return buckets.isEmpty ? nil : domain
        }
        guard firstTracked > 0 else { return nil }
        return buckets[0].window.start.date...buckets[firstTracked].window.start.date
    }

    /// The tracked bucket nearest the pointer.
    private var selected: DashboardBucket? {
        guard let selection else { return nil }
        return tracked.min {
            abs($0.window.start.date.timeIntervalSince(selection)) < abs($1.window.start.date.timeIntervalSince(selection))
        }
    }

    private var xFormat: Date.FormatStyle {
        switch width {
        case .minute, .quarterHour, .hour: .dateTime.hour()
        case .day, .week: .dateTime.month(.abbreviated).day()
        case .month: .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }
}

/// The chart as data for VoiceOver's audio graph and data table, since
/// the hover card is pointer-only.
extension UsageChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let values = tracked.flatMap { bucket in visible.map { metric.value(bucket.providers[$0] ?? .zero) } }
        let label = { (value: Double) in metric == .cost ? Format.axisCost(value) : Format.figure(Int64(value)) }
        let names = tracked.map { BucketLabel.row($0.window, width: width, calendar: calendar, now: now) }
        let x = AXCategoricalDataAxisDescriptor(title: BucketLabel.noun(width), categoryOrder: names)
        let y = AXNumericDataAxisDescriptor(title: metric == .cost ? "Cost" : "Processed tokens",
                                            range: 0...max(values.max() ?? 0, 1), gridlinePositions: [],
                                            valueDescriptionProvider: label)
        let series = visible.map { provider in
            AXDataSeriesDescriptor(name: provider.displayName, isContinuous: true,
                                   dataPoints: zip(tracked, names).map { bucket, name in
                AXDataPoint(x: name, y: metric.value(bucket.providers[provider] ?? .zero))
            })
        }
        return AXChartDescriptor(title: "\(BucketLabel.adjective(width)) \(metric.noun)", summary: summary(names),
                                 xAxis: x, yAxis: y, additionalAxes: [], series: series)
    }
}

extension UsageChart {
    /// The chart in a sentence or two: each provider's total, and its
    /// busiest bucket, which is what the shape of a line is for.
    func summary(_ names: [String]) -> String? {
        guard !tracked.isEmpty else { return nil }
        return visible.map { provider in
            let totals = tracked.map { $0.providers[provider] ?? .zero }
            guard let total = try? totals.reduce(UsageTotals.zero, { try $0.adding($1) }) else {
                return "\(provider.displayName): total unavailable."
            }
            let values = totals.map(metric.value)
            guard metric.value(total) > 0, let peak = values.indices.max(by: { values[$0] < values[$1] }) else {
                return "\(provider.displayName): none."
            }
            return "\(provider.displayName): \(metric.text(total)) in all, most in \(names[peak]) at \(metric.text(totals[peak]))."
        }
        .joined(separator: " ")
    }
}

/// The hover card: the bucket, each provider with its colour, and the total.
struct ChartTooltip: View {
    let bucket: DashboardBucket
    let providers: [ProviderKey]
    let metric: Metric
    let title: String

    private var hiddenUsage: Bool {
        bucket.providers.contains { !providers.contains($0.key) && $0.value.events > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Palette.textSecondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(providers, id: \.self) { provider in
                    GridRow {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1).fill(Palette.accent(provider)).frame(width: 3, height: 10)
                            Text(provider.displayName)
                        }
                        Text(metric.text(bucket.providers[provider] ?? .zero))
                            .monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
                if providers.count > 1 || hiddenUsage {
                    Divider().gridCellColumns(2)
                    GridRow {
                        // A total that includes providers hidden from the chart says so.
                        Text(hiddenUsage ? "All providers" : "Total").foregroundStyle(Palette.textSecondary)
                        Text(metric.text(bucket.total)).monospacedDigit().fontWeight(.medium)
                    }
                }
            }
            .font(.caption)
        }
        // Wide enough for most figures, so the card keeps its size as it moves.
        .frame(minWidth: 150, alignment: .leading)
        .padding(10)
        // A readout under a moving pointer changes at once; only the card
        // glides. Clipped, so nothing in it can draw past its edge.
        .transaction { $0.disablesAnimations = true }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.separator.opacity(0.7), lineWidth: 0.5))
        // Two soft layers rather than one hard one: a close contact shadow and a wide ambient one.
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .fixedSize()
    }
}
