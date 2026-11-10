//
//  PopoverView.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import BurnlineServices
import SwiftUI

/// The menu-bar item: its icon, filled while a provider is live, and the
/// title the user chose.
public struct MenuBarLabel: View {
    let model: StatusModel
    @AppStorage(MenuBarTitleMode.storageKey) private var mode = MenuBarTitleMode.default
    @Environment(\.openWindow) private var openWindow

    public init(model: StatusModel) {
        self.model = model
    }

    public var body: some View {
        icon
            .accessibilityLabel(model.storeFailure == nil ? "Burnline"
                                : model.failedToStart ? "Burnline, cannot open its database"
                                : "Burnline, new usage is not being saved")
            // The label is always alive, so it is what opens the dashboard
            // when the database did not, even in menu-bar-only mode.
            .onChange(of: model.failedToStart) { _, failed in
                guard failed else { return }
                openWindow(id: SceneID.dashboard)
                NSApp.activate()
            }
            .onChange(of: model.dashboardRequests) {
                openWindow(id: SceneID.dashboard)
                NSApp.activate()
            }
        if let text = mode.text(today: model.today, quotas: model.quotas) {
            Text(text).monospacedDigit()
        }
    }

    /// The flame burns with the work: an outline when nothing is running,
    /// filled while it is, in ember once busy and red at a peak. It changes
    /// only when the stage does, never animates, so it costs nothing idle.
    /// A store that cannot save is the one thing louder.
    @ViewBuilder private var icon: some View {
        if model.storeFailure != nil {
            Image(systemName: "exclamationmark.triangle")
        } else {
            switch model.heatStage {
            case .idle: Image(systemName: "flame")
            case .warm: Image(systemName: "flame.fill")
            case .hot: Image(nsImage: Self.flame(Palette.ember))
            case .blazing: Image(nsImage: Self.flame(Palette.critical))
            }
        }
    }

    /// A coloured flame. The menu bar draws a template image in its own ink,
    /// so colour needs an image that is not one.
    private static func flame(_ color: Color) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(color)]))
        let image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }
}

/// The popover, in the dashboard's own surfaces rather than the system
/// glass: today's cost and tokens, each provider's limits, the sessions
/// running now, one comparison, and the way to the dashboard. The limits
/// come first and everything else is a line or two; analysis belongs in
/// the dashboard.
public struct PopoverView: View {
    let model: StatusModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    /// Wide enough for a reset countdown beside a usable bar, and for two
    /// windows side by side in a compact provider row.
    static let width: CGFloat = 340
    /// Up to this many providers each get a full card; past it, each is a
    /// compact row that opens into its card, so the popover never grows long.
    static let fullCardsUpTo = 2

    @State private var opened: ProviderKey?

