//
//  Achievement.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// The shelves the achievements page is arranged in.
public enum AchievementCategory: String, Sendable, CaseIterable {
    case volume, landmarks, streaks, efficiency, pacing, sessions, explorer, repeatable, monthly, limited

    public var title: String {
        switch self {
        case .volume: "Volume"
        case .landmarks: "Landmarks"
        case .streaks: "Streaks"
        case .efficiency: "Efficiency"
        case .pacing: "Pacing"
        case .sessions: "Sessions"
        case .explorer: "Explorer"
        case .repeatable: "Again and Again"
        case .monthly: "Monthly Challenges"
        case .limited: "Limited Edition"
        }
    }

    /// Habits, whose progress Burnline may show and suggest. Volume, sessions
    /// and range are observations only: showing how far the next one is
    /// would invite more usage to reach it, which a spend monitor must not.
    public var isHabit: Bool { [.streaks, .efficiency, .pacing, .monthly].contains(self) }
}

/// A medal's metal: how hard it is to earn. Each metal has three grades,
/// so the six metals make eighteen rungs, bronze I to ember III, and every
/// ladder spreads its rungs across them by how far up the ladder each sits:
/// the same metal and grade mean the same rarity on every shelf, and every
/// ladder tops out at ember III. A single medal takes the metal of the rung
/// it would sit on: bronze for a first time, silver for a week's habit, gold
/// for a month's or a feat, platinum for a year's, ember for never again.
public enum Metal: Int, Sendable, Comparable, CaseIterable {
    case bronze, silver, gold, platinum, diamond, ember

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public static let grades = 3
    public static var rungs: Int { allCases.count * grades }

    /// The metal and grade, 1 to 3, of rung `index` on a ladder of `count`.
    public static func rung(_ index: Int, of count: Int) -> (metal: Metal, grade: Int) {
        let position = max(0, min(rungs - 1, (index + 1) * rungs / max(1, count) - 1))
        return (allCases[position / grades], position % grades + 1)
    }

    /// "I", "II" or "III".
    public static func numeral(_ grade: Int) -> String { String(repeating: "I", count: max(1, min(grades, grade))) }

    public var name: String {
        switch self {
        case .bronze: "Bronze"
        case .silver: "Silver"
        case .gold: "Gold"
        case .platinum: "Platinum"
        case .diamond: "Diamond"
        case .ember: "Ember"
        }
    }
}

/// What an achievement observes; the stored `achievements.key`. Each is a
/// fact about work already done, and none rewards spend itself.
public enum AchievementKind: String, Sendable, CaseIterable {
    case lifetimeTokens = "lifetime-tokens"
    case odometer
    case landmark
    case streak
    case freezeUsed = "freeze-used"
    case restDay = "rest-day"
    case cacheSavings = "cache-savings"
    case cacheMaster = "cache-master"
    case steadyHand = "steady-hand"
    case sessions
    case nightOwl = "night-owl"
    case earlyBird = "early-bird"
    case marathon
    case leapDay = "leap-day"
    case midnightCrossing = "midnight-crossing"
    case firstSession = "first-session"
    case providersInADay = "providers-in-a-day"
    case models
    case projects
    case deepDive = "deep-dive"
    case projectHopper = "project-hopper"
    case modelHopper = "model-hopper"
    case comeback
    case aroundTheClock = "around-the-clock"
    case sevenDays = "seven-days"
    case oldFriend = "old-friend"
    case perfectWeek = "perfect-week"
    case hotCache = "hot-cache"
    case underTheLine = "under-the-line"
    case monthly
    case alphaTester = "alpha-tester"
    case foundingYear = "founding-year"
    case anniversary
    case yearOfBuilding = "year-of-building"

    public var category: AchievementCategory {
        switch self {
        case .lifetimeTokens, .odometer: .volume
        case .landmark: .landmarks
        case .streak, .freezeUsed, .restDay: .streaks
        case .cacheSavings, .cacheMaster: .efficiency
        case .steadyHand: .pacing
        case .sessions, .nightOwl, .earlyBird, .marathon, .leapDay, .midnightCrossing: .sessions
        case .firstSession, .providersInADay, .models, .projects, .deepDive, .projectHopper, .modelHopper,
             .comeback, .aroundTheClock, .sevenDays, .oldFriend: .explorer
        case .perfectWeek, .hotCache, .underTheLine: .repeatable
        case .monthly: .monthly
        case .alphaTester, .foundingYear, .anniversary, .yearOfBuilding: .limited
        }
    }

    /// Earned once per period, each time stored under the period's own tier.
    public var isRepeatable: Bool { [.perfectWeek, .hotCache, .underTheLine].contains(self) }

