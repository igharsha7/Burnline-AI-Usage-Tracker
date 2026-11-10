//
//  AchievementsPage.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import SwiftUI

/// Every medal, earned or not, shelf by shelf, with this month's challenge
/// and the personal records; or, under History, everything earned in the
/// order it happened. A medal opens its detail, where it can be turned over.
struct AchievementsPage: View {
    let model: DashboardModel

    enum Mode: Hashable { case medals, history }

    @State private var mode = Mode.medals
    @State private var selected: AchievementBadge?
    @Environment(SettingsModel.self) private var settings: SettingsModel?
    /// New medals whose arrival is playing.
    @State private var arriving: Arrival?
    /// The arrivals captured for the current sheet. A later award must not be
    /// marked celebrated when this sheet closes.
    @State private var presented = MedalArrivalProgress(achievements: [])
    /// Medals the user closed the arrival before reaching. They stay
    /// uncelebrated, and play the next time the page opens, not at once.
    @State private var skipped: Set<Achievement> = []

    struct Arrival: Identifiable {
        let achievements: [Achievement]
        var id: [Achievement] { achievements }
    }

    var body: some View {
        let activity = model.activity
        Page {
            VStack(alignment: .leading, spacing: 20) {
                if let snapshot = activity.snapshot, let shelf = activity.shelf {
                    AchievementsHeader(shelf: shelf, mode: $mode).arrival(0)
                    switch mode {
                    case .medals:
                        Card { ChallengeCard(challenge: snapshot.challenge, shelf: shelf, select: select) }.arrival(1)
                        ForEach(Array(shelf.categories.enumerated()), id: \.element) { index, category in
                            Card { ShelfSection(category: category, shelf: shelf, calendar: model.calendar, select: select) }
                                .arrival(min(index + 2, 6))
                        }
                        if let records = snapshot.records {
                            Card { RecordsSection(records: records, calendar: model.calendar) }.arrival(6)
                        }
                    case .history:
                        Card { HistorySection(shelf: shelf, calendar: model.calendar, select: select) }.arrival(1)
                    }
                } else if let failure = activity.failure {
                    ContentUnavailableView("Achievements could not be read", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView("Reading achievements…").controlSize(.small).frame(maxWidth: .infinity, minHeight: 360)
                }
            }
        }
        .task(id: model.refreshes) { await activity.follow() }
        // New medals arrive whenever the page shows them: on opening, from
        // a notification's click, or as usage earns one while it is open.
        .onChange(of: activity.snapshot?.uncelebrated, initial: true) { _, fresh in
            let waiting = (fresh ?? []).filter { !skipped.contains($0) }
            guard !waiting.isEmpty, arriving == nil, selected == nil else { return }
            presented = MedalArrivalProgress(achievements: waiting)
            arriving = Arrival(achievements: waiting)
        }
        .background {
            Color.clear.sheet(item: $arriving, onDismiss: {
                let celebrated = presented.shown
                skipped.formUnion(presented.achievements.dropFirst(celebrated.count))
                presented = MedalArrivalProgress(achievements: [])
                activity.celebrated(celebrated)
            }) { _ in
                if let shelf = activity.shelf {
                    MedalArrival(progress: $presented, shelf: shelf,
                                 calendar: model.calendar, name: settings?.engravedName)
                }
            }
        }
        .sheet(item: $selected) { badge in
            if let shelf = activity.shelf {
                MedalDetail(badge: badge, shelf: shelf, calendar: model.calendar,
                            comparisons: model.comparisons, name: settings?.engravedName)
            }
        }
    }

    private func select(_ badge: AchievementBadge) { selected = badge }
}

/// The snapshot's achievements arranged for the shelves: each medal with
/// the times it was earned and, for a habit, how far the next has come.
struct AchievementShelf {
    let catalogue: [AchievementBadge]
    let achievements: [Achievement]
    let progress: [AchievementProgress]
    let challenge: MonthlyChallenge?
    /// Every streak run, for how often each streak medal was reached.
    let streakRuns: [StreakRun]

    /// Each medal's earned instances, and each instance's medal, matched
    /// once rather than for every tile and row that asks.
    private let earnedByBadge: [AchievementBadge: [Achievement]]
    private let badgeByAchievement: [Achievement: AchievementBadge]

