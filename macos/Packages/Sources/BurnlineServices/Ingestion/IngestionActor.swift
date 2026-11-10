//
//  IngestionActor.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import BurnlineProviders
import BurnlineStore
import Darwin
import Foundation
import os

/// The single writer of usage data. Every import goes through here, so writes
/// never interleave and a write failure has one place to be handled.
///
/// Each file is read from where the last pass stopped. The first pass over a
/// history reads everything; later ones stat each file and read only what was
/// appended, so a sync after one new line costs one short read.
public actor IngestionActor {
    /// Records written per transaction. Large enough to amortise the commit,
    /// small enough that one failure does not discard much work.
    static let batchSize = 1_000

    let database: BurnlineDatabase
    let clock: any WallClock

    public init(database: BurnlineDatabase, clock: any WallClock = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    /// Forgets where every file was read to, between syncs, so the next pass
    /// reads each from the start. Events before the compaction boundary are
    /// dropped on insert, so compacted history is never counted twice.
    public func forgetSources() throws(StoreError) {
        try database.sourceStates.removeAll()
    }

    /// Brings `adapter`'s files up to date. A file that cannot be read is
    /// counted and skipped; it does not stop the rest. Store failures, such as
    /// a full disk, stop the sync and are thrown, because continuing would
    /// only fail again.
    public func sync(from adapter: any UsageProviderAdapter) throws(StoreError) -> ImportResult {
        var result = ImportResult(provider: adapter.provider, detection: adapter.detect())
        guard case .installed = result.detection else { return result }

        let files: [URL]
        do { files = try adapter.sourceFiles() } catch {
            result.unreadableFiles += 1
            return result
        }

        adapter.prepareForSync()
        var states = try database.sourceStates.states(provider: adapter.provider)
        // Which files need reading, and from where, is decided before any is read.
        var reads: [FileRead] = []
        for file in files {
            let saved = states.removeValue(forKey: file.path)
            guard let facts = FileFacts(file) else {
                result.unreadableFiles += 1
                continue
            }
            guard let start = ResumePoint(saved: saved, current: facts, file: file) else {
                result.filesUnchanged += 1
                continue
            }
            reads.append(FileRead(file: file, facts: facts, saved: saved, start: start))
        }

        // Parsing touches no database, so a group of files is parsed in
        // parallel; writing stays one file at a time, in the listed order.
        for group in stride(from: 0, to: reads.count, by: Self.parallelFiles) {
            let reads = reads[group..<min(group + Self.parallelFiles, reads.count)]
            for (read, output) in zip(reads, Self.parse(reads, with: adapter)) {
                guard let output else {
                    result.unreadableFiles += 1
                    continue
                }
                result.filesRead += 1
                result.linesRead += output.linesRead
                result.recordsParsed += output.records.count
                result.issues += output.issueCount

                // The size is the one seen before reading. If the file grew
                // while it was read, the next pass sees a new size and resumes
                // from `endOffset`, so nothing appended meanwhile is missed.
                let state = SourceState(
                    provider: adapter.provider, identifier: read.file.path, inode: read.facts.inode,
                    fileSize: read.facts.size, lastModifiedAt: read.facts.modifiedAt, lastOffset: output.endOffset,
                    lastEventIdentifier: output.records.last?.sourceEventID ?? read.saved?.lastEventIdentifier,
                    lastScanAt: clock.now, resumeState: output.endState,
                    lastModifiedNanoseconds: read.facts.modifiedNanoseconds)
                result.eventsWritten += try write(output, provider: adapter.provider, state: state)
            }
        }
        // What is left belongs to files the provider no longer lists.
        try database.sourceStates.remove(provider: adapter.provider, identifiers: states.keys)
        return result
    }

    /// Files parsed at once: enough to keep every core busy past the odd large
    /// file, few enough that the parsed records held before writing stay small.
    static let parallelFiles = ProcessInfo.processInfo.activeProcessorCount * 2

    /// A file that needs reading, from where, and what was known of it.
    struct FileRead {
        let file: URL
        let facts: FileFacts
        let saved: SourceState?
        let start: ResumePoint
    }

    /// Parses `reads` across the cores, in their order; nil for a file that
    /// could not be read. Blocking here, rather than awaiting, keeps the actor
    /// from taking another sync of the same files mid-pass.
    private static func parse(_ reads: ArraySlice<FileRead>,
                              with adapter: any UsageProviderAdapter) -> [ParseOutput?] {
        let jobs = reads.map { (file: $0.file, offset: $0.start.offset, state: $0.start.state) }
        let outputs = OSAllocatedUnfairLock(initialState: [ParseOutput?](repeating: nil, count: jobs.count))
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let job = jobs[index]
            let output = try? adapter.parse(job.file, from: job.offset, state: job.state)
            outputs.withLock { $0[index] = output }
        }
        return outputs.withLock { $0 }
    }

    /// Writes a file's records in batches. Issues travel with the first batch
    /// and the new offset with the last, so the offset only moves once every
    /// event before it is stored. A crash between batches leaves the old
    /// offset, and the next pass re-reads lines whose events are already
    /// stored, which the uniqueness constraint absorbs.
    private func write(_ output: ParseOutput, provider: ProviderKey, state: SourceState) throws(StoreError) -> Int {
        // Judged for the whole file, so one reply is never split across batches.
        var output = output
        output.records = try database.admissible(output.records, provider: provider)
        let starts = Array(stride(from: 0, to: output.records.count, by: Self.batchSize))
        var written = 0
        // A file with nothing new still commits once, to advance its offset.
        for (index, start) in (starts.isEmpty ? [0] : starts).enumerated() {
            let batch = output.records[start..<min(start + Self.batchSize, output.records.count)]
            let isLast = index == max(starts.count - 1, 0)
            written += try database.ingest(Array(batch), issues: index == 0 ? output.issues : [],
                                           provider: provider, sourceState: isLast ? state : nil).eventsWritten
        }
        return written
    }
}