    /// Processed tokens over all time, cache reads included: a day of agent
    /// work runs to tens of millions, and the heaviest users pass trillions.
    public static let tokenTiers: [Int64] = [
        1_000_000, 50_000_000, 100_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000,
        10_000_000_000, 20_000_000_000, 50_000_000_000, 100_000_000_000, 200_000_000_000, 500_000_000_000,
        1_000_000_000_000, 1_500_000_000_000, 2_000_000_000_000, 2_500_000_000_000, 3_000_000_000_000,
    ]
    /// Consecutive counted days, up to two years.
    public static let streakTiers: [Int64] = [3, 7, 14, 30, 60, 100, 200, 365, 730]
    public static let sessionTiers: [Int64] = [10, 50, 100, 500, 1_000, 5_000, 25_000, 100_000]
    /// What caching saved over all time, in dollars.
    public static let cacheSavingsDollars: [Int64] = [10, 50, 100, 500, 1_000, 10_000, 100_000, 1_000_000]
    /// Days a 90% cache share was held: a week, then whole months running,
    /// up to two years.
    public static let cacheMasterDays: [Int64] = [7, 30, 90, 180, 270, 365, 545, 730]
    /// Weekly windows in a row closed without reaching the limit, up to a year.
    public static let steadyHandTiers: [Int64] = [2, 4, 8, 12, 26, 52]
    public static let modelTiers: [Int64] = [3, 6, 12, 25, 50]
    public static let projectTiers: [Int64] = [5, 10, 25, 50, 100]
    /// Tokens processed in a single project.
    public static let deepDiveTiers: [Int64] = [100_000_000, 500_000_000, 1_000_000_000, 5_000_000_000,
                                                10_000_000_000]
    /// Projects worked in on one day.
    public static let projectHopperTiers: [Int64] = [5, 10, 15]
    /// Days away before coming back.
    public static let comebackDays: [Int64] = [30, 90, 180, 365]
}

/// One achievement earned. `awardedAt` is when the history first met it,
/// not when Burnline noticed, so history imported later is awarded where it
/// happened; once stored it never changes.
public struct Achievement: Hashable, Sendable {
    public let kind: AchievementKind
    /// The threshold met, the provider for a first session, or the period
    /// for a repeatable one. Unique per kind.
    public let tier: String
    public let provider: ProviderKey?
    /// The figure behind it: the threshold, a percentage, or for a monthly
    /// challenge which challenge it was (`MonthlyChallenge.Kind`).
    public let value: Int64
    public let awardedAt: Timestamp

    public init(kind: AchievementKind, tier: String, provider: ProviderKey? = nil, value: Int64,
                awardedAt: Timestamp) {
        self.kind = kind
        self.tier = tier
        self.provider = provider
        self.value = value
        self.awardedAt = awardedAt
    }
}

// MARK: - Catalogue

/// One medal on the shelf. A repeatable kind has one entry, `tier` nil, for
/// all its periods.
public struct AchievementBadge: Hashable, Sendable, Identifiable {
    public let kind: AchievementKind
    public let tier: String?
    public let metal: Metal
    /// A ladder rung's grade within its metal, 1 to 3; nil for a single medal.
    public let grade: Int?
    /// The birth month whose stone a monthly medal is set in, 1 to 12.
    public let stone: Int?
    public let title: String
    public let requirement: String
    /// Shown as "???" until earned.
    public let secret: Bool
    /// The figure a ladder counts toward, for progress.
    public let threshold: Int64?

    public init(kind: AchievementKind, tier: String?, metal: Metal, grade: Int? = nil, stone: Int? = nil,
                title: String, requirement: String, secret: Bool = false, threshold: Int64? = nil) {
        self.kind = kind
        self.tier = tier
        self.metal = metal
        self.grade = grade
        self.stone = stone
        self.title = title
        self.requirement = requirement
        self.secret = secret
        self.threshold = threshold
    }

    public var id: String { "\(kind.rawValue)|\(tier ?? "*")" }
    public var category: AchievementCategory { kind.category }

    /// "Gold II", or "Gold" for a single medal.
    public var metalName: String { grade.map { "\(metal.name) \(Metal.numeral($0))" } ?? metal.name }

    /// Whether `achievement` is one of this medal's.
    public func matches(_ achievement: Achievement) -> Bool {
        achievement.kind == kind && (tier == nil || tier == achievement.tier)
    }

