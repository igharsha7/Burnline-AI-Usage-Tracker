//
//  ActivityPage.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import BurnlineServices
import SwiftUI

/// Every tracked day at a glance, then what the days add up to: streaks,
/// achievements and comparisons. Streaks and achievements are observations
/// about work done, never goals, and Settings can hide them entirely.
struct ActivityPage: View {
    let model: DashboardModel

    @AppStorage(ActivityPreferences.showComparisonsKey) private var showComparisons = true
    @Environment(SettingsModel.self) private var settings: SettingsModel?

    var body: some View {
        let activity = model.activity
        Page {
            VStack(alignment: .leading, spacing: 20) {
                if let snapshot = activity.snapshot {
                    if snapshot.days.isEmpty {
                        ContentUnavailableView("Nothing tracked yet", systemImage: "square.grid.3x3",
                                               description: Text("Each day you use Codex or Claude Code fills a square here."))
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        // Above the cards after it, so a day's hover card can
                        // reach over them rather than slide underneath.
                        Card { HeatmapSection(model: model, activity: activity) }.arrival(0).tourTarget(.heatmap)
                            .zIndex(1)
                        if settings?.showAchievements != false {
                            Card { StreakCard(streaks: snapshot.streaks, calendar: model.calendar, now: model.clock.now) }
                                .arrival(1)
                            Card {
                                AchievementsSummary(snapshot: snapshot, calendar: model.calendar) {
                                    model.area = .achievements
                                }
                            }
                            .arrival(2)
                        }
                        if showComparisons, snapshot.lifetime.tokens.processed > 0 {
                            Card {
                                ClimbCard(climb: Climb(days: snapshot.days), engine: model.comparisons,
                                          calendar: model.calendar, lifetimeTokens: snapshot.lifetime.tokens.processed)
                            }
                            .arrival(3)
                        }
                    }
                } else if let failure = activity.failure {
                    ContentUnavailableView("Activity could not be read", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView("Reading activity…").controlSize(.small).frame(maxWidth: .infinity, minHeight: 360)
                }
            }
        }
        .task(id: model.refreshes) { await activity.follow() }
    }
}

/// Totals at two significant figures, the precision a comparison shows,
/// to tell when one needs drawing again.
private func roughly(_ totals: UsageTotals?) -> String {
    guard let totals else { return "none" }
    func twoFigures(_ value: Double) -> String { value > 0 ? String(format: "%.2g", value) : "0" }
    return "\(twoFigures(Double(totals.tokens.processed)))|\(twoFigures(Double(totals.cost.raw)))"
}

// MARK: Heatmap

/// One square of the grid: a tracked day, or a day before tracking began,
/// which is drawn apart from a tracked day without usage.
enum HeatmapCell {
    case tracked(ActivityDay)
    case untracked(LocalDay)

    var day: LocalDay {
        switch self {
        case .tracked(let day): day.day
        case .untracked(let day): day
        }
    }
}

/// The heatmap's columns: one per week, starting on the user's first
/// weekday, ending with the week holding today. Nil pads a week's start
/// before the range and its end after today.
struct HeatmapGrid {
    let weeks: [[HeatmapCell?]]
    let tracked: [ActivityDay]

    init(days: [ActivityDay], range: HeatmapRange, calendar: LocalCalendar, now: Timestamp) {
        let count = range.days ?? max(days.count, 1)
        let shown = calendar.days(endingWith: now, count: count)
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        var cells: [HeatmapCell?] = []
        if let first = shown.first {
            let weekday = calendar.calendar.component(.weekday, from: calendar.window(for: first).start.date)
            cells = Array(repeating: nil, count: (weekday - calendar.calendar.firstWeekday + 7) % 7)
        }
        cells += shown.map { day in byDay[day].map(HeatmapCell.tracked) ?? .untracked(day) }
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
        tracked = shown.compactMap { byDay[$0] }
    }
}

private struct HeatmapSection: View {
    let model: DashboardModel
    @Bindable var activity: ActivityModel

