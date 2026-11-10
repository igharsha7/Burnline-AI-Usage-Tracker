//
//  LineReader.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation

/// Streams newline-terminated lines from a file in fixed-size chunks, so a
/// transcript of any size is read without loading it whole. Plain
/// and zstd-compressed files share the line splitting.
///
/// Each line comes with its byte offset, which is what incremental reading
/// resumes from. A final line with no newline is not returned: it may be a
/// record still being written, and reading it now would parse half of it.
///
/// Given markers, only lines containing one of them are handed over. Most of
/// a transcript is message text that no adapter reads, and checking the raw
/// bytes before copying a line is what keeps a first import fast.
struct LineReader {
    static let chunkSize = 1 << 20

    struct Line {
        let bytes: Data
        /// Byte offset of the line's first byte.
        let offset: Int64
        /// One-based, counted from `startOffset`, over every line read.
        let number: Int
    }

    /// How far a read got: the offset just past the last complete line, and
    /// how many lines it passed, handed over or not.
    struct Pass {
        let endOffset: Int64
        let lines: Int
    }

    /// Decides from a line's raw bytes, before they are copied, whether it is
    /// handed over.
    typealias Selection = (UnsafeRawBufferPointer) -> Bool

    /// Lines holding any of `markers`.
    static func containing(_ markers: [String]) -> Selection {
        let needles = markers.map { Array($0.utf8) }
        return { line in needles.contains { contains(line, $0) } }
    }

    /// Calls `body` for every complete line from `startOffset` that contains
    /// one of `markers`, or for every line when there are none.
    static func read(_ file: URL, from startOffset: Int64, containing markers: [String] = [],
                     _ body: (Line) throws -> Void) throws -> Pass {
        try read(file, from: startOffset, selecting: markers.isEmpty ? nil : containing(markers), body)
    }

    /// The same, handing over the lines `selection` accepts, or all when nil.
    static func read(_ file: URL, from startOffset: Int64, selecting selection: Selection?,
                     _ body: (Line) throws -> Void) throws -> Pass {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startOffset))
        return try read(from: startOffset, selection: selection, chunks: { try handle.read(upToCount: chunkSize) }, body)
    }

    /// The same, for a zstd-compressed file. Offsets count decompressed bytes,
    /// and a compressed stream cannot be entered midway, so it is always read
    /// from the start.
    static func readCompressed(_ file: URL, selecting selection: Selection?,
                               _ body: (Line) throws -> Void) throws -> Pass {
        let stream = try ZstdStream(file)
        return try read(from: 0, selection: selection, chunks: stream.next, body)
    }

    /// Whether `needle` occurs in `bytes`.
    static func contains(_ bytes: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return needle.isEmpty }
        return needle.withUnsafeBytes { memmem(base, bytes.count, $0.baseAddress, needle.count) != nil }
    }

    /// How many times `needle` occurs in `bytes`, without overlapping.
    static func occurrences(of needle: [UInt8], in bytes: UnsafeRawBufferPointer) -> Int {
        guard let base = bytes.baseAddress, !needle.isEmpty else { return 0 }
        var count = 0, from = 0
        needle.withUnsafeBytes { pattern in
            while from < bytes.count, let hit = memmem(base + from, bytes.count - from, pattern.baseAddress, needle.count) {
                count += 1
                from = base.distance(to: UnsafeRawPointer(hit)) + needle.count
            }
        }
        return count
    }

    private static func read(from startOffset: Int64, selection: Selection?, chunks: () throws -> Data?,
                             _ body: (Line) throws -> Void) throws -> Pass {
        var pending = Data()
        var pendingOffset = startOffset
        var number = 0
        // Bytes of `pending` already searched for a newline. Only new bytes can
        // end a line already pending; rescanning makes a long line quadratic.
        var scanned = 0
        while let chunk = try chunks(), !chunk.isEmpty {
            pending.append(chunk)
            let consumed = try pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var lineStart = 0
                var searchFrom = scanned
                while searchFrom < raw.count, let hit = memchr(base + searchFrom, 0x0A, raw.count - searchFrom) {
                    let newline = base.distance(to: UnsafeRawPointer(hit))
                    number += 1
                    let line = UnsafeRawBufferPointer(start: base + lineStart, count: newline - lineStart)
                    if !line.isEmpty, selection?(line) ?? true {
                        try body(Line(bytes: Data(line), offset: pendingOffset + Int64(lineStart), number: number))
                    }
                    lineStart = newline + 1
                    searchFrom = lineStart
                }
                return lineStart
            }
            if consumed > 0 {
                pending.removeSubrange(pending.startIndex..<pending.startIndex + consumed)
                pendingOffset += Int64(consumed)
            }
            scanned = pending.count
        }
        return Pass(endOffset: pendingOffset, lines: number)
    }
}