    /// Every medal, shelf by shelf, lowest tier first. Monthly challenges
    /// after `revealedThrough`'s year stay off the shelf until their year
    /// comes; nil reveals the whole schedule.
    public static func catalogue(providers: [ProviderKey], revealedThrough year: Int? = nil) -> [AchievementBadge] {
        // Each rung takes its place among the eighteen metals and grades.
        func ladder(_ kind: AchievementKind, _ tiers: [Int64],
                    title: (Int64) -> String, requirement: (Int64) -> String) -> [AchievementBadge] {
            tiers.enumerated().map { index, tier in
                let rung = Metal.rung(index, of: tiers.count)
                return AchievementBadge(kind: kind, tier: String(tier), metal: rung.metal, grade: rung.grade,
                                        title: title(tier), requirement: requirement(tier), threshold: tier)
            }
        }
        func one(_ kind: AchievementKind, _ metal: Metal, _ title: String, _ requirement: String,
                 tier: String? = "1", secret: Bool = false) -> AchievementBadge {
            AchievementBadge(kind: kind, tier: tier, metal: metal, title: title, requirement: requirement,
                             secret: secret)
        }
        let landmarks = Landmark.all.enumerated().map { index, landmark in
            let rung = Metal.rung(index, of: Landmark.all.count)
            return AchievementBadge(kind: .landmark, tier: String(landmark.tokens), metal: rung.metal,
                                    grade: rung.grade, title: landmark.name,
                                    requirement: "Print your tokens and stack them past \(Self.meters(landmark.meters)).",
                                    threshold: landmark.tokens)
        }
        let monthly = MonthlyChallenge.months.compactMap { tier -> AchievementBadge? in
            guard let kind = MonthlyChallenge.schedule[tier], let (scheduled, month) = MonthlyChallenge.month(tier),
                  scheduled <= year ?? .max else {
                return nil
            }
            return AchievementBadge(kind: .monthly, tier: tier, metal: .gold, stone: month, title: kind.title,
                                    requirement: kind.summary)
        }
        return ladder(.lifetimeTokens, AchievementKind.tokenTiers,
                      title: { "\(compact($0)) Tokens" },
                      requirement: { "Process \(compact($0)) tokens over all time." })
            + [one(.odometer, .silver, "Odometer",
                   "Watch your lifetime tokens roll past \(Achievement.odometerTokens.formatted()).", secret: true)]
            + landmarks
            + ladder(.streak, AchievementKind.streakTiers,
                     title: { "\($0)-Day Streak" },
                     requirement: { "Keep a streak going for \($0) days." })
            + [one(.freezeUsed, .bronze, "Saved by a Freeze", "Have a freeze carry your streak over a short day."),
               one(.restDay, .silver, "Rest Day", "Take a whole day off and let a freeze keep your streak.")]
            + ladder(.cacheSavings, AchievementKind.cacheSavingsDollars,
                     title: { "$\(compact($0)) Saved" },
                     requirement: { "Save $\(compact($0)) through caching, against plain input prices." })
            + ladder(.cacheMaster, AchievementKind.cacheMasterDays,
                     title: { "Cache Master · \(cacheMasterSpan($0))" },
                     requirement: { days in
                         days <= 7 ? "Serve 90% of a busy week's input from the cache."
                             : "Serve 90% of each month's input from the cache, \(cacheMasterSpan(days).lowercased()) running."
                     })
            + ladder(.steadyHand, AchievementKind.steadyHandTiers,
                     title: { "Steady Hand · \($0) Weeks" },
                     requirement: { "Close \($0) busy weekly windows in a row without reaching the limit." })
            + ladder(.sessions, AchievementKind.sessionTiers,
                     title: { "\(compact($0)) Sessions" },
                     requirement: { "Record \(compact($0)) sessions." })
            + [one(.nightOwl, .bronze, "Night Owl", "Start a session between midnight and 5 a.m.", secret: true),
               one(.earlyBird, .bronze, "Early Bird", "Start a session between 5 and 7 a.m.", secret: true),
               one(.marathon, .gold, "Marathon", "Keep one session going for four hours.", secret: true),
               one(.leapDay, .platinum, "Leap Day", "Be active on the 29th of February.", secret: true),
               one(.midnightCrossing, .gold, "Midnight Crossing",
                   "Have a session running as the new year arrives.", secret: true)]
            + providers.map { one(.firstSession, .bronze, "First \($0.displayName) Session",
                                  "Record a session with \($0.displayName).", tier: $0.rawValue) }
            + [one(.providersInADay, .bronze, "Two at Once", "Use two providers on the same day.", tier: "2"),
               one(.providersInADay, .silver, "Full House", "Use three providers on the same day.", tier: "3")]
            + ladder(.models, AchievementKind.modelTiers, title: { "\($0) Models" },
                     requirement: { "Work with \($0) different models." })
            + ladder(.projects, AchievementKind.projectTiers, title: { "\($0) Projects" },
                     requirement: { "Work in \($0) different projects." })
            + ladder(.deepDive, AchievementKind.deepDiveTiers, title: { "Deep Dive · \(compact($0))" },
                     requirement: { "Process \(compact($0)) tokens in a single project." })
            + ladder(.projectHopper, AchievementKind.projectHopperTiers, title: { "Project Hopper · \($0)" },
                     requirement: { "Work in \($0) different projects on the same day." })
            + ladder(.comeback, AchievementKind.comebackDays, title: { "Comeback · \($0) Days" },
                     requirement: { "Come back after \($0) days away." })
            + [one(.modelHopper, .silver, "Model Hopper",
                   "Work with \(Achievement.modelHopperCount) different models on the same day."),
               one(.aroundTheClock, .gold, "Around the Clock", "Start sessions in every hour of the day, over time."),
               one(.sevenDays, .bronze, "Seven Days", "Start sessions on every day of the week, over time."),
               one(.oldFriend, .platinum, "Old Friend", "Keep working in one project for a year.")]
            + [one(.perfectWeek, .silver, "Perfect Week", "Count every day of a calendar week toward your streak.",
                   tier: nil),
               one(.hotCache, .silver, "Hot Cache", "Serve over 90% of a week's input from the cache.", tier: nil),
               one(.underTheLine, .gold, "Under the Line",
                   "Pass 75% of a weekly limit and still close the window without reaching it.", tier: nil)]
            + monthly
            + [one(.alphaTester, .ember, "Alpha Tester", "Use Burnline during its first alpha.", tier: "0.1"),
               one(.foundingYear, .ember, "Founding Year",
                   "Use Burnline in \(Achievement.foundingYear), the year it began.",
                   tier: String(Achievement.foundingYear)),
               one(.anniversary, .platinum, "One Year of Burnline", "Track your usage for a year."),
               one(.yearOfBuilding, .platinum, "A Year of Building", "Be active on 100 days in one calendar year.",
                   tier: nil)]
    }

