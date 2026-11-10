//
//  StreakCard.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import CoreText
import SwiftUI

/// The Streaks card: the current streak in a ring with its flame, Bot-7's
/// story at the streak's tier, the road of tiers, this month and year, and
/// the year's streaks on a timeline, under `StreakRule`. It shows how much
/// of today's hour is done and the freezes held, but never asks the user to
/// keep a streak: a broken one simply starts again.
struct StreakCard: View {
    let streaks: Streaks
    let calendar: LocalCalendar
    let now: Timestamp

    /// The best streak's colour, wherever it is marked.
    static let record = Palette.record
    /// Narrower than this, the ring sits above the story instead of beside it.
    nonisolated private static let sideBySide: CGFloat = 740

    @AppStorage("streaks.celebratedTier") private var celebratedTier = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popAt: Date?
    @State private var wide = true

    var body: some View {
        let progress = StreakProgress(days: streaks.current)
        let lit = streaks.current > 0 && streaks.todayCounts
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Streaks") {
                if let best = streaks.best { bestLine(best) }
            }
            .help(Self.rule)
            Group {
                if wide {
                    HStack(alignment: .center, spacing: 32) {
                        dial(progress, lit: lit)
                        story(progress, lit: lit)
                    }
                } else {
                    VStack(spacing: 16) {
                        dial(progress, lit: lit)
                        story(progress, lit: lit)
                    }
                }
            }
            StreakSeason(streaks: streaks, calendar: calendar, now: now, tierColour: Self.colour(progress))
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.sideBySide } action: { wide = $0 }
        .onAppear { celebrate(progress) }
    }

    /// The rule, as the header's help states it.
    static var rule: String {
        let base = StreakRule.baseQuarterHours * StreakRule.quarterHourMinutes
        let most = StreakRule.maximumQuarterHours * StreakRule.quarterHourMinutes
        return "A day counts once it has \(minutes(base)) of usage across any providers, in any 15-minute stretches. "
            + "Every \(StreakRule.rampDays) days of a streak add 15 minutes, up to \(minutes(most)). "
            + "Each \(StreakRule.freezeEvery) counted days earn a freeze, \(StreakRule.maximumFreezes) at most; a freeze "
            + "covers a day that falls short, without adding to the streak. A streak ends on a short day with no freeze."
    }

    /// "45 min", "1 hr", "1 hr 15 min".
    static func minutes(_ total: Int) -> String {
        let hours = total / 60, rest = total % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// "40 of 60 min today".
    static func todayLine(_ streaks: Streaks) -> String {
        let done = streaks.todayQuarterHours * StreakRule.quarterHourMinutes
        return "\(done) of \(streaks.todayRequired * StreakRule.quarterHourMinutes) min today"
    }

    /// The tier's flame colour, for the ring and everything that follows the tier.
    static func colour(_ progress: StreakProgress) -> Color { Color(rgb: FlameLook.at(progress.tierIndex).colours.body) }

    /// A tier reached since the card was last shown springs the flame and
    /// throws sparks, once. Falling back below a tier lets it celebrate again.
    private func celebrate(_ progress: StreakProgress) {
        let tier = progress.tierIndex ?? -1
        if tier > celebratedTier { popAt = now.date }
        celebratedTier = tier
    }

    private func bestLine(_ best: StreakRun) -> some View {
        let date = { (day: LocalDay) in StreakCard.date(day, from: best, calendar: calendar, now: now) }
        return (Text("Best ").foregroundStyle(Palette.textSecondary)
            + Text(Self.days(best.length)).foregroundStyle(Palette.textPrimary).fontWeight(.semibold)
            + Text(" · \(Self.dates(best, date))").foregroundStyle(Palette.textSecondary))
            .font(.callout.monospacedDigit())
    }

    // MARK: The dial

    private func dial(_ progress: StreakProgress, lit: Bool) -> some View {
        let previousBest = streaks.runs.dropLast().map(\.length).max() ?? 0
        let newBest = streaks.current > previousBest && streaks.runs.count > 1
        let waiting = !streaks.todayCounts
        return ZStack {
            StreakRing(fraction: progress.fraction, progress: progress, best: streaks.longest,
                       colour: lit ? Self.colour(progress) : Palette.separator)
                .animation(Motion.draw, value: progress.fraction)
            FireFlame(look: FlameLook.at(progress.tierIndex), lit: lit, popAt: popAt)
                .frame(width: 180, height: 180)
                .offset(y: -44)
            VStack(spacing: 4) {
                Text("\(streaks.current)")
                    .font(Typography.display(42))
                    .tracking(Typography.tracking(42))
                    .rollingNumber(Double(streaks.current))
                    .animation(Motion.standard(reduced: reduceMotion), value: streaks.current)
                Text("day streak")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
                if waiting || newBest {
                    Text(waiting ? Self.todayLine(streaks) : "New best")
                        .monospacedDigit()
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(waiting ? Palette.textSecondary : Self.record)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background((waiting ? Palette.control : Self.record.opacity(0.2)), in: Capsule())
                }
            }
            .offset(y: 78)
        }
        .frame(width: 280, height: 280)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(progress, streaks: streaks, waiting: waiting))
    }

    static func summary(_ progress: StreakProgress, streaks: Streaks, waiting: Bool) -> String {
        var parts = ["Current streak \(days(streaks.current))"]
        if let tier = progress.tier { parts.append(tier.name) }
        if let next = progress.next, let left = progress.daysToNext { parts.append("\(days(left)) to \(next.name)") }
        if waiting { parts.append(todayLine(streaks)) }
        if streaks.freezes > 0 { parts.append("\(streaks.freezes) \(streaks.freezes == 1 ? "freeze" : "freezes") held") }
        parts.append("best \(days(streaks.longest))")
        return parts.joined(separator: ", ")
    }

    /// A streak's first or last day, with the year when the streak is not
    /// all within this one.
    static func date(_ day: LocalDay, from run: StreakRun, calendar: LocalCalendar, now: Timestamp) -> String {
        let thisYear = calendar.day(containing: now).year
        let template = run.start.year == thisYear && run.end.year == thisYear ? "dMMM" : "dMMMy"
        return BucketLabel.date(calendar.window(for: day).start, template, calendar: calendar)
    }

    /// "25 Aug – 12 Oct", or one date for a streak of one day.
    static func dates(_ run: StreakRun, _ date: (LocalDay) -> String) -> String {
        run.start == run.end ? date(run.start) : "\(date(run.start)) – \(date(run.end))"
    }

    static func days(_ count: Int) -> String { "\(count) \(count == 1 ? "day" : "days")" }

    // MARK: The story, tiers and figures

    private func story(_ progress: StreakProgress, lit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StoryBanner(progress: progress, lit: lit, popAt: popAt)
            TierRoad(progress: progress, best: streaks.longest)
            figures
        }
        .frame(maxWidth: .infinity)
    }

    private var figures: some View {
        let today = calendar.day(containing: now)
        let dayOfYear = calendar.calendar.ordinality(of: .day, in: .year, for: now.date) ?? today.day
        let thisYear = streaks.runs.count { $0.end.year == today.year }
        return HStack(alignment: .top, spacing: 30) {
            figure(BucketLabel.date(now, "MMMM", calendar: calendar), "\(streaks.countedThisMonth) of \(today.day)",
                   share: Double(streaks.countedThisMonth) / Double(today.day))
            figure(String(today.year), "\(streaks.countedThisYear) of \(dayOfYear)",
                   share: Double(streaks.countedThisYear) / Double(dayOfYear))
            VStack(alignment: .leading, spacing: 4) {
                Text("Streaks this year").font(.callout).foregroundStyle(Palette.textSecondary)
                Text("\(thisYear)").font(Typography.figure)
            }
            .accessibilityElement(children: .combine)
            freezes
        }
    }

    /// The freezes the streak holds, shown so a covered day is never a
    /// surprise.
    private var freezes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Freezes").font(.callout).foregroundStyle(Palette.textSecondary)
            HStack(spacing: 6) {
                ForEach(0..<StreakRule.maximumFreezes, id: \.self) { index in
                    Image(systemName: "snowflake")
                        .font(.system(size: 17, weight: .semibold))
                        // An empty slot is dim but legible, so the two a streak
                        // can hold read as places waiting to fill.
                        .foregroundStyle(index < streaks.freezes ? Palette.ice : Palette.inactive)
                }
            }
            .frame(height: 28)
        }
        .help("Each \(StreakRule.freezeEvery) counted days earn a freeze, \(StreakRule.maximumFreezes) at most. A freeze "
              + "covers a day that falls short, without adding to the streak, and goes when the streak ends.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Freezes: \(streaks.freezes) of \(StreakRule.maximumFreezes)")
    }

    private func figure(_ title: String, _ value: String, share: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(Palette.textSecondary)
            (Text(value).font(Typography.figure)
                + Text(" days").font(.callout).foregroundStyle(Palette.textSecondary))
            Capsule().fill(Palette.controlTrack)
                .frame(width: 120, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.textSecondary).frame(width: 120 * min(1, max(0, share)), height: 4)
                }
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value) days counted")
    }
}

