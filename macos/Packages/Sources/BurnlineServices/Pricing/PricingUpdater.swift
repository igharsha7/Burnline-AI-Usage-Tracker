//
//  PricingUpdater.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import Foundation

/// Keeps prices current: the manifest bundled with the app, then a newer copy
/// fetched from Burnline's repository at most once a day.
///
/// The fetch is the only network call ingestion makes. It downloads a public
/// file and sends nothing about the user; it can be switched off, and without
/// it the bundled prices still price all history. A fetched manifest is used
/// only if it keeps every version already known exactly as it was, so a bad
/// or tampered file can add prices but never move historical cost. Whatever is
/// added re-prices the events it covers, and nothing else.
public actor PricingUpdater {
    /// Where the scheduled pricing job publishes. A data-only branch, so price
    /// updates never wait on an app release or touch `main` directly.
    public static let defaultURL =
        URL(string: "https://raw.githubusercontent.com/igharsha7/Burnline-AI-Usage-Tracker/pricing-data/shared/pricing/pricing.json")!
    /// LiteLLM, the generator's source, changes several times a day; prices
    /// themselves change rarely, so a day is fresh enough.
    public static let refreshInterval: Int64 = 86_400
    static let requestTimeout: TimeInterval = 30

    public enum Outcome: Equatable, Sendable {
        case disabled
        /// The cached copy is younger than the refresh interval.
        case fresh
        case unchanged
        /// New versions were added and `repriced` events updated.
        case updated(versions: Int, repriced: Int)
        /// The download failed or was refused; the reason is for diagnostics.
        case failed(String)
    }

    public typealias Fetch = @Sendable (URL) async throws -> Data

    let database: BurnlineDatabase
    let bundled: PricingManifest
    let cacheFile: URL
    let url: URL
    private(set) var enabled: Bool
    let clock: any WallClock
    let fetch: Fetch

    init(database: BurnlineDatabase, bundled: PricingManifest, cacheFile: URL, url: URL = defaultURL,
         enabled: Bool, clock: any WallClock, fetch: @escaping Fetch = PricingUpdater.download) {
        self.database = database
        self.bundled = bundled
        self.cacheFile = cacheFile
        self.url = url
        self.enabled = enabled
        self.clock = clock
        self.fetch = fetch
    }

    /// Applies the bundled manifest and the last fetched copy, re-pricing what
    /// they add. Runs before the first sync, so new events price on arrival.
    @discardableResult
    public func applyLocal() throws(StoreError) -> Int {
        var repriced = try apply(bundled)
        if let cached = try? PricingManifest.load(from: cacheFile), cached.preserves(bundled) {
            repriced += try apply(cached)
        }
        return repriced
    }

    /// Switches the daily fetch on or off, as Settings does.
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    /// How many price versions are known, and when prices were last fetched.
    public func info() -> (versions: Int, fetchedAt: Timestamp?) {
        ((try? database.pricing.count()) ?? 0, cacheAge())
    }

    /// Fetches a newer manifest if the cached one is older than a day, or
    /// now when `force`, as Settings' Check Now does.
    @discardableResult
    public func refresh(force: Bool = false) async -> Outcome {
        guard enabled else { return .disabled }
        // A cache dated after now means the clock went back; fetch rather than trust it.
        if !force, let fetchedAt = cacheAge(), (0..<Self.refreshInterval).contains(clock.now.seconds(since: fetchedAt)) {
            return .fresh
        }
        let data: Data
        do { data = try await fetch(url) } catch { return .failed("download: \(error.localizedDescription)") }

        let manifest: PricingManifest
        do { manifest = try PricingManifest.decode(data) } catch { return .failed("unreadable: \(error)") }
        let previous = try? PricingManifest.load(from: cacheFile)
        guard manifest.preserves(bundled), previous.map(manifest.preserves) ?? true else {
            return .failed("refused: it changes prices already recorded")
        }
        do {
            let before = try database.pricing.count()
            let repriced = try apply(manifest)
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: cacheFile, options: .atomic)
            // Dated by the injected clock, the one freshness is judged against.
            try FileManager.default.setAttributes([.modificationDate: clock.now.date], ofItemAtPath: cacheFile.path)
            let added = try database.pricing.count() - before
            return added == 0 ? .unchanged : .updated(versions: added, repriced: repriced)
        } catch {
            return .failed("store: \(error)")
        }
    }

    /// Refreshes now and then every day until the calling task is cancelled.
    public func run<C: Clock<Duration>>(clock: C = ContinuousClock()) async {
        repeat {
            await refresh()
        } while (try? await clock.sleep(for: .seconds(Self.refreshInterval))) != nil
    }

    private func apply(_ manifest: PricingManifest) throws(StoreError) -> Int {
        try database.pricing.apply(manifest)
        return try database.pricing.repricePending()
    }

    /// When the cached copy was written, which is when it was last fetched.
    private func cacheAge() -> Timestamp? {
        (try? FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate] as? Date)
            .flatMap(Timestamp.init)
    }

    /// A plain HTTPS GET with no cookies, cache, or credentials, so the request
    /// carries nothing beyond the URL.
    @Sendable static func download(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
