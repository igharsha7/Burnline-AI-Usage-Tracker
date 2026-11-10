//
//  ActivityModelTests.swift
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

/// The activity page's model: what it loads, how it follows new usage, and
/// medals that play once.
struct ActivityModelTests {
    static let now = StatusModelTests.now
    static let utc = StatusModelTests.utc

    struct Fixture {
        let model = DashboardModel(clock: ManualClock(ActivityModelTests.now), defaults: DashboardTests.defaults())
        let feed = ChangeFeed()
        let database: BurnlineDatabase

        /// One event `daysAgo` before now for each entry.
        init(daysAgo: [Int64]) throws {
            let clock = ManualClock(ActivityModelTests.now)
            database = try BurnlineDatabase.open(
                at: StoreLocation(directory: TestDirectory.make("ActivityModel")),
                schema: Schema(directory: StatusModelTests.repositoryRoot.appending(path: "shared/schema")),
                clock: clock)
            try ingest(daysAgo.map { ("e\($0)", ActivityModelTests.now.adding(seconds: -$0 * 86_400 - 60)) })
            let aggregation = AggregationService(database: database, calendar: ActivityModelTests.utc, clock: clock)
            model.connect(aggregation: aggregation, catalog: CatalogService(database: database),
                          activity: ActivityService(database: database, aggregation: aggregation,
                                                    calendar: ActivityModelTests.utc, clock: clock),
                          changes: feed, health: { [:] }, calendar: ActivityModelTests.utc, comparisons: nil)
        }

        func ingest(_ events: [(id: String, at: Timestamp)]) throws {
            try database.ingest(events.map { id, at in
                IncomingUsage(sourceEventID: id, sessionSourceID: id, project: nil, rawModel: "gpt-5.5",
                              timestamp: at, tokens: try TokenCounts(output: 100), sourceType: "test",
                              file: "/a.jsonl", schemaVersion: nil, offset: 0)
            }, issues: [], provider: .codex)
        }

        /// Follows the page as it would on screen, until the returned task is cancelled.
        func follow() -> Task<Void, Never> {
            let activity = model.activity
            return Task { await activity.follow() }
        }
    }

    @Test func `following loads every tracked day, and the range trims what the heatmap shows`() async throws {
        let fixture = try Fixture(daysAgo: [0, 100, 200])
        let page = fixture.follow()
        defer { page.cancel() }
        let activity = fixture.model.activity

        #expect(await eventually { activity.snapshot != nil })
        #expect(activity.snapshot?.days.count == 201)
        #expect(activity.snapshot?.lifetime.events == 3)
        #expect(activity.failure == nil)

        activity.range = .threeMonths
        #expect(activity.visibleDays.count == 91)
        #expect(activity.visibleDays.last?.totals.events == 1)
        activity.range = .all
        #expect(activity.visibleDays.count == 201)
    }

    @Test(.timeLimit(.minutes(1)))
    func `new usage pushed while following is shown once the reload settles`() async throws {
        let fixture = try Fixture(daysAgo: [0])
        let page = fixture.follow()
        defer { page.cancel() }
        let activity = fixture.model.activity
        #expect(await eventually { activity.snapshot?.lifetime.events == 1 })

        try fixture.ingest([("later", Self.now.adding(seconds: -5))])
        fixture.feed.send(.usage(.codex))

        // Reloads are gathered for a few seconds, so a burst of writes reads once.
        #expect(await eventually(within: 10) { activity.snapshot?.lifetime.events == 2 })
    }

    @Test(.timeLimit(.minutes(1)))
    func `a medal's arrival plays once: celebrated, it is no longer new`() async throws {
        let fixture = try Fixture(daysAgo: [0])
        let medal = Achievement(kind: .streak, tier: "7", value: 7, awardedAt: Self.now)
        try fixture.database.achievements.award([medal], at: Self.now)
        let page = fixture.follow()
        defer { page.cancel() }
        let activity = fixture.model.activity
        // Loading also awards what the history has earned, beside the streak.
        #expect(await eventually { activity.snapshot?.uncelebrated.contains { $0.kind == .streak } == true })
        let fresh = activity.snapshot?.uncelebrated ?? []
        #expect(fixture.model.newMedals == fresh.count)

        activity.celebrated(fresh)

        #expect(await eventually { activity.snapshot?.uncelebrated.isEmpty == true })
        #expect(fixture.model.newMedals == 0)
        // Played, not lost: every medal is still on the shelf.
        #expect(activity.snapshot?.achievements.count == fresh.count)
    }
}
