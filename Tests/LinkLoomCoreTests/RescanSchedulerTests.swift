import Foundation
import CoreServices
import Testing
@testable import LinkLoomCore

@Suite("Incremental rescan scheduler")
struct RescanSchedulerTests {
    @Test func fseventFlagsMapMountLifecycleBeforeContentChanges() {
        #expect(
            FSEventsDirectoryWatcher.kind(for: FSEventStreamEventFlags(
                kFSEventStreamEventFlagUnmount | kFSEventStreamEventFlagItemModified
            )) == .rootUnavailable
        )
        #expect(
            FSEventsDirectoryWatcher.kind(for: FSEventStreamEventFlags(
                kFSEventStreamEventFlagMount | kFSEventStreamEventFlagItemCreated
            )) == .rootAvailable
        )
        #expect(
            FSEventsDirectoryWatcher.kind(for: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemRenamed
            )) == .contentChanged
        )
    }

    @Test func burstOfEventsProducesOneRescanForAffectedSource() async throws {
        let watcher = FakeDirectoryWatcher()
        let rescanner = CountingSourceRescanner()
        let scheduler = RescanScheduler(watcher: watcher, rescanner: rescanner)
        let first = source(named: "First")
        let second = source(named: "Second")
        await scheduler.start(source: first, url: URL(fileURLWithPath: first.pathHint))
        await scheduler.start(source: second, url: URL(fileURLWithPath: second.pathHint))
        await watcher.waitUntilWatching(sourceIDs: [first.id, second.id])

        for _ in 0..<5 {
            watcher.emit(DirectoryChange(sourceRootID: first.id, kind: .contentChanged))
        }
        try await ContinuousClock().sleep(for: .milliseconds(100))
        #expect(await rescanner.count(sourceID: first.id) == 0)
        try await waitUntil {
            await rescanner.count(sourceID: first.id) == 1
        }

        #expect(await rescanner.count(sourceID: first.id) == 1)
        #expect(await rescanner.count(sourceID: second.id) == 0)
        await scheduler.stopAll()
    }

    @Test func stoppingOneSourceLeavesOtherWatcherActive() async throws {
        let watcher = FakeDirectoryWatcher()
        let rescanner = CountingSourceRescanner()
        let scheduler = RescanScheduler(watcher: watcher, rescanner: rescanner)
        let first = source(named: "First")
        let second = source(named: "Second")
        await scheduler.start(source: first, url: URL(fileURLWithPath: first.pathHint))
        await scheduler.start(source: second, url: URL(fileURLWithPath: second.pathHint))
        await watcher.waitUntilWatching(sourceIDs: [first.id, second.id])

        await scheduler.stop(sourceID: first.id)
        await watcher.waitUntilTerminated(sourceID: first.id)
        watcher.emit(DirectoryChange(sourceRootID: second.id, kind: .contentChanged))
        try await waitUntil {
            await rescanner.count(sourceID: second.id) == 1
        }

        #expect(watcher.isWatching(sourceID: first.id) == false)
        #expect(watcher.isWatching(sourceID: second.id))
        #expect(await rescanner.count(sourceID: first.id) == 0)
        await scheduler.stopAll()
    }

    @Test func cancelledOlderDebounceCannotDetachNewerTimer() async throws {
        let watcher = FakeDirectoryWatcher()
        let rescanner = CountingSourceRescanner()
        let scheduler = RescanScheduler(watcher: watcher, rescanner: rescanner)
        let source = source(named: "Archive")
        await scheduler.start(source: source, url: URL(fileURLWithPath: source.pathHint))
        await watcher.waitUntilWatching(sourceIDs: [source.id])

        watcher.emit(DirectoryChange(sourceRootID: source.id, kind: .contentChanged))
        try await ContinuousClock().sleep(for: .milliseconds(20))
        watcher.emit(DirectoryChange(sourceRootID: source.id, kind: .contentChanged))
        try await ContinuousClock().sleep(for: .milliseconds(20))
        watcher.emit(DirectoryChange(sourceRootID: source.id, kind: .contentChanged))
        try await ContinuousClock().sleep(for: .milliseconds(600))

        #expect(await rescanner.count(sourceID: source.id) == 1)
        await scheduler.stopAll()
    }

    @Test func unavailableRootDoesNotMarkKnownDocumentsMissing() async throws {
        let fixture = try WatcherDatabaseFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = DocumentRecord(
            sourceRootID: source.id,
            relativePath: "known.pdf",
            contentHash: "known-hash",
            byteCount: 10,
            modifiedAt: Date(timeIntervalSince1970: 100),
            mediaType: .pdf,
            lastSeenAt: Date(timeIntervalSince1970: 100)
        )
        try await fixture.documents.save(document)
        let watcher = FakeDirectoryWatcher()
        let rescanner = MissingMarkingRescanner(documents: fixture.documents)
        let scheduler = RescanScheduler(watcher: watcher, rescanner: rescanner)
        await scheduler.start(source: source, url: URL(fileURLWithPath: source.pathHint))
        await watcher.waitUntilWatching(sourceIDs: [source.id])

        watcher.emit(DirectoryChange(sourceRootID: source.id, kind: .rootUnavailable))
        try await ContinuousClock().sleep(for: .milliseconds(600))

        let stored = try #require(try await fixture.documents.all(sourceRootID: source.id).first)
        #expect(stored.availability == .available)
        #expect(await rescanner.callCount == 0)
        await scheduler.stopAll()
    }

    @Test func availableRootSchedulesCatchUpRescan() async throws {
        let watcher = FakeDirectoryWatcher()
        let rescanner = CountingSourceRescanner()
        let scheduler = RescanScheduler(watcher: watcher, rescanner: rescanner)
        let source = source(named: "Archive")
        await scheduler.start(source: source, url: URL(fileURLWithPath: source.pathHint))
        await watcher.waitUntilWatching(sourceIDs: [source.id])

        watcher.emit(DirectoryChange(sourceRootID: source.id, kind: .rootAvailable))
        try await waitUntil {
            await rescanner.count(sourceID: source.id) == 1
        }

        #expect(await rescanner.count(sourceID: source.id) == 1)
        await scheduler.stopAll()
    }

    @Test func endingReplacedStreamCannotDetachReplacement() async throws {
        let watcher = RestartableDirectoryWatcher()
        let rescanner = CountingSourceRescanner()
        let scheduler = RescanScheduler(watcher: watcher, rescanner: rescanner)
        let source = source(named: "Archive")
        let url = URL(fileURLWithPath: source.pathHint)
        await scheduler.start(source: source, url: url)
        await watcher.waitUntilStreamCount(1)

        await scheduler.start(source: source, url: url)
        await watcher.waitUntilStreamCount(2)
        watcher.emitToLatest(DirectoryChange(
            sourceRootID: source.id,
            kind: .contentChanged
        ))
        try await waitUntil {
            await rescanner.count(sourceID: source.id) == 1
        }

        #expect(await rescanner.count(sourceID: source.id) == 1)
        await scheduler.stopAll()
    }

    @Test func watcherFailurePublishesUnavailableAndAllowsRestart() async throws {
        let watcher = FailingDirectoryWatcher()
        let rescanner = CountingSourceRescanner()
        let scheduler = RescanScheduler(watcher: watcher, rescanner: rescanner)
        let source = source(named: "Archive")
        let recorder = DirectoryChangeRecorder()
        let observation = Task {
            for await change in scheduler.changes {
                await recorder.record(change)
            }
        }

        await scheduler.start(source: source, url: URL(fileURLWithPath: source.pathHint))
        try await waitUntil {
            await recorder.changes.count == 1
        }

        #expect(await recorder.changes == [
            DirectoryChange(sourceRootID: source.id, kind: .rootUnavailable),
        ])
        #expect(await scheduler.isWatching(sourceID: source.id) == false)
        observation.cancel()
    }

    @Test func stopAllWaitsForWatcherTerminationCleanup() async {
        let watcher = BlockingTerminationDirectoryWatcher()
        let scheduler = RescanScheduler(
            watcher: watcher,
            rescanner: CountingSourceRescanner()
        )
        let source = source(named: "Archive")
        let completion = CompletionRecorder()
        await scheduler.start(
            source: source,
            url: URL(fileURLWithPath: source.pathHint)
        )
        await watcher.waitUntilStreamStarts()

        let stop = Task {
            await scheduler.stopAll()
            await completion.record()
        }
        await watcher.waitUntilTerminationStarts()

        #expect(await completion.didComplete == false)
        watcher.releaseTermination()
        await stop.value
        #expect(await completion.didComplete)
    }

    private func source(named name: String) -> SourceRootRecord {
        SourceRootRecord(
            displayName: name,
            pathHint: "/Volumes/\(name)",
            bookmarkData: Data(name.utf8),
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !(await condition()) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                throw RescanSchedulerTestError.timeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

private actor DirectoryChangeRecorder {
    private(set) var changes: [DirectoryChange] = []

    func record(_ change: DirectoryChange) {
        changes.append(change)
    }
}

private actor CompletionRecorder {
    private(set) var didComplete = false

    func record() {
        didComplete = true
    }
}

private final class BlockingTerminationDirectoryWatcher: DirectoryWatching, @unchecked Sendable {
    private let condition = NSCondition()
    private var streamStarted = false
    private var terminationStarted = false
    private var releaseRequested = false

    func events(
        for sourceRootID: UUID,
        url: URL
    ) -> AsyncThrowingStream<DirectoryChange, Error> {
        AsyncThrowingStream { continuation in
            condition.withLock {
                streamStarted = true
                condition.broadcast()
            }
            continuation.onTermination = { [self] _ in
                condition.lock()
                terminationStarted = true
                condition.broadcast()
                while !releaseRequested {
                    condition.wait()
                }
                condition.unlock()
            }
        }
    }

    func waitUntilStreamStarts() async {
        while !condition.withLock({ streamStarted }) {
            await Task.yield()
        }
    }

    func waitUntilTerminationStarts() async {
        while !condition.withLock({ terminationStarted }) {
            await Task.yield()
        }
    }

    func releaseTermination() {
        condition.withLock {
            releaseRequested = true
            condition.broadcast()
        }
    }
}

private struct FailingDirectoryWatcher: DirectoryWatching {
    func events(
        for sourceRootID: UUID,
        url: URL
    ) -> AsyncThrowingStream<DirectoryChange, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: RescanSchedulerTestError.watcherFailed)
        }
    }
}

