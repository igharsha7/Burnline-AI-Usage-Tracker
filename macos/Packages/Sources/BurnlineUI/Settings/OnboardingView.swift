//
//  OnboardingView.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import SwiftUI

/// The dashboard window's content: onboarding on the first run, so a new
/// user meets an explanation rather than a zeroed dashboard, then the
/// dashboard itself.
public struct DashboardWindow: View {
    let dashboard: DashboardModel
    let status: StatusModel
    let settings: SettingsModel

    public init(dashboard: DashboardModel, status: StatusModel, settings: SettingsModel) {
        self.dashboard = dashboard
        self.status = status
        self.settings = settings
    }

    /// When onboarding's fuse burnt out, while its burst is still on screen.
    @State private var burst: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        Group {
            // A database that did not open is explained before anything is offered.
            if settings.onboarded || dashboard.startupFailure != nil {
                DashboardView(model: dashboard, status: status)
                    .environment(settings)
            } else {
                OnboardingView(settings: settings) {
                    dashboard.refresh()
                    if !reduceMotion { burst = .now }
                }
            }
        }
        // Over both, so the burst carries across the change to the dashboard.
        .overlay {
            if let burst {
                ScreenBurst(start: burst, origin: OnboardingView.fuseEnd) { self.burst = nil }
            }
        }
    }
}

/// Five short steps along a burning fuse: what Burnline is and what it
/// reads; the name engraved on the user's medals, which may be skipped;
/// which providers to track, the ones found on this Mac chosen to begin
/// with and all of them recommended; how their import is going; the
/// medals that history had already earned, when it earned any; and
/// notifications, offered with the reason and asked for only if the user
/// chooses them. Nothing is read before the user chooses, and nothing is
/// asked on the first frame.
struct OnboardingView: View {
    let settings: SettingsModel
    let finished: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, name, choose, sources, medals, notifications