    /// 1,000 as "1K", 10,000,000,000 as "10B", 1.5 trillion as "1.5T".
    public static func compact(_ value: Int64) -> String {
        for (size, suffix) in [(Int64(1_000_000_000_000), "T"), (1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
            where value >= size {
            let whole = value / size, tenths = value % size * 10 / size
            return tenths == 0 ? "\(whole)\(suffix)" : "\(whole).\(tenths)\(suffix)"
        }
        return String(value)
    }

    /// "Week", "Month", "3 Months", "1 Year", "18 Months", "2 Years".
    static func cacheMasterSpan(_ days: Int64) -> String {
        switch cacheMasterMonths(days) {
        case 0: "Week"
        case 1: "Month"
        case let months where months.isMultiple(of: 12): months == 12 ? "1 Year" : "\(months / 12) Years"
        case let months: "\(months) Months"
        }
    }

    /// The whole months a Cache Master rung asks for; 0 for the week.
    public static func cacheMasterMonths(_ days: Int64) -> Int {
        days <= 7 ? 0 : Int((Double(days) / 30.4).rounded())
    }

    /// 828 as "828 m", 408,000 as "408 km".
    public static func meters(_ meters: Double) -> String {
        meters >= 10_000 ? "\(Int(meters / 1_000).formatted()) km" : "\(Int(meters).formatted()) m"
    }
}

// MARK: - History

/// Everything achievements are decided from, read by the activity service.
public struct AchievementHistory: Sendable {
    public struct Session: Sendable {
        public let startedAt: Timestamp
        public let endedAt: Timestamp?
        public let provider: ProviderKey

        public init(startedAt: Timestamp, endedAt: Timestamp?, provider: ProviderKey) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.provider = provider
        }
    }

    /// One weekly quota window: when it began and reset, and the highest
    /// share of its limit seen in it.
    public struct QuotaCycle: Sendable, Equatable {
        public let provider: ProviderKey
        public let key: String
        public let start: Timestamp
        public let end: Timestamp
        public let peak: Double
        /// A subsequent provider observation confirmed that a new window began.
        public let isConfirmedClosed: Bool

        public init(provider: ProviderKey, key: String, start: Timestamp, end: Timestamp, peak: Double,
                    isConfirmedClosed: Bool) {
            self.provider = provider
            self.key = key
            self.start = start
            self.end = end
            self.peak = peak
            self.isConfirmedClosed = isConfirmedClosed
        }
    }

    /// Every tracked day, oldest first and ending today.
    public let days: [ActivityDay]
    public let sessions: [Session]
    /// When each model and each project was first used.
    public let modelFirstUses: [Timestamp]
    public let projectFirstUses: [Timestamp]
    /// Weekly quota windows, in any order.
    public let weeklyCycles: [QuotaCycle]
    /// Five-hour quota windows, in any order.
    public let fiveHourCycles: [QuotaCycle]
    /// Each day's processed tokens by project, merged projects under the
    /// one they joined; in step with `days`.
    public let projectTokens: [[Int64: Int64]]
    /// The different models used each day, in step with `days`.
    public let modelsPerDay: [Int]
    public let calendar: LocalCalendar
    public let now: Timestamp
    /// The running app's version, for limited editions tied to a release.
    public let appVersion: String?

    public init(days: [ActivityDay], sessions: [Session], modelFirstUses: [Timestamp] = [],
                projectFirstUses: [Timestamp] = [], weeklyCycles: [QuotaCycle] = [],
                fiveHourCycles: [QuotaCycle] = [], projectTokens: [[Int64: Int64]] = [], modelsPerDay: [Int] = [],
                calendar: LocalCalendar, now: Timestamp, appVersion: String? = nil) {
        self.days = days
        self.sessions = sessions.sorted { $0.startedAt < $1.startedAt }
        self.modelFirstUses = modelFirstUses.sorted()
        self.projectFirstUses = projectFirstUses.sorted()
        self.weeklyCycles = weeklyCycles.sorted { $0.end < $1.end }
        self.fiveHourCycles = fiveHourCycles.sorted { $0.end < $1.end }
        self.projectTokens = projectTokens
        self.modelsPerDay = modelsPerDay
        self.calendar = calendar
        self.now = now
        self.appVersion = appVersion
    }

    var closedCycles: [QuotaCycle] { weeklyCycles.filter { $0.isConfirmedClosed && $0.end <= now } }
}

// MARK: - Earning

extension Achievement {
    /// How long a new achievement is news. Older ones, awarded late by a
    /// backfill, join their shelf without a notification or an arrival.
    public static let freshness: Int64 = 3 * 86_400

