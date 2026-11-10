//
//  SettingsView.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import BurnlineServices
import SwiftUI

/// The Settings window: one native tab per pane, grouped forms inside.
public struct SettingsView: View {
    let settings: SettingsModel
    let status: StatusModel

    public init(settings: SettingsModel, status: StatusModel) {
        self.settings = settings
        self.status = status
    }

    public var body: some View {
        TabView {
            GeneralPane(settings: settings).tabItem { Label("General", systemImage: "gearshape") }
            ProvidersPane(settings: settings, status: status).tabItem { Label("Providers", systemImage: "square.stack.3d.up") }
            NotificationsPane(settings: settings).tabItem { Label("Notifications", systemImage: "bell.badge") }
            PricingPane(settings: settings).tabItem { Label("Pricing", systemImage: "dollarsign.circle") }
            DataPane(settings: settings).tabItem { Label("Data", systemImage: "internaldrive") }
            PrivacyPane().tabItem { Label("Privacy", systemImage: "hand.raised") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600)
        .frame(minHeight: 460)
        .task { await settings.reload() }
    }
}

// MARK: General

private struct GeneralPane: View {
    @Bindable var settings: SettingsModel
    @AppStorage(MenuBarTitleMode.storageKey) private var mode = MenuBarTitleMode.default
    @AppStorage(DockPresence.menuBarOnlyKey) private var menuBarOnly = false
    @AppStorage(ActivityPreferences.showComparisonsKey) private var showComparisons = true
    @AppStorage(ActivityPreferences.comparisonToneKey) private var tone = ActivityPreferences.mix
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var needsApproval = LoginItem.needsApproval
    @Environment(UpdateModel.self) private var updates: UpdateModel?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                    try? LoginItem.set(enabled)
                    launchAtLogin = LoginItem.isEnabled
                    needsApproval = LoginItem.needsApproval
                }))
                if needsApproval {
                    LabeledContent("macOS is holding it until you allow it.") {
                        Button("Open Login Items…") { LoginItem.openSettings() }
                    }
                    .font(.callout)
                }
                Toggle(isOn: Binding(get: { menuBarOnly }, set: { only in
                    menuBarOnly = only
                    DockPresence.apply(menuBarOnly: only)
                })) {
                    Text("Menu bar only")
                    Text("No Dock icon, and the dashboard does not open at login.")
                }
            }
            Section {
                TextField(text: $settings.name, prompt: Text("Optional")) {
                    Text("Your name")
                    Text("Engraved on the back of your medals. Kept on this Mac.")
                }
                Picker("Menu bar shows", selection: $mode) {
                    ForEach(MenuBarTitleMode.allCases) { Text($0.label).tag($0) }
                }
                Picker(selection: $settings.weekStart) {
                    ForEach(WeekStart.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Weeks start on")
                    Text("Applies the next time Burnline opens.")
                }
            }
            Section("Activity") {
                Toggle(isOn: $settings.showAchievements) {
                    Text("Show streaks and achievements")
                    Text("Observations about work already done, kept on this Mac.")
                }
                Toggle(isOn: $showComparisons) {
                    Text("Show comparisons")
                    Text("Your usage set against books, coffees and other things.")
                }
                Picker("Comparison tone", selection: $tone) {
                    Text("Mix").tag(ActivityPreferences.mix)
                    ForEach(ComparisonTone.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
                .disabled(!showComparisons)
            }
            if let updates { UpdatesSection(updates: updates) }
        }
        .formStyle(.grouped)
    }
}

// MARK: Providers

/// Each provider's sources and how fresh they are: when history last synced
/// and what that sync read, and the state of its quota.
private struct ProvidersPane: View {
    let settings: SettingsModel
    let status: StatusModel

