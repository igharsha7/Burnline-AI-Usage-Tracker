//
//  NotificationService.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import Foundation
import UserNotifications

/// Whether the system lets Burnline show notifications.
public enum NotificationPermission: Sendable {
    case notDetermined, denied, allowed
}

/// Shows notifications, so tests can record them instead.
public protocol NotificationPoster: Sendable {
    func permission() async -> NotificationPermission
    /// Asks the user. Only in context, after saying why; never on launch.
    func requestPermission() async -> Bool
    func post(title: String, body: String, identifier: String) async throws
}

/// Turns quota updates and usage syncs into notifications, each sent once.
///
/// Every alert decided is recorded, shown or not, so a denied permission
/// degrades to silence and never to a backlog. Permission is asked for in
/// context: by onboarding, after explaining why; by the test button; and,
/// if neither ever asked, by the first alert there is to show, which is
/// then shown if allowed. Once refused, nothing asks again.
public actor NotificationService {
    let database: BurnlineDatabase
    let poster: any NotificationPoster
    let aggregation: AggregationService
    let clock: any WallClock
    private(set) var planner: AlertPlanner
    private var fired: Set<AlertKey>?
    /// Words the milestones, once the comparison corpus has loaded.
    private var corpus: ComparisonCorpus?
    /// Lifetime tokens at the last check, first read when milestones are
    /// turned on. A fresh store has none: its first import only sets it,
    /// so a history imported at onboarding does not announce a billion.
    private var lifetimeSeen: Double?
    /// When achievements were last judged. Judging reads all of history, so
    /// a burst of imports judges once.
    private var achievementsChecked: Timestamp?
    private(set) var achievementCheck: Task<Void, Never>?
    private let achievementSleep: @Sendable (Duration) async throws -> Void
    private let onAchievements: @Sendable () -> Void

    /// The least time between two judgements of achievements.
    static let achievementInterval: Int64 = 5 * 60
    /// Identifies an achievement notification, so a click on it can open
    /// the Achievements page.
    public static let achievementPrefix = "burnline.achievement"

    /// Alerts older than this belong to windows, days and weeks long over.
    static let memory: Int64 = 40 * 86_400

    public init(database: BurnlineDatabase, poster: any NotificationPoster, aggregation: AggregationService,
                settings: AlertSettings = AlertSettings(), calendar: LocalCalendar, clock: any WallClock = SystemClock(),
                achievementSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                onAchievements: @escaping @Sendable () -> Void = {}) {
        self.database = database
        self.poster = poster
        self.aggregation = aggregation
        self.clock = clock
        self.achievementSleep = achievementSleep
        self.onAchievements = onAchievements
        planner = AlertPlanner(settings: settings, calendar: calendar)
    }

    deinit { achievementCheck?.cancel() }

    public func update(settings: AlertSettings) {
        planner = AlertPlanner(settings: settings, calendar: planner.calendar, locale: planner.locale)
    }

    /// Alerts for one fresh quota reading.
    public func handle(_ update: QuotaUpdate) async {
        var fired = loadFired()
        let rates = update.state.burnRates.compactMapValues { try? $0.get() }
        let alerts = planner.quotaAlerts(previous: update.previous, state: update.state, events: update.events,
                                         burnRates: rates, now: clock.now, fired: &fired)
        self.fired = fired
        await deliver(alerts)
    }

    /// Starts announcing milestones, worded from `corpus`.
    public func use(milestones corpus: ComparisonCorpus) {
        self.corpus = corpus
        lifetimeSeen = lifetimeTokens().flatMap { $0 > 0 ? $0 : nil }
    }

    private func lifetimeTokens() -> Double? {
        (try? aggregation.summary(.all).totals.tokens.processed).map(Double.init)
    }

    /// New usage was imported: checks the milestones, the spend alerts and
    /// the achievements. Spend comes before the achievements, which read the
    /// clock again, so its day and its totals are one moment.
    public func noteUsage() async {
        await checkMilestone()
        await checkSpend()
        await checkAchievements()
    }

    private func checkSpend() async {
        guard planner.settings.dailySpend != nil || planner.settings.weeklySpend != nil else { return }
        let now = clock.now
        let dayWindow = planner.calendar.window(for: planner.calendar.day(containing: now))
        guard let day = try? aggregation.summary(.custom(dayWindow)).totals.cost,
              let week = try? aggregation.summary(.custom(planner.calendar.week(containing: now))).totals.cost
        else { return }
        var fired = loadFired()
        let alerts = planner.spendAlerts(day: day, week: week, now: now, fired: &fired)
        self.fired = fired
        await deliver(alerts)
    }

    /// The highest milestone lifetime usage passed since the last check, if
    /// any; each is announced once.
    private func checkMilestone() async {
        guard let corpus, let total = lifetimeTokens() else { return }
        defer { lifetimeSeen = total > 0 ? total : nil }
        guard planner.settings.milestones, let seen = lifetimeSeen,
              let text = corpus.milestone(crossing: total, from: seen),
              let crossed = corpus.milestones.filter({ $0.tokens > seen && $0.tokens <= total })
                .map(\.tokens).max() else { return }
        var fired = loadFired()
        let key = AlertKey(provider: nil, quotaKey: nil, kind: .milestone, threshold: crossed, cycleToken: "lifetime")
        guard fired.insert(key).inserted else { return }
        self.fired = fired
        await deliver([QuotaAlert(key: key, title: "Milestone", body: text, silent: false)])
    }

    /// Awards what new usage earned, at most once per interval, and tells
    /// of the fresh ones: one by name, several together. A new store's first
    /// awards are its backfill and pass silently, as do late awards for old
    /// usage; every one is marked announced either way.
    private func checkAchievements(afterDelay: Bool = false) async {
        let now = clock.now
        if !afterDelay, let checked = achievementsChecked {
            let elapsed = now.seconds(since: checked)
            if elapsed >= 0, elapsed < Self.achievementInterval {
                // Keep one trailing check: the last import in a burst must
                // still be judged if no more usage arrives.
                if achievementCheck == nil {
                    let delay = Duration.seconds(Self.achievementInterval - elapsed)
                    achievementCheck = Task { [weak self, achievementSleep] in
                        guard (try? await achievementSleep(delay)) != nil, !Task.isCancelled else { return }
                        await self?.finishAchievementCheck()
                    }
                }
                return
            }
        }
        if !afterDelay {
            achievementCheck?.cancel()
            achievementCheck = nil
        }
        let activity = ActivityService(database: database, aggregation: aggregation, calendar: planner.calendar,
                                       clock: clock)
        guard (try? activity.award()) != nil,
              let (unannounced, firstEver) = try? database.achievements.takeUnannounced(at: now) else { return }
        achievementsChecked = now
        onAchievements()
        guard planner.settings.achievements, !firstEver else { return }
        let fresh = unannounced.filter { $0.isFresh(at: now) }
        guard let text = Self.announcement(fresh) else { return }
        await show(title: text.title, body: text.body,
                   identifier: "\(Self.achievementPrefix).\(now.epochSeconds)")
    }

    private func finishAchievementCheck() async {
        defer { achievementCheck = nil }
        await checkAchievements(afterDelay: true)
    }

    /// What a notification says about `achievements`: the medal by name, or
    /// how many and which.
    static func announcement(_ achievements: [Achievement]) -> (title: String, body: String)? {
        let catalogue = AchievementBadge.catalogue(providers: ProviderKey.trackable)
        let badges = achievements.compactMap { achievement in catalogue.first { $0.matches(achievement) } }
        guard let first = badges.first else { return nil }
        if badges.count == 1 {
            return ("New medal: \(first.title)", "\(first.metalName) · \(first.category.title). Click to see it.")
        }
        let names = badges.map(\.title)
        return ("\(badges.count) new medals", "\(names.formatted(.list(type: .and))). Click to see them.")
    }

    /// Whether the system lets Burnline notify. Reading it never asks.
    public func permission() async -> NotificationPermission {
        await poster.permission()
    }

    /// The in-app test. Asks for permission first if it was never asked,
    /// since the user just pressed the button. Says whether it was shown.
    public func sendTest() async -> NotificationPermission {
        var permission = await poster.permission()
        if permission == .notDetermined { permission = await poster.requestPermission() ? .allowed : .denied }
        guard permission == .allowed else { return permission }
        do {
            try await poster.post(title: "Burnline notifications are on",
                                  body: "Limits, resets and banked resets will appear like this.",
                                  identifier: "burnline.test")
            return .allowed
        } catch {
            return .denied
        }
    }

    private func loadFired() -> Set<AlertKey> {
        if let fired { return fired }
        let loaded = (try? database.notifications.fired(since: clock.now.adding(seconds: -Self.memory))) ?? []
        fired = loaded
        return loaded
    }

    private func deliver(_ alerts: [QuotaAlert]) async {
        guard !alerts.isEmpty else { return }
        let now = clock.now
        for alert in alerts { try? database.notifications.record(alert.key, at: now) }
        for alert in alerts where !alert.silent {
            await show(title: alert.title, body: alert.body, identifier: Self.identifier(alert.key))
        }
    }

    /// Posts one notification, asking for permission first if it was never
    /// asked, since there is now something to show.
    private func show(title: String, body: String, identifier: String) async {
        var permission = await poster.permission()
        if permission == .notDetermined { permission = await poster.requestPermission() ? .allowed : .denied }
        guard permission == .allowed else { return }
        try? await poster.post(title: title, body: body, identifier: identifier)
    }

    /// Stable per alert, so the system replaces rather than stacks a repeat.
    static func identifier(_ key: AlertKey) -> String {
        ["burnline", key.provider?.rawValue ?? "all", key.quotaKey ?? "-", key.kind.rawValue,
         key.threshold.map { String(Int64($0)) } ?? "-", key.cycleToken].joined(separator: ".")
    }
}

/// The system's notification centre. Built cheaply; the centre is reached
/// only when used, since it needs an app bundle and a test process has none.
public struct SystemNotificationPoster: NotificationPoster {
    public init() {}

    public func permission() async -> NotificationPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    public func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func post(title: String, body: String, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
