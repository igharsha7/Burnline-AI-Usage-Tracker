//
//  DashboardProjectTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineServices
import BurnlineStore
import BurnlineTestSupport
@testable import BurnlineUI
import Foundation
import Testing

/// Renaming, merging and unmerging projects from a project's page. Each is a
/// redirect or an alias, never a rewrite of usage, so every one can be undone.
struct DashboardProjectTests {
    static let now = StatusModelTests.now
    static let utc = StatusModelTests.utc

    struct Fixture {
        let model = DashboardModel(clock: ManualClock(DashboardProjectTests.now), defaults: DashboardTests.defaults())
        let api: Int64
        let web: Int64

        /// Two projects with a session each.
        init() async throws {
            let clock = ManualClock(DashboardProjectTests.now)
            let database = try BurnlineDatabase.open(
                at: StoreLocation(directory: TestDirectory.make("DashboardProjects")),
                schema: Schema(directory: StatusModelTests.repositoryRoot.appending(path: "shared/schema")),
                clock: clock)
            let records = try ["acme-api", "acme-web"].map { name in
                IncomingUsage(sourceEventID: name, sessionSourceID: name,
                              project: ProjectCandidate(identity: .gitRemote("github.com/acme/\(name)"),
                                                        displayName: name, path: "/work/\(name)"),
                              rawModel: "gpt-5.5", timestamp: DashboardProjectTests.now.adding(seconds: -60),
                              tokens: try TokenCounts(output: 100), sourceType: "test", file: "/a.jsonl",
                              schemaVersion: nil, offset: 0)
            }
            try database.ingest(records, issues: [], provider: .codex)
            let aggregation = AggregationService(database: database, calendar: DashboardProjectTests.utc, clock: clock)
            model.connect(aggregation: aggregation, catalog: CatalogService(database: database),
                          activity: ActivityService(database: database, aggregation: aggregation,
                                                    calendar: DashboardProjectTests.utc, clock: clock),
                          changes: ChangeFeed(), health: { [:] }, calendar: DashboardProjectTests.utc, comparisons: nil)
            // Connecting starts its own catalog read; wait for it to land.
            let model = model
            #expect(await eventually { model.projects.count == 2 })
            let projects = model.projects
            api = try #require(projects.first { $0.identity == .gitRemote("github.com/acme/acme-api") }).id
            web = try #require(projects.first { $0.identity == .gitRemote("github.com/acme/acme-web") }).id
        }

        func project(_ id: Int64) -> Project? { model.projects.first { $0.id == id } }
    }

    @Test func `a project is named readably, renamed to the user's alias, and back`() async throws {
        let fixture = try await Fixture()
        #expect(fixture.model.name(ofProject: fixture.api) == "Acme Api")

        fixture.model.rename(project: fixture.api, to: "Billing")
        #expect(await eventually { fixture.model.name(ofProject: fixture.api) == "Billing" })

        fixture.model.rename(project: fixture.api, to: nil)
        #expect(await eventually { fixture.model.name(ofProject: fixture.api) == "Acme Api" })
    }

    @Test func `EC-P7 merging redirects a project and drops its filter, and unmerging undoes it`() async throws {
        let fixture = try await Fixture()
        fixture.model.filter(project: fixture.api)
        #expect(fixture.model.filters.projects[fixture.api] != nil)

        fixture.model.merge(project: fixture.api, into: fixture.web)
        #expect(fixture.model.filters.projects[fixture.api] == nil)
        #expect(await eventually { fixture.project(fixture.api)?.mergedIntoID == fixture.web })
        #expect(fixture.model.rootProjects.map(\.id) == [fixture.web])

        fixture.model.unmerge(project: fixture.api)
        #expect(await eventually { fixture.project(fixture.api)?.mergedIntoID == nil })
        #expect(Set(fixture.model.rootProjects.map(\.id)) == [fixture.api, fixture.web])
    }

    @Test func `EC-P7 a merge that would make a loop is refused and says so`() async throws {
        let fixture = try await Fixture()
        fixture.model.merge(project: fixture.api, into: fixture.web)
        #expect(await eventually { fixture.project(fixture.api)?.mergedIntoID == fixture.web })

        fixture.model.merge(project: fixture.web, into: fixture.api)

        #expect(await eventually { fixture.model.failure != nil })
        #expect(fixture.project(fixture.web)?.mergedIntoID == nil)
        #expect(fixture.project(fixture.api)?.mergedIntoID == fixture.web)
    }
}