    init(_ snapshot: ActivitySnapshot) {
        catalogue = snapshot.catalogue
        achievements = snapshot.achievements
        progress = snapshot.progress
        challenge = snapshot.challenge
        streakRuns = snapshot.streaks.runs
        var badges: [Achievement: AchievementBadge] = [:]
        for achievement in achievements {
            badges[achievement] = catalogue.first { $0.matches(achievement) }
        }
        badgeByAchievement = badges
        earnedByBadge = Dictionary(grouping: achievements.filter { badges[$0] != nil }) { badges[$0]! }
    }

    /// The shelves, in the order the page shows them. Monthly challenges
    /// have their own card.
    var categories: [AchievementCategory] { AchievementCategory.allCases.filter { $0 != .monthly } }

    func badges(_ category: AchievementCategory) -> [AchievementBadge] {
        catalogue.filter { $0.category == category }
    }

    /// Every time `badge` was earned, oldest first.
    func earned(_ badge: AchievementBadge) -> [Achievement] {
        earnedByBadge[badge] ?? []
    }

    /// How many separate streaks reached a streak medal's length. The medal
    /// is awarded once, the first time; this counts every time since.
    func reached(_ badge: AchievementBadge) -> Int {
        guard badge.kind == .streak, let days = badge.threshold else { return 0 }
        return streakRuns.count { Int64($0.length) >= days }
    }

    /// The longest streak, in days.
    var longestStreak: Int { streakRuns.map(\.length).max() ?? 0 }

    /// What an earned medal is made of: "Gold II", or a monthly medal's stone.
    func material(_ badge: AchievementBadge) -> String {
        badge.stone.flatMap(MetalPalette.stoneName) ?? badge.metalName
    }

    func progress(_ badge: AchievementBadge) -> AchievementProgress? {
        progress.first { $0.badge == badge }
    }

    func badge(for achievement: Achievement) -> AchievementBadge? {
        badgeByAchievement[achievement]
    }

    var earnedCount: Int { catalogue.count { !earned($0).isEmpty } }

    /// Medals earned by metal, the repeatable ones counted each time.
    var tally: [(Metal, Int)] {
        Metal.allCases.compactMap { metal in
            let count = achievements.count { badge(for: $0)?.metal == metal }
            return count > 0 ? (metal, count) : nil
        }
    }

    /// What an earned instance is called: a repeatable one names its period.
    func title(_ achievement: Achievement, calendar: LocalCalendar) -> String {
        guard let badge = badge(for: achievement) else { return achievement.kind.rawValue }
        switch achievement.kind {
        case .monthly: return "\(badge.title) · \(AchievementText.month(achievement.tier) ?? achievement.tier)"
        case .perfectWeek, .hotCache:
            return "\(badge.title) · week of \(AchievementText.day(achievement.tier, calendar: calendar) ?? achievement.tier)"
        case .yearOfBuilding: return "\(badge.title) · \(achievement.tier)"
        default: return badge.title
        }
    }
}

enum AchievementText {
    /// The Gregorian calendar in the user's locale; without a locale its
    /// month symbols are "M01"…"M12".
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        return calendar
    }()

    /// "2026-11" as "November 2026".
    static func month(_ tier: String) -> String? {
        let parts = tier.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return nil }
        return "\(calendar.monthSymbols[parts[1] - 1]) \(parts[0])"
    }

    /// "2026-11-02" as "2 Nov".
    static func day(_ tier: String, calendar: LocalCalendar) -> String? {
        let parts = tier.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return BucketLabel.date(Timestamp(epochSeconds: Int64(date.timeIntervalSince1970)), "dMMM", calendar: calendar)
    }

    static func date(_ instant: Timestamp, calendar: LocalCalendar) -> String {
        BucketLabel.date(instant, "yMMMd", calendar: calendar)
    }
}

// MARK: - Header

private struct AchievementsHeader: View {
    let shelf: AchievementShelf
    @Binding var mode: AchievementsPage.Mode

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(shelf.earnedCount) of \(shelf.catalogue.count) medals")
                    .font(Typography.display(26))
                HStack(spacing: 14) {
                    ForEach(shelf.tally, id: \.0) { metal, count in
                        HStack(spacing: 6) {
                            MedalView(form: .disc, metal: metal, face: MedalFace(symbol: "flame.fill"), size: 18)
                            Text("\(count)").monospacedDigit()
                        }
                        .help("\(count) \(metal.name)")
                    }
                }
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            SegmentedChoice(options: [(.medals, "Medals"), (.history, "History")], selection: $mode)
        }
    }
}

