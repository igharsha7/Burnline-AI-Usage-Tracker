//
//  StatusModel.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineServices
import Foundation
import Observation

/// Everything the menu bar shows, kept current by pushed changes rather than
/// polling, so the popover opens instantly from what is already here.
///
/// It exists before ingestion starts, empty, so the scenes can be built at
/// launch; `connect` fills it once the services are up.
@Observable
public final class StatusModel {
    public private(set) var today: TodayStatus?
    public private(set) var quotas: [ProviderQuotaState] = []
    public private(set) var live: LiveActivity?
    /// This history's own measure of busy, against which live heat is judged.
    public private(set) var heatScale = HeatScale.starting
    public private(set) var calendar = LocalCalendar(timeZone: .current, firstWeekday: .monday)
    public private(set) var refreshing = false
    /// Why Burnline's database is not saving usage, or could not be opened.
    public private(set) var storeFailure: StoreFailure?
    /// Whether the database never opened, so no figure can be read at all.
    public private(set) var failedToStart = false
    /// Counts requests to bring the dashboard forward from outside a view,
    /// as a notification's click does; the menu-bar label opens it on each.
    public private(set) var dashboardRequests = 0
    /// How the last read of Claude Code's login went, so the Limits page can
    /// offer to allow it again; nil until ingestion connects.
    public private(set) var claudeLogin: ClaudeLoginAccess.Status?

    public func requestDashboard() { dashboardRequests += 1 }

    @ObservationIgnored private var services: Services?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var liveExpiry: Task<Void, Never>?
    @ObservationIgnored private var usageReload: Task<Void, Never>?
    @ObservationIgnored private var usageDirty = false
    @ObservationIgnored private var usageReloads = 0
    @ObservationIgnored let clock: any WallClock
    @ObservationIgnored let sleep: Sleep
    /// Says the live pace as a book or codebase every so often, when the
    /// comparison corpus loaded.
    @ObservationIgnored public var comparisons: ComparisonEngine?

    struct Services {
        let status: StatusService
        let quota: QuotaActor
        let claudeLogin: ClaudeLoginAccess?
        let allowClaudeLogin: (@Sendable () async -> Void)?
    }