/// Silkscreen, the pixel font of the story's labels, registered for this
/// process on first use. The system's monospaced font stands in if it is
/// missing from the build.
enum PixelFont {
    private static let available: Bool = {
        if let url = Bundle.module.url(forResource: "Silkscreen-Regular", withExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: "Silkscreen", size: 12) != nil
    }()

    static func font(_ size: CGFloat) -> Font {
        available ? .custom("Silkscreen", fixedSize: size) : .system(size: size, weight: .bold, design: .monospaced)
    }
}

/// Bot-7's story at the streak's tier, with the chapter, tier and its line
/// over the sky, and the next tier opposite. Drawn fifteen times a second,
/// as pixel art is; still under Reduce Motion, while the window is inactive,
/// and in rendered frames.
private struct StoryBanner: View {
    let progress: StreakProgress
    let lit: Bool
    let popAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrames) private var stillFrames
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Group {
            if reduceMotion || stillFrames {
                scene(t: 0.4, popAge: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 15, paused: activeState == .inactive)) { context in
                    scene(t: context.date.timeIntervalSinceReferenceDate, popAge: popAt.map { context.date.timeIntervalSince($0) })
                }
            }
        }
        .aspectRatio(Double(PixelBuffer.width) / Double(PixelBuffer.height), contentMode: .fit)
        .overlay {
            LinearGradient(stops: [.init(color: .black.opacity(0.38), location: 0), .init(color: .clear, location: 0.46)],
                           startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .top) { heading }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.06), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func scene(t: Double, popAge: Double?) -> some View {
        let frame = StoryPainter(tierIndex: progress.tierIndex, lit: lit).frame(t: t, popAge: popAge)
        return Group {
            if let image = frame.image() {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
            } else {
                Color.black
            }
        }
    }

    private var heading: some View {
        let chapter = StoryChapter.of(tierIndex: progress.tierIndex)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Chapter \(chapter.rawValue + 1) · \(chapter.title)").font(PixelFont.font(9)).opacity(0.72)
                Text(progress.tier?.name ?? "Unlit").font(PixelFont.font(18))
                Text(progress.tier?.line ?? "One day of usage lights it.").font(PixelFont.font(9)).opacity(0.85)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let next = progress.next, let left = progress.daysToNext {
                    Text("\(StreakCard.days(left)) to").font(PixelFont.font(9)).opacity(0.72)
                    Text(next.name).font(PixelFont.font(11))
                } else if let lap = progress.lap {
                    Text("Lap \(lap)").font(PixelFont.font(9)).opacity(0.72)
                    Text("Past the end").font(PixelFont.font(11))
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 0, y: 2)
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var accessibilityText: String {
        let chapter = StoryChapter.of(tierIndex: progress.tierIndex)
        return "Chapter \(chapter.rawValue + 1), \(chapter.title): " + (progress.tier.map { "\($0.name). \($0.line)" }
            ?? "Unlit. One day of usage lights it.")
    }
}

