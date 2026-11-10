//
//  LimitsView.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import SwiftUI

/// Every provider's quota limits. A board of ring tiles shows each provider
/// at a glance, however many there are, with a headline of where it stands;
/// choosing one opens its windows below: a card per window with its
/// burn-down, its banked resets, and how full its earlier windows got. A
/// provider's own page shows its details alone. Figures come from the same
/// model as the menu bar, so the two never disagree.
struct LimitsView: View {
    let status: StatusModel
    /// One provider's limits, as its own page shows them; nil for all.
    var only: ProviderKey?

    /// The provider whose details are open, remembered across launches and
    /// rebuilds of the page; until one is chosen, the most pressing is shown.
    @AppStorage(Self.chosenKey) private var chosenRaw = ""
    static let chosenKey = "limitsProvider"

    private var chosen: ProviderKey? { ProviderKey(rawValue: chosenRaw) }

    /// Every provider's details on one page, rather than the chosen one's.
    @AppStorage(Self.showAllKey) private var showAll = false
    static let showAllKey = "limitsShowAll"

    private var quotas: [ProviderQuotaState] {
        status.visibleQuotas.filter { only == nil || $0.provider == only }
    }

    var body: some View {
        let quotas = quotas
        // Ages, countdowns and the chart's now line move by the minute.
        TimelineView(.everyMinute) { context in
            let now = Timestamp(context.date) ?? Timestamp(epochSeconds: 0)
            VStack(alignment: .leading, spacing: 32) {
                if quotas.isEmpty, only == nil {
                    ContentUnavailableView("No limits read yet", systemImage: "gauge.with.dots.needle.0percent",
                                           description: Text("Codex and Claude quota appear here once either has been read."))
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
                if only == nil, !quotas.isEmpty {
                    let open = showAll ? nil : shown(quotas, now: now)
                    VStack(alignment: .leading, spacing: 12) {
                        if quotas.count > 1 {
                            SegmentedChoice(options: [(false, "One provider"), (true, "All providers")],
                                            selection: $showAll.animation(.snappy(duration: 0.3)))
                        }
                        LimitsBoard(states: quotas, open: open, now: now) { provider in
                            withAnimation(.snappy(duration: 0.3)) {
                                chosenRaw = provider.rawValue
                                showAll = false
                            }
                        }
                    }
                    .arrival(0)
                    ForEach(quotas.filter { showAll || $0.provider == open }, id: \.provider) { state in
                        ProviderLimits(state: state, status: status, now: now)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    .arrival(1)
                } else if let state = quotas.first {
                    ProviderLimits(state: state, status: status, now: now)
                }
            }
        }
    }

    /// The chosen provider while it still has limits, else the most pressing.
    private func shown(_ quotas: [ProviderQuotaState], now: Timestamp) -> ProviderKey? {
        if let chosen, quotas.contains(where: { $0.provider == chosen }) { return chosen }
        return quotas.max { a, b in
            (WindowOutlook.of(a, now: now).map(\.standing).max() ?? .idle)
                < (WindowOutlook.of(b, now: now).map(\.standing).max() ?? .idle)
        }?.provider
    }
}

// MARK: - Outlook

/// Where one window stands, judged from its use, how much of its time has
/// gone, and the burn rate.
struct WindowOutlook: Equatable {
    enum Standing: Int, Comparable {
        // Ordered from calmest to most pressing.
        case idle, under, onPace, ahead, runsOut, reached

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    let name: String
    /// Percent used, 0 to 100 and over.
    let used: Double
    /// The share of the window's time gone, 0 to 1; nil without a start.
    let elapsed: Double?
    /// Seconds before the reset the limit would run out at this rate.
    let lead: Int64?

    /// How far off an even pace counts as ahead or under, in shares of the window.
    static let paceTolerance = 0.1
    /// Below this much used, a window is barely touched.
    static let idleBelow = 3.0

    var standing: Standing {
        if used >= 100 { return .reached }
        if lead != nil { return .runsOut }
        if used < Self.idleBelow { return .idle }
        guard let elapsed else { return .onPace }
        let share = used / 100
        if share > elapsed + Self.paceTolerance { return .ahead }
        if share < elapsed - Self.paceTolerance { return .under }
        return .onPace
    }

    /// The provider's headline, from its most pressing window.
    static func headline(_ windows: [WindowOutlook]) -> String? {
        guard let worst = windows.max(by: { $0.standing < $1.standing }) else { return nil }
        let lower = worst.name.lowercased()
        switch worst.standing {
        case .reached: return "\(worst.name) limit reached"
        case .runsOut: return "\(worst.name) runs out \(Countdown.compact(worst.lead ?? 0)) early"
        case .ahead: return "Running ahead on the \(lower) limit"
        case .onPace: return "Right on pace"
        case .under: return "Comfortably under pace"
        case .idle: return "Barely touched"
        }
    }

    /// The window the headline is about.
    static func focus(_ windows: [WindowOutlook]) -> Int? {
        windows.indices.max { windows[$0].standing < windows[$1].standing
            || (windows[$0].standing == windows[$1].standing && windows[$0].used < windows[$1].used) }
    }
}

extension WindowOutlook {
    /// Each of `state`'s windows, shortest first.
    static func of(_ state: ProviderQuotaState, now: Timestamp) -> [WindowOutlook] {
        state.orderedWindows.map { window in
            var lead: Int64?
            if case .success(let rate) = state.burnRates[window.key] { lead = rate.exhaustionLead }
            return WindowOutlook(name: window.name, used: window.percentageUsed ?? 0,
                                 elapsed: window.elapsed(at: now), lead: lead)
        }
    }
}

extension ProviderQuotaState {
    /// Shortest window first: the innermost ring, the first card.
    var orderedWindows: [QuotaSnapshot] {
        windows.sorted { ($0.span ?? .max, $0.key) < ($1.span ?? .max, $1.key) }
    }
}

extension QuotaSnapshot {
    /// The share of the window's time gone at `now`, 0 to 1; nil without a span.
    func elapsed(at now: Timestamp) -> Double? {
        guard let start = windowStartedAt, let end = resetAt, end > start else { return nil }
        return min(1, max(0, Double(now.seconds(since: start)) / Double(end.seconds(since: start))))
    }

    /// How long the window lasts, for ordering; nil without a span.
    var span: Int64? {
        guard let start = windowStartedAt, let end = resetAt, end > start else { return nil }
        return end.seconds(since: start)
    }
}

// MARK: - The board

/// One tile per provider: its rings, its headline, and when its most
/// pressing window resets. Tiles wrap, so four providers still read at once.
private struct LimitsBoard: View {
    let states: [ProviderQuotaState]
    let open: ProviderKey?
    let now: Timestamp
    let choose: (ProviderKey) -> Void

    static let tileWidth: CGFloat = 220

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileWidth), spacing: 14)], spacing: 14) {
            ForEach(states, id: \.provider) { state in
                Button { choose(state.provider) } label: {
                    LimitTile(state: state, now: now, isOpen: state.provider == open && states.count > 1)
                }
                .buttonStyle(PressableStyle())
                .accessibilityAddTraits(state.provider == open ? .isSelected : [])
            }
        }
    }
}

