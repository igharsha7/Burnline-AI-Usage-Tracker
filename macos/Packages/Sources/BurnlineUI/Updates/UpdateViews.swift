//
//  UpdateViews.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import SwiftUI

/// The small mark of a nightly build: a crescent moon on a patch of night
/// sky, the colours of the nightly icon, where there is no room for the
/// sidebar's card: the popover's footer and About. It never animates.
struct NightlyBadge: View {
    let build: BuildInfo
    /// The moon alone, for the popover's crowded footer.
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.stars.fill")
                .font(.caption2.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
            if !compact {
                Text("Nightly").font(.caption.weight(.semibold))
                if let day = build.nightlyDay {
                    Text(day).font(.caption).opacity(0.75)
                }
            }
        }
        .foregroundStyle(Palette.moonlight)
        .padding(.horizontal, compact ? 6 : 8)
        .frame(minHeight: 20)
        .background(LinearGradient(colors: [Palette.nightTop, Palette.nightBottom], startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.moonlight.opacity(0.18)))
        .help("A nightly build: the newest work, before it reaches a release")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(build.nightlyDay.map { "Nightly build of \($0)" } ?? "Nightly build")
    }
}

/// The foot of the dashboard's sidebar, on every page: what this build is,
/// and the way to update it. An update found is offered as a button above.
struct SidebarUpdateFooter: View {
    let updates: UpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let version = updates.available {
                Button { updates.check() } label: {
                    Label {
                        Text("Update to \(version)").foregroundStyle(Palette.textPrimary)
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Palette.ember)
                    }
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Palette.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.pressable)
                .help("See what is new in \(version), and install it")
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if updates.build.isNightly {
                NightSky(build: updates.build) { checkButton.foregroundStyle(Palette.moonlight.opacity(0.8)) }
            } else {
                HStack(spacing: 6) {
                    Text("Burnline \(updates.build.version)")
                        .font(.caption).foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    checkButton.foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(Motion.standard, value: updates.available)
    }

    private var checkButton: some View {
        Button { updates.check() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.callout)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(!updates.canCheck)
        .help(updates.unavailableReason ?? "Check for Updates")
        .accessibilityLabel("Check for Updates")
    }
}

/// A nightly's mark at the foot of the sidebar: a small window onto the
/// night sky of its icon, deep blue into purple, with a glowing crescent,
/// stars, and what this build is. It is still while idle; the stars
/// brighten only while the pointer is over it.
struct NightSky<Accessory: View>: View {
    let build: BuildInfo
    @ViewBuilder let accessory: Accessory
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stars as fractions of the card, with their size and brightness.
    static var stars: [(x: CGFloat, y: CGFloat, size: CGFloat, glow: Double)] {
        [(0.30, 0.18, 1.6, 0.9), (0.46, 0.68, 1.0, 0.5), (0.55, 0.22, 1.2, 0.7), (0.66, 0.80, 1.4, 0.6),
         (0.74, 0.12, 1.0, 0.45), (0.83, 0.55, 1.8, 0.85), (0.92, 0.28, 1.0, 0.5), (0.38, 0.86, 1.1, 0.4),
         (0.62, 0.45, 0.9, 0.35), (0.97, 0.78, 1.2, 0.55)]
    }

    /// The release a nightly leads to, without its suffix: 0.2.0 from 0.2.0-nightly.20261111.
    private var release: String { build.version.split(separator: "-").first.map(String.init) ?? build.version }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Palette.moonlight.opacity(0.22)).frame(width: 30, height: 30).blur(radius: 7)
                Image(systemName: "moon.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .rotationEffect(.degrees(-18))
                    .foregroundStyle(Palette.moonlight)
                    .shadow(color: Palette.moonlight.opacity(0.7), radius: 5)
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nightly")
                    .font(.system(.callout, design: .rounded).weight(.bold))
                    .tracking(0.4)
                    .foregroundStyle(Palette.moonlight)
                Text([release, build.nightlyDay].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2.weight(.medium)).monospacedDigit()
                    .foregroundStyle(Palette.moonlight.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            accessory
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 9)
        .background {
            ZStack {
                LinearGradient(colors: [Palette.nightTop, Palette.nightBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Palette.moonlight.opacity(0.16), .clear],
                               center: UnitPoint(x: 0.12, y: 0.3), startRadius: 0, endRadius: 70)
                Canvas { context, size in
                    for star in Self.stars {
                        let rect = CGRect(x: star.x * size.width, y: star.y * size.height,
                                          width: star.size, height: star.size)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(hovering ? min(1, star.glow + 0.35)
                                                                                            : star.glow)))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Palette.moonlight.opacity(0.35), Palette.moonlight.opacity(0.06)],
                                         startPoint: .top, endPoint: .bottom)))
        .shadow(color: Palette.nightBottom.opacity(0.55), radius: 10, y: 3)
        .onHover { inside in
            if reduceMotion { hovering = inside } else { withAnimation(.easeOut(duration: 0.4)) { hovering = inside } }
        }
        .help("A nightly build: the newest work, before it reaches a release")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(build.nightlyDay.map { "Nightly build \(release), \($0)" } ?? "Nightly build \(release)")
    }
}

/// The popover's share: the nightly moon, and an update waiting.
struct PopoverUpdateItems: View {
    let updates: UpdateModel
    let dismiss: DismissAction

    var body: some View {
        if updates.build.isNightly {
            NightlyBadge(build: updates.build, compact: true)
        }
        if let version = updates.available {
            Button {
                dismiss()
                updates.check()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Palette.ember)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("Update to \(version)")
            .accessibilityLabel("Update to \(version)")
        }
    }
}

/// Settings' updates: the channel, checks by themselves, and a check now.
struct UpdatesSection: View {
    @Bindable var updates: UpdateModel
    @State private var confirmingNightly = false

    var body: some View {
        Section {
            Picker(selection: Binding(get: { updates.channel }, set: { choose($0) })) {
                ForEach(UpdateChannel.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("Channel")
                if let note = updates.channelNote { Text(note) }
            }
            Toggle("Check for updates daily", isOn: $updates.automaticallyChecks)
                .disabled(!updates.canCheck)
            LabeledContent {
                Button("Check Now") { updates.check() }.disabled(!updates.canCheck)
            } label: {
                Text(updates.build.isNightly ? "Nightly \(updates.build.fullVersion)" : "Version \(updates.build.fullVersion)")
                Text(status)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("A check downloads a public list of versions, and sends nothing about you or your usage.")
        }
        .confirmationDialog("Follow nightly builds?", isPresented: $confirmingNightly) {
            Button("Follow Nightly") { updates.channel = .nightly }
        } message: {
            Text("Nightly builds carry the newest work and can be rough. One may change the database in a way a stable "
                 + "release does not read yet, so going back means restoring a backup.")
        }
    }

    private var status: String {
        if let reason = updates.unavailableReason { return reason }
        if let version = updates.available { return "Version \(version) is ready to install." }
        guard let lastCheck = updates.lastCheck else { return "Not checked yet." }
        return "Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))."
    }

    private func choose(_ channel: UpdateChannel) {
        if updates.needsConfirmation(toFollow: channel) {
            confirmingNightly = true
        } else {
            updates.channel = channel
        }
    }
}

/// The app menu's Check for Updates, under About.
public struct UpdateCommands: Commands {
    let updates: UpdateModel

    public init(updates: UpdateModel) {
        self.updates = updates
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.check() }
                .disabled(!updates.canCheck)
        }
    }
}
