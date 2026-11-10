//
//  TourTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

@testable import BurnlineUI
import Foundation
import Testing

@MainActor
struct TourTests {
    @Test func `the tour offers itself once, and skipping counts as seen`() {
        let (defaults, name) = SettingsTests.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let tour = TourModel(defaults: defaults)
        tour.startIfNew()
        #expect(tour.index == 0)
        tour.end()
        #expect(tour.index == nil && tour.seen)

        // A later launch reads that it was seen, and does not offer it again.
        let later = TourModel(defaults: defaults)
        later.startIfNew()
        #expect(later.index == nil)
        later.start()
        #expect(later.index == 0)
    }

    @Test func `it walks forward and back within its steps, and ends after the last`() {
        let (defaults, name) = SettingsTests.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let tour = TourModel(defaults: defaults)
        tour.start()
        tour.back()
        #expect(tour.index == 0)
        for _ in 1..<tour.steps.count { tour.next() }
        #expect(tour.current?.id == tour.steps.last?.id)
        tour.next()
        #expect(tour.index == nil && tour.seen)
    }

    @Test func `it visits every area and the limits, and begins and ends on the overview`() {
        let steps = TourStep.all
        let areas = Set(steps.map(\.area))
        #expect(areas.contains(.overview) && areas.contains(.projects) && areas.contains(.sessions)
                    && areas.contains(.activity) && areas.contains(.achievements)
                    && areas.contains { if case .provider = $0 { true } else { false } })
        #expect(steps.contains { $0.tab == .limits })
        #expect(steps.first?.area == .overview && steps.first?.tab == .cost)
        #expect(steps.last?.area == .overview && steps.last?.tab == .cost)
        #expect(Set(steps.map(\.id)).count == steps.count)
    }

    @Test func `pages switched off in Settings are left out of the tour, and come back when switched on`() {
        let (defaults, name) = SettingsTests.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let tour = TourModel(defaults: defaults)
        #expect(tour.steps.map(\.id).contains("achievements") && tour.steps.map(\.id).contains("comparison"))

        defaults.set(false, forKey: ActivityPreferences.showAchievementsKey)
        defaults.set(false, forKey: ActivityPreferences.showComparisonsKey)
        tour.start()
        #expect(!tour.steps.contains { $0.id == "achievements" || $0.id == "comparison" })
        #expect(tour.steps.count == TourStep.all.count - 2)

        defaults.set(true, forKey: ActivityPreferences.showAchievementsKey)
        tour.start()
        #expect(tour.steps.contains { $0.id == "achievements" })
    }
}
