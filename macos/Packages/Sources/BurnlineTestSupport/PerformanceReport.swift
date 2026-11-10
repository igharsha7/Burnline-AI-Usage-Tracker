//
//  PerformanceReport.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// Figures measured by the performance suites, each with the budget it must
/// meet, written as JSON for CI to compare against the base branch.
///
/// The suites run only when `BURNLINE_PERF` names a directory; each writes its
/// own `<suite>.json` there. See docs/performance.md.
public struct PerformanceReport: Codable, Sendable {
    public enum Better: String, Codable, Sendable { case lower, higher }

    public struct Metric: Codable, Sendable {
        public let id: String
        public let title: String
        public let value: Double
        public let unit: String
        public let budget: Double
        public let better: Better
        /// The section of docs/performance.md that explains the budget.
        public let doc: String

        public init(id: String, title: String, value: Double, unit: String, budget: Double, better: Better,
                    doc: String) {
            self.id = id; self.title = title; self.value = value; self.unit = unit
            self.budget = budget; self.better = better; self.doc = doc
        }

        public var withinBudget: Bool { better == .lower ? value <= budget : value >= budget }
    }

    public var metrics: [Metric] = []

    public init() {}

    /// The directory the suites write to, or nil when they should not run.
    public static var directory: URL? {
        ProcessInfo.processInfo.environment["BURNLINE_PERF"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    public static var enabled: Bool { directory != nil }

    public mutating func record(_ metric: Metric) {
        metrics.append(metric)
        print("PERF \(metric.id): \(Self.format(metric.value)) \(metric.unit) (budget \(Self.format(metric.budget)))")
    }

    public func write(suite: String) throws {
        guard let directory = Self.directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appending(path: "\(suite).json"))
    }

    /// Milliseconds in a duration, for reporting.
    public static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The fastest of several runs: on a shared machine, noise only ever adds
    /// time, so the minimum is the steadiest estimate of the work itself.
    public static func fastest(of runs: Int, _ body: () throws -> Void) rethrows -> Duration {
        var best = Duration.seconds(Int64.max)
        for _ in 0..<runs {
            let started = ContinuousClock.now
            try body()
            best = min(best, ContinuousClock.now - started)
        }
        return best
    }

    public static func fastest(of runs: Int, _ body: () async throws -> Void) async rethrows -> Duration {
        var best = Duration.seconds(Int64.max)
        for _ in 0..<runs {
            let started = ContinuousClock.now
            try await body()
            best = min(best, ContinuousClock.now - started)
        }
        return best
    }

    private static func format(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }
}
