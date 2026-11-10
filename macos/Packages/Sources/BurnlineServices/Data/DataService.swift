//
//  DataService.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineStore
import Darwin
import Foundation

/// A file format for exported usage.
public enum ExportFormat: String, CaseIterable, Sendable {
    case csv, json

    public var fileExtension: String { rawValue }
}

extension StoreFailure {
    /// Any error from opening or writing the store, as the interface explains it.
    public init(_ error: any Error) {
        if let failure = error as? StoreFailure {
            self = failure
        } else {
            self = (error as? StoreError)?.failure ?? .other(String(describing: error))
        }
    }
}

/// What a backup is, and the restore it stages, as the user sees them.
public struct RestorePlan: Sendable {
    public let inspection: BackupInspection
    /// Whether the backup carried Burnline's settings too.
    public let includesSettings: Bool
}

/// The user's control over Burnline's copy of their history: export,
/// backup and restore, deletion, repair, and diagnostics. Provider files
/// are only ever read; every operation here works on Burnline's own data.
public struct DataService: Sendable {
    /// A backup is a folder holding the database and the settings.
    public static let backupDatabaseName = "burnline.sqlite"
    public static let backupSettingsName = "settings.plist"
    /// Settings waiting for the next launch, with a staged database.
    static let stagedSettingsName = "burnline.pending-settings.plist"

    let database: BurnlineDatabase
    let reconciler: Reconciler
    let changes: ChangeFeed
    let schema: Schema
    let clock: any WallClock

    public init(database: BurnlineDatabase, reconciler: Reconciler, changes: ChangeFeed, schema: Schema,
                clock: any WallClock = SystemClock()) {
        self.database = database
        self.reconciler = reconciler
        self.changes = changes
        self.schema = schema
        self.clock = clock
    }

    private var location: StoreLocation { database.location }

    // MARK: Export

    /// Writes `dataset` to `file` as `format`, streaming, and returns how many
    /// rows it holds. A failure leaves no partial file behind.
    @concurrent
    public func export(_ dataset: ExportDataset, as format: ExportFormat, to file: URL) async throws -> Int {
        let writer = try ExportWriter(file: file, columns: ExportRepository.columns(dataset), format: format)
        do {
            let rows = try database.exports.rows(dataset) { try writer.write($0) }
            try writer.finish()
            return rows
        } catch {
            writer.abandon()
            throw error
        }
    }

    // MARK: Backup and restore

