//
//  DashboardCommands.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import SwiftUI

/// The dashboard in the menus, with its shortcuts: Command-1 to 6 for the
/// areas, Option-Command-1 to 3 for cost, tokens and limits,
/// Command-F for the page's search, Command-[ back from a project or
/// session, and the tour in the Help menu.
public struct DashboardCommands: Commands {
    @Bindable var model: DashboardModel
    @Bindable var settings: SettingsModel
    @Environment(\.openWindow) private var openWindow

    public init(model: DashboardModel, settings: SettingsModel) {
        self.model = model
        self.settings = settings
    }

    public var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Overview") { model.area = .overview }.keyboardShortcut("1")
            Button("Providers") { model.showProviders(tracked: settings.tracked) }
                .keyboardShortcut("2")
                .disabled(settings.tracked.isEmpty)
            Button("Projects") { model.area = .projects }.keyboardShortcut("3")
            Button("Sessions") { model.area = .sessions }.keyboardShortcut("4")
            Button("Activity") { model.area = .activity }.keyboardShortcut("5")
            if settings.showAchievements {
                Button("Achievements") { model.area = .achievements }.keyboardShortcut("6")
            }
            Button("Back") { model.path.removeLast() }
                .keyboardShortcut("[")
                .disabled(model.path.isEmpty)
            Divider()
            Picker("Show", selection: $model.tab) {
                ForEach(Array(DashboardTab.allCases.enumerated()), id: \.element) { index, tab in
                    Text(tab.title)
                        .tag(tab)
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
            }
            .pickerStyle(.inline)
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button("Filter Rows") { model.requestSearch() }.keyboardShortcut("f")
        }
        CommandGroup(after: .help) {
            Button("Burnline Tour") {
                openWindow(id: SceneID.dashboard)
                model.tour.start()
            }
        }
    }
}
