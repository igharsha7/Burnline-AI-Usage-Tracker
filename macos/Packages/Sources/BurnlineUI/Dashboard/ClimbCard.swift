//
//  ClimbCard.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import Charts
import SwiftUI

/// Everything ever processed, printed and stacked, climbing past landmarks:
/// a figure that can be said several ways, and the climb seen through a
/// camera that frames the last landmark passed and the next one up. The
/// Activity page's all-time card.
struct ClimbCard: View {
    let climb: Climb
    let engine: ComparisonEngine?
    let calendar: LocalCalendar
    let lifetimeTokens: Int64

    /// How many times the figure has been said another way; never wraps,
    /// so the digits always roll up.
    @State private var turns = 0
    @AppStorage(ActivityPreferences.showComparisonsKey) private var showComparisons = true
    @AppStorage(ActivityPreferences.comparisonToneKey) private var tone = ActivityPreferences.mix

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ClimbScene(climb: climb, calendar: calendar)
                .frame(height: 280)
        }
    }

    // MARK: Header

    private var header: some View {
        let ways = ReelFigure.all(tokens: lifetimeTokens, meters: climb.meters, engine: showComparisons ? engine : nil,
                                  tone: ActivityPreferences.tone(tone))
        let way = ways[turns % max(1, ways.count)]
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                // The button sits by the caption, where it never moves
                // however long the figure's wording.
                HStack(spacing: 6) {
                    Text("All time, printed and stacked")
                        .font(.callout).foregroundStyle(Palette.textSecondary)
                    if ways.count > 1 {
                        Button {
                            withAnimation(.snappy) { turns += 1 }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Say it another way")
                        .accessibilityLabel("Say it another way")
                    }
                }
                // The digits roll to the new figure, and the unit rises in
                // as the old one fades where it stood.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(way.figure)
                        .font(Typography.display(32))
                        .foregroundStyle(Palette.textPrimary)
                        .rollingNumber(Double(turns))
                    Text(way.unit)
                        .font(.title3)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .id(way.unit)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .opacity))
                }
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                // Its line, fading over as the figure changes; the room for
                // it is kept, so the card does not jump when one has none.
                Text(way.quip ?? " ")
                    .font(.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(turns)
                    .transition(.opacity)
                    .accessibilityHidden(way.quip == nil)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            nextLandmark.frame(width: 260, alignment: .trailing)
        }
    }

    @ViewBuilder private var nextLandmark: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let next = climb.next {
                Text("Next: \(next.name)").font(.callout.weight(.semibold))
                ProgressView(value: climb.towardNext).tint(Palette.textPrimary)
                Text("\(AchievementBadge.meters(next.meters - climb.meters)) to go")
                    .font(.callout).monospacedDigit().foregroundStyle(Palette.textSecondary)
                if let pace = paceLine {
                    Text(pace).font(.caption).foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                Text("Above every landmark").font(.callout.weight(.semibold))
                Text("Past the Space Station, and still climbing.")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// How far ahead an arrival date is worth naming; past it, a date
    /// years away only discourages, so the line says the recent climb.
    private static let arrivalHorizon: TimeInterval = 183 * 86_400

    /// When the next landmark comes at this pace, if soon, or else how far
    /// the stack climbed lately.
    private var paceLine: String? {
        guard let recent = climb.climbed(), let last = climb.points.last else { return nil }
        if let arrival = climb.arrival(pace: recent.meters / recent.days),
           TimeInterval(arrival.epochSeconds - last.at.epochSeconds) <= Self.arrivalHorizon {
            return "At this pace, around \(BucketLabel.date(arrival, "MMMy", calendar: calendar))"
        }
        // The span runs from one day's start to the last's, so it covers a day more.
        let days = Int(recent.days.rounded()) + 1
        return "+\(AchievementBadge.meters(recent.meters)) in the last \(days >= 28 ? "month" : "\(days) days")"
    }
}

/// One way of saying the stack: a figure, what it counts, and a line that
/// goes with it.
struct ReelFigure: Equatable {
    let figure: String
    let unit: String
    var quip: String?

    /// The fewest and most of a thing worth saying: under one is not a
    /// count, and past this a number stops meaning anything.
    static let countable = 1.0...100_000.0

    /// The stack's height, the time it would take to read aloud, then
    /// everything the corpus can count it in, from Bee Movie scripts to
    /// Linux kernels, taking categories in turn so one press never lands on
    /// a second book. Each comes with one of its lines in `tone`; mixed
    /// tones alternate roast and nerd.
    static func all(tokens: Int64, meters: Double, engine: ComparisonEngine?,
                    tone: ComparisonTone? = nil) -> [ReelFigure] {
        var ways = [ReelFigure(figure: AchievementBadge.meters(meters), unit: "of printed paper")]
        guard let engine, tokens > 0 else { return ways }
        let value = Double(tokens)
        let seconds = engine.derived.readAloudDuration(tokens: value)
        let years = seconds / (365.25 * 86_400)
        ways.append(years >= 1
            ? ReelFigure(figure: amount(years), unit: years < 2 ? "year of reading aloud" : "years of reading aloud")
            : ReelFigure(figure: amount(seconds / 86_400), unit: "days of reading aloud"))
        let counted = engine.countableTokenUnits.compactMap { unit -> (ComparisonUnit, Double)? in
            guard let each = unit.tokenValue, countable.contains(value / each) else { return nil }
            return (unit, value / each)
        }
        for (index, (unit, count)) in interleaved(counted, by: { $0.0.category }).enumerated() {
            let voice = tone ?? (index.isMultiple(of: 2) ? .roast : .nerd)
            let lines = unit.lines[voice] ?? unit.lines.values.first ?? []
            ways.append(ReelFigure(figure: amount(count), unit: unit.many ?? unit.label,
                                   quip: lines.isEmpty ? nil : lines[index % lines.count]))
        }
        return ways
    }

    /// `items` taking their groups in turn, each group in its own order.
    static func interleaved<T>(_ items: [T], by group: (T) -> String) -> [T] {
        var groups: [[T]] = []
        var slot: [String: Int] = [:]
        for item in items {
            let key = group(item)
            if let at = slot[key] { groups[at].append(item) } else { slot[key] = groups.count; groups.append([item]) }
        }
        let rounds = groups.map(\.count).max() ?? 0
        return (0..<rounds).flatMap { round in groups.compactMap { round < $0.count ? $0[round] : nil } }
    }

    /// One decimal below ten, whole and grouped above.
    static func amount(_ value: Double) -> String {
        value < 10 ? value.formatted(.number.precision(.fractionLength(1)))
                   : Int(value.rounded()).formatted()
    }
}

// MARK: - Scene

/// The climb as one wide world: time runs right, height runs up, and every
/// landmark stands in it at its true height, the ones passed where the
/// stack passed them. The card is a camera that follows the stack: it
/// frames the ground up to about twice the stack's height, on a linear
/// scale so sizes are honest, so the view widens smoothly as the stack
/// climbs and never jumps when a landmark is passed. The next landmark
/// stands at the right; one taller than the frame rises out of the top,
/// its summit marked at the edge, and comes whole into view as the stack
/// nears it. Landmarks beyond the next stay out of frame. On appearing, the
/// camera rises into place.
///
/// Replay runs the climb again from its first day: the camera follows the
/// stack as it stood each day, every landmark is reached where it was, and
/// the stack's label carries the date.
private struct ClimbScene: View {
    let climb: Climb
    let calendar: LocalCalendar

    @State private var pulledBack = false
    /// The replay under way, if one is.
    @State private var clock: ReplayClock?
    @State private var speed = ClimbScene.speeds[0]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let speeds = [1.0, 1.5, 2.0]
    /// A replay's length at 1×: a couple of seconds for each landmark
    /// passed, within bounds.
    private static let secondsPerLandmark = 2.2
    private static let replayLength = 8.0...30.0
    /// Slow out of the first day and into today.
    private static let pace = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.4, y: 0),
                                               endControlPoint: UnitPoint(x: 0.6, y: 1))

    var body: some View {
        // The timeline only ticks; the replay keeps its own, monotonic, time.
        TimelineView(.animation(paused: clock == nil)) { _ in
            ClimbCanvas(climb: climb, calendar: calendar, reveal: pulledBack || reduceMotion ? 1 : 0,
                        playhead: clock.map { Self.pace.value(at: $0.progress(at: .now)) } ?? 1)
        }
        .onAppear {
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 1.6).delay(0.15)) { pulledBack = true }
        }
        .task(id: clock) {
            guard let clock else { return }
            try? await Task.sleep(for: .seconds(clock.remaining))
            if !Task.isCancelled { self.clock = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The climb")
        .accessibilityValue(accessibilityValue)
        // In the band under the ground, left of the first date.
        .overlay(alignment: .bottomLeading) {
            if !reduceMotion, climb.points.count > 1 { controls }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                if clock == nil { replay() } else { skip() }
            } label: {
                Label(clock == nil ? "Replay" : "Skip", systemImage: clock == nil ? "play.fill" : "forward.end.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(clock == nil ? "Replay the climb from the first day" : "Skip to today")
            Button(action: nextSpeed) {
                Text("\(speed.formatted(.number.precision(.fractionLength(0...1))))×")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: speed))
            }
            .help("Replay speed")
            .accessibilityLabel("Replay speed")
            .accessibilityValue("\(speed.formatted()) times")
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(ReplayControlStyle())
        .foregroundStyle(Palette.textSecondary)
    }

    private func replay() {
        let seconds = min(max(Double(climb.passed.count) * Self.secondsPerLandmark, Self.replayLength.lowerBound),
                          Self.replayLength.upperBound)
        // A cut to the first day, unanimated, and the clock runs from there.
        clock = ReplayClock(from: 0, since: ContinuousClock.now, speed: speed, seconds: seconds)
    }

    /// The canvas animates from where the replay stood to today.
    private func skip() {
        withAnimation(.snappy(duration: 0.6)) { clock = nil }
    }

    private func nextSpeed() {
        let index = Self.speeds.firstIndex(of: speed) ?? 0
        withAnimation(.snappy) { speed = Self.speeds[(index + 1) % Self.speeds.count] }
        // A replay under way carries on from where it stands, at the new speed.
        if let running = clock {
            let now = ContinuousClock.now
            clock = ReplayClock(from: running.progress(at: now), since: now, speed: speed, seconds: running.seconds)
        }
    }

    private var accessibilityValue: String {
        var parts = ["\(AchievementBadge.meters(climb.meters)) of printed paper"]
        if let last = climb.lastPassed { parts.append("past \(last.name)") }
        if let next = climb.next { parts.append("next \(next.name) at \(AchievementBadge.meters(next.meters))") }
        return parts.joined(separator: ", ")
    }
}

