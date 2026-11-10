//
//  FoundMedals.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import SwiftUI

/// The medals an import found in a history the user already had, for setup
/// and Add Provider: the few that matter most, struck in, and how many more
/// wait on the shelves.
struct FoundMedals: View {
    let found: [Achievement]
    var shown = FoundMedals.shown
    var size: CGFloat = 84

    /// How many are shown before the rest are counted.
    static let shown = 4

    @State private var struck = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let calendar = LocalCalendar(timeZone: .current, firstWeekday: .monday)

    var body: some View {
        let picked = Self.significant(found, count: shown)
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(picked.enumerated()), id: \.element.badge.id) { index, medal in
                    VStack(spacing: 8) {
                        MedalView(form: MedalForm(medal.badge.category), metal: medal.badge.metal,
                                  face: MedalFace(medal.badge, tier: medal.achievement.tier), size: size,
                                  secret: medal.badge.secret)
                        Text(medal.badge.title).font(.callout.weight(.semibold))
                            .multilineTextAlignment(.center).lineLimit(2)
                        Text(AchievementText.date(medal.achievement.awardedAt, calendar: calendar))
                            .font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                    .frame(width: size + 40)
                    .scaleEffect(struck || reduceMotion ? 1 : 0.6)
                    .opacity(struck || reduceMotion ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(Double(index) * 0.12), value: struck)
                    .accessibilityElement(children: .combine)
                }
            }
            if found.count > picked.count {
                Text("and \(found.count - picked.count) more on your shelves in Achievements")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { struck = true }
    }

    /// The `count` most significant of `found`: the finest metal, then the
    /// higher grade, then the latest, taking one from each category before a
    /// second from any, so a history of many streaks still shows its range.
    static func significant(_ found: [Achievement], count: Int) -> [(achievement: Achievement, badge: AchievementBadge)] {
        let catalogue = AchievementBadge.catalogue(providers: ProviderKey.trackable)
        let ranked = found.compactMap { achievement in
            catalogue.first { $0.matches(achievement) }.map { (achievement: achievement, badge: $0) }
        }
        .sorted { a, b in
            if a.badge.metal != b.badge.metal { return a.badge.metal > b.badge.metal }
            if (a.badge.grade ?? 0) != (b.badge.grade ?? 0) { return (a.badge.grade ?? 0) > (b.badge.grade ?? 0) }
            return a.achievement.awardedAt > b.achievement.awardedAt
        }
        var picked: [(achievement: Achievement, badge: AchievementBadge)] = []
        var categories: Set<AchievementCategory> = []
        for medal in ranked where picked.count < count && categories.insert(medal.badge.category).inserted {
            picked.append(medal)
        }
        for medal in ranked where picked.count < count && !picked.contains(where: { $0.badge.id == medal.badge.id }) {
            picked.append(medal)
        }
        return picked
    }
}