    public init(model: StatusModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = model.storeFailure {
                StoreFailureRow(failure: failure, failedToStart: model.failedToStart)
            }
            if !model.failedToStart {
                TodayHeader(today: model.today)
            }
            limits
            if let live = model.live, !live.sessions.isEmpty {
                ActiveSessions(live: live)
            }
            if let engine = model.comparisons, let today = model.today, today.tokens > 0 {
                PopoverQuip(engine: engine, tokens: today.tokens, live: model.live)
            }
            footer
        }
        .padding(12)
        .frame(width: Self.width)
        .foregroundStyle(Palette.textPrimary)
        // Behind the cards, so the burn lights the gaps and the rim, never the figures.
        .background { HeatGlow(heat: model.heat) }
        .background(Palette.background)
    }

    @ViewBuilder private var limits: some View {
        let states = model.visibleQuotas
        if states.count <= Self.fullCardsUpTo {
            ForEach(states, id: \.provider) { state in
                ProviderLimitsCard(state: state, calendar: model.calendar)
            }
        } else {
            VStack(spacing: 6) {
                ForEach(states, id: \.provider) { state in
                    if opened == state.provider {
                        ProviderLimitsCard(state: state, calendar: model.calendar)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(state.provider) }
                            .transition(.opacity)
                    } else {
                        Button { toggle(state.provider) } label: { CompactLimits(state: state) }
                            .buttonStyle(.pressable)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    private func toggle(_ provider: ProviderKey) {
        withAnimation(.snappy(duration: 0.25)) { opened = opened == provider ? nil : provider }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                openWindow(id: SceneID.dashboard)
                NSApp.activate()
                dismiss()
            } label: {
                Text("Open Dashboard").font(.callout.weight(.medium)).foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Palette.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.pressable)
            .keyboardShortcut("d")
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(model.refreshing)
            .keyboardShortcut("r")
            .help("Refresh quota")
            .accessibilityLabel("Refresh quota")
            OptionsMenu()
        }
        .foregroundStyle(Palette.textSecondary)
        .padding(.top, 2)
    }
}

/// Why the store is not saving, or did not open, with the dashboard as the
/// place to deal with it.
struct StoreFailureRow: View {
    let failure: StoreFailure
    let failedToStart: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(failedToStart ? failure.title : "New usage is not being saved").font(.callout.weight(.semibold))
                Text(failedToStart ? "No usage can be shown. Open the dashboard for what to do."
                     : "\(failure.cause.prefix(1).uppercased() + failure.cause.dropFirst()). "
                        + "It stays in the providers’ files until it can be saved.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Today's equivalent cost and tokens on one line. How much of the cost is
/// priced is in its help text, and said only when some is not.
struct TodayHeader: View {
    let today: TodayStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
                Spacer()
                if let today, let coverage = today.costCoverage, coverage < 1 {
                    Text("\(Int((coverage * 100).rounded(.down)))% priced")
                        .font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            if let today {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.cost(today.cost)).font(.title.weight(.semibold)).monospacedDigit()
                        .rollingNumber(Double(today.cost.raw))
                        .animation(Motion.standard, value: today.cost)
                        .help(Self.costNote(today.costCoverage))
                    Spacer()
                    Text("\(Format.tokens(today.tokens)) tokens").font(.callout).monospacedDigit()
                        .rollingNumber(Double(today.tokens))
                        .animation(Motion.standard, value: today.tokens)
                        .foregroundStyle(Palette.textSecondary)
                }
            } else {
                Text("Reading your usage…").foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    /// Every headline cost says how much of it is priced.
    static func costNote(_ coverage: Double?) -> String {
        guard let coverage, coverage < 1 else { return "Equivalent cost at API prices" }
        return "Equivalent cost · \(Int((coverage * 100).rounded(.down)))% of events priced"
    }
}

/// One provider's limits as a card: a header with its plan, banked resets
/// and any staleness, then one row per window, and a warning line only when
/// a window runs out before its reset.
struct ProviderLimitsCard: View {
    let state: ProviderQuotaState
    let calendar: LocalCalendar

    var body: some View {
        // Ages and expiries read in minutes, so a minute's cadence keeps them true.
        TimelineView(.everyMinute) { context in
            content(now: Timestamp(context.date) ?? state.lastSuccess ?? Timestamp(epochSeconds: 0))
        }
    }

    private func content(now: Timestamp) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            header(now: now)
            if case .degraded(let reason, _) = state.health {
                Text(reason).font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(state.windows, id: \.key) { window in
                    LimitRow(window: window, provider: state.provider, calendar: calendar, now: now)
                }
            }
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Palette.warning)
            }
        }
        .padding(10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func header(now: Timestamp) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ProviderLogo(provider: state.provider, size: 13).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(Format.quotaLabel(state.provider)).font(.callout.weight(.semibold))
                .help(state.isAccountWide ? "Counts use of this account from every device and app, not this Mac alone" : "")
            if let plan = state.plan {
                Text(plan.capitalized).font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 6)
            if let note = healthNote(now: now) {
                Text(note).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
            } else if !state.heldResets.isEmpty {
                Label("\(state.heldResets.count)", systemImage: "ticket")
                    .font(.caption).monospacedDigit().foregroundStyle(Palette.textSecondary)
                    .help(bankedHelp(now: now))
            }
        }
    }

    /// "5-hour runs out 2h 32m early", for each window on course to.
    private var warnings: [String] {
        state.windows.compactMap { window in
            guard case .success(let rate) = state.burnRates[window.key], let lead = rate.exhaustionLead else { return nil }
            return "\(window.name) runs out \(Countdown.compact(lead)) early"
        }
    }

    private func bankedHelp(now: Timestamp) -> String {
        let count = state.heldResets.count
        var lines = ["\(count) banked reset\(count == 1 ? "" : "s"): each clears a \(Format.quotaLabel(state.provider)) usage window when spent"]
        if let soonest = state.heldResets.compactMap(\.expiresAt).min() {
            lines.append("\(count > 1 ? "First expires" : "Expires") \(Countdown.moment(soonest, now: now, calendar: calendar))")
        }
        return lines.joined(separator: "\n")
    }

    /// Stale figures are shown with their age, never replaced.
    private func healthNote(now: Timestamp) -> String? {
        let age = state.age(at: now).map { "\(Countdown.compact($0)) old" }
        switch state.health {
        case .degraded: return age.map { "Not refreshed · \($0)" } ?? "Not refreshed"
        case .unavailable(let reason): return reason
        case .ok: return state.isStale(at: now) ? age : nil
        }
    }
}

