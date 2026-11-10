//
//  Reconciler.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineProviders
import BurnlineStore
import Foundation

/// Keeps the database in step with every provider's files.
///
/// Three things start a sync: a file watcher reporting a change, which is how
/// a new reply appears within seconds; a slow sweep, which catches whatever
/// the watcher missed; and an explicit `reconcile()`, which the app calls at
/// launch and after the Mac wakes. All of them are the same
/// incremental sync, so a spurious trigger costs a stat per file.
///
/// Providers are synced one at a time and independently: one that fails is
/// recorded and the rest carry on. Only the providers the user chose to
/// track are read; the rest are never opened.
public actor Reconciler {
    /// How often to sweep with no watcher signal. The watcher covers the
    /// common case, so this only bounds how stale a missed change can be.
    public static let defaultSweepInterval: Duration = .seconds(300)

    let ingestion: IngestionActor
    let adapters: [any UsageProviderAdapter]
    /// Told when a sync wrote new events, so quota is read more often while
    /// a provider is in use.
    let onNewUsage: @Sendable (ProviderKey) async -> Void
    /// Told when saving starts failing, with why, and when it recovers, with nil.
    let onStorageChange: @Sendable (StoreFailure?) async -> Void
    let clock: any WallClock
    /// The providers chosen for tracking.
    public private(set) var tracked: Set<ProviderKey>

    /// The most recent result per provider.
    public private(set) var latest: [ProviderKey: ImportResult] = [:]
    /// Providers whose most recent sync hit a store failure, such as a full
    /// disk. Cleared by that provider's next successful sync.
    public private(set) var failures: [ProviderKey: StoreError] = [:]
    /// When each provider last synced, and when its current failure began.
    private var syncedAt: [ProviderKey: Timestamp] = [:]
    private var failingSince: [ProviderKey: Timestamp] = [:]

    public init(ingestion: IngestionActor, adapters: [any UsageProviderAdapter],
                tracked: Set<ProviderKey> = Set(ProviderKey.allCases), clock: any WallClock = SystemClock(),
                onNewUsage: @escaping @Sendable (ProviderKey) async -> Void = { _ in },
                onStorageChange: @escaping @Sendable (StoreFailure?) async -> Void = { _ in }) {
        self.ingestion = ingestion
        self.adapters = adapters
        self.tracked = tracked
        self.clock = clock
        self.onNewUsage = onNewUsage
        self.onStorageChange = onStorageChange
    }

    /// Why usage is not being saved, if it is not.
    public var storageFailure: StoreFailure? {
        failures.values.first?.failure
    }

    /// Whether each provider's tool is on this Mac, without reading any of
    /// its history, for choosing what to track.
    public func detections() -> [ProviderKey: ProviderDetection] {
        Dictionary(adapters.map { ($0.provider, $0.detect()) }, uniquingKeysWith: { first, _ in first })
    }

    /// Starts tracking `provider` and imports its history now.
    public func track(_ provider: ProviderKey) async {
        guard tracked.insert(provider).inserted else { return }
        for adapter in adapters where adapter.provider == provider { await reconcile(adapter) }
    }

    /// Each tracked provider's health as the interface shows it, from its
    /// latest sync. A provider not yet synced is absent.
    public func health() -> [ProviderKey: ProviderHealth] {
        var health: [ProviderKey: ProviderHealth] = [:]
        for adapter in adapters where tracked.contains(adapter.provider) {
            let provider = adapter.provider
            if let error = failures[provider], let since = failingSince[provider] {
                health[provider] = .degraded(reason: "New usage is not being saved: \(error.failure.cause).",
                                             since: since)
                continue
            }
            guard let result = latest[provider], let synced = syncedAt[provider] else { continue }
            health[provider] = switch result.detection {
            case .installed: .healthy(lastImport: synced)
            case .notInstalled: .notInstalled
            case .unavailable(let reason): .unavailable(reason: reason)
            }
        }
        return health
    }

    /// Reads every provider's history again from the start, as for a
    /// repair: what the providers still keep, and Burnline lost or never
    /// read, comes back. Usage the user deleted comes back too.
    public func rescanFromStart() async throws(StoreError) {
        try await ingestion.forgetSources()
        await reconcile()
    }

    /// Syncs every tracked provider once.
    public func reconcile() async {
        for adapter in adapters {
            await reconcile(adapter)
        }
    }

    private func reconcile(_ adapter: any UsageProviderAdapter) async {
        guard tracked.contains(adapter.provider) else { return }
        let before = storageFailure
        await sync(adapter)
        if storageFailure != before { await onStorageChange(storageFailure) }
    }

    private func sync(_ adapter: any UsageProviderAdapter) async {
        do {
            let result = try await ingestion.sync(from: adapter)
            latest[adapter.provider] = result
            syncedAt[adapter.provider] = clock.now
            failures[adapter.provider] = nil
            failingSince[adapter.provider] = nil
            if result.eventsWritten > 0 { await onNewUsage(adapter.provider) }
        } catch {
            if failures[adapter.provider] == nil { failingSince[adapter.provider] = clock.now }
            failures[adapter.provider] = error
        }
    }

    /// Watches every installed provider and sweeps on `clock` until the
    /// calling task is cancelled. A provider installed after this starts has
    /// no watcher yet, and is picked up by the sweep.
    public func run<C: Clock<Duration>>(sweepEvery interval: Duration = defaultSweepInterval,
                                        clock: C = ContinuousClock()) async {
        await withDiscardingTaskGroup { group in
            for adapter in adapters {
                for watcher in adapter.watchedDirectories().compactMap({ FileWatcher(directory: $0) }) {
                    group.addTask {
                        for await _ in watcher.changes {
                            await self.reconcile(adapter)
                        }
                    }
                }
            }
            group.addTask {
                while (try? await clock.sleep(for: interval)) != nil {
                    await self.reconcile()
                }
            }
        }
    }
}
