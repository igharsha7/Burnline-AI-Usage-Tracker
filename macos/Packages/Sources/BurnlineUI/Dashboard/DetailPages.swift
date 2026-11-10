//
//  DetailPages.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import SwiftUI

/// One provider: its health, its limits and live activity, then its figures.
/// A provider whose usage cannot be measured shows why instead, and is left
/// out of every figure rather than drawn at zero.
struct ProviderPage: View {
    let model: DashboardModel
    let status: StatusModel
    let provider: ProviderKey

    var body: some View {
        if case .unavailable(let reason)? = model.health[provider] {
            Page {
                ContentUnavailableView {
                    Label("\(provider.displayName) cannot be measured", systemImage: "eye.slash")
                } description: {
                    Text("\(reason) Its usage is left out of every figure, not counted as zero.")
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            }
        } else {
            ScopePage(model: model, scope: model.scope(.provider(provider))) {
                VStack(alignment: .leading, spacing: 24) {
                    if let health = model.health[provider] {
                        Label(HealthText.long(health, now: model.clock.now),
                              systemImage: health.isDegraded ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(health.isDegraded ? Palette.warning : Palette.textSecondary)
                    }
                    if let live = status.live, live.provider == provider {
                        Card { LiveRow(live: live) }
                    }
                    LimitsView(status: status, only: provider)
                }
            }
        }
    }
}

extension ProviderHealth {
    var isDegraded: Bool {
        if case .degraded = self { return true }
        return false
    }
}

/// A page that is one table: every project, or every session, in the range,
/// a screenful at a time.
struct ListPage: View {
    let model: DashboardModel
    let scope: ScopeModel
    let note: String

    @State private var height: CGFloat = 0
    @State private var rowsTop: CGFloat = 0

    static let space = "listPage"
    /// The height a row takes with the space after it, and what the page
    /// spends below its rows in the card: the pager and the card's padding.
    static let rowHeight: CGFloat = 48
    static let below: CGFloat = 72
    static let fewestRows = 5

    /// As many rows as fit between where they begin and the window's foot.
    /// Where they begin is measured in the content, so it holds still while
    /// the page scrolls.
    private var pageSize: Int {
        max(Self.fewestRows, Int((height - PageInsets.top - rowsTop - Self.below - PageInsets.bottom) / Self.rowHeight))
    }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 20) {
                FilterBar(model: model, scope: scope.scope)
                Text(note).font(.callout).foregroundStyle(Palette.textSecondary)
                if let data = scope.data {
                    Card {
                        BreakdownSection(model: model, scope: scope, width: data.series.width,
                                         title: "\(scope.table(.ranked(scope.breakdown ?? .project, model.metric))?.lines.count ?? 0) in \(model.rangeLabel.lowercased())",
                                         pageSize: pageSize, rowsTop: { rowsTop = $0 })
                    }
                    .tourTarget(.list)
                } else if let failure = scope.failure {
                    ContentUnavailableView("Usage could not be read", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView("Reading usage…").controlSize(.small).frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .task(id: FollowKey(scope: scope.scope, query: model.query)) { await scope.follow(model.query) }
    }
}

struct ProjectsPage: View {
    let model: DashboardModel

    var body: some View {
        ListPage(model: model, scope: model.scope(.projects),
                 note: "A project is a repository, or a folder outside one. Open one to rename it or merge it with another.")
    }
}

struct SessionsPage: View {
    let model: DashboardModel

    var body: some View {
        ListPage(model: model, scope: model.scope(.sessions),
                 note: "Sessions are listed for the detail window; older history is kept as totals only.")
    }
}

/// One project: what it is, the corrections the user can make to it, and
/// its figures. Merging and unmerging only redirect, so both are undoable
/// and no usage is rewritten.
struct ProjectPage: View {
    let model: DashboardModel
    let id: Int64

    @State private var renaming = false
    @State private var alias = ""

    private var project: Project? { model.projects.first { $0.id == id } }

    var body: some View {
        ScopePage(model: model, scope: model.scope(.project(id))) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.name(ofProject: id)).font(Typography.display(28)).lineLimit(1)
                    Spacer()
                    Button("Rename…") {
                        alias = project?.userAlias ?? ""
                        renaming = true
                    }
                    mergeMenu
                }
                if let project {
                    details(project)
                }
            }
        }
        .navigationTitle(model.name(ofProject: id))
        .alert("Rename project", isPresented: $renaming) {
            TextField(project?.derivedName ?? "Name", text: $alias)
            Button("Rename") { model.rename(project: id, to: alias) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to use \(project?.derivedName ?? "the name Burnline found").")
        }
    }