private struct LimitTile: View {
    let state: ProviderQuotaState
    let now: Timestamp
    let isOpen: Bool

    @State private var hovering = false

    var body: some View {
        let windows = state.orderedWindows
        let outlooks = WindowOutlook.of(state, now: now)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 12) {
            LimitRings(rings: windows.indices.map { index in
                LimitRings.Ring(used: outlooks[index].used / 100, elapsed: outlooks[index].elapsed,
                                color: LimitRings.color(index, outlooks[index], provider: state.provider))
            }, provider: state.provider, size: 104)
            .frame(width: 104, height: 104)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(Format.quotaLabel(state.provider)).font(.callout.weight(.medium))
                    if let plan = state.plan {
                        Text(plan.capitalized).font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                }
                Text(WindowOutlook.headline(outlooks) ?? "No windows read")
                    .font(.caption).foregroundStyle(standingColor(outlooks))
                    .multilineTextAlignment(.center).lineLimit(2)
            }
            // Every window, each beside its ring's colour.
            Grid(horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(windows.indices, id: \.self) { index in
                    GridRow {
                        Circle().fill(LimitRings.color(index, outlooks[index], provider: state.provider))
                            .frame(width: 7, height: 7)
                        Text(windows[index].name).foregroundStyle(Palette.textSecondary)
                            .gridColumnAlignment(.leading)
                        Text(Format.percent(outlooks[index].used)).fontWeight(.semibold)
                            .gridColumnAlignment(.trailing)
                        Text(Self.reset(windows[index], now: now) ?? "").foregroundStyle(Palette.textSecondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.caption).monospacedDigit()
        }
        .padding(.vertical, 18).padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Palette.surface, in: shape)
        .overlay(shape.strokeBorder(isOpen ? Palette.accent(state.provider).opacity(0.7)
                                           : Palette.rim.opacity(hovering ? 1 : 0.6),
                                    lineWidth: isOpen ? 1.5 : 0.75))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private func standingColor(_ outlooks: [WindowOutlook]) -> Color {
        (outlooks.map(\.standing).max() ?? .idle) >= .runsOut ? Palette.critical : Palette.textSecondary
    }

    /// When the window resets, said briefly.
    static func reset(_ window: QuotaSnapshot, now: Timestamp) -> String? {
        if window.status(at: now) == .resetPending { return "reset due" }
        return window.resetAt.map { "resets \(Countdown.compact($0.seconds(since: now)))" }
    }
}

// MARK: - A provider's details

private struct ProviderLimits: View {
    let state: ProviderQuotaState
    let status: StatusModel
    let now: Timestamp