private final class RestartableDirectoryWatcher: DirectoryWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<DirectoryChange, Error>.Continuation] = []

    func events(
        for sourceRootID: UUID,
        url: URL
    ) -> AsyncThrowingStream<DirectoryChange, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
        }
    }

    func waitUntilStreamCount(_ expectedCount: Int) async {
        while lock.withLock({ continuations.count < expectedCount }) {
            await Task.yield()
        }
    }

    func emitToLatest(_ change: DirectoryChange) {
        lock.withLock { continuations.last }?.yield(change)
    }
}

private final class FakeDirectoryWatcher: DirectoryWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncThrowingStream<DirectoryChange, Error>.Continuation] = [:]
    private var terminatedSourceIDs = Set<UUID>()

    func events(
        for sourceRootID: UUID,
        url: URL
    ) -> AsyncThrowingStream<DirectoryChange, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                continuations[sourceRootID] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.continuations[sourceRootID] = nil
                    self?.terminatedSourceIDs.insert(sourceRootID)
                }
            }
        }
    }

    func emit(_ change: DirectoryChange) {
        let continuation = lock.withLock { continuations[change.sourceRootID] }
        continuation?.yield(change)
    }

    func isWatching(sourceID: UUID) -> Bool {
        lock.withLock { continuations[sourceID] != nil }
    }

    func waitUntilWatching(sourceIDs: Set<UUID>) async {
        while !lock.withLock({ sourceIDs.allSatisfy { continuations[$0] != nil } }) {
            await Task.yield()
        }
    }

    func waitUntilTerminated(sourceID: UUID) async {
        while !lock.withLock({ terminatedSourceIDs.contains(sourceID) }) {
            await Task.yield()
        }
    }
}

