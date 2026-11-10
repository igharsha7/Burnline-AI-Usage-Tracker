//
//  DataPane.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import BurnlineCore
import BurnlineServices
import SwiftUI
import UniformTypeIdentifiers

/// The user's data: where it lives and how long it is kept, export, backup
/// and restore, deletion, repair and diagnostics. Everything here works on
/// Burnline's own copy; the files Codex and Claude Code keep are only read.
struct DataPane: View {
    let settings: SettingsModel

    @State private var pendingDetail: DetailRetention?
    @State private var pendingHistory: HistoryRetention?
    @State private var dataset = ExportDataset.events
    @State private var format = ExportFormat.csv
    @State private var restore: RestorePlan?
    @State private var deleting = false
    @State private var copied = false

    var body: some View {
        Form {
            storage
            retention
            Section("Export") {
                Picker("Contents", selection: $dataset) {
                    Text("Every event in the detail window").tag(ExportDataset.events)
                    Text("15-minute totals for all history").tag(ExportDataset.totals)
                }
                Picker("Format", selection: $format) {
                    Text("CSV").tag(ExportFormat.csv)
                    Text("JSON").tag(ExportFormat.json)
                }
                .pickerStyle(.segmented)
                LabeledContent("Token counts, models, projects, sessions and costs. Never prompts or code.") {
                    Button("Export…", action: export)
                }
                .font(.callout)
            }
            Section {
                LabeledContent("A copy of the database and your settings, to keep or move to another Mac.") {
                    HStack {
                        Button("Restore…", action: chooseRestore)
                        Button("Back Up…", action: backUp)
                    }
                }
                .font(.callout)
            } header: {
                Text("Backup")
            } footer: {
                Text("Time Machine also backs up Burnline when it includes the folder above.")
            }
            Section("Delete") {
                LabeledContent("By provider, project, dates, or everything. The files Codex and Claude Code keep are not touched.") {
                    Button("Delete History…", role: .destructive) { deleting = true }
                }
                .font(.callout)
            }
            Section("Repair") {
                // The button names the action, so the row says only what it does.
                ForEach(RepairAction.allCases, id: \.self) { action in
                    LabeledContent(action.detail) {
                        Button(action.title) { Task { await settings.repair(action) } }
                    }
                    .font(.callout)
                }
                LabeledContent("Versions, sizes, counts and sync results for a bug report. No usage, names or paths.") {
                    Button(copied ? "Copied" : "Copy Diagnostics", action: copyDiagnostics)
                }
                .font(.callout)
            }
            if let outcome = settings.dataOutcome {
                Section {
                    Label(outcome.text, systemImage: outcome.failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(outcome.failed ? Palette.warning : Palette.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(settings.busy)
        .sheet(isPresented: $deleting) { DeleteHistorySheet(settings: settings) }
        .confirmationDialog("Keep full detail for \(pendingDetail.map(Self.title)?.lowercased() ?? "")?",
                            isPresented: Binding(get: { pendingDetail != nil }, set: { if !$0 { pendingDetail = nil } })) {
            Button("Compact Older History", role: .destructive) {
                if let pendingDetail { Task { await settings.change(retention: pendingDetail) } }
                pendingDetail = nil
            }
        } message: {
            Text("""
                Per-event detail older than that is replaced by 15-minute totals now. Totals and charts stay exact, \
                but those sessions leave the Sessions list and their costs can no longer be re-priced. Codex and \
                Claude Code may already have deleted their own copies, so this cannot be undone.
                """)
        }
        .confirmationDialog("Keep \(pendingHistory.map(Self.title)?.lowercased() ?? "") of history?",
                            isPresented: Binding(get: { pendingHistory != nil }, set: { if !$0 { pendingHistory = nil } })) {
            Button("Delete Older History", role: .destructive) {
                if let pendingHistory { Task { await settings.change(history: pendingHistory) } }
                pendingHistory = nil
            }
        } message: {
            Text("""
                Usage older than that is deleted now, totals included, and again each day. Codex and Claude Code \
                may already have deleted their own copies, so it may not come back.
                """)
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restore != nil },
                                                                          set: { if !$0 { cancelRestore() } })) {
            Button("Restore and Reopen", role: .destructive) {
                restore = nil
                settings.relaunch?()
            }
            Button("Cancel", role: .cancel) { cancelRestore() }
        } message: {
            if let restore { Text(RestoreText.describe(restore)) }
        }
    }

    // MARK: Sections

    private var storage: some View {
        Section {
            LabeledContent("Database") {
                HStack(spacing: 6) {
                    Text(settings.databaseBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([settings.databaseDirectory]) }
                        .buttonStyle(.link)
                }
            }
            LabeledContent("Tracking since") {
                Text(settings.trackingStart.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "Nothing yet")
            }
        }
    }

    private var retention: some View {
        Section {
            Picker(selection: Binding(get: { settings.retention }, set: { choice in
                if SettingsModel.shrinks(from: settings.retention, to: choice) { pendingDetail = choice }
                else { Task { await settings.change(retention: choice) } }
            })) {
                ForEach(DetailRetention.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            } label: {
                Text("Keep full detail for")
                Text("Older history is kept as 15-minute totals: every total, chart and cost stays exact.")
            }
            Picker(selection: Binding(get: { settings.history }, set: { choice in
                if SettingsModel.shrinks(from: settings.history, to: choice) { pendingHistory = choice }
                else { Task { await settings.change(history: choice) } }
            })) {
                ForEach(HistoryRetention.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            } label: {
                Text("Keep history for")
                Text("Usage older than this is deleted, totals included.")
            }
        }
    }

    // MARK: Actions

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Burnline \(dataset == .events ? "events" : "totals") "
            + today + "." + format.fileExtension
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let (dataset, format) = (dataset, format)
        Task { await settings.export(dataset, as: format, to: url) }
    }

    private func backUp() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Burnline Backup " + today
        panel.message = "Burnline saves a folder holding the database and your settings."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await settings.backup(to: url) }
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: "sqlite") ?? .data]
        panel.message = "Choose a Burnline backup folder, or a database file from Burnline's Backups folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { restore = await settings.stageRestore(from: url) }
    }

