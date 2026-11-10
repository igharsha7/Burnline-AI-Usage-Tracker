//
//  Tour.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation
import Observation
import SwiftUI

/// The guided tour: a fixed walk through every part of the dashboard, from a
/// welcome to a send-off, that leaves the user on the overview where it
/// started. It runs once on its own, the first time the dashboard opens, and
/// again whenever Help asks for it.
@Observable
public final class TourModel {
    static let seenKey = "tourSeen"

    /// The steps of the tour now running, or of the next one: those for
    /// pages the user has switched off are left out.
    private(set) var steps: [TourStep]
    /// The step on screen; nil when no tour is running.
    private(set) var index: Int?
    /// Whether the tour has run to its end or been skipped.
    private(set) var seen: Bool

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        seen = defaults.bool(forKey: Self.seenKey)
        steps = TourStep.shown(defaults)
    }

    var current: TourStep? { index.map { steps[$0] } }

    public func start() {
        steps = TourStep.shown(defaults)
        index = 0
    }

    /// Starts the tour for someone who has not seen it, once.
    func startIfNew() {
        if !seen, index == nil { start() }
    }

    func next() {
        guard let index else { return }
        if index + 1 < steps.count { self.index = index + 1 } else { end() }
    }

    func back() {
        if let index, index > 0 { self.index = index - 1 }
    }

    /// Finishing and skipping both count as seen: the tour is offered once,
    /// and Help has it after that.
    func end() {
        index = nil
        seen = true
        defaults.set(true, forKey: Self.seenKey)
    }
}

/// What a step points at. Each is set on its view with `tourTarget(_:)`.
enum TourTarget: Hashable {
    case hero, chart, tokenMix, breakdown, filters, limits, list, heatmap
}

/// One stop: where the dashboard goes for it, what it points at, and what
/// it says. A step with no target, or whose target is not on the page,
/// shows its card on its own, where `placement` puts it.
struct TourStep: Identifiable {
    enum Placement { case center, toolbar, sidebar }

    let id: String
    let title: String
    let body: String
    var area: Area = .overview
    var tab: DashboardTab = .cost
    var target: TourTarget?
    var placement: Placement = .center
    /// A preference that switches the step's subject off; the step is left
    /// out while it is false.
    var requires: String?

    /// The steps for what the user has switched on.
    static func shown(_ defaults: UserDefaults) -> [TourStep] {
        all.filter { step in step.requires.map { defaults.object(forKey: $0) as? Bool ?? true } ?? true }
    }