    /// A backup folder at `folder`: a consistent copy of the database, and
    /// `settings`, the app's preferences, which hold no secrets.
    @concurrent
    public func backup(to folder: URL, settings: Data) async throws {
        let manager = FileManager.default
        // Only a folder created by this attempt may be removed on failure.
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try database.backup(to: folder.appending(path: Self.backupDatabaseName))
            try settings.write(to: folder.appending(path: Self.backupSettingsName))
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    /// Checks `backup`, a backup folder or a bare database file, and stages
    /// it to replace the database at the next launch. Nothing changes until
    /// then; a backup that fails its check stages nothing.
    @concurrent
    public func stageRestore(from backup: URL) async throws -> RestorePlan {
        try Self.stageRestore(from: backup, location: location, schema: schema)
    }

    static func stageRestore(from backup: URL, location: StoreLocation, schema: Schema) throws -> RestorePlan {
        let isFolder = (try? backup.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let file = isFolder ? backup.appending(path: Self.backupDatabaseName) : backup
        let manager = FileManager.default
        let staged = location.directory.appending(path: Self.stagedSettingsName)
        do {
            let inspection = try DatabaseBackups.stageRestore(file, in: location, schema: schema)
            if manager.fileExists(atPath: staged.path) { try manager.removeItem(at: staged) }
            let settings = backup.appending(path: Self.backupSettingsName)
            let includesSettings = isFolder && manager.fileExists(atPath: settings.path)
            if includesSettings { try manager.copyItem(at: settings, to: staged) }
            return RestorePlan(inspection: inspection, includesSettings: includesSettings)
        } catch {
            DatabaseBackups.cancelStagedRestore(in: location)
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    public func cancelRestore() {
        DatabaseBackups.cancelStagedRestore(in: location)
        try? FileManager.default.removeItem(at: location.directory.appending(path: Self.stagedSettingsName))
    }

    /// The settings a restore staged, taken once at launch before anything
    /// reads the preferences. Nil when none wait.
    public static func takeStagedSettings(in directory: URL) -> Data? {
        let file = directory.appending(path: stagedSettingsName)
        defer { try? FileManager.default.removeItem(at: file) }
        return try? Data(contentsOf: file)
    }

    // MARK: Deletion

    /// Deletes the scope's history from Burnline's store, then returns the
    /// space to the disk and tells every page to read again.
    @concurrent
    public func delete(_ scope: DeletionScope) async throws -> DeletionReport {
        let report = try database.delete(scope)
        _ = try? database.reclaimSpace()
        announce()
        return report
    }

    // MARK: Repair

    /// Reads every provider's history again from the start.
    public func rescanFromStart() async throws {
        try await reconciler.rescanFromStart()
        announce()
    }

    /// Rebuilds the quarter-hour totals of uncompacted time from its events.
    @concurrent
    public func rebuildTotals() async throws {
        try database.rebuildRollups()
        announce()
    }

    /// Re-applies the model manifest to stored events, then re-prices them.
    /// Returns how many events changed model.
    @concurrent
    public func reapplyModelNames() async throws -> Int {
        let moved = try database.remapModels()
        if moved > 0 { _ = try database.pricing.repriceAll() }
        announce()
        return moved
    }

    /// Re-prices every stored event from the versioned price history, each
    /// at the price in force when it happened, never today's.
    @concurrent
    public func recalculatePrices() async throws -> Int {
        let repriced = try database.pricing.repriceAll()
        announce()
        return repriced
    }

    @concurrent
    public func check() async throws -> DatabaseCheck {
        try database.check()
    }

    /// Every page reads again: the store changed under all of them.
    private func announce() {
        for provider in ProviderKey.allCases { changes.send(.usage(provider)) }
    }

    // MARK: Diagnostics

    /// A plain-text report for a bug report: versions, sizes, counts, sync
    /// results and failures. It holds no usage figure, project, session,
    /// path or credential, and the home folder is written as `~`.
    public func diagnostics(app: String, settings: [String]) async -> String {
        var lines = ["Burnline diagnostics", "App: \(app)",
                     "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        lines += settings.map { "Setting: \($0)" }
        lines += Self.storeLines(database)
        let health = await reconciler.health()
        let latest = await reconciler.latest
        for provider in ProviderKey.allCases {
            var line = "\(provider.rawValue): \(health[provider].map(Self.describe) ?? "not yet synced")"
            if let result = latest[provider] {
                line += "; last sync read \(result.filesRead) files, \(result.filesUnchanged) unchanged, "
                    + "\(result.unreadableFiles) unreadable, \(result.eventsWritten) events written, \(result.issues) issues"
            }
            lines.append(line)
        }
        if let check = try? database.check() {
            lines.append(check.isHealthy ? "Check: healthy" : "Check: " + check.problems.joined(separator: "; "))
        }
        return Self.redact(lines.joined(separator: "\n"))
    }

    private static func storeLines(_ database: BurnlineDatabase) -> [String] {
        let counts = (try? database.diagnosticCounts()) ?? [:]
        var lines = ["Schema: \((try? database.schemaVersion()).map(String.init) ?? "unreadable")"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: database.location.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        lines.append("Store: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) in \(files.count) files, "
                     + "\(DatabaseBackups.list(in: database.location).count) backups")
        lines.append("Rows: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        if let boundary = try? database.compactedBefore(), boundary.epochSeconds > 0 {
            lines.append("Compacted before: \(boundary.date.formatted(.iso8601))")
        }
        return lines
    }

    private static func describe(_ health: ProviderHealth) -> String {
        switch health {
        case .healthy(let last): "healthy, synced \(last.date.formatted(.iso8601))"
        case .degraded(let reason, let since): "degraded since \(since.date.formatted(.iso8601)): \(reason)"
        case .notInstalled: "not installed"
        case .unavailable(let reason): "unavailable: \(reason)"
        }
    }

    /// The home folder as `~`, so the report does not carry the user's name.
    static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}

/// Streams rows a megabyte at a time, replacing the destination only once
/// the complete export has been written and closed.
private final class ExportWriter {
    private let file: URL
    private let directory: URL
    private let staged: URL
    private let handle: FileHandle
    private let columns: [String]
    private let format: ExportFormat
    private var buffer = Data()
    private var first = true
    private static let flushBytes = 1 << 20

    init(file: URL, columns: [String], format: ExportFormat) throws {
        let manager = FileManager.default
        let directory = file.deletingLastPathComponent().appending(path: ".burnline-export-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let staged = directory.appending(path: "export")
        do {
            let permissions = (try? manager.attributesOfItem(atPath: file.path))?[.posixPermissions]
            guard manager.createFile(atPath: staged.path, contents: nil,
                                     attributes: permissions.map { [.posixPermissions: $0] }) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: file.path])
            }
            handle = try FileHandle(forWritingTo: staged)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        self.file = file
        self.directory = directory
        self.staged = staged
        self.columns = columns
        self.format = format
        switch format {
        case .csv: append(columns.joined(separator: ",") + "\n")
        case .json: append("[")
        }
    }

    func write(_ values: [ExportValue]) throws {
        switch format {
        case .csv:
            append(values.map(Self.csv).joined(separator: ",") + "\n")
        case .json:
            let fields = zip(columns, values).map { "\(Self.json($0)):\(Self.json($1))" }
            append((first ? "\n" : ",\n") + "{" + fields.joined(separator: ",") + "}")
        }
        first = false
        if buffer.count >= Self.flushBytes { try flush() }
    }

    func finish() throws {
        if format == .json { append(first ? "]\n" : "\n]\n") }
        try flush()
        try handle.close()
        // A sibling staging file is on the same volume, so rename atomically
        // replaces an existing destination without first removing it.
        guard rename(staged.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func abandon() {
        try? handle.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func append(_ text: String) { buffer.append(contentsOf: text.utf8) }

    private func flush() throws {
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// RFC 4180: quoted when it holds a comma, quote or line break.
    private static func csv(_ value: ExportValue) -> String {
        switch value {
        case .null: return ""
        case .integer(let number): return String(number)
        case .text(let text):
            guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    private static func json(_ value: ExportValue) -> String {
        switch value {
        case .null: "null"
        case .integer(let number): String(number)
        case .text(let text): json(text)
        }
    }

    private static func json(_ text: String) -> String {
        (try? String(decoding: JSONEncoder().encode(text), as: UTF8.self)) ?? "\"\""
    }
}