    @State private var history: [String: LimitHistory] = [:]

    var body: some View {
        let windows = state.orderedWindows
        VStack(alignment: .leading, spacing: 14) {
            header
            // Why the figures stopped updating, so an expired login reads
            // differently from a dropped connection.
            if case .degraded(let reason, _) = state.health {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Palette.warning)
            }
            ForEach(windows, id: \.key) { window in
                LimitCard(window: window, provider: state.provider, burnRate: state.burnRates[window.key],
                          banked: banked(for: window.key), history: history[window.key],
                          engine: status.comparisons, calendar: status.calendar, now: now)
            }
            if !state.heldResets.isEmpty || state.unconfirmedResets > 0 {
                BankedResetRow(resets: state.heldResets, unconfirmed: state.unconfirmedResets, provider: state.provider,
                               calendar: status.calendar, now: now)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            }
            PastWindows(provider: state.provider, windows: windows, history: history,
                        calendar: status.calendar, now: now)
        }
        // Read again whenever a window's figures move.
        .task(id: windows.map { "\($0.key)@\($0.observedAt.epochSeconds)" }) {
            history = await status.limitHistory(state)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProviderLogo(provider: state.provider, size: 17)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(Format.quotaLabel(state.provider)).font(.title3.weight(.medium))
                if let plan = state.plan {
                    Text(plan.capitalized).font(.callout).foregroundStyle(Palette.textSecondary)
                }
                if state.isAccountWide {
                    Text("· Account-wide").font(.callout).foregroundStyle(Palette.textSecondary)
                        .help("Counts use of this account from every device and app, not this Mac alone")
                }
                Spacer()
                if let note {
                    Text(note).font(.callout).foregroundStyle(Palette.textSecondary)
                }
            }
            if let focus = WindowOutlook.focus(WindowOutlook.of(state, now: now)),
               let usage = history[state.orderedWindows[focus].key]?.usage {
                WindowQuip(usage: usage, engine: status.comparisons)
            }
        }
    }

    /// Held resets that can clear this window: those for it, and those for
    /// the provider's limit as a whole, as Codex keys them, which can clear
    /// any of its windows.
    private func banked(for key: String) -> [BankedReset] {
        let keys = Set(state.windows.map(\.key))
        return state.heldResets.filter { reset in
            guard let applies = reset.appliesToQuotaKey else { return true }
            return applies == key || !keys.contains(applies)
        }
    }

    /// Stale figures are shown with their age, never replaced.
    private var note: String? {
        let age = state.age(at: now).map { "Updated \(Countdown.compact($0)) ago" }
        switch state.health {
        case .degraded: return age.map { "Not refreshed · \($0)" } ?? "Not refreshed"
        case .unavailable(let reason): return reason
        case .ok: return state.isStale(at: now) ? age : nil
        }
    }
}

/// Concentric rings, innermost first: each fills with use, and carries a
/// tick where an even pace would be.
private struct LimitRings: View {
    struct Ring {
        let used: Double
        let elapsed: Double?
        let color: Color
    }