    static let all: [TourStep] = [
        TourStep(id: "welcome", title: "Welcome to Burnline",
                 body: "Your AI coding usage, limits and what it would cost at API prices, across Codex and "
                     + "Claude Code. Everything is read on this Mac and stays here. This takes about a minute."),
        TourStep(id: "headline", title: "The headline",
                 body: "What everything in the range would have cost at each model's API prices, against the "
                     + "range before it. Beside it, each provider's share: click one to hide it from the chart.",
                 target: .hero),
        TourStep(id: "comparison", title: "In other words",
                 body: "The line at the top says the figure on screen as something familiar, such as books or "
                     + "codebases, and changes every so often. Switch it off in Settings if you prefer numbers.",
                 requires: ActivityPreferences.showComparisonsKey),
        TourStep(id: "toolbar", title: "Range and measure",
                 body: "Choose the range up here, and switch between cost, tokens and your plan limits. "
                     + "⌘R refreshes.",
                 placement: .toolbar),
        TourStep(id: "chart", title: "Over time",
                 body: "Each provider's usage across the range. Move the pointer along it to read any moment.",
                 target: .chart),
        TourStep(id: "tokens", title: "Where the tokens went",
                 body: "Most of what an agent sends is read back from the cache. Point at a kind to split it by "
                     + "provider, and see what caching saved.",
                 target: .tokenMix),
        TourStep(id: "breakdown", title: "The breakdown",
                 body: "Every model, ranked. Click a row to open its mix and rates, sort by any column, or group "
                     + "by project or day. ⌘F filters the rows.",
                 target: .breakdown),
        TourStep(id: "filters", title: "Filters",
                 body: "Narrow every figure to a provider, model or project. What is applied always shows here, "
                     + "so a number never changes without the reason on screen.",
                 target: .filters),
        TourStep(id: "limits", title: "Limits",
                 body: "How much of each plan window is used, against an even pace, when it resets, and any "
                     + "banked resets you hold.",
                 tab: .limits, target: .limits),
        TourStep(id: "providers", title: "Providers",
                 body: "Each provider has a page of its own: its limits, a session running now, and its figures. "
                     + "One Burnline cannot read says so in the sidebar.",
                 area: .provider(.claudeCode), target: .hero, placement: .sidebar),
        TourStep(id: "projects", title: "Projects",
                 body: "Usage by the repository it happened in. Rename a project, or merge ones that belong "
                     + "together.",
                 area: .projects, target: .list),
        TourStep(id: "sessions", title: "Sessions",
                 body: "Every session, with what it cost and used. Open one to see it on its own.",
                 area: .sessions, target: .list),
        TourStep(id: "activity", title: "Activity",
                 body: "A year at a glance, with your streaks. Click a day to see it across the dashboard.",
                 area: .activity, target: .heatmap),
        TourStep(id: "achievements", title: "Achievements",
                 body: "Medals for habits and milestones, this month's challenge and your personal records. "
                     + "Switch them off in Settings if they are not for you.",
                 area: .achievements, requires: ActivityPreferences.showAchievementsKey),
        TourStep(id: "settings", title: "Settings",
                 body: "⌘, opens Settings: alerts before a limit runs out, pricing, and your data, with backups, "
                     + "export and how long detail is kept."),
        TourStep(id: "menubar", title: "In the menu bar",
                 body: "Click the flame in the menu bar for today's usage and your limits, without opening this "
                     + "window. While an agent is at work, the panel glows with it."),
        TourStep(id: "done", title: "That's the tour",
                 body: "Take it again any time from Help → Burnline Tour."),
    ]
}

// MARK: Targets

/// Where each target is on the page, for the spotlight.
private struct TourAnchors: PreferenceKey {
    static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Which targets the page holds, so it can scroll to one once it exists.
private struct TourPresence: PreferenceKey {
    static let defaultValue: Set<TourTarget> = []
    static func reduce(value: inout Set<TourTarget>, nextValue: () -> Set<TourTarget>) {
        value.formUnion(nextValue())
    }
}

extension View {
    /// Marks this view as what a tour step points at.
    func tourTarget(_ target: TourTarget) -> some View {
        id(target)
            .anchorPreference(key: TourAnchors.self, value: .bounds) { [target: $0] }
            .preference(key: TourPresence.self, value: [target])
    }

    /// The tour over a scrolling page: scrolls the step's target into view
    /// and draws the spotlight and card above it.
    func tourLayer(_ tour: TourModel?, scroll: ScrollViewProxy) -> some View {
        modifier(TourLayerModifier(tour: tour, scroll: scroll))
    }
}

private struct TourLayerModifier: ViewModifier {
    let tour: TourModel?
    let scroll: ScrollViewProxy

    @State private var present: Set<TourTarget> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(TourPresence.self) { present = $0 }
            .overlayPreferenceValue(TourAnchors.self) { anchors in
                if let tour, let step = tour.current {
                    GeometryReader { geometry in
                        TourOverlay(tour: tour, step: step,
                                    spot: step.target.flatMap { anchors[$0] }.map { geometry[$0] },
                                    bounds: CGRect(origin: .zero, size: geometry.size))
                    }
                }
            }
            // Scrolls once the target exists: a page's figures arrive after it
            // opens. High in the view rather than centred, so even a tall
            // section leaves room below it for the card.
            .onChange(of: ScrollRequest(target: tour?.current?.target, present: present)) { _, request in
                guard let target = request.target, request.present.contains(target) else { return }
                withAnimation(Motion.standard(reduced: reduceMotion)) {
                    scroll.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.15))
                }
            }
    }
}

private struct ScrollRequest: Equatable {
    let target: TourTarget?
    let present: Set<TourTarget>
}

// MARK: Overlay