/// What a stat says about a source file, compared against the saved state to
/// decide how much of it to read.
struct FileFacts: Equatable {
    let inode: Int64
    let size: Int64
    let modifiedAt: Timestamp?
    let modifiedNanoseconds: Int64?

    init?(_ file: URL) {
        var metadata = stat()
        guard stat(file.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        self.init(inode: Int64(bitPattern: metadata.st_ino), size: metadata.st_size,
                  modifiedAt: Timestamp(epochSeconds: Int64(metadata.st_mtimespec.tv_sec)),
                  modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec))
    }

    init(inode: Int64, size: Int64, modifiedAt: Timestamp?, modifiedNanoseconds: Int64? = nil) {
        self.inode = inode
        self.size = size
        self.modifiedAt = modifiedAt
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

/// Where to start reading a file, or nil when it has not changed.
struct ResumePoint: Equatable {
    let offset: Int64
    let state: String?

    static let beginning = ResumePoint(offset: 0, state: nil)

    init(offset: Int64, state: String?) {
        self.offset = offset
        self.state = state
    }

    /// Resumes at the saved offset only when the file is evidently the same
    /// one, grown by appending. Anything else is read again from the start,
    /// and the uniqueness constraint absorbs what was already stored.
    init?(saved: SourceState?, current: FileFacts, file: URL) {
        guard let saved else {
            self = .beginning
            return
        }
        if saved.inode == current.inode, saved.fileSize == current.size,
           saved.lastModifiedAt == current.modifiedAt,
           let nanos = saved.lastModifiedNanoseconds, nanos == current.modifiedNanoseconds {
            return nil
        }
        let sameFile = saved.inode == current.inode
        // Same file, same size, new modification time: rewritten in place, or
        // touched. Either way, appending did not happen.
        if sameFile, saved.fileSize == current.size {
            self = .beginning
            return
        }
        let grew = saved.fileSize.map { current.size > $0 } ?? false
        let validOffset = saved.lastOffset >= 0 && current.size >= saved.lastOffset
        // A file rewritten in place to a longer length keeps its inode and
        // grows, but the saved offset no longer falls just after a newline.
        if sameFile, grew, validOffset, saved.lastOffset == 0 || Self.newline(before: saved.lastOffset, in: file) {
            self.init(offset: saved.lastOffset, state: saved.resumeState)
        } else {
            self = .beginning
        }
    }

    private static func newline(before offset: Int64, in file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset - 1))) != nil,
              let byte = try? handle.read(upToCount: 1) else { return false }
        return byte.first == UInt8(ascii: "\n")
    }
}

/// What one sync did, for provider health and for the import summary.
public struct ImportResult: Hashable, Sendable {
    public let provider: ProviderKey
    public let detection: ProviderDetection
    public var filesRead = 0
    /// Files skipped because nothing changed since the last pass.
    public var filesUnchanged = 0
    public var unreadableFiles = 0
    public var linesRead = 0
    public var recordsParsed = 0
    /// New events, plus stored events replaced by a more complete copy.
    public var eventsWritten = 0
    /// Lines skipped or patched, including any beyond the per-file detail cap.
    public var issues = 0

    public init(provider: ProviderKey, detection: ProviderDetection) {
        self.provider = provider
        self.detection = detection
    }
}
