//
//  DataServiceTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineServices
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import Testing

/// Export files, backup folders, retention and diagnostics, as the
/// interface uses them.
struct DataServiceTests {
    static let now = AggregationServiceTests.now

    static func service(daysAgo: [Int64] = [0, 1, 2], project: String? = nil)
        throws -> (DataService, BurnlineDatabase, URL) {
        let directory = TestDirectory.make("Data")
        let schema = try Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema"))
        let database = try BurnlineDatabase.open(at: StoreLocation(directory: directory.appending(path: "store")),
                                                 schema: schema, clock: ManualClock(now))
        let records = try daysAgo.map { ago in
            IncomingUsage(sourceEventID: "e\(ago)", sessionSourceID: "s\(ago)",
                          project: project.map { ProjectCandidate(identity: .path(pathHash: $0), displayName: $0, path: nil) },
                          rawModel: "claude-opus-5", timestamp: now.adding(seconds: -ago * 86_400 - 60),
                          tokens: try TokenCounts(output: 10), sourceType: "test", file: "/a.jsonl",
                          schemaVersion: nil, offset: 0)
        }
        try database.ingest(records, issues: [], provider: .claudeCode)
        let reconciler = Reconciler(ingestion: IngestionActor(database: database), adapters: [])
        let service = DataService(database: database, reconciler: reconciler, changes: ChangeFeed(), schema: schema,
                                  clock: ManualClock(now))
        return (service, database, directory)
    }

    @Test func `a CSV export has a header and a row per event, quoted where it must be`() async throws {
        let (service, _, directory) = try Self.service(project: "acme, \"tools\"")
        let file = directory.appending(path: "events.csv")
        #expect(try await service.export(.events, as: .csv, to: file) == 3)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("timestamp,provider,model,project,session,"))
        #expect(lines[1].contains(",claude_code,claude-opus-5,\"acme, \"\"tools\"\"\",s2,"))
    }

    @Test func `a JSON export is valid JSON with one object per total`() async throws {
        let (service, database, directory) = try Self.service()
        let file = directory.appending(path: "totals.json")
        let rows = try await service.export(.totals, as: .json, to: file)
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        #expect(parsed?.count == rows)
        #expect(rows == (try database.diagnosticCounts())["usage_rollups"])
        #expect(parsed?.first?["provider"] as? String == "claude_code")
        #expect(parsed?.first?["output_tokens"] as? Int == 10)
    }

    @Test func `an empty export is still a valid file`() async throws {
        let (service, _, directory) = try Self.service(daysAgo: [])
        let file = directory.appending(path: "empty.json")
        #expect(try await service.export(.events, as: .json, to: file) == 0)
        #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [Any])?.isEmpty == true)
    }

    @Test func `an export failure preserves the existing destination`() async throws {
        let (service, database, directory) = try Self.service()
        let file = directory.appending(path: "events.csv")
        let original = Data("previous export".utf8)
        try original.write(to: file)
        try database.write { try $0.execute(sql: "DROP TABLE usage_events") }

        await #expect(throws: (any Error).self) {
            try await service.export(.events, as: .csv, to: file)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect((try? Data(contentsOf: file)) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["events.csv", "store"])
    }

    @Test func `a successful export replaces the existing destination`() async throws {
        let (service, _, directory) = try Self.service()
        let file = directory.appending(path: "events.json")
        try Data("previous export".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try await service.export(.events, as: .json, to: file) == 3)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        #expect(rows?.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["events.json", "store"])
    }

    @Test func `EC-D2 a failed settings copy leaves no restore staged`() async throws {
        let (service, database, directory) = try Self.service()
        let folder = directory.appending(path: "Backup")
        try await service.backup(to: folder, settings: Data("settings".utf8))
        let settings = folder.appending(path: DataService.backupSettingsName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path) }
        await #expect(throws: (any Error).self) { try await service.stageRestore(from: folder) }
        #expect(!DatabaseBackups.hasStagedRestore(in: database.location))
        #expect(DataService.takeStagedSettings(in: database.location.directory) == nil)
    }

    @Test func `a backup folder carries the settings, and restoring stages both`() async throws {
        let (service, database, directory) = try Self.service()
        let folder = directory.appending(path: "Burnline Backup")
        let settings = try PropertyListSerialization.data(fromPropertyList: ["weekStart": 2], format: .xml, options: 0)
        try await service.backup(to: folder, settings: settings)

        let plan = try await service.stageRestore(from: folder)
        #expect(plan.includesSettings && plan.inspection.events == 3)
        #expect(DatabaseBackups.hasStagedRestore(in: database.location))
        #expect(DataService.takeStagedSettings(in: database.location.directory) == settings)
        #expect(DataService.takeStagedSettings(in: database.location.directory) == nil)

        service.cancelRestore()
        #expect(!DatabaseBackups.hasStagedRestore(in: database.location))
    }

    @Test func `a repeated backup never removes the existing backup folder`() async throws {
        let (service, _, directory) = try Self.service()
        let folder = directory.appending(path: "existing-backup")
        let settings = Data("original settings".utf8)
        try await service.backup(to: folder, settings: settings)
        let original = try Data(contentsOf: folder.appending(path: DataService.backupDatabaseName))
        await #expect(throws: (any Error).self) {
            try await service.backup(to: folder, settings: Data("replacement".utf8))
        }
        #expect(try Data(contentsOf: folder.appending(path: DataService.backupDatabaseName)) == original)
        #expect(try Data(contentsOf: folder.appending(path: DataService.backupSettingsName)) == settings)
    }

    @Test func `EC-D5 a shorter history span deletes what falls outside it`() async throws {
        let (_, database, _) = try Self.service(daysAgo: [0, 400, 800])
        let maintenance = StoreMaintenance(database: database, retention: .forever, clock: ManualClock(Self.now))
        await maintenance.change(history: .oneYear)
        #expect(try database.usage.count() == 1)
        await maintenance.change(history: .forever)
        #expect(try database.usage.count() == 1)
    }

    @Test func `diagnostics carry counts, never a project, session or the home folder`() async throws {
        let (service, _, _) = try Self.service(project: "secret-project")
        let report = await service.diagnostics(app: "1.0 (1)", settings: ["Detail window: 180 days"])
        #expect(report.contains("usage_events 3"))
        #expect(report.contains("Setting: Detail window: 180 days"))
        #expect(!report.contains("secret-project") && !report.contains("s0"))
        #expect(!report.contains(NSHomeDirectory()))
        #expect(DataService.redact("/Users/someone/Library/x", home: "/Users/someone") == "~/Library/x")
    }
}

