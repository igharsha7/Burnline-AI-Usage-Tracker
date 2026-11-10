//
//  ProviderSetup.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import SwiftUI

/// One provider to choose, with whether its tool was found on this Mac. The
/// whole row toggles it: a checkbox where several can be chosen, a radio
/// button where one is.
struct ProviderSetupRow: View {
    let provider: ProviderKey
    let detection: ProviderDetection?
    let selected: Bool
    var several = true
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                ProviderLogo(provider: provider, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.body.weight(.medium))
                    Text(ProviderSetup.status(detection)).font(.caption).foregroundStyle(Palette.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Image(systemName: selected ? (several ? "checkmark.square.fill" : "largecircle.fill.circle")
                                           : (several ? "square" : "circle"))
                    .font(.title3)
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What each provider's setup says, in words.
enum ProviderSetup {
    static func status(_ detection: ProviderDetection?) -> String {
        switch detection {
        case .installed(let directory): "Found · \((directory.path as NSString).abbreviatingWithTildeInPath)"
        case .notInstalled: "Not detected on this Mac"
        case .unavailable(let reason): reason
        case nil: "Looking…"
        }
    }

    static func isFound(_ detection: ProviderDetection?) -> Bool {
        if case .installed = detection { true } else { false }
    }

    /// Where the provider's limits come from, and anything macOS may ask.
    static func quotaNote(_ provider: ProviderKey) -> String {
        switch provider {
        case .claudeCode: "Limits come from your Claude Code sign-in. macOS may ask once to let Burnline read it "
            + "from the Keychain; it is read when needed and never kept."
        case .codex: "Limits come from Codex itself, through the app server it runs on this Mac."
        case .cursor: "Cursor keeps no usage on this Mac yet."
        }
    }
}

/// Adds a provider after the first run: pick one not yet tracked, see
/// whether its tool is on this Mac and what Burnline will read, then import
/// its history, watching it arrive, and see any medals that history earned.
struct AddProviderSheet: View {
    let settings: SettingsModel
    let added: () -> Void

    @State private var candidates: [ProviderKey] = []
    @State private var choice: ProviderKey?
    @State private var phase = Phase.choosing
    /// The medals the import found, once it has finished.
    @State private var medals: [Achievement] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase { case choosing, importing, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a provider").font(Typography.display(22))
                Text("Burnline imports the history the tool keeps on this Mac, then follows new usage as it happens.")
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if candidates.count > 1, phase == .choosing {
                VStack(spacing: 0) {
                    ForEach(candidates, id: \.self) { provider in
                        ProviderSetupRow(provider: provider, detection: settings.detections[provider],
                                         selected: choice == provider, several: false) { choice = provider }
                        if provider != candidates.last { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let choice { steps(choice) }
            if phase == .done, !medals.isEmpty {
                VStack(spacing: 12) {
                    Text(medals.count == 1 ? "Its history earned a medal" : "Its history earned \(medals.count) medals")
                        .font(.headline)
                    FoundMedals(found: medals, shown: 3, size: 64)
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }
            buttons
        }
        .padding(24)
        .frame(width: 480)
        .background(Palette.background)
        .animation(Motion.standard(reduced: reduceMotion), value: phase)
        .animation(Motion.standard(reduced: reduceMotion), value: choice)
        .task {
            candidates = ProviderKey.trackable.filter { !settings.tracked.contains($0) }
            await settings.reload()
            choice = candidates.first { ProviderSetup.isFound(settings.detections[$0]) } ?? candidates.first
        }
    }

    /// Found or not, what limits come from, and the import as it runs.
    private func steps(_ provider: ProviderKey) -> some View {
        let detection = settings.detections[provider]
        let found = ProviderSetup.isFound(detection)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderLogo(provider: provider, size: 26)
                Text(provider.displayName).font(.title3.weight(.semibold))
            }
            step(found ? "checkmark.circle.fill" : "xmark.circle",
                 found ? ProviderSetup.status(detection) : "\(provider.displayName) is not on this Mac yet",
                 found ? "Burnline reads the usage figures in these files, never prompts or code."
                       : "Use \(provider.displayName) once, then check again.")
            step("gauge.with.needle", "Limits", ProviderSetup.quotaNote(provider))
            if phase != .choosing { progress(provider) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Palette.textSecondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func progress(_ provider: ProviderKey) -> some View {
        let sessions = settings.sessions[provider] ?? 0
        let count = "\(sessions.formatted()) \(sessions == 1 ? "session" : "sessions")"
        return HStack(spacing: 10) {
            if phase == .done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.textSecondary).frame(width: 18)
                Text("Imported \(count)")
            } else {
                ProgressView().controlSize(.small).frame(width: 18)
                Text(sessions > 0 ? "Importing… \(count) so far" : "Importing…")
            }
        }
        .monospacedDigit()
        .transition(.opacity)
    }

    private var buttons: some View {
        let found = choice.map { ProviderSetup.isFound(settings.detections[$0]) } ?? false
        return HStack {
            if phase == .choosing, choice != nil, !found {
                Button("Check Again") { Task { await settings.reload() } }
            }
            Spacer()
            switch phase {
            case .choosing:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import History") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!found)
            case .importing:
                Button("Continue in Background") { dismiss() }
            case .done:
                Button("Done") {
                    let shown = medals
                    Task { await settings.celebrate(shown) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func start() {
        guard let choice else { return }
        phase = .importing
        Task {
            // Progress shows while the import runs; tracking returns when it ends.
            let polling = Task {
                while !Task.isCancelled {
                    await settings.reloadProgress()
                    try? await Task.sleep(for: OnboardingView.pollInterval)
                }
            }
            let started = settings.clock.now
            await settings.track([choice])
            polling.cancel()
            // The import may have earned medals, however old its history.
            medals = await settings.foundMedals(since: started)
            added()
            phase = .done
        }
    }
}
