//
//  QuotaSchedule.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Foundation
import IOKit.ps

/// When to read a provider's quota next. Conservative by design: the
/// provider is never hammered, reads slow down when nothing is happening and
/// on battery, and back off after failures.
enum QuotaSchedule {
    /// Between reads while the provider is in use.
    static let activeInterval: Int64 = 5 * 60
    /// Between reads when it is not.
    static let idleInterval: Int64 = 15 * 60
    /// Between reads while a window is nearly spent, when a reset matters most.
    static let criticalInterval: Int64 = 2 * 60
    /// How much longer intervals get on battery. Not applied near a limit.
    static let batteryFactor: Int64 = 2
    /// Usage this recent counts as in use.
    static let activityWindow: Int64 = 10 * 60
    /// The first wait after a failure, doubled after each further one.
    static let firstBackoff: Int64 = 60
    static let maximumBackoff: Int64 = 30 * 60
    /// How long after a reset time to read, so the provider has had time to
    /// begin the new window.
    static let resetGrace: Int64 = 30

    struct Inputs {
        var lastAttempt: Timestamp?
        var consecutiveFailures = 0
        var lastUsage: Timestamp?
        var nearLimit = false
        var onBattery = false
        /// The soonest reset time of the provider's windows.
        var nextReset: Timestamp?
    }

    static func next(_ inputs: Inputs, now: Timestamp) -> Timestamp {
        guard let last = inputs.lastAttempt else { return now }
        if inputs.consecutiveFailures > 0 {
            let doublings = min(inputs.consecutiveFailures - 1, 10)
            return last.adding(seconds: min(firstBackoff << doublings, maximumBackoff))
        }
        let active = inputs.lastUsage.map { now.seconds(since: $0) <= activityWindow } ?? false
        var interval = inputs.nearLimit ? criticalInterval : active ? activeInterval : idleInterval
        if inputs.onBattery && !inputs.nearLimit { interval *= batteryFactor }
        var due = last.adding(seconds: interval)
        // A reset that lands before the next read is confirmed as soon as it
        // happens, never assumed from the clock.
        if let reset = inputs.nextReset, reset.adding(seconds: resetGrace) > last {
            due = min(due, reset.adding(seconds: resetGrace))
        }
        return due
    }
}

/// Whether the Mac is running on battery.
public protocol PowerSource: Sendable {
    var onBattery: Bool { get }
}

/// The real power source, from IOKit. Low Power Mode counts as battery.
public struct SystemPowerSource: PowerSource {
    public init() {}

    public var onBattery: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