    /// Whether it was awarded recently enough to announce and celebrate.
    public func isFresh(at now: Timestamp) -> Bool {
        now.epochSeconds - awardedAt.epochSeconds <= Self.freshness
    }
}

extension Achievement {
    /// Weekly windows below this share of their limit neither extend nor
    /// break a Steady Hand run: an idle week shows no restraint.
    public static let busyWindow = 50.0
    public static let underTheLineFloor = 75.0
    public static let hotCacheRate = 0.9
    /// A week needs this much usage before its cache rate means anything.
    public static let hotCacheMinimumTokens: Int64 = 1_000_000
    public static let marathonSeconds: Int64 = 4 * 3_600
    /// Longer than this, a "session" is a conversation resumed days later.
    public static let marathonCeiling: Int64 = 16 * 3_600
    public static let yearOfBuildingDays = 100
    /// The lifetime total the Odometer rolls past.
    public static let odometerTokens: Int64 = 123_456_789
    public static let modelHopperCount = 5
    /// How far apart, in days, a project's first and latest work must be.
    public static let oldFriendDays = 365
    /// The year Burnline began, for its limited edition.
    public static let foundingYear = 2026
    /// A month needs this much input, cache included, before its cache
    /// share counts toward Cache Master.
    public static let cacheMasterMonthTokens: Int64 = 4_000_000

    /// Every achievement the history has earned. A threshold crossed during
    /// a day is dated from that day's start, since usage is summed by day; a
    /// period's award is dated from the period's end.
    public static func earned(_ history: AchievementHistory) -> [Achievement] {
        var earned: [Achievement] = []
        let days = history.days

        func crossings(_ kind: AchievementKind, tiers: [Int64], scale: Int64 = 1,
                       running value: (ActivityDay) -> Int64) {
            var total: Int64 = 0
            var remaining = tiers[...]
            for day in days {
                let (sum, overflow) = total.addingReportingOverflow(value(day))
                total = overflow ? .max : sum
                while let tier = remaining.first, total >= tier * scale {
                    earned.append(Achievement(kind: kind, tier: String(tier), value: tier * scale,
                                              awardedAt: day.window.start))
                    remaining.removeFirst()
                }
            }
        }
        crossings(.lifetimeTokens, tiers: AchievementKind.tokenTiers) { $0.totals.tokens.processed }
        crossings(.odometer, tiers: [odometerTokens]) { $0.totals.tokens.processed }
        crossings(.landmark, tiers: Landmark.all.map(\.tokens)) { $0.totals.tokens.processed }
        crossings(.cacheSavings, tiers: AchievementKind.cacheSavingsDollars, scale: Nanodollars.perDollar) {
            $0.totals.cacheSavings.saved.raw
        }

        // Streaks, and the first freeze spent.
        let steps = StreakRule.walk(days)
        var streaks = AchievementKind.streakTiers[...]
        for step in steps {
            if case .counted(let length) = step.outcome, let tier = streaks.first, Int64(length) >= tier {
                earned.append(Achievement(kind: .streak, tier: String(tier), value: tier, awardedAt: step.day.window.start))
                streaks.removeFirst()
            }
        }
        if let frozen = steps.first(where: { $0.outcome == .frozen }) {
            earned.append(Achievement(kind: .freezeUsed, tier: "1", value: 1, awardedAt: frozen.day.window.start))
        }
        if let rest = steps.first(where: { $0.outcome == .frozen && !$0.day.isActive }) {
            earned.append(Achievement(kind: .restDay, tier: "1", value: 1, awardedAt: rest.day.window.start))
        }

        earned += sessionAchievements(history)
        earned += countCrossings(.models, AchievementKind.modelTiers, history.modelFirstUses)
        earned += countCrossings(.projects, AchievementKind.projectTiers, history.projectFirstUses)

        // Two providers in one day, and later three: each count once, and a
        // day with three also counts as two.
        var most = 1
        for day in days {
            let used = day.providers.values.count { $0.events > 0 }
            guard used > most else { continue }
            for count in (most + 1)...used {
                earned.append(Achievement(kind: .providersInADay, tier: String(count), value: Int64(count),
                                          awardedAt: day.window.start))
            }
            most = used
        }

        earned += explorerAchievements(history)
        earned += cacheMasterAchievements(history)
        earned += pacingAchievements(history)
        earned += weekAchievements(history, steps: steps)
        earned += MonthlyChallenge.earned(history)
        earned += limitedEditions(history)
        return earned
    }

    private static func countCrossings(_ kind: AchievementKind, _ tiers: [Int64], _ firstUses: [Timestamp])
        -> [Achievement] {
        tiers.compactMap { tier in
            firstUses.count >= tier
                ? Achievement(kind: kind, tier: String(tier), value: tier, awardedAt: firstUses[Int(tier) - 1])
                : nil
        }
    }