    var body: some View {
        Form {
            ForEach(ProviderKey.allCases, id: \.self) { provider in
                Section {
                    LabeledContent("History") {
                        Text(settings.health[provider].map { HealthText.long($0, now: settings.clock.now) } ?? "Not synced yet")
                            .multilineTextAlignment(.trailing)
                    }
                    if let result = settings.imports[provider] {
                        if case .installed(let directory) = result.detection {
                            LabeledContent("Reads from") {
                                HStack(spacing: 6) {
                                    Text(directory.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                                        .font(.callout.monospaced())
                                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                                        .buttonStyle(.link)
                                }
                            }
                        }
                        if result.filesRead + result.filesUnchanged > 0 {
                            LabeledContent("Last sync") {
                                Text(syncSummary(result))
                            }
                        }
                    }
                    if let quota = status.quotas.first(where: { $0.provider == provider }) {
                        LabeledContent("Quota") { Text(quotaText(quota)).multilineTextAlignment(.trailing) }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.accent(provider)).frame(width: 8, height: 8)
                        Text(provider.displayName)
                    }
                }
            }
            Section {
                HStack {
                    Button("Re-scan History") { Task { await settings.rescan() } }
                        .disabled(settings.busy)
                    Button("Refresh Quota") { Task { await settings.refreshQuota() } }
                    if settings.busy { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text("A re-scan reads only what changed since the last sync; provider files are never modified.")
            }
        }
        .formStyle(.grouped)
    }

    private func syncSummary(_ result: ImportResult) -> String {
        var parts = ["\(result.filesRead) \(result.filesRead == 1 ? "file" : "files") read",
                     "\(result.filesUnchanged) unchanged"]
        if result.unreadableFiles > 0 { parts.append("\(result.unreadableFiles) unreadable") }
        return parts.joined(separator: " · ")
    }

    private func quotaText(_ state: ProviderQuotaState) -> String {
        switch state.health {
        case .ok:
            state.lastSuccess.map { "Read \(Countdown.compact(settings.clock.now.seconds(since: $0))) ago" } ?? "Reading…"
        case .degraded(let reason, _): reason
        case .unavailable(let reason): reason
        }
    }
}

// MARK: Notifications

/// What alerts, per provider and window. Permission is asked only by the
/// test button, after the user has chosen what they want to hear about.
private struct NotificationsPane: View {
    @Bindable var settings: SettingsModel
    @State private var daily = ""
    @State private var weekly = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("macOS permission") {
                    HStack(spacing: 10) {
                        Text(permissionText).foregroundStyle(.secondary)
                        Button("Send Test") { Task { await settings.testNotification() } }
                    }
                }
                if settings.permission == .denied {
                    Button("Open Notification Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    .buttonStyle(.link)
                }
            }
            ForEach([ProviderKey.codex, .claudeCode], id: \.self) { provider in
                Section(provider.displayName) {
                    ForEach([QuotaWindowKind.fiveHour, .weekly], id: \.self) { kind in
                        LabeledContent(kind == .fiveHour ? "5-hour window" : "Weekly window") {
                            HStack(spacing: 12) {
                                ForEach(AlertSettings.thresholdChoices, id: \.self) { threshold in
                                    Toggle("\(Int(threshold))%", isOn: thresholdBinding(provider, kind, threshold))
                                        .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }
            }
            Section("Also tell me when") {
                Toggle("A limit is reached", isOn: $settings.alerts.limitReached)
                Toggle("A limit is available again", isOn: $settings.alerts.availableAgain)
                Toggle("A provider resets usage early", isOn: $settings.alerts.providerResets)
                Toggle("Usage is on course to run out before the reset", isOn: $settings.alerts.burnRate)
                Toggle("A limit is close and a banked reset could clear it", isOn: $settings.alerts.bankedResets)
                Toggle("Lifetime usage passes a milestone", isOn: $settings.alerts.milestones)
                Toggle("You earn a medal", isOn: $settings.alerts.achievements)
            }
            Section {
                spendField("Daily equivalent cost over", text: $daily, value: \.dailySpend)
                spendField("Weekly equivalent cost over", text: $weekly, value: \.weeklySpend)
            } header: {
                Text("Spend")
            } footer: {
                Text("At API prices, as the dashboard shows it. Leave empty for no alert.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            daily = settings.alerts.dailySpend.map(Self.dollars) ?? ""
            weekly = settings.alerts.weeklySpend.map(Self.dollars) ?? ""
        }
    }

    private var permissionText: String {
        switch settings.permission {
        case .allowed: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        case nil: "…"
        }
    }

    private func thresholdBinding(_ provider: ProviderKey, _ kind: QuotaWindowKind, _ threshold: Double) -> Binding<Bool> {
        let target = AlertSettings.Target(provider, kind)
        return Binding {
            (settings.alerts.thresholds[target] ?? AlertSettings.defaultThresholds).contains(threshold)
        } set: { on in
            var chosen = Set(settings.alerts.thresholds[target] ?? AlertSettings.defaultThresholds)
            if on { chosen.insert(threshold) } else { chosen.remove(threshold) }
            settings.alerts.thresholds[target] = chosen.sorted()
        }
    }

    private func spendField(_ title: String, text: Binding<String>,
                            value: WritableKeyPath<AlertSettings, Nanodollars?>) -> some View {
        LabeledContent(title) {
            TextField("Off", text: text, prompt: Text("Off"))
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
                .onSubmit {
                    let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
                    settings.alerts[keyPath: value] = trimmed.isEmpty ? nil : Nanodollars(decimalString: trimmed)
                    text.wrappedValue = settings.alerts[keyPath: value].map(Self.dollars) ?? ""
                }
        }
    }

    /// Whole dollars without decimals, cents when there are any.
    static func dollars(_ amount: Nanodollars) -> String {
        let cents = amount.raw / (Nanodollars.perDollar / 100)
        return cents % 100 == 0 ? "\(cents / 100)" : String(format: "%d.%02d", cents / 100, cents % 100)
    }
}

// MARK: Pricing

private struct PricingPane: View {
    @Bindable var settings: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.pricingUpdates) {
                    Text("Fetch new prices daily")
                    Text("A public price list, downloaded with nothing sent but the request.")
                }
                LabeledContent("Price history") {
                    Text(settings.priceVersions.map { "\($0) versions" } ?? "…")
                }
                LabeledContent("Last fetched") {
                    Text(settings.pricesFetchedAt.map { "\(Countdown.compact(settings.clock.now.seconds(since: $0))) ago" }
                         ?? "Using the prices built in")
                }
                HStack {
                    Button("Check Now") { Task { await settings.checkPrices() } }
                        .disabled(!settings.pricingUpdates)
                    if let outcome = settings.pricingOutcome {
                        Text(outcome).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Prices are history: a new price applies from its date on, and past costs are never rewritten.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Privacy

private struct PrivacyPane: View {
    var body: some View {
        Form {
            Section {
                point("internaldrive", "Your usage stays on this Mac.",
                      "No account, no server, no analytics. Burnline downloads public price and update lists, "
                        + "and reads your limits with your tools' own logins. Nothing about you is sent.")
                point("text.badge.xmark", "Burnline never stores what you said.",
                      "It reads token counts, models and times. Prompts, replies and code are never saved.")
                point("folder", "Project paths stay local.", "They name your projects on this Mac and nowhere else.")
                point("key", "Logins are read, never kept.",
                      "To read Claude quota, Burnline reads Claude Code's login for one request and drops it. Nothing is written to your Keychain.")
                point("doc.text.magnifyingglass", "Provider files are read-only.",
                      "Burnline never changes or deletes the files Codex and Claude Code keep.")
            }
        }
        .formStyle(.grouped)
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}