    @ViewBuilder private func details(_ project: Project) -> some View {
        let calendar = model.calendar, now = model.clock.now
        VStack(alignment: .leading, spacing: 6) {
            if let path = project.lastKnownPath {
                Text(path).font(.callout.monospaced()).foregroundStyle(Palette.textSecondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Text("First seen \(BucketLabel.moment(project.firstSeenAt, calendar: calendar, now: now)) · "
                 + "last seen \(BucketLabel.moment(project.lastSeenAt, calendar: calendar, now: now))")
                .font(.callout).foregroundStyle(Palette.textSecondary)
            if let target = project.mergedIntoID {
                HStack(spacing: 8) {
                    Text("Merged into \(model.name(ofProject: target)); its usage counts there.")
                    Button("Unmerge") { model.unmerge(project: id) }.buttonStyle(.link)
                }
                .font(.callout)
            }
            let merged = model.projects.filter { $0.mergedIntoID == id }
            if !merged.isEmpty {
                HStack(spacing: 8) {
                    Text("Includes").foregroundStyle(Palette.textSecondary)
                    ForEach(merged) { other in
                        HStack(spacing: 4) {
                            Text(other.name)
                            Button("Unmerge") { model.unmerge(project: other.id) }.buttonStyle(.link)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    /// Merging this project into another: for one repository that Burnline
    /// saw as two, such as after it moved without a remote.
    private var mergeMenu: some View {
        Menu("Merge Into") {
            ForEach(model.rootProjects.filter { $0.id != id }) { other in
                Button(other.name) {
                    model.merge(project: id, into: other.id)
                    model.path.removeLast()
                }
            }
        }
        .fixedSize()
        .disabled(project?.mergedIntoID != nil)
        .help("Count this project's usage as part of another. Unmerge undoes it.")
    }
}

/// One session: its provider and project, when it ran, and its figures over
/// that span alone. Burnline shows usage, never what was said.
struct SessionPage: View {
    let model: DashboardModel
    let id: Int64

    var body: some View {
        let scope = model.scope(.session(id))
        ScopePage(model: model, scope: scope) {
            if let session = scope.session {
                header(session)
            }
        }
        .navigationTitle("Session")
        // The page spans the session, not the toolbar's range.
        .navigationSubtitle(scope.session.map { "From " + BucketLabel.moment($0.startedAt, calendar: model.calendar,
                                                                            now: model.clock.now) } ?? "")
    }

    private func header(_ session: Session) -> some View {
        let calendar = model.calendar, now = model.clock.now
        let end = session.endedAt ?? session.startedAt
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Palette.accent(session.provider)).frame(width: 8, height: 8)
                Text(session.projectID.map(model.name(ofProject:)) ?? "No project").font(Typography.display(28))
            }
            Text("\(session.provider.displayName) · \(BucketLabel.moment(session.startedAt, calendar: calendar, now: now)) "
                 + "to \(BucketLabel.moment(end, calendar: calendar, now: now)) · "
                 + Countdown.compact(end.seconds(since: session.startedAt)))
                .font(.callout).foregroundStyle(Palette.textSecondary)
            Text(session.sourceSessionID).font(.caption.monospaced()).foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
        }
    }
}