private actor CountingSourceRescanner: SourceRescanning {
    private var counts: [UUID: Int] = [:]

    func rescan(source: SourceRootRecord) async {
        counts[source.id, default: 0] += 1
    }

    func count(sourceID: UUID) -> Int {
        counts[sourceID, default: 0]
    }
}

private actor MissingMarkingRescanner: SourceRescanning {
    private let documents: DocumentRepository
    private(set) var callCount = 0

    init(documents: DocumentRepository) {
        self.documents = documents
    }

    func rescan(source: SourceRootRecord) async {
        callCount += 1
        _ = try? await documents.markMissing(
            sourceRootID: source.id,
            excludingDocumentIDs: []
        )
    }
}

private final class WatcherDatabaseFixture: @unchecked Sendable {
    let directory: URL
    let sources: SourceRootRepository
    let documents: DocumentRepository

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkLoomWatcherTests-\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.makeQueue(
            at: directory.appendingPathComponent("linkloom.sqlite")
        )
        sources = SourceRootRepository(dbWriter: database)
        documents = DocumentRepository(dbWriter: database)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func addSource(named name: String) async throws -> SourceRootRecord {
        try await sources.add(
            url: directory.appendingPathComponent(name, isDirectory: true),
            sourceAccess: WatcherSourceAccess(),
            now: Date(timeIntervalSince1970: 100)
        )
    }
}

private struct WatcherSourceAccess: SourceAccessing {
    func createBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        throw RescanSchedulerTestError.unusedResolution
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await operation(URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)))
    }
}

private enum RescanSchedulerTestError: Error {
    case timeout
    case unusedResolution
    case watcherFailed
}