    private static func sessionAchievements(_ history: AchievementHistory) -> [Achievement] {
        let sessions = history.sessions
        var earned: [Achievement] = []
        for provider in ProviderKey.allCases {
            if let first = sessions.first(where: { $0.provider == provider }) {
                earned.append(Achievement(kind: .firstSession, tier: provider.rawValue, provider: provider,
                                          value: 1, awardedAt: first.startedAt))
            }
        }
        for tier in AchievementKind.sessionTiers where sessions.count >= tier {
            earned.append(Achievement(kind: .sessions, tier: String(tier), value: tier,
                                      awardedAt: sessions[Int(tier) - 1].startedAt))
        }
        let hour = { (session: AchievementHistory.Session) in
            history.calendar.calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(session.startedAt.epochSeconds)))
        }
        if let owl = sessions.first(where: { hour($0) < 5 }) {
            earned.append(Achievement(kind: .nightOwl, tier: "1", value: Int64(hour(owl)), awardedAt: owl.startedAt))
        }
        if let bird = sessions.first(where: { (5..<7).contains(hour($0)) }) {
            earned.append(Achievement(kind: .earlyBird, tier: "1", value: Int64(hour(bird)), awardedAt: bird.startedAt))
        }
        let marathon = sessions.compactMap { session -> (Timestamp, Int64)? in
            guard let end = session.endedAt else { return nil }
            let length = end.seconds(since: session.startedAt)
            guard length >= marathonSeconds, length <= marathonCeiling else { return nil }
            return (session.startedAt.adding(seconds: marathonSeconds), length)
        }.min { $0.0 < $1.0 }
        if let (reached, length) = marathon {
            earned.append(Achievement(kind: .marathon, tier: "1", value: length, awardedAt: reached))
        }
        if let leap = history.days.first(where: { $0.day.month == 2 && $0.day.day == 29 && $0.isActive }) {
            earned.append(Achievement(kind: .leapDay, tier: "1", value: Int64(leap.day.year),
                                      awardedAt: leap.window.start))
        }
        let calendar = history.calendar.calendar
        let crossing = sessions.lazy.compactMap { session -> Timestamp? in
            guard let end = session.endedAt, end.seconds(since: session.startedAt) <= marathonCeiling else { return nil }
            let year = calendar.component(.year, from: session.startedAt.date)
            guard let midnight = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return nil }
            let instant = Timestamp(epochSeconds: Int64(midnight.timeIntervalSince1970))
            return session.startedAt < instant && end >= instant ? instant : nil
        }.first
        if let crossing {
            earned.append(Achievement(kind: .midnightCrossing, tier: "1", value: 1, awardedAt: crossing))
        }
        return earned
    }

    /// Breadth and depth: projects worked hard or long, busy days, coming
    /// back, and the hours and weekdays covered over time.
    private static func explorerAchievements(_ history: AchievementHistory) -> [Achievement] {
        var earned: [Achievement] = []
        let days = history.days
        var totals: [Int64: Int64] = [:]
        var firstSeen: [Int64: Int] = [:]
        var deep = AchievementKind.deepDiveTiers[...]
        var hopper = AchievementKind.projectHopperTiers[...]
        var oldFriend = false
        for (index, projects) in history.projectTokens.prefix(days.count).enumerated() {
            let start = days[index].window.start
            for (project, tokens) in projects where tokens > 0 {
                let (sum, overflow) = totals[project, default: 0].addingReportingOverflow(tokens)
                totals[project] = overflow ? .max : sum
                let first = firstSeen[project] ?? index
                firstSeen[project] = first
                if !oldFriend, index - first >= oldFriendDays {
                    oldFriend = true
                    earned.append(Achievement(kind: .oldFriend, tier: "1", value: Int64(index - first), awardedAt: start))
                }
            }
            let top = totals.values.max() ?? 0
            while let tier = deep.first, top >= tier {
                earned.append(Achievement(kind: .deepDive, tier: String(tier), value: tier, awardedAt: start))
                deep.removeFirst()
            }
            let worked = Int64(projects.count { $0.value > 0 })
            while let tier = hopper.first, worked >= tier {
                earned.append(Achievement(kind: .projectHopper, tier: String(tier), value: tier, awardedAt: start))
                hopper.removeFirst()
            }
        }
        if let index = history.modelsPerDay.prefix(days.count).firstIndex(where: { $0 >= modelHopperCount }) {
            earned.append(Achievement(kind: .modelHopper, tier: "1", value: Int64(history.modelsPerDay[index]),
                                      awardedAt: days[index].window.start))
        }
        // Coming back: the days away before an active day.
        var comebacks = AchievementKind.comebackDays[...]
        var lastActive: Int?
        for (index, day) in days.enumerated() where day.isActive {
            if let last = lastActive {
                let away = Int64(index - last - 1)
                while let tier = comebacks.first, away >= tier {
                    earned.append(Achievement(kind: .comeback, tier: String(tier), value: away,
                                              awardedAt: day.window.start))
                    comebacks.removeFirst()
                }
            }
            lastActive = index
        }
        // Every hour of the day, and every day of the week, over time.
        let calendar = history.calendar.calendar
        var hours = Set<Int>(), weekdays = Set<Int>()
        var clock = false, week = false
        for session in history.sessions {
            let date = session.startedAt.date
            hours.insert(calendar.component(.hour, from: date))
            weekdays.insert(calendar.component(.weekday, from: date))
            if !clock, hours.count == 24 {
                clock = true
                earned.append(Achievement(kind: .aroundTheClock, tier: "1", value: 24, awardedAt: session.startedAt))
            }
            if !week, weekdays.count == 7 {
                week = true
                earned.append(Achievement(kind: .sevenDays, tier: "1", value: 7, awardedAt: session.startedAt))
            }
        }
        return earned
    }

    /// A 90% cache share held for a busy week, then for whole busy months
    /// running.
    private static func cacheMasterAchievements(_ history: AchievementHistory) -> [Achievement] {
        let calendar = history.calendar
        var earned: [Achievement] = []
        let weekTier = AchievementKind.cacheMasterDays.first { $0 <= 7 }
        var monthTiers = AchievementKind.cacheMasterDays.filter { $0 > 7 }[...]
        // The first busy week at 90%.
        var weeks: [TimeWindow: [TokenCounts]] = [:]
        for day in history.days { weeks[calendar.week(containing: day.window.start), default: []].append(day.totals.tokens) }
        let firstWeek = weeks.filter { week, tokens in
            week.end <= history.now && tokens.reduce(0) { $0 + $1.processed } >= hotCacheMinimumTokens
                && (cacheRate(tokens) ?? 0) >= hotCacheRate
        }.keys.min { $0.end < $1.end }
        if let firstWeek, let weekTier {
            earned.append(Achievement(kind: .cacheMaster, tier: String(weekTier), value: weekTier,
                                      awardedAt: firstWeek.end))
        }
        // Whole months, counted in a run while each holds the share.
        var months: [(year: Int, month: Int, tokens: [TokenCounts], active: Int)] = []
        for day in history.days {
            if months.last?.year == day.day.year, months.last?.month == day.day.month {
                months[months.count - 1].tokens.append(day.totals.tokens)
                months[months.count - 1].active += day.isActive ? 1 : 0
            } else {
                months.append((day.day.year, day.day.month, [day.totals.tokens], day.isActive ? 1 : 0))
            }
        }
        var run = 0
        for month in months {
            guard let window = MonthlyChallenge.monthWindow(month.year, month.month, calendar),
                  window.end <= history.now else { break }
            let input = month.tokens.reduce(Int64(0)) { $0 + $1.input + $1.cachedInput + $1.cacheWrite }
            let held = input >= cacheMasterMonthTokens && month.active >= MonthlyChallenge.minimumActiveDays
                && (cacheRate(month.tokens) ?? 0) >= hotCacheRate
            run = held ? run + 1 : 0
            while let tier = monthTiers.first, run >= AchievementBadge.cacheMasterMonths(tier) {
                earned.append(Achievement(kind: .cacheMaster, tier: String(tier), value: tier, awardedAt: window.end))
                monthTiers.removeFirst()
            }
        }
        return earned
    }

    /// Steady Hand runs and Under the Line windows, from closed weekly windows.
    private static func pacingAchievements(_ history: AchievementHistory) -> [Achievement] {
        var earned: [Achievement] = []
        var runs: [String: Int64] = [:]
        var remaining = AchievementKind.steadyHandTiers[...]
        for cycle in history.closedCycles {
            let series = "\(cycle.provider.rawValue):\(cycle.key)"
            if cycle.peak >= QuotaThresholds.exhausted {
                runs[series] = 0
            } else if cycle.peak >= busyWindow {
                let run = (runs[series] ?? 0) + 1
                runs[series] = run
                while let tier = remaining.first, run >= tier {
                    earned.append(Achievement(kind: .steadyHand, tier: String(tier), value: tier, awardedAt: cycle.end))
                    remaining.removeFirst()
                }
            }
            if cycle.peak >= underTheLineFloor, cycle.peak < QuotaThresholds.exhausted {
                earned.append(Achievement(kind: .underTheLine, tier: "\(series):\(cycle.end.epochSeconds)",
                                          provider: cycle.provider, value: Int64(cycle.peak.rounded()),
                                          awardedAt: cycle.end))
            }
        }
        return earned
    }

    /// Perfect Week and Hot Cache, over calendar weeks already over.
    private static func weekAchievements(_ history: AchievementHistory, steps: [StreakRule.Step]) -> [Achievement] {
        var weeks: [TimeWindow: [StreakRule.Step]] = [:]
        for step in steps { weeks[history.calendar.week(containing: step.day.window.start), default: []].append(step) }
        var earned: [Achievement] = []
        for (week, steps) in weeks where week.end <= history.now {
            let tier = history.calendar.day(containing: week.start).description
            if steps.count == 7, steps.allSatisfy({ if case .counted = $0.outcome { true } else { false } }) {
                earned.append(Achievement(kind: .perfectWeek, tier: tier, value: 7, awardedAt: week.end))
            }
            let tokens = steps.map(\.day.totals.tokens)
            let processed = tokens.reduce(0) { $0 + $1.processed }
            if processed >= hotCacheMinimumTokens, let rate = cacheRate(tokens), rate >= hotCacheRate {
                earned.append(Achievement(kind: .hotCache, tier: tier, value: Int64((rate * 1_000).rounded()),
                                          awardedAt: week.end))
            }
        }
        return earned.sorted { $0.awardedAt < $1.awardedAt }
    }

    /// The share of input served from the cache: cached reads over all input
    /// sent, cache writes included. Nil with no input.
    public static func cacheRate(_ tokens: [TokenCounts]) -> Double? {
        let cached = tokens.reduce(0.0) { $0 + Double($1.cachedInput) }
        let input = tokens.reduce(0.0) { $0 + Double($1.input + $1.cachedInput + $1.cacheWrite) }
        return input > 0 ? cached / input : nil
    }

    private static func limitedEditions(_ history: AchievementHistory) -> [Achievement] {
        var earned: [Achievement] = []
        if let version = history.appVersion, (version == "0.1" || version.hasPrefix("0.1.") || version.hasPrefix("0.1-")), let first = history.days.first {
            earned.append(Achievement(kind: .alphaTester, tier: "0.1", value: 1,
                                      awardedAt: max(first.window.start, history.now)))
        }
        if let start = history.days.first?.window.start,
           let year = history.calendar.calendar.date(byAdding: .year, value: 1,
                                                     to: Date(timeIntervalSince1970: TimeInterval(start.epochSeconds))) {
            let anniversary = Timestamp(epochSeconds: Int64(year.timeIntervalSince1970))
            if anniversary <= history.now {
                earned.append(Achievement(kind: .anniversary, tier: "1", value: 1, awardedAt: anniversary))
            }
        }
        if let founding = history.days.first(where: { $0.day.year == foundingYear && $0.isActive }) {
            earned.append(Achievement(kind: .foundingYear, tier: String(foundingYear), value: 1,
                                      awardedAt: founding.window.start))
        }
        var activeByYear: [Int: Int] = [:]
        for day in history.days where day.isActive {
            activeByYear[day.day.year, default: 0] += 1
            if activeByYear[day.day.year] == yearOfBuildingDays {
                earned.append(Achievement(kind: .yearOfBuilding, tier: String(day.day.year),
                                          value: Int64(yearOfBuildingDays), awardedAt: day.window.start))
            }
        }
        return earned
    }
}