/// A provider in two lines, for when there are too many for full cards:
/// its name, then each window's percentage over a thin bar, side by side.
/// A window on course to run out early shows its percentage in the warning
/// colour; the card it opens into says by how much.
struct CompactLimits: View {
    let state: ProviderQuotaState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 6) {
                ProviderLogo(provider: state.provider, size: 13)
                Text(Format.quotaLabel(state.provider)).font(.callout.weight(.semibold)).lineLimit(1)
            }
            .frame(width: 92, alignment: .leading)
            ForEach(state.windows, id: \.key) { window in
                let used = window.percentageUsed ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.name).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.percent(used)).font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(color(window, used: used))
                            .rollingNumber(used)
                            .animation(Motion.standard, value: used)
                    }
                    FuseBar(fraction: used / 100, pace: nil, color: Palette.accent(state.provider),
                            critical: used >= QuotaThresholds.critical, height: 4)
                }
                .frame(maxWidth: .infinity)
            }
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Format.quotaLabel(state.provider))
        .accessibilityValue(state.windows.map { "\($0.name) \(Format.percent($0.percentageUsed ?? 0))" }
            .joined(separator: ", "))
        .accessibilityHint("Shows resets and warnings")
    }

    private func color(_ window: QuotaSnapshot, used: Double) -> Color {
        if used >= QuotaThresholds.critical { return Palette.critical }
        if case .success(let rate) = state.burnRates[window.key], rate.exhaustionLead != nil { return Palette.warning }
        return Palette.textPrimary
    }
}

/// One window in a grid row: its name, a bar with an even-pace tick, the
/// percentage, and the time to its reset, the reset's moment in help. The
/// card's minute cadence redraws it, the precision its countdown shows.
struct LimitRow: View {
    // Fixed columns, so the bars line up from one provider's card to the next.
    static let nameWidth: CGFloat = 44
    static let percentWidth: CGFloat = 36
    static let countdownWidth: CGFloat = 54

    let window: QuotaSnapshot
    let provider: ProviderKey
    let calendar: LocalCalendar
    let now: Timestamp

    var body: some View {
        let used = window.percentageUsed ?? 0
        GridRow(alignment: .center) {
            Text(window.name).font(.caption).foregroundStyle(Palette.textSecondary)
                .frame(width: Self.nameWidth, alignment: .leading)
            FuseBar(fraction: used / 100, pace: pace(at: now), color: Palette.accent(provider),
                    critical: used >= QuotaThresholds.critical, height: 5)
                .frame(maxWidth: .infinity)
            Text(Format.percent(used)).font(.callout.weight(.medium)).monospacedDigit()
                .foregroundStyle(used >= QuotaThresholds.critical ? Palette.critical : Palette.textPrimary)
                .rollingNumber(used)
                .animation(Motion.standard, value: used)
                .frame(width: Self.percentWidth, alignment: .trailing)
            Text(countdown(at: now)).font(.caption).monospacedDigit().foregroundStyle(Palette.textSecondary)
                .frame(width: Self.countdownWidth, alignment: .trailing)
                .help(window.resetAt.map { "Resets " + Countdown.moment($0, now: now, calendar: calendar) } ?? "")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.name)
        .accessibilityValue("\(Format.percent(used)) used, \(countdown(at: now))")
    }

    private func countdown(at now: Timestamp) -> String {
        guard let resetAt = window.resetAt else { return "" }
        // A countdown at zero waits for the provider to confirm.
        if window.status(at: now) == .resetPending { return "reset due" }
        return Countdown.compact(resetAt.seconds(since: now))
    }

    /// How far through the window time has gone, where usage would sit at an
    /// even pace.
    private func pace(at now: Timestamp) -> Double? {
        guard let start = window.windowStartedAt, let end = window.resetAt, end > start else { return nil }
        let fraction = Double(now.seconds(since: start)) / Double(end.seconds(since: start))
        return (0...1).contains(fraction) ? fraction : nil
    }
}