    /// Waits for a duration, for the midnight and live-expiry timers; tests
    /// replace it to run those timers without waiting.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public init(clock: any WallClock = SystemClock(), sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.clock = clock
        self.sleep = sleep
    }

    /// Starts following the services: the figures already stored first, then
    /// every change as it is pushed, and a fresh day at midnight.
    /// `claudeLogin` and `allowClaudeLogin` are the live app's, for the
    /// Limits page's offer to read Claude Code's login again.
    public func connect(status: StatusService, quota: QuotaActor, changes: ChangeFeed, calendar: LocalCalendar,
                        claudeLogin: ClaudeLoginAccess? = nil, allowClaudeLogin: (@Sendable () async -> Void)? = nil) {
        services = Services(status: status, quota: quota, claudeLogin: claudeLogin, allowClaudeLogin: allowClaudeLogin)
        self.calendar = calendar
        // Subscribe before the first load, so no change falls between.
        let stream = changes.changes()
        tasks.append(Task { [weak self] in
            await self?.reloadUsage()
            guard let self else { return }
            let stored = await quota.states()
            // A state pushed while this load waited is at least as new as the
            // stored one, since both come from the quota actor; keep it.
            let shown = Set(quotas.map(\.provider))
            quotas = Self.ordered(quotas + stored.filter { !shown.contains($0.provider) })
            self.claudeLogin = claudeLogin?.status
            heatScale = await status.heatScale()
        })
        tasks.append(Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                switch change {
                case .usage: self.scheduleUsageReload()
                case .achievements: break
                case .quota(let state):
                    replace(state)
                    if state.provider == .claudeCode { self.claudeLogin = services?.claudeLogin?.status }
                case .storage(let failure): storeFailure = failure
                }
            }
        })
        tasks.append(Task { [weak self] in
            // Today starts over at midnight, used or not.
            while !Task.isCancelled {
                guard let sleep = self?.sleep else { return }
                guard let end = self?.today?.endsAt, let now = self?.clock.now else {
                    try? await sleep(.seconds(60))
                    continue
                }
                try? await sleep(.seconds(max(1, end.seconds(since: now))))
                await self?.reloadUsage()
                // A day's usage moves the scale a little; once a day is enough.
                if let scale = await self?.services?.status.heatScale() { self?.heatScale = scale }
            }
        })
    }

    /// The database could not be opened: there is nothing to follow.
    public func fail(_ failure: StoreFailure) {
        storeFailure = failure
        failedToStart = true
    }

    /// The Limits page's history of `state`'s windows, each with what this
    /// Mac used in it.
    func limitHistory(_ state: ProviderQuotaState) async -> [String: LimitHistory] {
        guard let services else { return [:] }
        var history = await Self.history(services.quota, state)
        for window in state.windows {
            guard let start = window.windowStartedAt, let known = history[window.key] else { continue }
            let usage = await services.status.usage(of: state.provider, from: start, until: window.resetAt)
            history[window.key] = LimitHistory(readings: known.readings, past: known.past, usage: usage)
        }
        return history
    }

    @concurrent
    private static func history(_ quota: QuotaActor, _ state: ProviderQuotaState) async -> [String: LimitHistory] {
        quota.history(of: state)
    }

    /// Reads Claude's quota letting macOS ask for Claude Code's login, as
    /// the user asked; the pushed state brings the new status.
    func allowClaudeLogin() async {
        await services?.allowClaudeLogin?()
    }

    /// Reads quota now and reloads the totals: the popover's refresh.
    public func refresh() async {
        guard let services, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await services.quota.refreshAll()
        await reloadUsage()
    }

    /// An agent writes usage every few seconds, often in bursts. Changes
    /// that arrive during a reload are folded into one more, never queued
    /// one reload each, and never delayed.
    private func scheduleUsageReload() {
        guard usageReload == nil else {
            usageDirty = true
            return
        }
        usageReload = Task { [weak self] in
            repeat {
                self?.usageDirty = false
                await self?.reloadUsage()
            } while self?.usageDirty == true
            self?.usageReload = nil
        }
    }

    private func reloadUsage() async {
        guard let services else { return }
        usageReloads += 1
        let generation = usageReloads
        async let today = services.status.today()
        async let live = services.status.live()
        let (newToday, newLive) = await (today, live)
        // Reloads come from pushes, midnight and live's end, and can overlap;
        // an older one finishing last must not put older figures back.
        guard generation == usageReloads else { return }
        if let newToday { self.today = newToday }
        self.live = newLive
        scheduleLiveExpiry()
    }

    /// Live ends when usage stops arriving, which no change announces.
    private func scheduleLiveExpiry() {
        liveExpiry?.cancel()
        guard let end = live?.endsAt else { return }
        let wait = max(1, end.seconds(since: clock.now)), sleep = sleep
        liveExpiry = Task { [weak self] in
            try? await sleep(.seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.reloadUsage()
        }
    }

    /// Sets the figures directly, for previews and tests.
    func show(today: TodayStatus?, quotas: [ProviderQuotaState], live: LiveActivity?,
              storeFailure: StoreFailure? = nil, heatScale: HeatScale = .starting) {
        self.storeFailure = storeFailure
        self.heatScale = heatScale
        self.today = today
        self.quotas = Self.ordered(quotas)
        self.live = live
    }

    private func replace(_ state: ProviderQuotaState) {
        quotas = Self.ordered(quotas.filter { $0.provider != state.provider } + [state])
    }

    static func ordered(_ states: [ProviderQuotaState]) -> [ProviderQuotaState] {
        states.sorted { ProviderKey.allCases.firstIndex(of: $0.provider)! < ProviderKey.allCases.firstIndex(of: $1.provider)! }
    }

    /// How hard usage is burning now, from 0 to 1; 0 when nothing is live.
    var heat: Double { live.map { heatScale.heat(costPerHour: $0.costPerHour) } ?? 0 }
    var heatStage: HeatStage { HeatStage(heat: heat) }

    /// Providers worth a section: any with figures, or a reason to show.
    var visibleQuotas: [ProviderQuotaState] {
        quotas.filter { state in
            if !state.windows.isEmpty { return true }
            if case .degraded = state.health { return true }
            return false
        }
    }
}