/// The fourteen tiers as stops on one road, lit in each tier's flame
/// colour up to the streak and on toward the next stop by the share of the
/// way it has come. The current stop holds the flame; stops behind it are
/// filled, stops only the best streak reached are ringed, and the rest wait
/// in grey. Hovering a stop names it, in a card like the timeline's.
private struct TierRoad: View {
    let progress: StreakProgress
    let best: Int

    @State private var hovered: Int?
    @State private var cardSize: CGSize = .zero
    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrames) private var stillFrames

    /// The road's line from the top, and room at each end for the end
    /// stops and their labels.
    private static let road: CGFloat = 24, edge: CGFloat = 17, height: CGFloat = 57

    private enum Stop { case passed, current, bestOnly, ahead }

    private func stop(_ index: Int) -> Stop {
        let days = StreakTier.all[index].days
        if index == progress.tierIndex { return .current }
        if progress.days >= days { return .passed }
        return best >= days ? .bestOnly : .ahead
    }

    var body: some View {
        let count = StreakTier.all.count
        let colours = FlameLook.tiers.map { Color(rgb: $0.colours.body) }
        GeometryReader { geometry in
            let width = geometry.size.width
            let step = (width - 2 * Self.edge) / CGFloat(count - 1)
            let x = { (index: Int) in Self.edge + CGFloat(index) * step }
            let reach: CGFloat = progress.tierIndex.map { index in
                index == count - 1 ? x(index) : x(index) + step * CGFloat(progress.fraction)
            } ?? 0
            let shown = risen || stillFrames
            ZStack(alignment: .topLeading) {
                Capsule().fill(Palette.controlTrack)
                    .frame(width: x(count - 1) - x(0), height: 3)
                    .offset(x: x(0), y: Self.road - 1.5)
                // The gradient spans the whole road, so each stretch takes
                // its own tier's colour; only the lit length shows.
                LinearGradient(stops: colours.indices.map { .init(color: colours[$0], location: x($0) / width) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: width, height: 3)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: shown ? max(0, reach) : 0)
                    }
                    .animation(reduceMotion ? nil : Motion.draw, value: shown)
                    .offset(y: Self.road - 1.5)
                ForEach(0..<count, id: \.self) { index in
                    mark(index, colour: colours[index])
                        .scaleEffect(shown || reduceMotion ? 1 : 0.3)
                        .opacity(shown ? 1 : 0)
                        .animation(Motion.reveal(index, reduced: reduceMotion), value: shown)
                        .position(x: x(index), y: Self.road)
                    label(index)
                        .position(x: x(index), y: Self.road + 24)
                }
            }
            .frame(width: width, height: Self.height, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if let hovered {
                    StreakHoverCard { card(hovered) }
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .offset(x: min(max(x(hovered) - cardSize.width / 2, 0), max(width - cardSize.width, 0)),
                                y: Self.road - 20 - cardSize.height)
                        .animation(Motion.standard(reduced: reduceMotion), value: hovered)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.standard(reduced: reduceMotion), value: hovered == nil)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let index = Int(((point.x - Self.edge) / step).rounded())
                    let near = (0..<count).contains(index) && abs(x(index) - point.x) <= max(12, step / 2)
                    if (near ? index : nil) != hovered { hovered = near ? index : nil }
                case .ended:
                    hovered = nil
                }
            }
        }
        .frame(height: Self.height)
        .zIndex(1)
        .onAppear { risen = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    @ViewBuilder private func mark(_ index: Int, colour: Color) -> some View {
        let major = StreakTier.all[index].isMajor
        switch stop(index) {
        case .current:
            // Every tier's fire the same size here, its tip rising out of the
            // stop: the dial is where it grows. Laid over the stop so its frame
            // never sizes it.
            Circle().fill(colour.opacity(0.18))
                .overlay(Circle().strokeBorder(colour, lineWidth: 1.5))
                .frame(width: 34, height: 34)
                .background(Palette.surface, in: Circle())
                .overlay {
                    FireIcon(look: FlameLook.tiers[index])
                        .frame(width: 32, height: 32)
                        .offset(y: -5)
                }
        case .passed:
            Circle().fill(colour).frame(width: major ? 11 : 9, height: major ? 11 : 9)
        case .bestOnly:
            Circle().strokeBorder(colour.opacity(0.8), lineWidth: 1.5)
                .background(Palette.surface, in: Circle())
                .frame(width: major ? 11 : 9, height: major ? 11 : 9)
        case .ahead:
            Circle().strokeBorder(Palette.separator, lineWidth: major ? 1.5 : 1)
                .background(Palette.surface, in: Circle())
                .frame(width: major ? 11 : 8, height: major ? 11 : 8)
        }
    }

    private func label(_ index: Int) -> some View {
        let tier = StreakTier.all[index], state = stop(index)
        return Text(tier.isMajor ? "★\(tier.days)" : "\(tier.days)")
            .font(.caption2.monospacedDigit().weight(state == .current ? .semibold : .regular))
            .foregroundStyle(state == .current ? Palette.textPrimary
                             : state == .ahead ? Palette.textSecondary.opacity(0.6) : Palette.textSecondary)
            .fixedSize()
    }

    private func card(_ index: Int) -> some View {
        let tier = StreakTier.all[index]
        let status: String = switch stop(index) {
        case .current: progress.next.map { "Now · \(StreakCard.days(progress.daysToNext ?? 0)) to \($0.name)" } ?? "Now"
        case .passed: "Passed"
        case .bestOnly: "Reached by your best streak"
        case .ahead: "\(StreakCard.days(tier.days - progress.days)) to go"
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                FireIcon(look: FlameLook.tiers[index]).frame(width: 26, height: 26)
                Text(tier.name).fontWeight(.semibold)
            }
            Text(StreakCard.days(tier.days))
            Text(status).foregroundStyle(Palette.textSecondary)
        }
    }

    private var spoken: String {
        let reached = (0..<StreakTier.all.count).count { stop($0) != .ahead }
        var parts = ["Tiers: \(reached) of \(StreakTier.all.count) reached"]
        if let tier = progress.tier { parts.append("current \(tier.name)") }
        if let next = progress.next { parts.append("next \(next.name) at \(StreakCard.days(next.days))") }
        return parts.joined(separator: ", ")
    }
}

