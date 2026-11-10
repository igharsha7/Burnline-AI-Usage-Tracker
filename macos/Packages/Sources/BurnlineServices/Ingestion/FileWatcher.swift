//
//  FileWatcher.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import CoreServices
import Foundation

/// Signals when anything under a directory changes, through FSEvents.
///
/// It says only *that* something changed, never what: a sync stats every
/// file and reads only what grew, so knowing which file is not worth the
/// bookkeeping. Bursts collapse into one pending signal, and FSEvents itself
/// coalesces changes over `latency`.
///
/// Signals can be missed, for example while the Mac sleeps. The `Reconciler`
/// sweeps on a timer and after wake for that reason.
public final class FileWatcher: @unchecked Sendable {
    // @unchecked: `stream` is created in `init` and touched again only in
    // `deinit`; FSEvents calls back on `queue`, and the callback only yields
    // to the continuation, which is itself thread-safe.

    /// How long FSEvents gathers changes before reporting them. Long enough to
    /// fold a burst of transcript writes into one sync, short enough that a
    /// new reply appears within seconds.
    public static let defaultLatency: TimeInterval = 1

    public let changes: AsyncStream<Void>
    /// Handed to FSEvents as the callback's context. Owned here, and so alive
    /// until `deinit` has stopped the stream that points at it.
    private let box: ContinuationBox
    private let queue = DispatchQueue(label: "io.github.igharsha7.Burnline.FileWatcher")
    private var stream: FSEventStreamRef?

    /// Nil when the directory cannot be watched, such as when it does not
    /// exist. The periodic sweep still covers it.
    public init?(directory: URL, latency: TimeInterval = defaultLatency) {
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.changes = changes
        self.box = ContinuationBox(continuation: continuation)

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ContinuationBox>.fromOpaque(info).takeUnretainedValue().continuation.yield()
        }
        guard FileManager.default.fileExists(atPath: directory.path),
              let stream = FSEventStreamCreate(
                  kCFAllocatorDefault, callback, &context, [directory.path] as CFArray,
                  FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                  FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { return nil }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        box.continuation.finish()
    }
}

private final class ContinuationBox: Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}