    /// Squares grow to fill the card, between these sizes; a range too long
    /// for the smallest scrolls, ending at today.
    static let cellRange: ClosedRange<CGFloat> = 9...16
    static let gap: CGFloat = 3
    @State private var width: CGFloat = 0
    @State private var cardSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Level 1 to 4's strength of a day's colours, lighter to stronger.
    static let shades: [Double] = [0.35, 0.55, 0.78, 1]
    static let corner: CGFloat = 2.5

    var body: some View {
        let calendar = model.calendar, now = model.clock.now
        let grid = HeatmapGrid(days: activity.snapshot?.days ?? [], range: activity.range, calendar: calendar, now: now)
        let scale = HeatmapScale(values: grid.tracked.map(activity.metric.value))
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Activity", detail: summary(grid)) {
                SegmentedChoice(options: HeatmapMetric.allCases.map { ($0, $0.title) }, selection: $activity.metric)
                SegmentedChoice(options: HeatmapRange.allCases.map { ($0, $0.short) }, selection: $activity.range)
                    .accessibilityLabel("Range")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                cells(grid, scale: scale, size: cellSize(weeks: grid.weeks.count), calendar: calendar, now: now)
            }
            .defaultScrollAnchor(.trailing)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            HStack(alignment: .firstTextBaseline) {
                Text(busiest(calendar: calendar))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 16)
                legend
            }
        }
        .overlayPreferenceValue(HoveredTile.self) { anchor in
            GeometryReader { proxy in
                if let anchor, let hovered = activity.hovered,
                   let day = activity.snapshot?.days.last(where: { $0.day == hovered }) {
                    let tile = proxy[anchor]
                    HeatmapTooltip(day: day, title: BucketLabel.date(day.window.start, "yMMMEd", calendar: calendar))
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .offset(tooltipOffset(tile: tile, in: proxy.size))
                        .animation(Motion.standard(reduced: reduceMotion), value: hovered)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(Motion.standard(reduced: reduceMotion), value: activity.hovered == nil)
    }

    /// Above the square where there is room, else below it; centred on it,
    /// and kept inside the card.
    private func tooltipOffset(tile: CGRect, in bounds: CGSize) -> CGSize {
        let gap: CGFloat = 8
        let x = min(max(tile.midX - cardSize.width / 2, 0), max(bounds.width - cardSize.width, 0))
        let above = tile.minY - gap - cardSize.height
        return CGSize(width: x, height: above >= 0 ? above : tile.maxY + gap)
    }

    private func cellSize(weeks: Int) -> CGFloat {
        guard weeks > 0, width > 0 else { return Self.cellRange.lowerBound }
        let fitted = ((width - CGFloat(weeks - 1) * Self.gap) / CGFloat(weeks)).rounded(.down)
        return min(max(fitted, Self.cellRange.lowerBound), Self.cellRange.upperBound)
    }

    private func cells(_ grid: HeatmapGrid, scale: HeatmapScale, size: CGFloat, calendar: LocalCalendar,
                       now: Timestamp) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Self.gap) {
                ForEach(grid.weeks.indices, id: \.self) { index in
                    Text(monthLabel(grid.weeks, index, calendar: calendar) ?? "")
                        .font(.caption2)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize()
                        .frame(width: size, alignment: .leading)
                }
            }
            .accessibilityHidden(true)
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(grid.weeks.indices, id: \.self) { index in
                    VStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { row in
                            if let cell = grid.weeks[index][row] {
                                square(cell, scale: scale, calendar: calendar)
                                    .frame(width: size, height: size)
                            } else {
                                Color.clear.frame(width: size, height: size).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Daily activity")
        }
    }

    /// The month's short name over the first week that starts in it.
    private func monthLabel(_ weeks: [[HeatmapCell?]], _ index: Int, calendar: LocalCalendar) -> String? {
        guard let first = weeks[index].compactMap({ $0 }).first?.day else { return nil }
        if index > 0, let previous = weeks[index - 1].compactMap({ $0 }).first?.day, previous.month == first.month {
            return nil
        }
        // A label needs a few columns of room before the next one.
        if index + 2 < weeks.count, let later = weeks[index + 2].compactMap({ $0 }).first?.day, later.month != first.month {
            return nil
        }
        return BucketLabel.date(calendar.window(for: first).start, "MMM", calendar: calendar)
    }

    @ViewBuilder
    private func square(_ cell: HeatmapCell, scale: HeatmapScale, calendar: LocalCalendar) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        let hovered = activity.hovered == cell.day
        switch cell {
        case .untracked:
            shape.strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.75)
                .accessibilityLabel("\(spoken(cell.day, calendar: calendar)), before tracking began")
        case .tracked(let day):
            let level = scale.level(for: activity.metric.value(day))
            Button {
                activity.hovered = nil
                model.open(day: day.window, from: .activity)
            } label: {
                Group {
                    if level == 0 {
                        shape.fill(Palette.control)
                    } else {
                        shape.fill(Self.fill(activity.metric.parts(day))).opacity(Self.shades[level - 1])
                    }
                }
                .overlay(shape.strokeBorder(Palette.textPrimary.opacity(hovered ? 0.8 : 0), lineWidth: 1))
                .anchorPreference(key: HoveredTile.self, value: .bounds) { hovered ? $0 : nil }
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { activity.hovered = day.day } else if activity.hovered == day.day { activity.hovered = nil }
            }
            .accessibilityLabel("\(spoken(day.day, calendar: calendar)), \(figures(day))")
            .accessibilityHint("Shows this day across the dashboard")
        }
    }

    /// Each provider's colours from the bottom of a square up, in proportion
    /// to its part of the day: hard stops, so the parts read as bands.
    static func fill(_ parts: [(provider: ProviderKey, share: Double)]) -> LinearGradient {
        var stops: [Gradient.Stop] = []
        var start = 0.0
        for part in parts {
            let color = Palette.accent(part.provider)
            stops.append(.init(color: color, location: start))
            start += part.share
            stops.append(.init(color: color, location: min(start, 1)))
        }
        return LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }

    private var legend: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        let size = Self.cellRange.lowerBound + 2
        let providers = Set(activity.visibleDays.flatMap(\.providers.keys))
        return HStack(spacing: Self.gap) {
            ForEach(ProviderKey.allCases.filter(providers.contains), id: \.self) { provider in
                HStack(spacing: 4) {
                    shape.fill(Palette.accent(provider)).frame(width: size, height: size)
                    Text(provider.displayName)
                }
                .padding(.trailing, 10)
            }
            shape.strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.75)
                .frame(width: size, height: size)
            Text("Not tracked").padding(.trailing, 10)
            Text("Less").padding(.trailing, 2)
            shape.fill(Palette.control).frame(width: size, height: size)
            ForEach(Self.shades, id: \.self) { shade in
                shape.fill(Palette.textSecondary).opacity(shade).frame(width: size, height: size)
            }
            Text("More").padding(.leading, 2)
        }
        .font(.caption)
        .foregroundStyle(Palette.textSecondary)
        .accessibilityHidden(true)
    }

    /// The line under the grid: the busiest day in view. A hovered day has
    /// its own card at the square.
    /// Chosen from days with usage, so a measure every day lacks, such as cost
    /// where nothing is priced, never reads as no usage.
    private func busiest(calendar: LocalCalendar) -> String {
        let metric = activity.metric
        let active = activity.visibleDays.filter(\.isActive)
        guard !active.isEmpty else { return "No usage in this range." }
        guard let busiest = active.max(by: { metric.value($0) < metric.value($1) }), metric.value(busiest) > 0 else {
            return "Usage recorded, but none of it has a known price."
        }
        let date = BucketLabel.date(busiest.window.start, "yMMMd", calendar: calendar)
        let events = metric == .events ? " · \(Format.figure(busiest.totals.events)) events" : ""
        return "Busiest by \(metric.title.lowercased()): \(date) · \(figures(busiest))\(events)"
    }

    /// A day's cost with how much of it is priced: a cost nothing
    /// priced is unknown, not $0.00.
    static func cost(_ totals: UsageTotals) -> String {
        guard let coverage = totals.costCoverage, coverage < 1 else { return Format.cost(totals.cost) }
        if totals.unpricedEvents == totals.events { return "cost unknown" }
        return "\(Format.cost(totals.cost)) (\(Int((coverage * 100).rounded(.down)))% priced)"
    }

    private func figures(_ day: ActivityDay) -> String {
        guard day.isActive else { return "no usage" }
        let sessions = "\(day.sessions) \(day.sessions == 1 ? "session" : "sessions")"
        return "\(Format.tokens(day.totals.tokens.processed)) tokens · \(Self.cost(day.totals)) · \(sessions)"
    }

    private func spoken(_ day: LocalDay, calendar: LocalCalendar) -> String {
        BucketLabel.date(calendar.window(for: day).start, "yMMMMEEEEd", calendar: calendar)
    }

    /// The heatmap in words, for the header and for VoiceOver.
    private func summary(_ grid: HeatmapGrid) -> String {
        let active = grid.tracked.count(where: \.isActive)
        return "\(active) active \(active == 1 ? "day" : "days") \(activity.range.span)"
    }
}