/// The hover card the tier road and the timeline share, drawn like the
/// heatmap's.
private struct StreakHoverCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .font(.callout.monospacedDigit())
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

/// This year as a skyline: each streak a bar standing on the days it ran,
/// as tall as it was long, so the long ones rise over the year at a glance.
/// The current streak is in the tier's colour with today's dot on its top;
/// the best is in the record colour with a star. Lengths sit over the bars
/// they fit over, the current and the best first. Bars rise in with the
/// page, and hovering one brings up its card.
private struct StreakSeason: View {
    let streaks: Streaks
    let calendar: LocalCalendar
    let now: Timestamp
    let tierColour: Color

    @State private var hovered: Int?
    @State private var cardSize: CGSize = .zero
    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrames) private var stillFrames

    /// Room over the tallest bar for its length, the tallest bar, and the
    /// months under the ground.
    private static let labels: CGFloat = 18, skyline: CGFloat = 56, months: CGFloat = 22
    private static let ground = labels + skyline, height = ground + months
    /// The shortest a bar is drawn, so a day's streak still shows.
    private static let stub: CGFloat = 3

    private struct Segment {
        let index: Int
        let run: StreakRun
        let frame: CGRect
    }

    private struct Tag {
        let index: Int
        let text: String
        let x: CGFloat
        let y: CGFloat
    }

    var body: some View {
        let today = calendar.day(containing: now)
        let year = today.year
        let first = LocalDay(year: year, month: 1, day: 1)
        let length = CGFloat(dayIndex(LocalDay(year: year, month: 12, day: 31), year: year) + 1)
        let runs = streaks.runs.enumerated().filter { $0.element.end >= first }
        let live = streaks.current > 0 ? streaks.runs.indices.last : nil
        let bestIndex = streaks.best.flatMap { best in streaks.runs.lastIndex(of: best) }
        let tallest = CGFloat(max(1, runs.map(\.element.length).max() ?? 1))
        GeometryReader { geometry in
            let width = geometry.size.width, perDay = width / length
            let x = { (day: LocalDay) in CGFloat(dayIndex(max(day, first), year: year)) * perDay }
            let segments = runs.map { index, run in
                let left = x(run.start)
                let tall = max(Self.stub, Self.skyline * CGFloat(run.length) / tallest)
                return Segment(index: index, run: run,
                               frame: CGRect(x: left, y: Self.ground - tall,
                                             width: max(3, x(run.end) + perDay - left - 1), height: tall))
            }
            let shown = risen || stillFrames
            let todayX = x(today) + perDay / 2
            let liveTop = segments.first { $0.index == live }?.frame.minY ?? Self.ground
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    // The ground: solid through today, faint for the months to come.
                    var past = Path(), future = Path()
                    past.move(to: CGPoint(x: 0, y: Self.ground))
                    past.addLine(to: CGPoint(x: x(today) + perDay, y: Self.ground))
                    future.move(to: CGPoint(x: x(today) + perDay, y: Self.ground))
                    future.addLine(to: CGPoint(x: width, y: Self.ground))
                    context.stroke(past, with: .color(Palette.textSecondary.opacity(0.5)), lineWidth: 1)
                    context.stroke(future, with: .color(Palette.separator),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    for month in 1...12 {
                        let day = LocalDay(year: year, month: month, day: 1), at = x(day)
                        var tick = Path()
                        tick.move(to: CGPoint(x: at, y: Self.ground))
                        tick.addLine(to: CGPoint(x: at, y: Self.ground + 4))
                        context.stroke(tick, with: .color(Palette.separator), lineWidth: 1)
                        let label = BucketLabel.date(calendar.window(for: day).start, "MMM", calendar: calendar)
                        let style = month == today.month ? Palette.textPrimary : Palette.textSecondary.opacity(0.7)
                        context.draw(Text(label).font(.caption).foregroundStyle(style),
                                     at: CGPoint(x: at + 3, y: Self.ground + 13), anchor: .leading)
                    }
                }
                ForEach(Array(segments.enumerated()), id: \.element.index) { order, segment in
                    UnevenRoundedRectangle(topLeadingRadius: min(3, segment.frame.width / 2),
                                           topTrailingRadius: min(3, segment.frame.width / 2), style: .continuous)
                        // Full at the top, fading to the ground, so a long streak, wide
                        // and tall, reads as a rise rather than a slab.
                        .fill(LinearGradient(colors: [fill(segment.index, live: live, best: bestIndex),
                                                      fill(segment.index, live: live, best: bestIndex).opacity(0.35)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: segment.frame.width, height: segment.frame.height)
                        // A day a freeze covered: a sliver of ice at the bar's foot.
                        .overlay(alignment: .bottomLeading) {
                            ZStack(alignment: .bottomLeading) {
                                ForEach(segment.run.frozen, id: \.self) { day in
                                    Rectangle().fill(Palette.ice)
                                        .frame(width: max(2, perDay - 1), height: min(3, segment.frame.height))
                                        .offset(x: x(day) - segment.frame.minX)
                                }
                            }
                        }
                        .scaleEffect(x: 1, y: shown ? 1 : 0.001, anchor: .bottom)
                        .animation(Motion.reveal(order, reduced: reduceMotion), value: shown)
                        .offset(x: segment.frame.minX, y: segment.frame.minY)
                }
                .animation(Motion.standard(reduced: reduceMotion), value: hovered)
                // Today: on top of the current streak, or on the ground when
                // today has not joined one yet.
                Circle()
                    .fill(live != nil && streaks.todayCounts ? tierColour : Palette.surface)
                    .overlay(Circle().strokeBorder(live != nil ? tierColour : Palette.textSecondary, lineWidth: 2))
                    .frame(width: 10, height: 10)
                    .position(x: todayX, y: liveTop)
                    .opacity(shown ? 1 : 0)
                    .animation(Motion.standard(reduced: reduceMotion)?.delay(0.3), value: shown)
                ForEach(tags(segments, live: live, best: bestIndex, width: width), id: \.index) { tag in
                    Text(tag.text)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(tag.index == live ? tierColour
                                         : tag.index == bestIndex ? StreakCard.record : Palette.textSecondary)
                        .fixedSize()
                        .position(x: tag.x, y: tag.y)
                        .opacity(shown ? 1 : 0)
                        .animation(Motion.standard(reduced: reduceMotion), value: shown)
                }
            }
            .frame(width: width, height: Self.height, alignment: .topLeading)
            // Over the skyline, not part of its layout, so showing it never
            // moves what the pointer is on.
            .overlay(alignment: .topLeading) {
                if let hovered, let segment = segments.first(where: { $0.index == hovered }) {
                    StreakHoverCard { card(segment.run) }
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .offset(x: min(max(segment.frame.midX - cardSize.width / 2, 0), max(width - cardSize.width, 0)),
                                y: segment.frame.minY - Self.labels - 6 - cardSize.height)
                        .animation(Motion.standard(reduced: reduceMotion), value: hovered)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.standard(reduced: reduceMotion), value: hovered == nil)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    // A bar's whole column counts, so a short one is as easy to find as a tall one.
                    let within = segments.first {
                        $0.frame.minX - 3 <= point.x && point.x <= $0.frame.maxX + 3 && point.y <= Self.ground + 4
                    }
                    let nearest = within ?? segments.min {
                        abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x)
                    }.flatMap { abs($0.frame.midX - point.x) <= 8 ? $0 : nil }
                    if nearest?.index != hovered { hovered = nearest?.index }
                case .ended:
                    hovered = nil
                }
            }
        }
        .frame(height: Self.height)
        .zIndex(1)
        .onAppear { risen = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Streaks in \(year): \(runs.count), the longest \(StreakCard.days(runs.map(\.element.length).max() ?? 0))")
    }

    private func fill(_ index: Int, live: Int?, best: Int?) -> Color {
        if index == live { return tierColour }
        if index == best { return StreakCard.record }
        return index == hovered ? Palette.textPrimary.opacity(0.75) : Palette.textSecondary.opacity(0.45)
    }

    /// Lengths over the bars they fit over: the current and the best first,
    /// then the longest, each placed only where it clears those already
    /// placed.
    private func tags(_ segments: [Segment], live: Int?, best: Int?, width: CGFloat) -> [Tag] {
        let rank = { (segment: Segment) in segment.index == live ? 0 : segment.index == best ? 1 : 2 }
        let ordered = segments.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.run.length > $1.run.length }
        var placed: [(tag: Tag, span: ClosedRange<CGFloat>)] = []
        for segment in ordered where segment.run.length > 1 {
            let text = segment.index == best && segment.index != live ? "★ \(segment.run.length)" : "\(segment.run.length)"
            // Roughly the caption's width; the gap between tags absorbs the rest.
            let half = CGFloat(text.count) * 3.6 + 2
            // A tag wider than an ordinary streak would sit over its neighbours.
            guard rank(segment) < 2 || segment.frame.width >= half * 2 else { continue }
            let centre = min(max(segment.frame.midX, half), width - half)
            let span = (centre - half - 4)...(centre + half + 4)
            guard !placed.contains(where: { $0.span.overlaps(span) }) else { continue }
            placed.append((Tag(index: segment.index, text: text, x: centre, y: segment.frame.minY - Self.labels / 2 - (segment.index == live ? 6 : 0)), span))
        }
        return placed.map(\.tag)
    }

    private func card(_ run: StreakRun) -> some View {
        let progress = StreakProgress(days: run.length)
        let date = { (day: LocalDay) in StreakCard.date(day, from: run, calendar: calendar, now: now) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(StreakCard.days(run.length)).fontWeight(.semibold)
            if let tier = progress.tier {
                HStack(spacing: 7) {
                    FireIcon(look: FlameLook.at(progress.tierIndex)).frame(width: 26, height: 26)
                    Text(tier.name)
                }
            }
            Text(StreakCard.dates(run, date)).foregroundStyle(Palette.textSecondary)
            if !run.frozen.isEmpty {
                Label(run.frozen.count == 1 ? "1 day frozen" : "\(run.frozen.count) days frozen", systemImage: "snowflake")
                    .foregroundStyle(Palette.ice)
            }
        }
    }

    /// Days after 1 January of `year`, counted on the calendar.
    private func dayIndex(_ day: LocalDay, year: Int) -> Int {
        let start = calendar.window(for: LocalDay(year: year, month: 1, day: 1)).start.date
        let date = calendar.window(for: day).start.date
        return calendar.calendar.dateComponents([.day], from: start, to: date).day ?? 0
    }
}
