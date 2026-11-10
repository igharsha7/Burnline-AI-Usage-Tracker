//
//  Countdown.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// Durations and moments as the menu bar, the dashboard and notifications
/// write them.
public enum Countdown {
    /// "1d 4h", "2h 48m", "52m", "under a minute". The two largest units.
    public static func compact(_ seconds: Int64) -> String {
        guard seconds >= 60 else { return "under a minute" }
        let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// Seconds until `compact(remaining)` reads differently, so a live
    /// countdown redraws only when its text changes: once an hour while it
    /// shows days, once a minute while it shows minutes, and under a minute
    /// only when it reaches zero. Nil once it has.
    public static func nextChange(remaining: Int64) -> Int64? {
        guard remaining > 0 else { return nil }
        if remaining < 60 { return remaining }
        if remaining < 86_400 { return remaining % 60 + 1 }
        return remaining % 3_600 + 1
    }

    /// "48 minutes", "2 hours 10 minutes", "9 hours", "3 days", for a
    /// sentence. Minutes are kept only while they matter.
    public static func spoken(_ seconds: Int64) -> String {
        func plural(_ n: Int64, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        guard seconds >= 60 else { return "under a minute" }
        let minutes = seconds / 60
        if minutes < 60 { return plural(minutes, "minute") }
        let hours = minutes / 60
        if hours < 3, minutes % 60 > 0 { return plural(hours, "hour") + " " + plural(minutes % 60, "minute") }
        if hours < 24 { return plural((seconds + 1_800) / 3_600, "hour") }
        return plural((seconds + 43_200) / 86_400, "day")
    }

    /// "11:20 PM" today, "9:00 AM tomorrow", "Tue 9:00 AM" within the week,
    /// "Nov 9, 9:00 AM" beyond, on the user's calendar and in their locale.
    public static func moment(_ instant: Timestamp, now: Timestamp, calendar: LocalCalendar,
                              locale: Locale = .current) -> String {
        func format(_ template: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar.calendar
            formatter.timeZone = calendar.calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: instant.date)
        }
        let day = calendar.day(containing: instant), today = calendar.day(containing: now)
        if day == today { return format("jmm") }
        if day == calendar.day(containing: calendar.window(for: today).end) { return format("jmm") + " tomorrow" }
        if instant.seconds(since: now) < 6 * 86_400, instant > now { return format("EEE jmm") }
        return format("MMM d jmm")
    }
}