        /// Its name on the fuse.
        var label: String {
            switch self {
            case .welcome: "Welcome"
            case .name: "You"
            case .choose: "Tools"
            case .sources: "History"
            case .medals: "Medals"
            case .notifications: "Alerts"
            }
        }
    }
    @State private var step = Step.welcome
    /// The providers picked; nil until the user changes the starting choice.
    @State private var picked: Set<ProviderKey>?
    /// The import under way, and when it began: medals added since then are
    /// the ones the history earned.
    @State private var importing: Task<Void, Never>?
    @State private var importStarted: Timestamp?
    /// What the import found; nil while it is still being looked for.
    @State private var medalsFound: [Achievement]?
    /// Set once the user finishes: the fuse burns to its end before the
    /// dashboard is shown.
    @State private var finale = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How often import progress is read while the sources step is open.
    static let pollInterval: Duration = .seconds(1)
    /// How long the fuse takes to burn from the last step to its end.
    static let finaleBurn = 0.9
    /// Where on the window the fuse ends: the burst starts there.
    static let fuseEnd = UnitPoint(x: 0.965, y: 0.88)

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .name: naming
                case .choose: choose
                case .sources: sources
                case .medals: medals
                case .notifications: notifications
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .opacity(finale ? 0 : 1)
            OnboardingFuse(progress: finale ? 1 : (Double(step.rawValue) + 0.5) / Double(Step.allCases.count),
                           steps: Step.allCases.map(\.label), current: step.rawValue)
                .animation(.easeInOut(duration: 0.9), value: step)
                .padding(.top, 24)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 40)
        .background(Palette.background)
        .animation(Motion.standard(reduced: reduceMotion), value: step)
        .frame(minWidth: 640, minHeight: 520)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 24) {
            Image(nsImage: AboutView.icon).resizable().frame(width: 148, height: 148)
                .background {
                    // The ember the icon's line burns toward, lighting the dark.
                    RadialGradient(colors: [Palette.ember.opacity(0.35), Palette.ember.opacity(0)], center: .center,
                                   startRadius: 20, endRadius: 190)
                        .frame(width: 380, height: 380)
                        .allowsHitTesting(false)
                }
            Text("One place for your AI coding usage").font(Typography.display(44)).multilineTextAlignment(.center)
            Text("Burnline shows what Codex and Claude Code cost at API prices, how close you are to their limits, "
                 + "and where the tokens went.")
                .font(.title3)
                .multilineTextAlignment(.center).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Burnline reads usage from the files those tools keep on this Mac. Your prompts and code are never "
                  + "stored, and nothing leaves this Mac.", systemImage: "lock")
                .font(.body).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button("Get Started") { step = .name }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
    }

    /// The name engraved on the back of each medal. Optional: an empty one
    /// leaves the backs without it.
    private var naming: some View {
        @Bindable var settings = settings
        return VStack(spacing: 22) {
            NamePreview(name: settings.engravedName)
                .padding(.bottom, 8)
            Text("What should we call you?").font(Typography.display(38)).multilineTextAlignment(.center)
            Text("Your name is engraved on the back of every medal you earn. It stays on this Mac, and you can "
                 + "change it in Settings.")
                .font(.title3)
                .multilineTextAlignment(.center).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Your name", text: $settings.name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(.title3)
                .frame(maxWidth: 320)
                .multilineTextAlignment(.center)
                .onSubmit { step = .choose }
            HStack(spacing: 12) {
                Button("Skip") {
                    settings.name = ""
                    step = .choose
                }
                .controlSize(.large)
                Button("Continue") { step = .choose }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(settings.engravedName == nil)
            }
        }
    }

    /// To begin with, every provider found on this Mac.
    private var found: Set<ProviderKey> {
        Set(ProviderKey.trackable.filter { ProviderSetup.isFound(settings.detections[$0]) })
    }

    private var choose: some View {
        let chosen = picked ?? found
        let all = ProviderKey.trackable
        return VStack(alignment: .leading, spacing: 20) {
            Text("Choose what to track").font(Typography.display(38))
            Text("Burnline reads only the tools you pick. You can add the others later from Providers in the sidebar.")
                .font(.title3).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                Button {
                    picked = chosen.count == all.count ? [] : Set(all)
                } label: {
                    HStack(spacing: 10) {
                        Text("All providers").font(.body.weight(.medium))
                        Text("Recommended")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Palette.control, in: Capsule())
                        Spacer()
                        Image(systemName: chosen.count == all.count ? "checkmark.square.fill"
                                          : chosen.isEmpty ? "square" : "minus.square.fill")
                            .font(.title3)
                            .foregroundStyle(chosen.isEmpty ? Palette.textSecondary : Palette.textPrimary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen.count == all.count ? .isSelected : [])
                ForEach(all, id: \.self) { provider in
                    Divider()
                    ProviderSetupRow(provider: provider, detection: settings.detections[provider],
                                     selected: chosen.contains(provider)) {
                        var next = chosen
                        if next.remove(provider) == nil { next.insert(provider) }
                        picked = next
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Label("We recommend importing all of them. Burnline keeps usage figures only, never prompts or code, "
                  + "and nothing leaves this Mac. A tool not on this Mac yet is picked up once you use it.",
                  systemImage: "sparkles")
                .font(.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") { step = .name }.controlSize(.large)
                Spacer()
                Button(chosen.count == all.count ? "Import All" : chosen.isEmpty ? "Choose a Provider" : "Import") {
                    importStarted = settings.clock.now
                    importing = Task { await settings.track(chosen) }
                    step = .sources
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .task { await settings.reload() }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Finding your history").font(Typography.display(38))
            Text("Burnline imports whatever history each tool still keeps. You can start while it finishes.")
                .font(.title3).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                let tracked = ProviderKey.allCases.filter(settings.tracked.contains)
                ForEach(tracked, id: \.self) { provider in
                    SourceRow(provider: provider, health: settings.health[provider], sessions: settings.sessions[provider])
                    if provider != tracked.last { Divider() }
                }
            }
            .padding(.horizontal, 14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let start = settings.trackingStart {
                Text("History begins \(start.date.formatted(date: .long, time: .omitted)).")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
            }
            HStack {
                Spacer()
                Button("Continue") { step = .medals }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .task {
            while !Task.isCancelled {
                await settings.reloadProgress()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// The medals the imported history had already earned: the few that
    /// matter most, and how many more. Looked for once the import ends,
    /// passed over when there are none, and skippable throughout.
    private var medals: some View {
        VStack(spacing: 22) {
            if let found = medalsFound, !found.isEmpty {
                Text(found.count == 1 ? "You've already earned a medal" : "You've already earned \(found.count) medals")
                    .font(Typography.display(38)).multilineTextAlignment(.center)
                Text("Your history counted before Burnline was here to see it.")
                    .font(.title3).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
                FoundMedals(found: found)
                    .padding(.vertical, 8)
            } else {
                MedalSearch(sessions: settings.sessions.values.reduce(0, +))
            }
            if let found = medalsFound, !found.isEmpty {
                HStack {
                    Button("Skip") { step = .notifications }.controlSize(.large)
                    Spacer()
                    Button("Continue") {
                        Task { await settings.celebrate(found) }
                        step = .notifications
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Skip") { step = .notifications }.controlSize(.large)
            }
        }
        .task {
            // The count of sessions read keeps moving while the import ends.
            let polling = Task {
                while !Task.isCancelled {
                    await settings.reloadProgress()
                    try? await Task.sleep(for: Self.pollInterval)
                }
            }
            await importing?.value
            let medals = await settings.foundMedals(since: importStarted ?? settings.clock.now)
            polling.cancel()
            if medals.isEmpty { step = .notifications } else { medalsFound = medals }
        }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: -10) {
                NotificationPreview(title: "Codex 5-hour usage reached 90%",
                                    message: "About 40 minutes left at this pace. It resets at 6:15 PM.")
                    .rotationEffect(.degrees(-1.5))
                NotificationPreview(title: "New medal: 30-Day Streak", message: "Silver · Streaks. Click to see it.")
                    .rotationEffect(.degrees(1.2))
                    .offset(x: 30)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)
            Text("Know before you hit a limit").font(Typography.display(38))
            Text("Burnline can tell you when a limit reaches \(Int(QuotaThresholds.warning))% and \(Int(QuotaThresholds.critical))%, when it is reached, when it is available "
                 + "again, and when usage is on course to run out before the reset. You can change each one in Settings.")
                .font(.title3).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.permission == .allowed {
                Label("Notifications are on. A test one just arrived.", systemImage: "checkmark.circle")
            } else if settings.permission == .denied {
                Label("macOS has notifications for Burnline turned off. You can allow them in System Settings later.",
                      systemImage: "bell.slash")
                    .foregroundStyle(Palette.textSecondary)
            }
            HStack {
                Spacer()
                if settings.permission == .allowed || settings.permission == .denied {
                    Button("Open Dashboard") { finish() }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { finish() }.controlSize(.large)
                    Button("Turn On Notifications") { Task { await settings.testNotification() } }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }
        }
        .task { await settings.reload() }
    }

    /// Burns the fuse to its end, then hands over to the dashboard, which
    /// bursts into view. Straight there under Reduce Motion.
    private func finish() {
        guard !finale else { return }
        guard !reduceMotion else { return complete() }
        withAnimation(.easeIn(duration: Self.finaleBurn)) { finale = true }
        Task {
            try? await Task.sleep(for: .seconds(Self.finaleBurn))
            complete()
        }
    }

    private func complete() {
        settings.finishOnboarding()
        finished()
    }
}

/// The wait while the history is judged, made to look like work, because it
/// is: a medal of each kind catching the light in turn, what is being checked, and the
/// sessions read so far, still rising, so a long import never looks stuck.
private struct MedalSearch: View {
    let sessions: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One medal of each shelf, uncast.
    private static let medals: [AchievementBadge] = {
        var seen: Set<AchievementCategory> = []
        return AchievementBadge.catalogue(providers: ProviderKey.trackable)
            .filter { !$0.secret && seen.insert($0.category).inserted }
    }()
    /// What the judging looks at, in the order the medals are judged.
    private static let checks = [
        "Adding up every token…", "Stacking the pages against the landmarks…", "Counting your streaks…",
        "Looking for sessions past midnight…", "Seeing what the cache saved you…", "Counting your projects…",
        "Finding your busiest day…",
    ]
    private static let medalBeat = 0.55
    private static let checkBeat = 2.2

    var body: some View {
        VStack(spacing: 22) {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let lit = reduceMotion ? -1 : Int(t / Self.medalBeat) % Self.medals.count
                let check = reduceMotion ? 0 : Int(t / Self.checkBeat) % Self.checks.count
                VStack(spacing: 22) {
                    HStack(spacing: 14) {
                        ForEach(Array(Self.medals.enumerated()), id: \.element.id) { index, badge in
                            // The one being judged catches the light in silver.
                            MedalView(form: MedalForm(badge.category), metal: index == lit ? .silver : nil,
                                      face: MedalFace(badge), size: 52)
                                .scaleEffect(index == lit ? 1.12 : 1)
                                .opacity(index == lit ? 1 : 0.7)
                                .animation(.easeInOut(duration: 0.35), value: lit)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(Self.checks[check])
                        .font(.title3).foregroundStyle(Palette.textSecondary)
                        .id(check)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .opacity))
                        .animation(.smooth(duration: 0.4), value: check)
                }
            }
            Text(sessions > 0 ? "\(sessions.formatted()) \(sessions == 1 ? "session" : "sessions") read so far" : "Reading your sessions…")
                .font(.callout).monospacedDigit().foregroundStyle(Palette.textSecondary)
                .contentTransition(.numericText(value: Double(sessions)))
                .animation(.snappy, value: sessions)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Looking through your history for medals")
    }
}

/// One provider's detection and import, as it happens.
private struct SourceRow: View {
    let provider: ProviderKey
    let health: ProviderHealth?
    let sessions: Int?

    var body: some View {
        HStack(spacing: 10) {
            ProviderLogo(provider: provider, size: 16)
            Text(provider.displayName)
            Spacer()
            switch health {
            case nil:
                ProgressView().controlSize(.small)
                Text("Importing…").foregroundStyle(Palette.textSecondary)
            case .healthy, .degraded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.textSecondary)
                Text(sessions.map { "\($0.formatted()) \($0 == 1 ? "session" : "sessions")" } ?? "Found")
            case .notInstalled:
                Text("Not detected").foregroundStyle(Palette.textSecondary)
            case .unavailable:
                Text("Not supported yet").foregroundStyle(Palette.textSecondary)
            }
        }
        .font(.callout)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
