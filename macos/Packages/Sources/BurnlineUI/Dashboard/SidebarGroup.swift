//
//  SidebarGroup.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit

/// Opens and closes the sidebar's group by pressing its own disclosure
/// chevron. A sidebar `DisclosureGroup` animates when its chevron is
/// clicked, but not when its binding changes, nor when the outline view is
/// told to expand from code; pressing the chevron takes the clicked path.
/// The sidebar has one group, so it is the outline view's one expandable row.
enum SidebarGroup {
    /// Toggles the group in `window`; false when no chevron was found, so
    /// the caller can change its binding instead.
    static func toggle(in window: NSWindow?) -> Bool {
        guard let content = window?.contentView else { return false }
        for outline in views(NSOutlineView.self, in: content) {
            for row in 0..<outline.numberOfRows {
                guard let item = outline.item(atRow: row), outline.isExpandable(item),
                      let rowView = outline.rowView(atRow: row, makeIfNecessary: false),
                      let chevron = views(NSButton.self, in: rowView)
                          .first(where: { $0.identifier == NSOutlineView.disclosureButtonIdentifier }) else { continue }
                chevron.performClick(nil)
                return true
            }
        }
        return false
    }

    private static func views<V: NSView>(_ type: V.Type, in view: NSView) -> [V] {
        view.subviews.flatMap { subview -> [V] in
            let own: [V] = (subview as? V).map { [$0] } ?? []
            return own + views(type, in: subview)
        }
    }
}
