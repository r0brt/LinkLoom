import CoreServices
import Foundation

public struct FSEventsDirectoryWatcher: DirectoryWatching {
    public init() {}

    public func events(
        for sourceRootID: UUID,
        url: URL
    ) -> AsyncThrowingStream<DirectoryChange, Error> {
        AsyncThrowingStream { continuation in
            let sink = FSEventsSink(
                sourceRootID: sourceRootID,
                continuation: continuation
            )
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(sink).toOpaque(),
                retain: nil,
                release: { pointer in
                    guard let pointer else { return }
                    Unmanaged<FSEventsSink>.fromOpaque(pointer).release()
                },
                copyDescription: nil
            )
            let createFlags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagNoDefer
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.callback,
                &context,
                [url.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.1,
                createFlags
            ) else {
                Unmanaged<FSEventsSink>.fromOpaque(context.info!).release()
                continuation.finish(throwing: FSEventsWatcherError.streamCreationFailed)
                return
            }
            let queue = DispatchQueue(label: "LinkLoom.FSEvents.\(sourceRootID.uuidString)")
            let lifecycle = FSEventsLifecycle(
                stream: stream,
                sourceURL: url,
                securityScopeStarted: url.startAccessingSecurityScopedResource()
            )
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                lifecycle.stop()
                continuation.finish(throwing: FSEventsWatcherError.streamStartFailed)
                return
            }
            lifecycle.markStarted()
            continuation.onTermination = { _ in
                lifecycle.stop()
            }
        }
    }

    static func kind(for flags: FSEventStreamEventFlags) -> DirectoryChange.Kind {
        if flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagUnmount | kFSEventStreamEventFlagRootChanged
        ) != 0 {
            return .rootUnavailable
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMount) != 0 {
            return .rootAvailable
        }
        return .contentChanged
    }

    private static let callback: FSEventStreamCallback = {
        _, clientInfo, eventCount, _, eventFlags, _ in
        guard let clientInfo else { return }
        let sink = Unmanaged<FSEventsSink>.fromOpaque(clientInfo).takeUnretainedValue()
        for index in 0..<eventCount {
            sink.yield(kind: kind(for: eventFlags[index]))
        }
    }
}

private final class FSEventsSink: @unchecked Sendable {
    private let sourceRootID: UUID
    private let continuation: AsyncThrowingStream<DirectoryChange, Error>.Continuation

    init(
        sourceRootID: UUID,
        continuation: AsyncThrowingStream<DirectoryChange, Error>.Continuation
    ) {
        self.sourceRootID = sourceRootID
        self.continuation = continuation
    }

    func yield(kind: DirectoryChange.Kind) {
        continuation.yield(DirectoryChange(sourceRootID: sourceRootID, kind: kind))
    }
}

private final class FSEventsLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var didStart = false
    private let sourceURL: URL
    private let securityScopeStarted: Bool

    init(
        stream: FSEventStreamRef,
        sourceURL: URL,
        securityScopeStarted: Bool
    ) {
        self.stream = stream
        self.sourceURL = sourceURL
        self.securityScopeStarted = securityScopeStarted
    }

    func markStarted() {
        lock.withLock {
            didStart = true
        }
    }

    func stop() {
        let resources = lock.withLock { () -> (FSEventStreamRef, Bool)? in
            guard let stream else { return nil }
            self.stream = nil
            return (stream, didStart)
        }
        guard let (stream, didStart) = resources else { return }
        if didStart {
            FSEventStreamStop(stream)
        }
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        if securityScopeStarted {
            sourceURL.stopAccessingSecurityScopedResource()
        }
    }
}

private enum FSEventsWatcherError: Error {
    case streamCreationFailed
    case streamStartFailed
}