// MARK: - Shelves

/// One shelf: the eight medals around where the climb stands on it, the
/// latest earned and the next to reach, larger, with the rest a click away.
private struct ShelfSection: View {
    let category: AchievementCategory
    let shelf: AchievementShelf
    let calendar: LocalCalendar
    let select: (AchievementBadge) -> Void

    @State private var showsAll = false

    /// How many medals a shelf shows before "View all".
    static let shown = 8
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 4)

    var body: some View {
        let badges = shelf.badges(category)
        let visible = showsAll ? badges[...] : AchievementShelf.window(badges, shown: Self.shown) { !shelf.earned($0).isEmpty }
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: category.title,
                          detail: "\(badges.count { !shelf.earned($0).isEmpty }) of \(badges.count)")
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(visible) { badge in
                    MedalTile(badge: badge, earned: shelf.earned(badge), progress: shelf.progress(badge),
                              calendar: calendar, times: max(shelf.earned(badge).count, shelf.reached(badge)),
                              size: 92) {
                        select(badge)
                    }
                }
            }
            if badges.count > Self.shown {
                // Instant: medals join on both sides of the eight, so an
                // animated reflow would slide them across one another.
                Button(showsAll ? "Show fewer" : "View all \(badges.count)") { showsAll.toggle() }
                .buttonStyle(.borderless)
                .font(.callout.weight(.medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

extension AchievementShelf {
    /// `shown` of `badges` around the first not yet earned: half of them the
    /// latest earned before it, the rest the next to reach, slid to stay in
    /// range, so a shelf opens where the climb stands.
    static func window(_ badges: [AchievementBadge], shown: Int,
                       earned: (AchievementBadge) -> Bool) -> ArraySlice<AchievementBadge> {
        guard badges.count > shown else { return badges[...] }
        let frontier = badges.firstIndex { !earned($0) } ?? badges.count
        let start = max(0, min(frontier - shown / 2, badges.count - shown))
        return badges[start..<(start + shown)]
    }
}

/// A medal on its shelf: earned, it shows its metal and when, and opens
/// to its detail; not yet, it is cast in iron with what it asks, a habit
/// shows how far it has come, and the pointer over it brings up a short
/// card instead of a detail with nothing to turn over.
struct MedalTile: View {
    let badge: AchievementBadge
    let earned: [Achievement]
    let progress: AchievementProgress?
    let calendar: LocalCalendar
    /// How many times it was earned or, for a streak, reached.
    var times = 0
    var size: CGFloat = 76
    let open: () -> Void

    @State private var shine: CGFloat = -1
    /// The pointer's lean over the tile, -1 to 1 on each axis.
    @State private var lean = CGSize.zero
    @State private var tileWidth: CGFloat = 1
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far, in degrees, the pointer tilts a medal toward itself.
    private static let tilt = 16.0

    var body: some View {
        let isEarned = !earned.isEmpty
        let hidden = badge.secret && !isEarned
        Group {
            if isEarned {
                Button(action: open) { tile(isEarned: true, hidden: false) }
                    .buttonStyle(PressableStyle())
            } else {
                tile(isEarned: false, hidden: hidden)
                    .overlay(alignment: .top) {
                        if hovering { hoverCard(hidden: hidden).padding(.top, size * 0.28) }
                    }
                    .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
            }
        }
        .onContinuousHover { phase in
            // Only an earned medal turns to the pointer and catches the light;
            // an unearned one stays still, and costs no redraws.
            guard !reduceMotion, isEarned else { return }
            switch phase {
            case .active(let point):
                if lean == .zero {
                    shine = -1
                    withAnimation(.easeInOut(duration: 0.8)) { shine = 2 }
                }
                // Measured from the medal's middle, at the top of the tile.
                let x = point.x / max(1, tileWidth) * 2 - 1, y = (point.y - size / 2) / (size / 2)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    lean = CGSize(width: max(-1, min(1, x)), height: max(-1, min(1, y)))
                }
            case .ended:
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { lean = .zero }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tileWidth = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hidden ? "Secret achievement" : badge.title)
        .accessibilityValue(isEarned ? "Earned \(AchievementText.date(earned.last!.awardedAt, calendar: calendar))"
                                     : hidden ? "Not yet earned" : badge.requirement)
    }

    private func tile(isEarned: Bool, hidden: Bool) -> some View {
        VStack(spacing: 8) {
            MedalView(form: MedalForm(badge.category), metal: isEarned ? badge.metal : nil,
                      face: MedalFace(badge, tier: earned.last?.tier), size: size, secret: badge.secret,
                      shine: shine, light: CGSize(width: lean.width, height: -lean.height))
                .modifier(Tilt(yaw: lean.width * Self.tilt, pitch: -lean.height * Self.tilt))
                .overlay(alignment: .bottomTrailing) {
                    if times > 1 {
                        Text("×\(times)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Palette.textPrimary, in: Capsule())
                            .foregroundStyle(Palette.background)
                            .offset(x: 6, y: 2)
                    }
                }
            Text(hidden ? "Secret" : badge.title)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(isEarned ? Palette.textPrimary : Palette.textSecondary)
            caption(isEarned: isEarned, hidden: hidden)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// What an unearned medal asks, and how far along it is, in a line or two.
    private func hoverCard(hidden: Bool) -> some View {
        VStack(spacing: 3) {
            Text(hidden ? "A secret. It shows itself when you earn it." : badge.requirement)
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.textPrimary)
            if let progress {
                Text("\(Format.figure(progress.current)) of \(Format.figure(progress.target)) · \(Int((progress.fraction * 100).rounded()))%")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: max(140, tileWidth - 8))
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    @ViewBuilder
    private func caption(isEarned: Bool, hidden: Bool) -> some View {
        if let last = earned.last {
            Text(AchievementText.date(last.awardedAt, calendar: calendar))
                .font(.caption).foregroundStyle(Palette.textSecondary)
        } else if let progress {
            VStack(spacing: 4) {
                ProgressView(value: progress.fraction).tint(Palette.textPrimary).frame(width: size)
                Text("\(Format.figure(progress.current)) of \(Format.figure(progress.target))")
                    .font(.caption).monospacedDigit().foregroundStyle(Palette.textSecondary)
            }
        } else {
            Text(hidden ? "Found by doing." : badge.requirement)
                .font(.caption).foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center).lineLimit(3)
        }
    }
}

// MARK: - Monthly challenge

/// This month's challenge and how it stands, then every month's medal on
/// the schedule, a year to a row, each set in its birthstone once earned.
private struct ChallengeCard: View {
    let challenge: MonthlyChallenge?
    let shelf: AchievementShelf
    let select: (AchievementBadge) -> Void

    var body: some View {
        let badges = shelf.badges(.monthly)
        let years = Dictionary(grouping: badges) { $0.tier.flatMap(MonthlyChallenge.month)?.year ?? 0 }
        let completed = badges.count { !shelf.earned($0).isEmpty }
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: AchievementCategory.monthly.title,
                          detail: completed == 0 ? "A new challenge every month" : "\(completed) of \(badges.count) completed")
            if let challenge, let badge = badges.first(where: { $0.tier == challenge.tier }) {
                current(challenge, badge)
            }
            ForEach(years.keys.sorted(), id: \.self) { year in
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(year)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10, alignment: .top)], spacing: 14) {
                        ForEach(years[year] ?? []) { badge in month(badge) }
                    }
                }
            }
        }
    }

    private func current(_ challenge: MonthlyChallenge, _ badge: AchievementBadge) -> some View {
        let earned = !shelf.earned(badge).isEmpty
        return Button { select(badge) } label: {
            HStack(alignment: .center, spacing: 18) {
                MedalView(form: .seal, metal: earned ? badge.metal : nil, face: MedalFace(badge), size: 84)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(AchievementText.month(challenge.tier) ?? challenge.tier) · \(badge.title)")
                        .font(.title3.weight(.semibold))
                    Text(challenge.summary).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ChallengeStatus(challenge: challenge)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func month(_ badge: AchievementBadge) -> some View {
        let earned = !shelf.earned(badge).isEmpty
        let isCurrent = badge.tier == challenge?.tier
        let stone = badge.stone.flatMap(MetalPalette.stoneName)
        return Button { select(badge) } label: {
            VStack(spacing: 5) {
                MedalView(form: .seal, metal: earned ? badge.metal : nil, face: MedalFace(badge), size: 52)
                    .overlay {
                        if isCurrent {
                            Circle().strokeBorder(Palette.textPrimary.opacity(0.8), lineWidth: 1.5).frame(width: 62, height: 62)
                        }
                    }
                Text(badge.tier.flatMap(AchievementFace.month)?.capitalized ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(earned || isCurrent ? Palette.textPrimary : Palette.textSecondary)
                Text(earned ? stone ?? badge.title : badge.title)
                    .font(.caption2).foregroundStyle(Palette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("\(AchievementText.month(badge.tier ?? "") ?? "") · \(badge.title): \(badge.requirement)")
    }
}

/// How a month's challenge stands: a bar toward its target, or whether it
/// holds so far.
struct ChallengeStatus: View {
    let challenge: MonthlyChallenge

    var body: some View {
        if challenge.kind.isCounted {
            if let target = challenge.target {
                let current = challenge.current ?? 0
                HStack(spacing: 10) {
                    ProgressView(value: min(1, target > 0 ? current / target : 0)).tint(Palette.textPrimary).frame(maxWidth: 220)
                    Text("\(figure(current)) of \(figure(target))")
                        .font(.callout).monospacedDigit().foregroundStyle(Palette.textSecondary)
                    if challenge.onTrack {
                        Label("Met", systemImage: "checkmark.circle").font(.callout).foregroundStyle(Palette.textPrimary)
                    }
                }
            } else {
                Label("Needs a busy month before it to beat.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
            }
        } else {
            Label(challenge.onTrack ? "On track so far." : "Not met yet this month.",
                  systemImage: challenge.onTrack ? "checkmark.circle" : "circle.dashed")
                .font(.callout)
                .foregroundStyle(challenge.onTrack ? Palette.textPrimary : Palette.textSecondary)
        }
    }

    /// A share as a percentage; a count as itself.
    private func figure(_ value: Double) -> String {
        [.cacheKeeper, .betterCache, .oneThingWell].contains(challenge.kind)
            ? "\(Int((value * 100).rounded()))%" : "\(Int(value.rounded()))"
    }
}

// MARK: - History

private struct HistorySection: View {
    let shelf: AchievementShelf
    let calendar: LocalCalendar
    let select: (AchievementBadge) -> Void

    var body: some View {
        let newest = shelf.achievements.sorted { $0.awardedAt > $1.awardedAt }
        let months = Dictionary(grouping: newest) { BucketLabel.date($0.awardedAt, "yMMMM", calendar: calendar) }
        let order = newest.map { BucketLabel.date($0.awardedAt, "yMMMM", calendar: calendar) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "History", detail: "\(newest.count) earned")
            if newest.isEmpty {
                Text("Nothing earned yet.").foregroundStyle(Palette.textSecondary)
            }
            ForEach(order, id: \.self) { month in
                VStack(alignment: .leading, spacing: 10) {
                    Text(month).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    ForEach(months[month] ?? [], id: \.self) { achievement in
                        if let badge = shelf.badge(for: achievement) {
                            Button { select(badge) } label: { row(achievement, badge) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func row(_ achievement: Achievement, _ badge: AchievementBadge) -> some View {
        HStack(spacing: 14) {
            MedalView(form: MedalForm(badge.category), metal: badge.metal,
                      face: MedalFace(badge, tier: achievement.tier), size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf.title(achievement, calendar: calendar)).font(.callout.weight(.semibold))
                Text("\(shelf.material(badge)) · \(badge.category.title)")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Text(AchievementText.date(achievement.awardedAt, calendar: calendar))
                .font(.callout).foregroundStyle(Palette.textSecondary).monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Records

private struct RecordsSection: View {
    let records: PersonalRecords
    let calendar: LocalCalendar

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Personal Records", detail: "Your bests so far")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                row("Biggest day", "flame", records.biggestDay) { "\(Format.tokens($0)) tokens" }
                row("Biggest week", "calendar", records.biggestWeek) { "\(Format.tokens($0)) tokens" }
                row("Longest session", "timer", records.longestSession) { Countdown.compact($0) }
                row("Longest streak", "shield", records.longestStreak) { "\($0) days" }
                row("Most sessions in a day", "square.stack.3d.up", records.mostSessionsInADay) { "\($0) sessions" }
            }
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ symbol: String, _ record: PersonalRecords.Record?,
                     value: (Int64) -> String) -> some View {
        if let record {
            GridRow {
                Label(title, systemImage: symbol).foregroundStyle(Palette.textSecondary)
                Text(value(record.value)).font(.body.weight(.semibold)).monospacedDigit()
                Text(record.on.description == "" ? "" : day(record.on))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func day(_ day: LocalDay) -> String {
        AchievementText.day(day.description, calendar: calendar).map { "\($0) \(day.year)" } ?? day.description
    }
}

// MARK: - Detail

/// One medal, large and turnable, with what it asks and every time it was
/// earned. A volume medal borrows the corpus's milestone line.
struct MedalDetail: View {
    let badge: AchievementBadge
    let shelf: AchievementShelf
    let calendar: LocalCalendar
    let comparisons: ComparisonEngine?
    let name: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let earned = shelf.earned(badge)
        let hidden = badge.secret && earned.isEmpty
        VStack(spacing: 18) {
            SpinningMedal(form: MedalForm(badge.category), metal: earned.isEmpty ? nil : badge.metal,
                          face: MedalFace(badge, tier: earned.last?.tier), title: badge.title,
                          date: earned.last.map { AchievementText.date($0.awardedAt, calendar: calendar) },
                          secret: badge.secret, name: name)
                .padding(.top, 12)
            VStack(spacing: 6) {
                Text(hidden ? "Secret" : badge.title).font(Typography.display(24)).multilineTextAlignment(.center)
                Text(earned.isEmpty ? badge.category.title : "\(shelf.material(badge)) · \(badge.category.title)")
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(hidden ? "A secret achievement. It shows itself when you earn it." : badge.requirement)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let line = milestone, !earned.isEmpty {
                Label(line, systemImage: "sparkles").font(.callout).foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let progress = shelf.progress(badge), earned.isEmpty {
                VStack(spacing: 6) {
                    ProgressView(value: progress.fraction).tint(Palette.textPrimary).frame(width: 240)
                    Text("\(Format.figure(progress.current)) of \(Format.figure(progress.target))")
                        .font(.callout).monospacedDigit().foregroundStyle(Palette.textSecondary)
                }
            }
            if badge.kind == .streak, !earned.isEmpty {
                let reached = shelf.reached(badge)
                Text(reached > 1 ? "Reached \(reached) times · longest streak \(shelf.longestStreak) days"
                                 : "Longest streak \(shelf.longestStreak) days")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
            }
            if !earned.isEmpty {
                VStack(spacing: 4) {
                    Text(earned.count == 1 ? (badge.kind == .streak ? "First reached" : "Earned")
                                           : "Earned \(earned.count) times")
                        .font(.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    ForEach(earned.reversed().prefix(6), id: \.self) { achievement in
                        Text(earned.count == 1 ? AchievementText.date(achievement.awardedAt, calendar: calendar)
                                               : "\(shelf.title(achievement, calendar: calendar)), \(AchievementText.date(achievement.awardedAt, calendar: calendar))")
                            .font(.callout).monospacedDigit()
                    }
                    if earned.count > 6 {
                        Text("and \(earned.count - 6) more").font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 420)
        .background(Palette.background)
    }

    private var milestone: String? {
        guard badge.kind == .lifetimeTokens, let threshold = badge.threshold else { return nil }
        return comparisons?.milestone(crossing: Double(threshold), from: Double(threshold) - 1)
    }
}

// MARK: - Arrival

/// The fixed arrival queue and how far the user has reached in it.
struct MedalArrivalProgress {
    let achievements: [Achievement]
    private(set) var index = 0

    var current: Achievement? { achievements.indices.contains(index) ? achievements[index] : nil }
    var more: Bool { index + 1 < achievements.count }
    var shown: [Achievement] { Array(achievements.prefix(index + 1)) }

    mutating func advance() {
        guard more else { return }
        index += 1
    }
}

/// New medals presented one at a time, with only visited medals celebrated.
struct MedalArrival: View {
    @Binding var progress: MedalArrivalProgress
    let shelf: AchievementShelf
    let calendar: LocalCalendar
    let name: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let achievement = progress.current {
            arrival(achievement)
        }
    }

    private func arrival(_ achievement: Achievement) -> some View {
        let achievements = progress.achievements
        let index = progress.index
        let more = progress.more
        return VStack(spacing: 14) {
            Text(achievements.count > 1 ? "NEW MEDAL · \(index + 1) OF \(achievements.count)" : "NEW MEDAL")
                .font(.caption.weight(.heavy)).tracking(1.6)
                // In the colour of the medal that arrived.
                .foregroundStyle(shelf.badge(for: achievement)
                    .map { MetalPalette.of($0.metal, stone: $0.stone).light } ?? Palette.textPrimary)
                .padding(.top, 8)
            if let badge = shelf.badge(for: achievement) {
                SpinningMedal(form: MedalForm(badge.category), metal: badge.metal,
                              face: MedalFace(badge, tier: achievement.tier), title: badge.title,
                              date: AchievementText.date(achievement.awardedAt, calendar: calendar), name: name,
                              size: 240)
                    .background {
                        // The medal's own light, falling on the sheet behind it,
                        // given room to fade out before any edge.
                        RadialGradient(colors: [MetalPalette.of(badge.metal).light.opacity(0.22), .clear],
                                       center: .center, startRadius: 0, endRadius: 190)
                            .frame(width: 380, height: 380)
                            .allowsHitTesting(false)
                    }
                    .id(index)
                VStack(spacing: 6) {
                    Text(shelf.title(achievement, calendar: calendar))
                        .font(Typography.display(26)).multilineTextAlignment(.center)
                    Text("\(shelf.material(badge)) · \(badge.category.title)").foregroundStyle(Palette.textSecondary)
                }
                .id("title\(index)")
                .transition(.opacity.combined(with: .offset(y: 6)))
                Text(badge.requirement)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Earned \(AchievementText.date(achievement.awardedAt, calendar: calendar))")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
            }
            Button(more ? "Next" : "Done") {
                if more { withAnimation(Motion.standard) { progress.advance() } } else { dismiss() }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 440)
        .background(Palette.background)
    }
}

// MARK: - Activity summary

/// The Activity page's glimpse: the habit medals closest to earning, this
/// month's challenge, and the latest medals, with the way to them all.
struct AchievementsSummary: View {
    let snapshot: ActivitySnapshot
    let calendar: LocalCalendar
    let seeAll: () -> Void

    var body: some View {
        let shelf = AchievementShelf(snapshot)
        let recent = snapshot.achievements.sorted { $0.awardedAt > $1.awardedAt }.prefix(4)
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Achievements", detail: "\(shelf.earnedCount) of \(shelf.catalogue.count) medals") {
                Button("See All", systemImage: "chevron.right", action: seeAll)
                    .labelStyle(.titleOnly)
                    .buttonStyle(.borderless)
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Next up").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    ForEach(snapshot.progress.prefix(3), id: \.self) { progress in
                        nextUp(progress)
                    }
                    if snapshot.progress.isEmpty {
                        Text("Every habit medal is earned.").foregroundStyle(Palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recently earned").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(recent), id: \.self) { achievement in
                            if let badge = shelf.badge(for: achievement) {
                                VStack(spacing: 6) {
                                    MedalView(form: MedalForm(badge.category), metal: badge.metal,
                                              face: MedalFace(badge, tier: achievement.tier), size: 52)
                                    Text(shelf.title(achievement, calendar: calendar))
                                        .font(.caption).multilineTextAlignment(.center).lineLimit(2)
                                        .frame(width: 84)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func nextUp(_ progress: AchievementProgress) -> some View {
        HStack(spacing: 12) {
            MedalView(form: MedalForm(progress.badge.category), metal: nil, face: MedalFace(progress.badge), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.badge.title).font(.callout.weight(.semibold))
                ProgressView(value: progress.fraction).tint(Palette.textPrimary)
                Text("\(Format.figure(progress.current)) of \(Format.figure(progress.target))")
                    .font(.caption).monospacedDigit().foregroundStyle(Palette.textSecondary)
            }
        }
    }
}