/// The hovered square's bounds, for the card that floats over it.
private struct HoveredTile: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// A day's figures by provider, drawn like the chart's hover card.
private struct HeatmapTooltip: View {
    let day: ActivityDay
    let title: String

    /// Larger than the chart's readout: the squares it explains are small,
    /// so the card carries the reading.
    static let radius: CGFloat = 12

    var body: some View {
        let providers = day.providers.filter { $0.value.events > 0 }
            .sorted { $0.value.tokens.processed > $1.value.tokens.processed }
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout.weight(.semibold))
            if providers.isEmpty {
                Text("No usage").foregroundStyle(Palette.textSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                    ForEach(providers, id: \.key) { provider, totals in
                        GridRow {
                            HStack(spacing: 7) {
                                ProviderLogo(provider: provider, size: 15)
                                Text(provider.displayName).lineLimit(1)
                            }
                            .fixedSize()
                            Text(Format.tokens(totals.tokens.processed)).gridColumnAlignment(.trailing)
                            Text(HeatmapSection.cost(totals)).gridColumnAlignment(.trailing)
                        }
                    }
                    if providers.count > 1 {
                        Divider().gridCellColumns(3)
                        GridRow {
                            Text("Total").foregroundStyle(Palette.textSecondary)
                            Text(Format.tokens(day.totals.tokens.processed)).fontWeight(.semibold)
                            Text(HeatmapSection.cost(day.totals)).fontWeight(.semibold)
                        }
                    }
                }
                .monospacedDigit()
                Text("\(day.sessions) \(day.sessions == 1 ? "session" : "sessions")")
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .font(.callout)
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .transaction { $0.disablesAnimations = true }
        .background(Palette.surface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .fixedSize()
    }
}

// MARK: Comparisons

/// Comparisons under a page's figures, for the range on screen, taking
/// turns. Drawn again only when the range, the tone or the figures' rough
/// size changes.
struct ComparisonFooter: View {
    let model: DashboardModel
    let totals: UsageTotals
    let range: RangePreset

    @AppStorage(ActivityPreferences.showComparisonsKey) private var show = true
    @AppStorage(ActivityPreferences.comparisonToneKey) private var tone = ActivityPreferences.mix
    @State private var lines: [String] = []

    var body: some View {
        // A stack rather than a group: an empty group is no view at all,
        // and its task would never run to draw the first line.
        VStack {
            if show, !lines.isEmpty {
                ComparisonTicker(lines: lines)
            }
        }
        .task(id: "\(range)|\(tone)|\(show)|\(roughly(totals))") {
            lines = ComparisonTicker.lines(model.comparisons, tokens: totals.tokens.processed,
                                           tone: ActivityPreferences.tone(tone), scope: range.scope)
        }
    }
}

extension RangePreset {
    /// How a comparison says this range; a custom one is said by the header.
    var scope: ComparisonScope? {
        switch self {
        case .today: .today
        case .last7Days: .week
        case .last30Days: .month
        case .last90Days: .quarter
        case .yearToDate: .yearToDate
        case .lastYear: .year
        case .all: .allTime
        case .custom: nil
        }
    }
}

extension View {
    /// Selectable, with Copy in its context menu, so a line can be shared.
    func copyable(_ text: String) -> some View {
        textSelection(.enabled).contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}