    let rings: [Ring]
    let provider: ProviderKey
    let size: CGFloat

    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { size * 0.075 }
    private var gap: CGFloat { size * 0.035 }

    /// The innermost ring in the provider's colour, outer ones fainter, and
    /// any ring at its limit or running out in the critical colour.
    static func color(_ index: Int, _ outlook: WindowOutlook, provider: ProviderKey) -> Color {
        if outlook.standing >= .runsOut { return Palette.critical }
        return Palette.accent(provider).opacity(index == 0 ? 1 : max(0.45, 1 - Double(index) * 0.3))
    }

    var body: some View {
        ZStack {
            ForEach(rings.indices, id: \.self) { index in ring(rings[index], step: index) }
            ProviderLogo(provider: provider, size: size * 0.2)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.85)) { drawn = true }
        }
        .accessibilityHidden(true)
    }

    /// The innermost ring's diameter: rings grow outwards to fill `size`.
    private var innerDiameter: CGFloat {
        size - CGFloat(rings.count - 1) * (width + gap) * 2
    }

    /// The ring `step` rings out from the innermost.
    private func ring(_ ring: Ring, step: Int) -> some View {
        let diameter = innerDiameter + CGFloat(step) * (width + gap) * 2 - width
        return ZStack {
            Circle().stroke(Palette.controlTrack, lineWidth: width)
            Circle()
                .trim(from: 0, to: drawn ? min(1, max(0, ring.used)) : 0)
                .stroke(ring.color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let elapsed = ring.elapsed {
                // The even-pace tick, across the ring like the fuse bar's.
                Capsule().fill(Palette.textPrimary.opacity(0.85))
                    .frame(width: 2, height: width + 4)
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(elapsed * 360))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - A window

private struct LimitCard: View {
    let window: QuotaSnapshot
    let provider: ProviderKey
    let burnRate: Result<BurnRate, BurnRateGap>?
    let banked: [BankedReset]
    let history: LimitHistory?
    let engine: ComparisonEngine?
    let calendar: LocalCalendar
    let now: Timestamp

    private var used: Double { window.percentageUsed ?? 0 }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 32) {
                figure.frame(width: 180, alignment: .leading)
                chart
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.name)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var figure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.name).font(.callout.weight(.medium)).foregroundStyle(Palette.textSecondary)
            Text(Format.percent(used)).font(Typography.display(40)).tracking(Typography.tracking(40))
                .rollingNumber(used)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Palette.warning)
            } else if let pace {
                Label(pace, systemImage: "flame")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            if let usage = history?.usage, usage.tokens.processed > 0 {
                Text("\(Format.tokens(usage.tokens.processed)) tokens · \(Format.cost(usage.cost))")
                    .font(.caption).foregroundStyle(Palette.textSecondary).monospacedDigit()
                    .help("Sent from this Mac in this window")
            }
        }
    }

    /// The burn-down, with when it resets.
    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let start = window.windowStartedAt, let reset = window.resetAt, reset > start {
                BurnDown(start: start, reset: reset, now: now, used: used,
                         readings: history?.readings ?? [], rate: rate, color: Palette.accent(provider),
                         calendar: calendar)
                    .frame(height: 104)
                    .help("Solid: what was used. Dashed grey: an even pace. Dashed colour: where this rate leads.")
            } else {
                // No span to draw against: the fuse alone.
                FuseBar(fraction: used / 100, pace: nil, color: Palette.accent(provider),
                        critical: used >= QuotaThresholds.critical, height: 12)
            }
            if let countdown {
                Label(countdown, systemImage: "arrow.clockwise").help(absolute ?? "")
                    .font(.caption).monospacedDigit().foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The current rate in percent an hour, when usage is moving.
    private var rate: Double? {
        guard case .success(let rate) = burnRate, rate.percentPerHour >= BurnRateEstimator.idleRate else { return nil }
        return rate.percentPerHour
    }

    /// The card as a sentence, with durations spelled out for VoiceOver.
    private var spokenValue: String {
        var parts = ["\(Int(used.rounded())) percent used"]
        if window.status(at: now) == .resetPending {
            parts.append("reset due, waiting for the provider to confirm")
        } else if let resetAt = window.resetAt {
            parts.append("resets in " + Countdown.spoken(resetAt.seconds(since: now)))
        }
        if let time = window.elapsed(at: now) {
            parts.append("an even pace would be \(Int((time * 100).rounded())) percent")
        }
        if let pace { parts.append("using \(pace)") }
        if case .success(let rate) = burnRate, let lead = rate.exhaustionLead {
            parts.append("runs out " + Countdown.spoken(lead) + " before the reset")
        }
        if !banked.isEmpty { parts.append("\(banked.count) banked reset\(banked.count == 1 ? "" : "s") held") }
        return parts.joined(separator: ", ")
    }

    private var countdown: String? {
        guard let resetAt = window.resetAt else { return nil }
        // A countdown at zero waits for the provider to confirm.
        if window.status(at: now) == .resetPending { return "Reset due · waiting to confirm" }
        return "Resets in \(Countdown.compact(resetAt.seconds(since: now)))"
    }

    private var absolute: String? {
        window.resetAt.map { "Resets " + Countdown.moment($0, now: now, calendar: calendar) }
    }

    /// The rate now, or the window's average while usage is idle.
    private var pace: String? {
        guard case .success(let rate) = burnRate, rate.percentPerHour >= BurnRateEstimator.idleRate else { return nil }
        let figure = String(format: "%.1f%%", rate.percentPerHour)
        return rate.basis == .window ? "\(figure) an hour on average" : "\(figure) an hour"
    }

    private var warning: String? {
        guard case .success(let rate) = burnRate, let lead = rate.exhaustionLead else { return nil }
        let when = "runs out \(Countdown.compact(lead)) before the reset"
        return rate.basis == .window ? "At this pace, " + when : when.prefix(1).uppercased() + when.dropFirst()
    }
}