// MARK: - Progress

/// How far a habit medal not yet earned has come.
public struct AchievementProgress: Hashable, Sendable {
    public let badge: AchievementBadge
    public let current: Int64
    public let target: Int64

    public var fraction: Double { target > 0 ? min(1, Double(current) / Double(target)) : 0 }
}

extension AchievementProgress {
    /// The next medal on each habit ladder, with how far it has come.
    /// Volume, sessions and range ladders are left out on purpose; see
    /// `AchievementCategory.isHabit`.
    public static func next(_ history: AchievementHistory, earned: [Achievement],
                            catalogue: [AchievementBadge]) -> [AchievementProgress] {
        let streaks = Streaks(days: history.days)
        var savedNanos: Int64 = 0
        for day in history.days {
            let value = day.totals.cacheSavings.saved.raw
            let (sum, overflow) = savedNanos.addingReportingOverflow(value)
            savedNanos = overflow ? (value >= 0 ? .max : .min) : sum
        }
        let savedDollars = savedNanos / Nanodollars.perDollar
        var steadyRun: Int64 = 0
        var runs: [String: Int64] = [:]
        for cycle in history.closedCycles {
            let series = "\(cycle.provider.rawValue):\(cycle.key)"
            if cycle.peak >= QuotaThresholds.exhausted { runs[series] = 0 }
            else if cycle.peak >= Achievement.busyWindow { runs[series, default: 0] += 1 }
            steadyRun = runs.values.max() ?? 0
        }
        let current: [AchievementKind: Int64] = [
            .streak: Int64(streaks.current), .cacheSavings: savedDollars, .steadyHand: steadyRun,
        ]
        return current.compactMap { kind, value in
            let earnedTiers = Set(earned.filter { $0.kind == kind }.map(\.tier))
            guard let badge = catalogue.first(where: { $0.kind == kind && !earnedTiers.contains($0.tier ?? "") }),
                  let target = badge.threshold else { return nil }
            return AchievementProgress(badge: badge, current: value, target: target)
        }
        .sorted { $0.fraction > $1.fraction }
    }
}

