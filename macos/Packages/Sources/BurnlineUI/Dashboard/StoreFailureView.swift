//
//  StoreFailureView.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import BurnlineServices
import SwiftUI
import UniformTypeIdentifiers

/// The ways out of a database that would not open, supplied by the app,
/// which alone knows where the store lives and how to relaunch.
public struct StoreRecovery {
    let databaseFolder: URL
    let backupsFolder: URL
    let stageRestore: @Sendable (URL) throws -> RestorePlan
    let cancelRestore: () -> Void
    let relaunch: () -> Void

    public init(databaseFolder: URL, backupsFolder: URL, stageRestore: @escaping @Sendable (URL) throws -> RestorePlan,
                cancelRestore: @escaping () -> Void, relaunch: @escaping () -> Void) {
        self.databaseFolder = databaseFolder
        self.backupsFolder = backupsFolder
        self.stageRestore = stageRestore
        self.cancelRestore = cancelRestore
        self.relaunch = relaunch
    }

    @concurrent
    static func stage(_ action: @Sendable (URL) throws -> RestorePlan, from backup: URL) async throws -> RestorePlan {
        try action(backup)
    }
}

/// The dashboard when the database did not open: what happened, that
/// nothing was lost, and what to do, in place of a page that would wait
/// for figures forever.
struct StoreFailureView: View {
    let failure: StoreFailure
    let recovery: StoreRecovery?

    @State private var plan: RestorePlan?
    @State private var refusal: String?
    @State private var staging = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            Text(failure.title).font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(failure.explanation)
                .font(.body).foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            actions.padding(.top, 6).disabled(staging)
            if staging { ProgressView("Checking backup…").controlSize(.small) }
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Palette.warning)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { plan != nil },
                                                                          set: { if !$0 { cancel() } })) {
            Button("Restore and Reopen") {
                plan = nil
                recovery?.relaunch()
            }
            Button("Cancel", role: .cancel) { cancel() }
        } message: {
            if let plan { Text(RestoreText.describe(plan)) }
        }
    }

    private var symbol: String {
        switch failure {
        case .diskFull: "externaldrive.badge.exclamationmark"
        case .anotherInstance: "square.on.square"
        case .newerVersion: "arrow.up.circle"
        case .corrupt, .migrationFailed, .other: "exclamationmark.triangle"
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            if let recovery {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([recovery.databaseFolder])
                }
                if failure.offersRestore {
                    Button("Restore a Backup…", action: chooseBackup)
                        .keyboardShortcut(failure.canRetry ? nil : .defaultAction)
                }
                if failure.canRetry {
                    Button("Try Again", action: recovery.relaunch).keyboardShortcut(.defaultAction)
                }
            }
            if !failure.canRetry && !failure.offersRestore {
                Button("Quit Burnline") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    /// Opens on the copies Burnline takes before each update, the likeliest
    /// good one; a backup the user made can be chosen from anywhere.
    private func chooseBackup() {
        guard let recovery else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: "sqlite") ?? .data]
        panel.directoryURL = recovery.backupsFolder
        panel.message = "Choose a Burnline backup folder, or a database file from Burnline's Backups folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        staging = true
        Task {
            defer { staging = false }
            do {
                plan = try await StoreRecovery.stage(recovery.stageRestore, from: url)
                refusal = nil
            } catch {
                refusal = RestoreText.refusal(error)
            }
        }
    }

    private func cancel() {
        plan = nil
        recovery?.cancelRestore()
    }
}

/// While usage is not being saved, a band at the top of every page says so,
/// and that the providers' files still hold it.
struct SavingBanner: View {
    let problems: [(provider: ProviderKey, reason: String)]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(lines.joined(separator: "\n")).font(.callout.weight(.medium))
                Text("What is shown here is safe. New usage stays in the providers’ files and is read once saving works again.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.warning.opacity(0.35)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning. " + lines.joined(separator: " "))
    }

    /// One line per reason, naming every provider it stops: a full disk
    /// stops them all, and says so once.
    private var lines: [String] {
        var order: [String] = []
        var providers: [String: [String]] = [:]
        for problem in problems {
            if providers[problem.reason] == nil { order.append(problem.reason) }
            providers[problem.reason, default: []].append(problem.provider.displayName)
        }
        return order.map { reason in
            "\(providers[reason]!.formatted(.list(type: .and))): \(reason)"
        }
    }
}

/// How a restore is described and refused, wherever one is offered.
enum RestoreText {
    static func describe(_ plan: RestorePlan) -> String {
        let inspection = plan.inspection
        var text = "It holds \(inspection.events.formatted()) events"
        if let earliest = inspection.earliest, let latest = inspection.latest {
            text += " from \(earliest.date.formatted(date: .abbreviated, time: .omitted))"
                + " to \(latest.date.formatted(date: .abbreviated, time: .omitted))"
        }
        text += plan.includesSettings ? ", and your settings. " : ". "
        return text + "Burnline will quit and reopen to replace its history with it. The current database is "
            + "kept beside it, not deleted, and history the providers still keep is imported again."
    }

    /// Why a chosen backup was refused. Nothing was staged.
    static func refusal(_ error: any Error) -> String {
        switch StoreFailure(error) {
        case .corrupt: "This backup is damaged, so it was not restored."
        case .newerVersion: "This backup is from a newer Burnline, so this one cannot restore it."
        case .diskFull: "There is not enough space to restore this backup."
        case .other(let reason): "This backup cannot be restored: \(reason)."
        case .migrationFailed, .anotherInstance: "This backup cannot be restored."
        }
    }
}