/// A small control under the climb, with room around it to hit.
private struct ReplayControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(minWidth: 28, minHeight: 22)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A replay under way: how far it had come, 0 to 1 in time, when it was
/// last set going, and how fast it has run since.
private struct ReplayClock: Equatable {
    let from: Double
    let since: ContinuousClock.Instant
    let speed: Double
    /// Its length at 1×.
    let seconds: Double

    func progress(at instant: ContinuousClock.Instant) -> Double {
        let elapsed = since.duration(to: instant)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return min(1, from + seconds * speed / self.seconds)
    }

    var remaining: TimeInterval { (1 - from) * seconds / speed }
}

/// Draws the scene with the camera `reveal` of the way through its rise,
/// and the climb as it stood `playhead` of the way from its first day to
/// today.
private struct ClimbCanvas: View, Animatable {
    let climb: Climb
    let calendar: LocalCalendar
    var reveal: Double
    var playhead: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(reveal, playhead) }
        set { (reveal, playhead) = (newValue.first, newValue.second) }
    }

    /// Where "now" sits across the frame; the next landmark takes the rest.
    private static let nowAt = 0.6
    /// The shortest stretch of time the camera frames, in days.
    private static let minimumDays = 45.0
    /// How high the camera frames, as a multiple of the stack's height.
    private static let reach = 1.8
    /// The lowest the camera frames: the first landmark, whole, with room
    /// above for its name.
    private static let floorTop = Landmark.all[0].meters * 1.16
    /// Where the camera's rise starts, as a share of where it settles.
    private static let riseFrom = 0.6
    /// The band under the ground for the dates.
    private static let axisHeight: CGFloat = 22
    /// The fewest points apart, on screen, the climb's curve passes through.
    private static let curveSpacing: CGFloat = 14
    /// The least room between two landmarks standing side by side.
    private static let landmarkGap: CGFloat = 10
    /// How tall something that flies is drawn, wherever it flies.
    private static let flyingHeight: CGFloat = 46
    /// How much of the whole history a replay frames behind the stack.
    private static let replayShare = 0.25
    /// Where in a replay the camera starts to settle into the still view.
    private static let settleFrom = 0.85
    /// How far toward a new next landmark it takes, in a replay, to fade in.
    private static let arrivalFade = 0.08

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
    }

    // MARK: Camera

    private struct Camera {
        let start: Double, end: Double, top: Double
        let plot: CGRect

        /// How much time it frames behind the stack.
        var back: Double { (end - start) * ClimbCanvas.nowAt }
        func x(_ seconds: Double) -> CGFloat { plot.minX + plot.width * CGFloat((seconds - start) / (end - start)) }
        func y(_ meters: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(meters / top) }
    }

    /// The camera on `climb`. Still, it frames back to the last landmark
    /// passed; a replay gives it `back`, which changes only smoothly.
    private func camera(_ climb: Climb, size: CGSize, back fixed: Double? = nil) -> Camera? {
        guard let first = climb.points.first, let last = climb.points.last else { return nil }
        let now = Double(last.at.epochSeconds)
        let passedAt = climb.lastPassed.flatMap { climb.passed[$0.id] }.map { Double($0.epochSeconds) }
        // Back far enough to show the last landmark passed with room before it.
        var back = fixed ?? max(Self.minimumDays * 86_400, passedAt.map { (now - $0) * 1.35 } ?? 0)
        if fixed == nil { back = min(back, max(now - Double(first.at.epochSeconds), Self.minimumDays * 86_400)) }
        let target = max(climb.meters * Self.reach, Self.floorTop)
        // The camera opens a little low and rises into place.
        let eased = max(0, min(1, reveal))
        let top = target * (Self.riseFrom + (1 - Self.riseFrom) * eased)
        let plot = CGRect(x: 0, y: 0, width: size.width, height: size.height - Self.axisHeight)
        // Narrow the window if need be so the last landmark passed stands
        // whole before the stack, not across it.
        if fixed == nil, let landmark = climb.lastPassed, let passedAt {
            let height = landmark.silhouette.flies ? Self.flyingHeight : plot.height * CGFloat(landmark.meters / top)
            let width = height * LandmarkArt.aspect(landmark.silhouette)
            let right = width * (landmark.silhouette.flies ? 0.5 : 1 - LandmarkArt.peak(landmark.silhouette)) + Self.landmarkGap
            let fits = (now - passedAt) * Double(plot.width) * Self.nowAt / Double(max(right, 1))
            back = min(back, max(fits, 86_400))
        }
        // Never before the first day: early in a replay, the stack walks
        // in from the left edge to its place.
        let start = max(now - back, Double(first.at.epochSeconds))
        let end = start + back / Self.nowAt
        return Camera(start: start, end: end, top: max(top, 1), plot: plot)
    }

    /// One frame: the climb as it stood, and the camera on it.
    private struct Moment {
        let climb: Climb
        let camera: Camera
        let replaying: Bool
        /// How far the replay's camera has settled into the still view, 0 to 1.
        let settle: Double
    }

    private func moment(_ size: CGSize) -> Moment? {
        guard let still = camera(climb, size: size) else { return nil }
        guard playhead < 1, let first = climb.points.first, let last = climb.points.last else {
            return Moment(climb: climb, camera: still, replaying: false, settle: 1)
        }
        let start = Double(first.at.epochSeconds), end = Double(last.at.epochSeconds)
        let at = start + (end - start) * max(0, playhead)
        let shown = climb.asOf(Timestamp(epochSeconds: Int64(at)))
        // A steady window while replaying, eased into the still one at the end.
        let toward = max(0, min(1, (playhead - Self.settleFrom) / (1 - Self.settleFrom)))
        let settle = toward * toward * (3 - 2 * toward)
        let replayBack = max(Self.minimumDays * 86_400, (end - start) * Self.replayShare)
        guard let camera = camera(shown, size: size, back: replayBack + (still.back - replayBack) * settle)
        else { return nil }
        return Moment(climb: shown, camera: camera, replaying: true, settle: settle)
    }

    /// Where the next landmark stands: at the right, its day not yet come;
    /// in a replay, where the stack will reach it, if it has since.
    private func upcomingFrame(_ next: Landmark, in moment: Moment) -> CGRect {
        if moment.replaying, let at = climb.passed[next.id] { return passedFrame(next, at: at, camera: moment.camera) }
        return nextFrame(next, camera: moment.camera)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard let moment = moment(size) else { return }
        let climb = moment.climb, camera = moment.camera
        let plot = camera.plot
        // In a replay, a new next landmark fades in as the stack leaves the last.
        let appear = moment.replaying && climb.lastPassed != nil
            ? max(moment.settle, min(1, climb.towardNext / Self.arrivalFade)) : 1
        var scene = context
        scene.clip(to: Path(plot))

        // The summit line of the next landmark: the height to reach.
        if let next = climb.next {
            let y = camera.y(next.meters)
            var dash = Path()
            dash.move(to: CGPoint(x: plot.minX, y: y))
            dash.addLine(to: CGPoint(x: plot.maxX, y: y))
            scene.stroke(dash, with: .color(Palette.textSecondary.opacity(0.35 * appear)),
                         style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
        }

        // Landmarks already passed, each with its summit where the stack
        // passed it. Newest first: an older one that would crowd a newer
        // one is left out, as if it had passed behind.
        let today = climb.points.last.map { camera.x(Double($0.at.epochSeconds)) } ?? plot.minX + plot.width * CGFloat(Self.nowAt)
        var room = today - Self.landmarkGap
        for landmark in Landmark.all.reversed() {
            guard let at = climb.passed[landmark.id] else { continue }
            let frame = passedFrame(landmark, at: at, camera: camera)
            // A point's grace, so the newest, framed to fit exactly, always
            // does. In a replay the newest stands where it was reached,
            // under the stack as it passes, and drifts back from there.
            let newest = landmark == climb.lastPassed
            guard frame.maxX <= room + 1 || (moment.replaying && newest) else { continue }
            guard frame.maxX > plot.minX else { break }
            drawPassed(landmark, in: frame, camera: camera, newest: newest, context: &scene)
            room = frame.minX - Self.landmarkGap
        }

        // The next landmark, large at the right, in outline until reached.
        if let next = climb.next {
            let frame = upcomingFrame(next, in: moment)
            var scene = scene
            scene.opacity = appear
            let art = LandmarkArt(silhouette: next.silhouette, carved: false).path(in: frame)
            scene.fill(art, with: .color(Palette.textPrimary.opacity(0.07)))
            if let shade = LandmarkArt.shade(next.silhouette, in: frame) {
                scene.fill(shade, with: .color(Palette.textPrimary.opacity(0.06)))
            }
            if let snow = LandmarkArt.snow(next.silhouette, in: frame) {
                scene.fill(snow, with: .color(Palette.textPrimary.opacity(0.2)))
                scene.stroke(snow, with: .color(Palette.textPrimary.opacity(0.35)),
                             style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
            }
            // A snowy mountain is drawn by its snow and shade; the rest by their cuts.
            if LandmarkArt.snow(next.silhouette, in: frame) == nil,
               let details = LandmarkArt.details(next.silhouette, in: frame) {
                scene.fill(details, with: .color(Palette.textSecondary.opacity(0.5)))
            }
            scene.stroke(art, with: .color(Palette.textSecondary.opacity(0.8)),
                         style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            if next.silhouette.flies { dottedDrop(from: frame, to: plot.maxY, in: &scene) }
        }

        // The stack's climb: the area beneath it and the line.
        let points = climb.points
        let visible = points.indices.filter { camera.x(Double(points[$0].at.epochSeconds)) >= plot.minX }
        let from = max(0, (visible.first ?? points.count - 1) - 1)
        let screen = ClimbCurve.thinned(points[from...].map {
            CGPoint(x: camera.x(Double($0.at.epochSeconds)), y: camera.y($0.meters))
        }, spacing: Self.curveSpacing)
        let line = ClimbCurve.monotone(through: screen)
        if let first = screen.first, let last = screen.last {
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
            area.addLine(to: CGPoint(x: first.x, y: plot.maxY))
            area.closeSubpath()
            scene.fill(area, with: .linearGradient(Gradient(colors: [Palette.textPrimary.opacity(0.16),
                                                                     Palette.textPrimary.opacity(0.02)]),
                                                   startPoint: CGPoint(x: 0, y: camera.y(climb.meters)),
                                                   endPoint: CGPoint(x: 0, y: plot.maxY)))
        }
        scene.stroke(line, with: .color(Palette.textPrimary), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        // Where the stack is headed: a dotted line from it to the summit.
        guard let last = points.last else { return }
        let you = CGPoint(x: camera.x(Double(last.at.epochSeconds)), y: camera.y(climb.meters))
        if let next = climb.next {
            let frame = upcomingFrame(next, in: moment)
            let summit = CGPoint(x: frame.minX + frame.width * LandmarkArt.peak(next.silhouette),
                                 y: camera.y(next.meters))
            var aim = Path()
            aim.move(to: you)
            aim.addLine(to: summit)
            scene.stroke(aim, with: .color(Palette.textSecondary.opacity(0.7 * appear)),
                         style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1, 5]))
        }
        scene.fill(Path(ellipseIn: CGRect(x: you.x - 4.5, y: you.y - 4.5, width: 9, height: 9)),
                   with: .color(Palette.textPrimary))
        // In a replay, the stack says the day it stands on.
        let day = moment.replaying ? "\(BucketLabel.date(last.at, "dMMMy", calendar: calendar)) · " : ""
        let youLabel = label("You · \(day)\(AchievementBadge.meters(climb.meters))", at: CGPoint(x: you.x - 8, y: you.y - 10),
              anchor: .bottomTrailing, weight: .semibold, primary: true, in: &context, within: plot)

        // The next landmark's name, clear of the stack's.
        if let next = climb.next {
            let frame = upcomingFrame(next, in: moment)
            let summit = CGPoint(x: frame.minX + frame.width * LandmarkArt.peak(next.silhouette), y: camera.y(next.meters))
            var context = context
            context.opacity = appear
            let named = next.silhouette.flies ? frame.minY - 6 : summit.y - 8
            if summit.y < plot.minY {
                // Above the frame: its summit marked at the top edge.
                label("\(summit.x > plot.maxX ? "↗" : "↑") \(next.name) · \(AchievementBadge.meters(next.meters))",
                      at: CGPoint(x: summit.x, y: plot.minY + 4), anchor: .top, weight: .semibold, primary: true,
                      in: &context, within: plot)
            } else if named >= plot.minY + 24 {
                // In view with room above: named over its summit. Just as
                // the tip comes into view there is no room, and no name.
                label("\(next.name) · \(AchievementBadge.meters(next.meters))", at: CGPoint(x: summit.x, y: named),
                      anchor: .bottom, weight: .semibold, primary: true, in: &context, within: plot, avoiding: youLabel)
            }
        }

        // The last landmark passed, named over its top with the day.
        if let passed = climb.lastPassed, let at = climb.passed[passed.id] {
            let x = camera.x(Double(at.epochSeconds))
            let top = passed.silhouette.flies ? camera.y(passed.meters) - Self.flyingHeight / 2 : camera.y(passed.meters)
            if x > plot.minX, x < plot.maxX {
                label("\(passed.name) · \(BucketLabel.date(at, "dMMM", calendar: calendar))",
                      at: CGPoint(x: x, y: max(plot.minY + 14, top - 6)),
                      anchor: .bottom, weight: .medium, primary: false, in: &context, within: plot, avoiding: youLabel)
            }
        }

        // The ground and the dates along it.
        var ground = Path()
        ground.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        ground.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.stroke(ground, with: .color(Palette.separator), lineWidth: 1)
        let ticks = 5
        for index in 1..<ticks {
            let seconds = camera.start + (camera.end - camera.start) * Double(index) / Double(ticks)
            guard seconds <= Double(last.at.epochSeconds) else { continue }
            let text = context.resolve(Text(BucketLabel.date(Timestamp(epochSeconds: Int64(seconds)), "dMMM",
                                                             calendar: calendar))
                .font(.caption).foregroundStyle(Palette.textSecondary))
            context.draw(text, at: CGPoint(x: camera.x(seconds), y: plot.maxY + 6), anchor: .top)
        }
    }

    /// The next landmark's frame: standing on the ground at the right with
    /// its summit at its height, or, if it flies, floating at its height.
    private func nextFrame(_ next: Landmark, camera: Camera) -> CGRect {
        let plot = camera.plot
        let aspect = LandmarkArt.aspect(next.silhouette)
        let summit = camera.y(next.meters)
        let room = plot.width * (1 - Self.nowAt) - 24
        if next.silhouette.flies {
            let height = Self.flyingHeight * 1.4
            let width = min(room, height * aspect)
            return CGRect(x: plot.maxX - 16 - width, y: summit - height / 2, width: width, height: height)
        }
        let height = plot.maxY - summit
        let width = height * aspect
        if width <= room * 1.25 { return CGRect(x: plot.maxX - 12 - width, y: summit, width: width, height: height) }
        // Too big for its room: it keeps its proportions, rising from just
        // past the stack off the top and right, foothills first.
        let you = plot.minX + plot.width * Self.nowAt
        return CGRect(x: you + 24, y: summit, width: width, height: height)
    }

    /// Where a passed landmark stands: on the ground at its true height, or
    /// flying at it, with its summit over the day the stack passed it.
    private func passedFrame(_ landmark: Landmark, at: Timestamp, camera: Camera) -> CGRect {
        let aspect = LandmarkArt.aspect(landmark.silhouette)
        let x = camera.x(Double(at.epochSeconds))
        if landmark.silhouette.flies {
            let height = Self.flyingHeight
            return CGRect(x: x - height * aspect / 2, y: camera.y(landmark.meters) - height / 2,
                          width: height * aspect, height: height)
        }
        let height = max(0, camera.plot.maxY - camera.y(landmark.meters))
        let width = height * aspect
        return CGRect(x: x - width * LandmarkArt.peak(landmark.silhouette), y: camera.y(landmark.meters),
                      width: width, height: height)
    }

    /// A passed landmark, filled in: its shaded face darker, its snowfield
    /// and details traced in fine lines that stay fine at any size.
    private func drawPassed(_ landmark: Landmark, in frame: CGRect, camera: Camera, newest: Bool,
                            context: inout GraphicsContext) {
        guard frame.height >= 3 else { return }
        if landmark.silhouette.flies { dottedDrop(from: frame, to: camera.plot.maxY, in: &context) }
        let silhouette = landmark.silhouette
        context.fill(LandmarkArt(silhouette: silhouette, carved: false).path(in: frame),
                     with: .color(Palette.textPrimary.opacity(newest ? 0.85 : 0.5)))
        if let shade = LandmarkArt.shade(silhouette, in: frame) {
            context.fill(shade, with: .color(Palette.surface.opacity(0.22)))
        }
        if let snow = LandmarkArt.snow(silhouette, in: frame) {
            context.stroke(snow, with: .color(Palette.surface.opacity(0.7)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        } else if let details = LandmarkArt.details(silhouette, in: frame) {
            context.fill(details, with: .color(Palette.surface.opacity(0.85)))
        }
    }

    /// A dotted line from something flying down to the ground, for its height.
    private func dottedDrop(from frame: CGRect, to ground: CGFloat, in context: inout GraphicsContext) {
        var drop = Path()
        drop.move(to: CGPoint(x: frame.midX, y: frame.maxY + 3))
        drop.addLine(to: CGPoint(x: frame.midX, y: ground))
        context.stroke(drop, with: .color(Palette.textSecondary.opacity(0.4)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }

    /// A label on the card's surface, kept inside the plot and, where it
    /// would cover `avoiding`, lifted above it. Returns where it was drawn.
    @discardableResult
    private func label(_ string: String, at point: CGPoint, anchor: UnitPoint, weight: Font.Weight, primary: Bool,
                       in context: inout GraphicsContext, within plot: CGRect, avoiding: CGRect? = nil) -> CGRect {
        let text = context.resolve(Text(string).font(.callout.weight(weight)).monospacedDigit()
            .foregroundStyle(primary ? Palette.textPrimary : Palette.textSecondary))
        let size = text.measure(in: plot.size)
        var origin = CGPoint(x: point.x - size.width * anchor.x, y: point.y - size.height * anchor.y)
        origin.x = min(max(origin.x, plot.minX + 4), plot.maxX - size.width - 4)
        origin.y = min(max(origin.y, plot.minY + 2), plot.maxY - size.height - 2)
        if let avoiding, CGRect(origin: origin, size: size).insetBy(dx: -8, dy: -3).intersects(avoiding) {
            origin.y = max(plot.minY + 2, avoiding.minY - size.height - 6)
        }
        let box = CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -2)
        context.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(Palette.surface.opacity(0.92)))
        context.draw(text, in: CGRect(origin: origin, size: size))
        return box
    }
}

/// The climb's line on screen: thinned, then drawn as a smooth curve.
enum ClimbCurve {
    /// The points at least `spacing` apart across, keeping the first and
    /// last, so a quiet run of days and then a busy one reads as a slope,
    /// not a stair.
    static func thinned(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard let last = points.last else { return [] }
        var kept: [CGPoint] = []
        for point in points.dropLast() where kept.last.map({ point.x - $0.x >= spacing }) ?? true {
            kept.append(point)
        }
        if let end = kept.last, last.x - end.x < spacing / 2, kept.count > 1 { kept.removeLast() }
        kept.append(last)
        return kept
    }

    /// A smooth curve through `points` that never overshoots between them
    /// (Fritsch and Carlson's monotone cubic), so a running total that
    /// only rises is never drawn dipping.
    static func monotone(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        let n = points.count
        let slopes = (0..<(n - 1)).map { i in
            (points[i + 1].y - points[i].y) / max(points[i + 1].x - points[i].x, .ulpOfOne)
        }
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) where slopes[i - 1] * slopes[i] > 0 {
            let w1 = 2 * (points[i + 1].x - points[i].x) + (points[i].x - points[i - 1].x)
            let w2 = (points[i + 1].x - points[i].x) + 2 * (points[i].x - points[i - 1].x)
            tangents[i] = (w1 + w2) / (w1 / slopes[i - 1] + w2 / slopes[i])
        }
        for i in 0..<(n - 1) {
            let dx = (points[i + 1].x - points[i].x) / 3
            path.addCurve(to: points[i + 1],
                          control1: CGPoint(x: points[i].x + dx, y: points[i].y + tangents[i] * dx),
                          control2: CGPoint(x: points[i + 1].x - dx, y: points[i + 1].y - tangents[i + 1] * dx))
        }
        return path
    }
}