/// The focus window's usage from this Mac as a comparison, in the chosen tone.
private struct WindowQuip: View {
    let usage: UsageTotals
    let engine: ComparisonEngine?

    @AppStorage(ActivityPreferences.showComparisonsKey) private var show = true
    @AppStorage(ActivityPreferences.comparisonToneKey) private var tone = ActivityPreferences.mix
    @State private var quip: String?

    var body: some View {
        VStack(alignment: .leading) {
            if show, let quip {
                Label(quip, systemImage: "sparkles")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        // A new line only when the usage changes size, not each minute.
        .task(id: "\(Int(log2(Double(max(usage.tokens.processed, 1)))))|\(tone)|\(show)") {
            quip = engine?.comparison(tokens: Double(usage.tokens.processed),
                                      tone: ActivityPreferences.tone(tone))?.text
        }
    }
}

/// How the window has filled: the readings as a line over the window's
/// span, the even pace from empty at its start to full at its reset, and
/// the current rate carried on to the reset, or to the limit if sooner.
private struct BurnDown: View {
    let start: Timestamp
    let reset: Timestamp
    let now: Timestamp
    let used: Double
    let readings: [LimitHistory.Reading]
    let rate: Double?
    let color: Color
    let calendar: LocalCalendar

    @State private var hover: CGFloat?
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let labels: CGFloat = 16

    /// Now, held at the reset while a reset waits to be confirmed.
    private var present: Timestamp { min(now, reset) }

    /// The readings, ending at the figure now shown, so the line always
    /// meets the big number.
    private var points: [LimitHistory.Reading] {
        var points = readings.filter { $0.at >= start && $0.at <= present }
        if points.last.map({ $0.at < present }) ?? true {
            points.append(LimitHistory.Reading(at: present, percent: used))
        }
        return points
    }

    /// Where the current rate leads: the reset, or the moment the limit runs out.
    private var projection: (at: Timestamp, percent: Double)? {
        guard let rate, rate > 0, now < reset else { return nil }
        let hoursLeft = Double(reset.seconds(since: now)) / 3_600
        let atReset = used + rate * hoursLeft
        if atReset <= 100 { return (reset, atReset) }
        let seconds = Int64((100 - used) / rate * 3_600)
        return (now.adding(seconds: max(0, seconds)), 100)
    }

    var body: some View {
        let points = points
        let projection = projection
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(&context, size: size, points: points, projection: projection)
                    }
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: drawn ? size.width : 0)
                    }
                    if let hover, let reading = nearest(to: hover, in: size, points: points) {
                        hoverCard(reading, x: x(reading.at, size.width), size: size)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hover = location.x
                    case .ended: hover = nil
                    }
                }
            }
            HStack {
                Text(label(start))
                Spacer()
                if let projection, projection.percent >= 100 {
                    Text("Runs out \(label(projection.at))").foregroundStyle(Palette.critical)
                    Spacer()
                }
                Text(label(reset))
            }
            .font(.caption2).monospacedDigit().foregroundStyle(Palette.textSecondary)
            .frame(height: Self.labels)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9)) { drawn = true }
        }
        .accessibilityHidden(true)
    }

    private func x(_ at: Timestamp, _ width: CGFloat) -> CGFloat {
        let span = Double(reset.seconds(since: start))
        return CGFloat(Double(at.seconds(since: start)) / span) * width
    }

    private func y(_ percent: Double, _ height: CGFloat) -> CGFloat {
        height - CGFloat(min(100, max(0, percent)) / 100) * height
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, points: [LimitHistory.Reading],
                      projection: (at: Timestamp, percent: Double)?) {
        let w = size.width, h = size.height

        // The limit, and halfway, as quiet rules.
        for (percent, opacity) in [(100.0, 0.5), (50.0, 0.25)] {
            var rule = Path()
            rule.move(to: CGPoint(x: 0, y: y(percent, h)))
            rule.addLine(to: CGPoint(x: w, y: y(percent, h)))
            context.stroke(rule, with: .color(Palette.separator.opacity(opacity)), lineWidth: 1)
        }

        // An even pace: empty at the start, full at the reset.
        var even = Path()
        even.move(to: CGPoint(x: 0, y: h))
        even.addLine(to: CGPoint(x: w, y: 0))
        context.stroke(even, with: .color(Palette.textSecondary.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1.25, dash: [3, 3]))

        // The readings, stepped: a figure holds until the next is seen.
        guard let first = points.first else { return }
        var line = Path()
        line.move(to: CGPoint(x: x(first.at, w), y: y(first.percent, h)))
        for point in points.dropFirst() {
            line.addLine(to: CGPoint(x: x(point.at, w), y: line.currentPoint?.y ?? y(point.percent, h)))
            line.addLine(to: CGPoint(x: x(point.at, w), y: y(point.percent, h)))
        }
        var area = line
        area.addLine(to: CGPoint(x: x(points.last!.at, w), y: h))
        area.addLine(to: CGPoint(x: x(first.at, w), y: h))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.32), color.opacity(0.02)]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        // Before the first reading nothing was seen: a faint join from empty.
        if first.at > start {
            var unseen = Path()
            unseen.move(to: CGPoint(x: 0, y: h))
            unseen.addLine(to: CGPoint(x: x(first.at, w), y: y(first.percent, h)))
            context.stroke(unseen, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        }

        // The current rate, carried forward.
        let nowPoint = CGPoint(x: x(present, w), y: y(used, h))
        if let projection {
            var ahead = Path()
            ahead.move(to: nowPoint)
            let end = CGPoint(x: x(projection.at, w), y: y(projection.percent, h))
            ahead.addLine(to: end)
            let runsOut = projection.percent >= 100
            context.stroke(ahead, with: .color(runsOut ? Palette.critical : color.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            if runsOut {
                context.fill(Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)),
                             with: .color(Palette.critical))
            }
        }

        // Now.
        var rule = Path()
        rule.move(to: CGPoint(x: nowPoint.x, y: 0))
        rule.addLine(to: CGPoint(x: nowPoint.x, y: h))
        context.stroke(rule, with: .color(Palette.textSecondary.opacity(0.35)), lineWidth: 1)
        context.fill(Path(ellipseIn: CGRect(x: nowPoint.x - 4.5, y: nowPoint.y - 4.5, width: 9, height: 9)),
                     with: .color(color))
        context.stroke(Path(ellipseIn: CGRect(x: nowPoint.x - 4.5, y: nowPoint.y - 4.5, width: 9, height: 9)),
                       with: .color(Palette.surface), lineWidth: 2)
    }

    private func nearest(to location: CGFloat, in size: CGSize, points: [LimitHistory.Reading]) -> LimitHistory.Reading? {
        points.min { abs(x($0.at, size.width) - location) < abs(x($1.at, size.width) - location) }
    }

    private func hoverCard(_ reading: LimitHistory.Reading, x: CGFloat, size: CGSize) -> some View {
        let text = "\(label(reading.at)) · \(Format.percent(reading.percent))"
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.textPrimary.opacity(0.35)).frame(width: 1, height: size.height)
                .offset(x: x)
            Text(text)
                .font(.caption.weight(.medium)).monospacedDigit()
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Palette.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize()
                .offset(x: min(max(0, x - 50), size.width - 110), y: -4)
        }
        .allowsHitTesting(false)
    }

    /// A time for a short window, a day and time for a long one.
    private func label(_ instant: Timestamp) -> String {
        var style = Date.FormatStyle(timeZone: calendar.calendar.timeZone)
        style = reset.seconds(since: start) > 86_400
            ? style.weekday(.abbreviated).day().hour().minute()
            : style.hour().minute()
        return instant.date.formatted(style)
    }
}

