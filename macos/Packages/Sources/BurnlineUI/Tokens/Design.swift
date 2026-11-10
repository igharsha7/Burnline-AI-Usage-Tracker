//
//  Design.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import SwiftUI

/// Type, motion and surfaces shared by every dashboard view, so a spacing,
/// timing or weight is a decision made once.
enum Typography {
    /// Large figures: rounded, semibold, tracked tighter as they grow, with
    /// tabular digits so a changing figure does not shift.
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// Display tracking: about -2% of the size, as large type wants.
    static func tracking(_ size: CGFloat) -> CGFloat { -size * 0.02 }

    /// Section figures, rounded to match the display.
    static let figure = Font.system(.title2, design: .rounded).weight(.semibold).monospacedDigit()
}

enum Motion {
    /// Critically damped: settles without overshoot. Nothing on the
    /// dashboard is flung, so nothing bounces.
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1)

    /// The standard spring, or none under Reduce Motion.
    static func standard(reduced: Bool) -> Animation? { reduced ? nil : standard }

    /// For things arriving: slower than a response to the pointer, so a
    /// figure grows into place rather than snapping.
    static let reveal = Animation.spring(response: 0.7, dampingFraction: 1)

    /// The reveal, held back by `index` steps so a list arrives in order;
    /// capped, so a long list does not keep the last row waiting.
    static func reveal(_ index: Int, reduced: Bool) -> Animation? {
        reduced ? nil : reveal.delay(Double(min(index, 10)) * 0.035)
    }

    /// For a line drawing itself in: slow enough to be seen travelling.
    static let draw = Animation.spring(response: 0.9, dampingFraction: 1)

    /// For a drawing done again with new figures: quicker than the first,
    /// since the eye already knows the shape it is reading.
    static let redraw = Animation.spring(response: 0.6, dampingFraction: 1)

    /// How a small symbol arrives and leaves: from a quarter size, faded
    /// and blurred, so it resolves into place rather than popping.
    static let icon = AnyTransition.modifier(active: IconState(on: false), identity: IconState(on: true))

    /// Content opening below what was clicked: a short drop and a fade,
    /// each part a step behind the last. Leaving only fades, and quicker,
    /// so closing never feels heavier than opening.
    static func unfold(_ step: Int) -> AnyTransition {
        .asymmetric(insertion: AnyTransition.opacity.combined(with: .offset(y: -6))
                        .animation(standard.delay(Double(step) * 0.05)),
                    removal: AnyTransition.opacity.animation(.easeOut(duration: 0.12)))
    }
}

/// A section arriving with its page: up 8 points and in, a step behind the
/// section above it, so a page assembles in reading order. It plays once
/// per appearance; new figures for a page already shown morph instead.
private struct Arrival: ViewModifier {
    let step: Int
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrames) private var stillFrames

    func body(content: Content) -> some View {
        let shown = arrived || stillFrames
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                guard !arrived else { return }
                if reduceMotion { arrived = true } else {
                    withAnimation(Motion.standard.delay(Double(min(step, 6)) * 0.06)) { arrived = true }
                }
            }
    }
}

extension View {
    func arrival(_ step: Int) -> some View { modifier(Arrival(step: step)) }

    /// Rolls a number's digits to `value`: rising from below as it grows,
    /// dropping from above as it shrinks. Plain under Reduce Motion.
    func rollingNumber(_ value: Double) -> some View { modifier(RollingNumber(value: value)) }
}

/// Rolls a number's digits toward its new value: up when it grows, down
/// when it shrinks, the way a live counter ticks. SwiftUI reads the
/// direction from the change in `value` itself.
private struct RollingNumber: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText(value: value))
    }
}

extension EnvironmentValues {
    /// Set where views are rendered to an image rather than shown: their
    /// entrances start where they end, since no appearance will run them.
    @Entry var stillFrames = false
}

private struct IconState: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        content.scaleEffect(on ? 1 : 0.25).opacity(on ? 1 : 0).blur(radius: on ? 0 : 4)
    }
}

/// A plain button that gives under the pointer: 0.96 while pressed, the
/// least that still reads as a press. Reduce Motion keeps it still.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// A grouped surface: an opaque card with a lit top rim, the depth cue the
/// dashboard uses in place of glass, which belongs to the toolbar alone.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [Palette.rim, Palette.separator.opacity(0.35)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
    }
}

/// A section's title, with an optional detail beside it and controls at the end.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// The point a burn line has reached: a solid dot, cut out from the track
/// by a ring of the surface behind it, so it reads crisply on any fill
/// without a halo.
struct Ember: View {
    var color: Color = Palette.ember
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .padding(2)
            .background(Circle().fill(Palette.surface))
            .accessibilityHidden(true)
    }
}
