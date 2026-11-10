//
//  CatalogService.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore

/// The projects and sessions usage is grouped by, for the detail views: what
/// they are called, where they were seen, and the user's corrections to them.
///
/// Renaming and merging change only the project rows. Usage is never
/// rewritten, so a merge is undone by `unmerge` exactly.
public struct CatalogService: Sendable {
    let database: BurnlineDatabase

    public init(database: BurnlineDatabase) {
        self.database = database
    }

    /// Every project, merged ones included, most recently seen first.
    public func projects() throws(StoreError) -> [Project] {
        try database.projects.all()
    }

    public func rename(_ project: Int64, to alias: String?) throws(StoreError) {
        try database.projects.rename(project, to: alias)
    }

    public func merge(_ project: Int64, into target: Int64) throws(StoreError) {
        try database.projects.merge(project, into: target)
    }

    public func unmerge(_ project: Int64) throws(StoreError) {
        try database.projects.unmerge(project)
    }

    public func sessions(ids: some Collection<Int64>) throws(StoreError) -> [Session] {
        try database.sessions.sessions(ids: ids)
    }
}
