//
//  StoreMaintenance.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import Foundation

/// How long every event is kept in full. Older history is compacted into
/// 15-minute totals, which keep lifetime tokens, cost and charts exact but
/// drop per-event detail, so the database stays near the window's size.
public enum DetailRetention: Int, CaseIterable, Sendable {
    case ninetyDays = 90
    case halfYear = 180
    case year = 365
    case forever = 0

    /// Small enough that a heavy user's database settles near 2 GB, long
    /// enough to drill into any session from the last six months.
    public static let `default` = DetailRetention.halfYear

    /// The settings value, stored as a number of days; 0 is forever.
    public init(days: Int) {
        self = DetailRetention(rawValue: days) ?? .default
    }

    /// The window in seconds; nil keeps every event.
    public var window: Int64? { self == .forever ? nil : Int64(rawValue) * 86_400 }
}

/// How far back history is kept at all. Unlike the detail window, which
/// only compacts, this deletes: usage older than it is gone from Burnline,
/// and comes back only while a provider still keeps it.
public enum HistoryRetention: Int, CaseIterable, Sendable {
    case forever = 0
    case oneYear = 1
    case twoYears = 2
    case fiveYears = 5

    /// Lifetime history is the point of Burnline, so nothing is deleted
    /// unless the user asks.
    public static let `default` = HistoryRetention.forever

    /// The settings value, stored as a number of years; 0 is forever.
    public init(years: Int) {
        self = HistoryRetention(rawValue: years) ?? .default
    }

    /// The span kept, in seconds; nil keeps everything.
    public var window: Int64? { self == .forever ? nil : Int64(rawValue) * 365 * 86_400 }
}

/// Keeps the database small and its query plans current: a maintenance pass
/// a day, compacting history older than the detail window, and planner
/// statistics refreshed at quit. Each step is a short transaction, so it
/// never holds up a sync for long.
public struct StoreMaintenance: Sendable {
    public static let interval: Duration = .seconds(86_400)

    let database: BurnlineDatabase
    let clock: any WallClock
    private let setting: Shared<DetailRetention>
    private let historySetting: Shared<HistoryRetention>

    /// The detail window now. Settings can change it while the app runs.
    public var retention: DetailRetention { setting.value }
    public var history: HistoryRetention { historySetting.value }

    public init(database: BurnlineDatabase, retention: DetailRetention, history: HistoryRetention = .default,
                clock: any WallClock) {
        self.database = database
        self.clock = clock
        setting = Shared(retention)
        historySetting = Shared(history)
    }

    /// Takes a new detail window, compacting at once if it shrank, rather
    /// than at the next daily pass.
    @concurrent public func change(to retention: DetailRetention) async {
        let previous = setting.swap(retention)
        guard let window = retention.window else { return }
        if previous.window.map({ window < $0 }) ?? true { pass() }
    }

    /// Takes a new history span, deleting at once what falls outside it if
    /// it shrank.
    @concurrent public func change(history: HistoryRetention) async {
        let previous = historySetting.swap(history)
        guard let window = history.window else { return }
        if previous.window.map({ window < $0 }) ?? true { pass() }
    }

    /// Runs now and then every `interval` until the calling task is
    /// cancelled. A failed pass, such as on a full disk, is retried at the next.
    @concurrent public func run<C: Clock<Duration>>(clock sleeper: C = ContinuousClock()) async {
        repeat {
            pass()
        } while (try? await sleeper.sleep(for: Self.interval)) != nil
    }

    func pass() {
        if let window = historySetting.value.window {
            _ = try? database.usage.deleteEvents(before: clock.now.adding(seconds: -window))
        }
        if let window = setting.value.window {
            _ = try? database.compact(before: clock.now.adding(seconds: -window))
        }
        _ = try? database.maintain()
    }

    /// For the app's quit: fast, and skipped on failure.
    public func atQuit() {
        try? database.optimize()
    }
}

/// A retention setting, shared between the maintenance pass and settings.
private final class Shared<Value: Sendable>: @unchecked Sendable {
    // @unchecked: `stored` is only read and written under `lock`.
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    /// Sets the new value and returns the old one.
    func swap(_ new: Value) -> Value {
        lock.withLock {
            let old = stored
            stored = new
            return old
        }
    }
}