// MARK: - Records

/// Personal bests. Observations, never medals: a bigger day is not an
/// accomplishment in a spend monitor.
public struct PersonalRecords: Equatable, Sendable {
    public struct Record: Equatable, Sendable {
        public let value: Int64
        /// The day it was set, or the first day of its week.
        public let on: LocalDay
    }

    public let biggestDay: Record?
    public let biggestWeek: Record?
    /// Seconds, under the marathon ceiling so a resumed conversation does not count.
    public let longestSession: Record?
    public let longestStreak: Record?
    public let mostSessionsInADay: Record?

    public init(_ history: AchievementHistory) {
        let days = history.days
        biggestDay = days.max { $0.totals.tokens.processed < $1.totals.tokens.processed }
            .flatMap { $0.totals.tokens.processed > 0 ? Record(value: $0.totals.tokens.processed, on: $0.day) : nil }
        var weeks: [TimeWindow: Int64] = [:]
        for day in days { weeks[history.calendar.week(containing: day.window.start), default: 0] += day.totals.tokens.processed }
        biggestWeek = weeks.max { $0.value < $1.value }
            .flatMap { $0.value > 0 ? Record(value: $0.value, on: history.calendar.day(containing: $0.key.start)) : nil }
        longestSession = history.sessions.compactMap { session -> Record? in
            guard let end = session.endedAt else { return nil }
            let length = end.seconds(since: session.startedAt)
            guard length > 0, length <= Achievement.marathonCeiling else { return nil }
            return Record(value: length, on: history.calendar.day(containing: session.startedAt))
        }.max { $0.value < $1.value }
        let streaks = Streaks(days: days)
        longestStreak = streaks.best.map { Record(value: Int64($0.length), on: $0.end) }
        mostSessionsInADay = days.max { $0.sessions < $1.sessions }
            .flatMap { $0.sessions > 0 ? Record(value: Int64($0.sessions), on: $0.day) : nil }
    }
}