/// The sessions producing usage now, by project, each with its cost an
/// hour at its current pace; the new tokens a minute across them in the
/// header, since cache re-reads would make it look a hundred times larger.
struct ActiveSessions: View {
    let live: LiveActivity
    /// More than this and the rest are counted, not listed.
    static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Palette.positive).frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityHidden(true)
                Text("Active now").font(.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
                Spacer()
                Text("\(Format.tokens(Int64(live.newTokensPerMinute))) new tok/min")
                    .font(.caption).monospacedDigit().foregroundStyle(Palette.textSecondary)
                    .rollingNumber(live.newTokensPerMinute)
                    .animation(Motion.standard, value: live.newTokensPerMinute)
                    .help("Tokens sent and written each minute, leaving out the conversation re-read from cache on every reply")
            }
            ForEach(live.sessions.prefix(Self.shown), id: \.id) { session in
                HStack(spacing: 6) {
                    if let provider = session.provider { ProviderLogo(provider: provider, size: 12) }
                    Text(session.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(Format.cost(session.costPerHour))/h").font(.caption).monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                        .rollingNumber(Double(session.costPerHour.raw))
                        .animation(Motion.standard, value: session.costPerHour)
                }
            }
            if live.sessions.count > Self.shown {
                Text("and \(live.sessions.count - Self.shown) more").font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One comparison line, taking turns between today's tokens and, while
/// usage is arriving, the live pace. Drawn again only when the tone, the
/// rough size of today or the pace's order of magnitude changes.
struct PopoverQuip: View {
    let engine: ComparisonEngine
    let tokens: Int64
    let live: LiveActivity?

    /// Lines drawn for each source.
    static let variety = 3

    @AppStorage(ActivityPreferences.showComparisonsKey) private var show = true
    @AppStorage(ActivityPreferences.comparisonToneKey) private var tone = ActivityPreferences.mix
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading) {
            if show, !lines.isEmpty {
                ComparisonTicker(lines: lines, font: .caption, alignment: .leading)
            }
        }
        .padding(.horizontal, 2)
        .task(id: key) { lines = draw() }
    }

    private var key: String {
        let pace = live.map { Int(log2(max($0.tokensPerMinute, 1))) } ?? -1
        return "\(tone)|\(show)|\(String(format: "%.2g", Double(tokens)))|\(pace)"
    }

    private func draw() -> [String] {
        let tone = ActivityPreferences.tone(tone)
        let today = ComparisonTicker.lines(engine, tokens: tokens, tone: tone, scope: .today, count: Self.variety)
        var pace: [String] = []
        if let live {
            for _ in 0..<(Self.variety * 3) where pace.count < Self.variety {
                if let text = engine.pace(tokensPerHour: live.tokensPerMinute * 60, tone: tone)?.text,
                   !pace.contains(text) { pace.append(text) }
            }
        }
        // Interleaved, so the pace comes round between today's lines.
        return (0..<max(today.count, pace.count)).flatMap { index in
            [today.indices.contains(index) ? today[index] : nil,
             pace.indices.contains(index) ? pace[index] : nil].compactMap { $0 }
        }
    }
}

/// Banked resets as a count, never a percentage, with the soonest expiry.
/// A banked reset expires; only a window resets.
struct BankedResetRow: View {
    let resets: [BankedReset]
    /// Ones no longer reported, but never confirmed spent.
    var unconfirmed = 0
    let provider: ProviderKey
    let calendar: LocalCalendar
    let now: Timestamp

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Label("Banked reset", systemImage: "ticket")
                Spacer()
                Text("\(resets.count) available").monospacedDigit().foregroundStyle(.secondary)
            }
            Group {
                Text("Clears a \(Format.quotaLabel(provider)) usage window when spent")
                if let soonest = resets.compactMap(\.expiresAt).min() {
                    Text("\(resets.count > 1 ? "First expires" : "Expires") "
                         + Countdown.moment(soonest, now: now, calendar: calendar))
                }
                if unconfirmed > 0 {
                    Text("\(unconfirmed) more no longer reported; not counted as spent")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What is producing usage right now, on a provider's page: the provider,
/// model and project, and its pace in new tokens and cost an hour.
struct LiveRow: View {
    let live: LiveActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Palette.positive).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("Live").font(.caption.weight(.semibold))
                Text([live.provider.displayName, live.model].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).lineLimit(1)
            }
            // A project gets its own line: sharing one, the middle
            // truncation cut through the model name instead.
            if let project = live.project {
                Text(project).font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Text("\(Format.tokens(Int64(live.newTokensPerMinute))) new tok/min · \(Format.cost(Nanodollars(raw: live.costPerMinute.raw * 60)))/h")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The popover's way to Settings, About and quitting. Everything else that
/// can be set lives in Settings, so the menu stays short.
struct OptionsMenu: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Menu {
            Button("Settings…") { show { openSettings() } }.keyboardShortcut(",")
            Button("About Burnline") { show { openWindow(id: SceneID.about) } }
            Divider()
            Button("Quit Burnline") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Options")
    }

    /// Opens a window in front: in menu-bar-only mode the app is not active,
    /// and its windows would open behind the one in use.
    private func show(_ open: () -> Void) {
        open()
        NSApp.activate()
        dismiss()
    }
}
