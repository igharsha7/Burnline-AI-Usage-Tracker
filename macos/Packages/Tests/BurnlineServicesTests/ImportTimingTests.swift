//
//  ImportTimingTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
@testable import BurnlineProviders
import BurnlineServices
@testable import BurnlineStore
import BurnlineTestSupport
import Foundation
import Testing

/// Times a first import of this machine's real history, split into reading
/// and writing, so a change to either can be measured on its own. Off by
/// default; run in release with
///
///     BURNLINE_IMPORT_TIMING=1 swift test -c release --filter ImportTimingTests
///
/// Prints durations and counts only.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BURNLINE_IMPORT_TIMING"] != nil), .serialized)
struct ImportTimingTests {
    static let adapters: [any UsageProviderAdapter] = [ClaudeCodeAdapter(), CodexAdapter()]

    static func database() throws -> BurnlineDatabase {
        let database = try BurnlineDatabase.open(
            at: StoreLocation(directory: TestDirectory.make("ImportTiming")),
            schema: Schema(directory: RealHistoryTests.repositoryRoot.appending(path: "shared/schema")),
            clock: SystemClock())
        try database.models.sync(ModelAliasManifest.load(
            from: RealHistoryTests.repositoryRoot.appending(path: "shared/pricing/model_aliases.json")))
        return database
    }

    @Test func `a first import, read and written separately`() async throws {
        for adapter in Self.adapters {
            guard case .installed = adapter.detect() else { continue }
            adapter.prepareForSync()
            let files = try adapter.sourceFiles()

            var started = ContinuousClock.now
            var outputs: [(URL, ParseOutput)] = []
            for file in files {
                if let output = try? adapter.parse(file, from: 0, state: nil) { outputs.append((file, output)) }
            }
            let reading = ContinuousClock.now - started

            let database = try Self.database()
            started = ContinuousClock.now
            var written = 0
            for (_, output) in outputs {
                written += try database.ingest(output.records, issues: output.issues, provider: adapter.provider)
                    .eventsWritten
            }
            let writing = ContinuousClock.now - started

            let whole = try Self.database()
            started = ContinuousClock.now
            let result = try await IngestionActor(database: whole).sync(from: adapter)
            let syncing = ContinuousClock.now - started

            print("TIMING", adapter.provider.rawValue, files.count, "files,",
                  outputs.reduce(0) { $0 + $1.1.records.count }, "records,", written, "written | read", reading,
                  "| write", writing, "| sync", syncing, "(\(result.eventsWritten) written)")
        }
    }

    /// Where reading goes: every line copied out, against only the lines
    /// holding a marker. Decoding is the rest of the read time above.
    @Test func `reading, every line against marked lines`() throws {
        let stages: [[String]] = [
            ["\"assistant\""],
            ["\"session_meta\"", "\"turn_context\"", "\"token_usage_record\"", "\"token_count\"",
             "\"thread_settings_applied\""],
        ]
        for (adapter, markers) in zip(Self.adapters, stages) {
            guard case .installed = adapter.detect() else { continue }
            let files = try adapter.sourceFiles()
            func each(_ markers: [String], _ body: (LineReader.Line) -> Void) -> Int {
                files.reduce(0) { lines, file in
                    let selection = markers.isEmpty ? nil : LineReader.containing(markers)
                    let pass = CodexAdapter.isCompressed(file)
                        ? try? LineReader.readCompressed(file, selecting: selection) { body($0) }
                        : try? LineReader.read(file, from: 0, selecting: selection) { body($0) }
                    return lines + (pass?.lines ?? 0)
                }
            }
            var bytes = 0, keptBytes = 0, kept = 0
            var started = ContinuousClock.now
            let lines = each([]) { bytes += $0.bytes.count }
            let every = ContinuousClock.now - started
            started = ContinuousClock.now
            _ = each(markers) { kept += 1; keptBytes += $0.bytes.count }
            let marked = ContinuousClock.now - started
            print("STAGES", adapter.provider.rawValue, lines, "lines,", bytes / 1_000_000, "MB,", kept, "kept,",
                  keptBytes / 1_000_000, "MB kept | every line", every, "| marked lines", marked)
        }
    }

    /// Looking for Codex record types only near the start of each line must
    /// find exactly what looking everywhere finds, on this machine's history.
    @Test func `Codex reads the same records looking near the start of lines`() throws {
        let windowed = CodexAdapter()
        var everywhere = CodexAdapter()
        everywhere.markerWindow = nil
        guard case .installed = windowed.detect() else { return }
        var compared = 0
        for file in try windowed.sourceFiles() {
            guard let near = try? windowed.parse(file, from: 0, state: nil) else { continue }
            let far = try everywhere.parse(file, from: 0, state: nil)
            #expect(near.records == far.records, "\(file.lastPathComponent)")
            // Compared decoded: the encoder writes keys in no fixed order.
            #expect(near.issues == far.issues)
            #expect(near.endState.flatMap(CodexResumeState.init(encoded:))
                == far.endState.flatMap(CodexResumeState.init(encoded:)))
            compared += near.records.count
        }
        print("COMPARED", compared, "Codex records")
    }

    /// Judging medals reads the whole history. During an import it runs after
    /// each provider's sync, so its cost is paid before the next one starts.
    @Test func `judging medals after an import`() async throws {
        let database = try Self.database()
        let ingestion = IngestionActor(database: database)
        for adapter in Self.adapters { _ = try await ingestion.sync(from: adapter) }
        let calendar = LocalCalendar(timeZone: .current, firstWeekday: .monday)
        let activity = ActivityService(database: database,
                                       aggregation: AggregationService(database: database, calendar: calendar),
                                       calendar: calendar)
        var started = ContinuousClock.now
        try activity.award()
        let first = ContinuousClock.now - started
        started = ContinuousClock.now
        try activity.award()
        let again = ContinuousClock.now - started
        print("MEDALS first judging", first, "| again", again)
    }
}
