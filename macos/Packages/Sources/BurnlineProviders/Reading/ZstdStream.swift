//
//  ZstdStream.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import Foundation
import libzstd

/// Decompresses a zstd file a chunk at a time, so an archive of any size is
/// read without holding it, or its decompressed form, whole in memory.
/// Concatenated frames are read as one stream, as the zstd tool does.
final class ZstdStream {
    enum Failure: Error, Equatable {
        /// The data is not zstd, or is corrupt. Carries zstd's own reason.
        case invalid(String)
        /// The file ends inside a frame: still being written, or cut short.
        case truncated
    }

    private let handle: FileHandle
    private let context: OpaquePointer
    private var input = Data()
    private var inputPosition = 0
    /// zstd's hint after the last call: zero exactly at the end of a frame.
    // At least one frame is required, even for an empty decompressed file.
    private var pendingHint = 1

    init(_ file: URL) throws {
        handle = try FileHandle(forReadingFrom: file)
        guard let context = ZSTD_createDStream() else {
            try? handle.close()
            throw Failure.invalid("could not allocate a decoder")
        }
        self.context = context
    }

    deinit {
        ZSTD_freeDStream(context)
        try? handle.close()
    }

    /// The next decompressed bytes, up to `LineReader.chunkSize` at a time,
    /// or nil at the end of the file.
    func next() throws -> Data? {
        var output = Data()
        while output.count < LineReader.chunkSize, let piece = try nextPiece() {
            output.append(piece)
        }
        return output.isEmpty ? nil : output
    }

    /// What one call into zstd produces: at most its preferred output size.
    private func nextPiece() throws -> Data? {
        while true {
            if inputPosition == input.count {
                guard let chunk = try handle.read(upToCount: ZSTD_DStreamInSize()), !chunk.isEmpty else {
                    if pendingHint != 0 { throw Failure.truncated }
                    return nil
                }
                input = chunk
                inputPosition = 0
            }

            var output = Data(count: ZSTD_DStreamOutSize())
            let (hint, produced) = try input.withUnsafeBytes { source in
                try output.withUnsafeMutableBytes { destination in
                    var inBuffer = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: inputPosition)
                    var outBuffer = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let hint = ZSTD_decompressStream(context, &outBuffer, &inBuffer)
                    if ZSTD_isError(hint) != 0 { throw Failure.invalid(String(cString: ZSTD_getErrorName(hint))) }
                    inputPosition = inBuffer.pos
                    return (hint, outBuffer.pos)
                }
            }
            pendingHint = hint
            if produced > 0 { return output.prefix(produced) }
        }
    }
}