// MARK: - Past windows

/// How full each window got before it reset, newest at the right, with how
/// often the limit was reached.
private struct PastWindows: View {
    let provider: ProviderKey
    let windows: [QuotaSnapshot]
    let history: [String: LimitHistory]
    let calendar: LocalCalendar
    let now: Timestamp

    /// The span reported as "this month".
    static let month: Int64 = 30 * 86_400
    /// Windows needed before the strip shows.
    static let fewest = 2

    var body: some View {
        let rows = windows.compactMap { window in history[window.key].map { (window, $0) } }
            // One window is not yet a habit.
            .filter { $0.1.past.count >= PastWindows.fewest }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Earlier windows").font(.callout.weight(.medium)).foregroundStyle(Palette.textSecondary)
                ForEach(rows, id: \.0.key) { window, history in
                    PeakStrip(name: window.name, history: history, color: Palette.accent(provider),
                              calendar: calendar, now: now, long: (window.span ?? 0) > 86_400)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }
}

private struct PeakStrip: View {
    let name: String
    let history: LimitHistory
    let color: Color
    let calendar: LocalCalendar
    let now: Timestamp
    let long: Bool

    @State private var hovered: Int?
    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 40
    static let bar: CGFloat = 14

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            Text(name).font(.callout).frame(width: 70, alignment: .leading)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(history.past.indices, id: \.self) { index in bar(index) }
            }
            Group {
                if let hovered, history.past.indices.contains(hovered) {
                    let cycle = history.past[hovered]
                    Text("\(ended(cycle)) · peaked at \(Format.percent(cycle.peak))")
                } else {
                    Text(summary)
                }
            }
            .font(.caption).foregroundStyle(Palette.textSecondary).monospacedDigit()
            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.8)) { risen = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Earlier \(name.lowercased()) windows")
        .accessibilityValue(summary + ", " + history.past.map { "\(Int($0.peak.rounded())) percent" }.joined(separator: ", "))
    }

    private func bar(_ index: Int) -> some View {
        let cycle = history.past[index]
        let height: CGFloat = risen ? max(2, Self.height * CGFloat(min(1, cycle.peak / 100))) : 2
        let dimmed = hovered != nil && hovered != index
        return UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
            .fill(fill(cycle.peak).opacity(dimmed ? 0.45 : 1))
            .frame(width: Self.bar, height: height)
            .frame(height: Self.height, alignment: .bottom)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = index } else if hovered == index { hovered = nil }
            }
    }

    /// How often it ran out this month, and how full it usually gets.
    private var summary: String {
        let capped = history.capped(within: PastWindows.month, now: now)
        let limit = switch capped {
        case 0: "Never ran out this month"
        case 1: "Ran out once this month"
        default: "Ran out \(capped) times this month"
        }
        return history.averagePeak.map { "\(limit) · usually peaks near \(Format.percent($0))" } ?? limit
    }

    private func fill(_ peak: Double) -> Color {
        if peak >= 100 { return Palette.critical }
        if peak >= QuotaThresholds.critical { return Palette.warning }
        return color
    }

    private func ended(_ cycle: AchievementHistory.QuotaCycle) -> String {
        var style = Date.FormatStyle(timeZone: calendar.calendar.timeZone)
        style = long ? style.month(.abbreviated).day() : style.weekday(.abbreviated).hour().minute()
        return "Ended \(cycle.end.date.formatted(style))"
    }
}