/// Settings → Data's delete and repair actions, as the service runs them:
/// each changes the store as promised and tells every page to read again.
struct DataRepairTests {
    /// Providers heard so far, kept outside the wait so a timeout still reports them.
    final class Collected: @unchecked Sendable {
        // @unchecked: `heard` is only touched under `lock`.
        private let lock = NSLock()
        private var heard: Set<ProviderKey> = []
        var providers: Set<ProviderKey> { lock.withLock { heard } }
        func insert(_ provider: ProviderKey) -> Int { lock.withLock { heard.insert(provider); return heard.count } }
    }

    static let everything = TimeWindow(start: Timestamp(epochSeconds: 0), end: Timestamp(epochSeconds: .max))

    struct Fixture {
        let service: DataService
        let database: BurnlineDatabase
        let changes: AsyncStream<StatusChange>

        init() throws {
            let (_, database, _) = try DataServiceTests.service()
            let feed = ChangeFeed()
            changes = feed.changes()
            self.database = database
            let schema = try Schema(directory: IngestionActorTests.repositoryRoot.appending(path: "shared/schema"))
            service = DataService(database: database,
                                  reconciler: Reconciler(ingestion: IngestionActor(database: database), adapters: []),
                                  changes: feed, schema: schema, clock: ManualClock(DataServiceTests.now))
        }

        /// The providers the next announcement told pages to reload; whatever
        /// arrived within two seconds, so a missing one fails rather than hangs.
        func announced() async -> Set<ProviderKey> {
            let changes = changes
            let collected = Collected()
            _ = await within {
                for await change in changes {
                    if case .usage(let provider) = change, collected.insert(provider) == ProviderKey.allCases.count {
                        return true
                    }
                }
                return nil
            }
            return collected.providers
        }
    }

    @Test func `deleting a provider's history removes it and every page reloads`() async throws {
        let fixture = try Fixture()
        let report = try await fixture.service.delete(.provider(.claudeCode))
        #expect(report.events == 3)
        #expect(try fixture.database.usage.events(in: Self.everything).isEmpty)
        #expect(await fixture.announced() == Set(ProviderKey.allCases))
    }

    @Test func `deleting one provider's history keeps every other provider's, and its totals`() async throws {
        let fixture = try Fixture()
        try fixture.database.ingest([IncomingUsage(
            sourceEventID: "codex", sessionSourceID: "c", project: nil, rawModel: "gpt-5.5",
            timestamp: DataServiceTests.now.adding(seconds: -60), tokens: try TokenCounts(output: 7),
            sourceType: "test", file: "/b.jsonl", schemaVersion: nil, offset: 0)], issues: [], provider: .codex)

        _ = try await fixture.service.delete(.provider(.claudeCode))

        let left = try fixture.database.usage.events(in: Self.everything)
        #expect(left.map(\.provider) == [.codex])
        #expect(try fixture.database.usage.totals(in: Self.everything).tokens.output == 7)
        #expect(try await fixture.service.check().isHealthy)
    }

    @Test func `the check finds totals that drifted from their events, and Rebuild Totals repairs them`() async throws {
        let fixture = try Fixture()
        try fixture.database.write { try $0.execute(sql: "DELETE FROM usage_rollups") }
        #expect(try await !fixture.service.check().isHealthy)

        try await fixture.service.rebuildTotals()

        #expect(try await fixture.service.check().isHealthy)
        #expect(await fixture.announced() == Set(ProviderKey.allCases))
    }

    @Test func `Recalculate Prices prices events stored before their price was known`() async throws {
        let fixture = try Fixture()
        #expect(try fixture.database.usage.events(in: Self.everything).allSatisfy { $0.cost.amount == nil })
        try fixture.database.pricing.apply(PricingManifest.decode(PricingUpdaterTests.manifest([
            ("1970-01-01T00:00:00Z", "10")])))

        #expect(try await fixture.service.recalculatePrices() == 3)

        // 10 output tokens at $10 a million.
        let costs = try fixture.database.usage.events(in: Self.everything).map(\.cost.amount)
        #expect(costs == Array(repeating: Nanodollars(raw: 100_000), count: 3))
    }
}