    /// "2026-11-02", for file names.
    private var today: String { settings.clock.now.date.formatted(.iso8601.year().month().day()) }

    private func cancelRestore() {
        restore = nil
        settings.cancelRestore()
    }

    private func copyDiagnostics() {
        Task {
            guard let report = await settings.diagnostics() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            copied = true
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    // MARK: Words

    static func title(_ retention: DetailRetention) -> String {
        switch retention {
        case .ninetyDays: "90 days"
        case .halfYear: "180 days"
        case .year: "1 year"
        case .forever: "Forever"
        }
    }

    static func title(_ history: HistoryRetention) -> String {
        switch history {
        case .forever: "Forever"
        case .oneYear: "1 year"
        case .twoYears: "2 years"
        case .fiveYears: "5 years"
        }
    }
}

/// Choosing what to delete, then confirming it. Every choice names what
/// goes, and nothing is deleted before the second confirmation.
private struct DeleteHistorySheet: View {
    let settings: SettingsModel
    @Environment(\.dismiss) private var dismiss

    enum Kind: Hashable { case provider, project, range, everything }
    @State private var kind = Kind.provider
    @State private var provider = ProviderKey.codex
    @State private var project: Int64?
    /// The last week until the sheet appears and reads the clock.
    @State private var from = Date.distantPast
    @State private var through = Date.distantPast
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete History").font(.title2.weight(.semibold))
            Form {
                Picker("Delete", selection: $kind) {
                    Text("One provider").tag(Kind.provider)
                    Text("One project").tag(Kind.project)
                    Text("A date range").tag(Kind.range)
                    Text("Everything").tag(Kind.everything)
                }
                switch kind {
                case .provider:
                    Picker("Provider", selection: $provider) {
                        ForEach(ProviderKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                case .project:
                    Picker("Project", selection: $project) {
                        Text("Choose…").tag(Int64?.none)
                        ForEach(settings.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                case .range:
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("Through", selection: $through, in: from..., displayedComponents: .date)
                case .everything:
                    EmptyView()
                }
            }
            .formStyle(.grouped)
            Text(consequence).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete…", role: .destructive) { confirming = true }
                    .disabled(scope == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            through = settings.clock.now.date
            from = Calendar.current.date(byAdding: .day, value: -7, to: through) ?? through
        }
        .confirmationDialog("Delete \(target)?", isPresented: $confirming) {
            Button("Delete", role: .destructive) {
                if let scope { Task { await settings.delete(scope) } }
                dismiss()
            }
        } message: {
            Text("This cannot be undone. A backup made first can bring it back.")
        }
    }

    private var scope: DeletionScope? {
        switch kind {
        case .provider: return .provider(provider)
        case .project: return project.map(DeletionScope.project)
        case .range:
            let calendar = Calendar.current
            guard let start = Timestamp(calendar.startOfDay(for: from)),
                  let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through)),
                  let end = Timestamp(next), start < end else { return nil }
            return .range(TimeWindow(start: start, end: end))
        case .everything: return .everything
        }
    }

    private var target: String {
        switch kind {
        case .provider: "all \(provider.displayName) history"
        case .project: "this project's history"
        case .range: "history from \(from.formatted(date: .abbreviated, time: .omitted)) through \(through.formatted(date: .abbreviated, time: .omitted))"
        case .everything: "all of Burnline's history"
        }
    }

    private var consequence: String {
        let common = "Burnline deletes only its own copy and keeps reading new usage. A re-scan from the start "
            + "imports again whatever the providers still keep."
        switch kind {
        case .provider: return "Every \(provider.displayName) event, total, session and quota reading goes. " + common
        case .project: return "The project, those merged into it, and their usage and sessions go. " + common
        case .range: return "Usage in those days goes. In history older than the detail window, only whole quarter hours inside the range can go. " + common
        case .everything: return "Every event, total, session, project, quota reading and achievement goes. Settings stay. " + common
        }
    }
}