/// The page dimmed but for its target, and the step's card beside it. The
/// cut-out lets the pointer through, so the feature can be tried mid-tour.
private struct TourOverlay: View {
    let tour: TourModel
    let step: TourStep
    let spot: CGRect?
    let bounds: CGRect

    @State private var cardSize = CGSize(width: 340, height: 160)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let inset: CGFloat = 8
    static let gap: CGFloat = 14

    /// The cut-out: the target with room around it, or, with none, nothing,
    /// collapsed at the card so the dimming closes rather than jumps.
    private var hole: CGRect {
        guard let spot else { return CGRect(origin: CGPoint(x: bounds.midX, y: bounds.midY), size: .zero) }
        return spot.insetBy(dx: -Self.inset, dy: -Self.inset).intersection(bounds.insetBy(dx: 4, dy: 4))
    }

    private var cardCenter: CGPoint {
        let half = CGSize(width: cardSize.width / 2, height: cardSize.height / 2)
        guard spot != nil else {
            switch step.placement {
            case .center: return CGPoint(x: bounds.midX, y: bounds.midY)
            case .toolbar: return CGPoint(x: bounds.maxX - half.width - 20, y: bounds.minY + half.height + 16)
            case .sidebar: return CGPoint(x: bounds.minX + half.width + 20, y: bounds.minY + half.height + 80)
            }
        }
        let hole = hole
        // Below the target if it fits, else above, else inside its top.
        let below = hole.maxY + Self.gap + cardSize.height <= bounds.maxY - 12
        let above = hole.minY - Self.gap - cardSize.height >= bounds.minY + 12
        let y = below ? hole.maxY + Self.gap + half.height
            : above ? hole.minY - Self.gap - half.height
            : hole.minY + half.height + 16
        let x = min(max(hole.minX + half.width, bounds.minX + half.width + 16), bounds.maxX - half.width - 16)
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        let animation = Motion.standard(reduced: reduceMotion)
        ZStack(alignment: .topLeading) {
            Spotlight(hole: hole)
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                .contentShape(Spotlight(hole: hole), eoFill: true)
                .onTapGesture {}
            RoundedRectangle(cornerRadius: Spotlight.radius, style: .continuous)
                .strokeBorder(Palette.textPrimary.opacity(spot == nil ? 0 : 0.35), lineWidth: 1)
                .frame(width: hole.width, height: hole.height)
                .position(x: hole.midX, y: hole.midY)
                .allowsHitTesting(false)
            TourCard(tour: tour, step: step)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                .position(cardCenter)
        }
        .animation(animation, value: step.id)
        .animation(animation, value: hole)
        .transition(.opacity)
    }
}

/// The page with a rounded hole cut where the target is.
private struct Spotlight: Shape {
    static let radius: CGFloat = 14
    var hole: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(hole.origin.x, hole.origin.y), .init(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first,
                            height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if hole.width > 0, hole.height > 0 {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: Self.radius, height: Self.radius), style: .continuous)
        }
        return path
    }
}

/// The step's words, where it is in the tour, and the way on.
private struct TourCard: View {
    let tour: TourModel
    let step: TourStep

    private var position: Int { (tour.index ?? 0) + 1 }
    private var last: Bool { position == tour.steps.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title).font(.headline)
            Text(step.body).font(.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                progress
                Spacer(minLength: 12)
                if position > 1 {
                    Button("Back", action: tour.back)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                Button(position == 1 ? "Start" : last ? "Done" : "Next", action: tour.next)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
            if !last {
                Button(position == 1 ? "Not now" : "Skip tour", action: tour.end)
                    .buttonStyle(.link).font(.caption)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .id(step.id)
        .transition(.opacity)
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.rim, lineWidth: 0.75))
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tour, step \(position) of \(tour.steps.count)")
    }

    /// One dot a step, the current one drawn long.
    private var progress: some View {
        HStack(spacing: 4) {
            ForEach(0..<tour.steps.count, id: \.self) { index in
                Capsule()
                    .fill(index == position - 1 ? Palette.textPrimary : Palette.textSecondary.opacity(0.35))
                    .frame(width: index == position - 1 ? 14 : 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}
