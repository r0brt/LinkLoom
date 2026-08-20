import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Source access")
struct SourceAccessTests {
    @Test func repositoryPersistsBookmarkAndReturnsSource() async throws {
        let db = try TestDatabase.make()
        let repository = SourceRootRepository(dbWriter: db)
        let access = FakeSourceAccess(url: URL(fileURLWithPath: "/Volumes/Test"))

        let source = try await repository.add(
            url: access.url,
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 100)
        )
        let storedSources = try await repository.all()

        #expect(source.displayName == "Test")
        #expect(storedSources == [source])
        #expect(access.createdBookmarkCount == 1)
    }

    @Test func repositoryReaddingEquivalentRootReusesRecordAndRefreshesGrant() async throws {
        let db = try TestDatabase.make()
        let repository = SourceRootRepository(dbWriter: db)
        let documents = DocumentRepository(dbWriter: db)
        let access = RotatingBookmarkSourceAccess()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let selectedRoot = temporaryDirectory
            .appendingPathComponent("Selected Root", isDirectory: true)
        let selectedAlias = temporaryDirectory
            .appendingPathComponent("Selected Alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: selectedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: selectedAlias,
            withDestinationURL: selectedRoot
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let createdAt = Date(timeIntervalSince1970: 100)
        let scannedAt = Date(timeIntervalSince1970: 200)
        let first = try await repository.add(
            url: selectedRoot,
            sourceAccess: access,
            now: createdAt
        )
        let document = DocumentRecord(
            sourceRootID: first.id,
            relativePath: "invoice.pdf",
            contentHash: "sha256:invoice",
            byteCount: 42,
            modifiedAt: Date(timeIntervalSince1970: 150),
            mediaType: .pdf,
            lastSeenAt: Date(timeIntervalSince1970: 150)
        )
        try await documents.save(document)
        try await repository.updateLastScan(id: first.id, at: scannedAt)
        access.disableResolution()

        let second = try await repository.add(
            url: selectedAlias,
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 300)
        )

        let storedSources = try await repository.all()
        let storedSource = try #require(storedSources.first)
        #expect(second.id == first.id)
        #expect(storedSources.count == 1)
        #expect(storedSource.displayName == "Selected Alias")
        #expect(storedSource.pathHint == selectedAlias.path)
        #expect(storedSource.bookmarkData == second.bookmarkData)
        #expect(storedSource.bookmarkData != first.bookmarkData)
        #expect(storedSource.createdAt == createdAt)
        #expect(storedSource.lastScanAt == scannedAt)
        #expect(try await documents.all(sourceRootID: first.id) == [document])
    }

    @Test func concurrentEquivalentAddsProduceOneSourceRoot() async throws {
        let db = try TestDatabase.make()
        let firstRepository = SourceRootRepository(dbWriter: db)
        let secondRepository = SourceRootRepository(dbWriter: db)
        let access = RotatingBookmarkSourceAccess()
        let selectedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: selectedRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: selectedRoot) }

        async let first = firstRepository.add(url: selectedRoot, sourceAccess: access)
        async let second = secondRepository.add(url: selectedRoot, sourceAccess: access)
        let addedSources = try await [first, second]

        #expect(addedSources[0].id == addedSources[1].id)
        #expect(try await firstRepository.all().count == 1)
    }

    @Test func repositoryRenewsStaleBookmarkWithoutChangingSourceIdentity() async throws {
        let db = try TestDatabase.make()
        let repository = SourceRootRepository(dbWriter: db)
        let documents = DocumentRepository(dbWriter: db)
        let access = StaleBookmarkSourceAccess()
        let originalURL = URL(
            fileURLWithPath: "/Volumes/Original",
            isDirectory: true
        )
        let relocatedURL = URL(
            fileURLWithPath: "/Volumes/Renamed",
            isDirectory: true
        )
        let createdAt = Date(timeIntervalSince1970: 100)
        let scannedAt = Date(timeIntervalSince1970: 200)
        let source = try await repository.add(
            url: originalURL,
            sourceAccess: access,
            now: createdAt
        )
        let document = DocumentRecord(
            sourceRootID: source.id,
            relativePath: "invoice.pdf",
            contentHash: "sha256:invoice",
            byteCount: 42,
            modifiedAt: Date(timeIntervalSince1970: 150),
            mediaType: .pdf,
            lastSeenAt: Date(timeIntervalSince1970: 150)
        )
        try await documents.save(document)
        try await repository.updateLastScan(id: source.id, at: scannedAt)
        access.markStale(source.bookmarkData, resolvingTo: relocatedURL)

        let renewed = try await repository.renewBookmarkIfStale(
            source,
            sourceAccess: access
        )

        let stored = try #require(try await repository.all().first)
        #expect(renewed == stored)
        #expect(stored.id == source.id)
        #expect(stored.createdAt == createdAt)
        #expect(stored.lastScanAt == scannedAt)
        #expect(stored.bookmarkData != source.bookmarkData)
        #expect(stored.pathHint == relocatedURL.path)
        #expect(stored.displayName == "Renamed")
        #expect(try await documents.all(sourceRootID: source.id) == [document])
        #expect(access.startCount == 1)
        #expect(access.stopCount == 1)
    }

    @Test func repositoryLeavesCurrentBookmarkUntouched() async throws {
        let db = try TestDatabase.make()
        let repository = SourceRootRepository(dbWriter: db)
        let access = StaleBookmarkSourceAccess()
        _ = try await repository.add(
            url: URL(fileURLWithPath: "/Volumes/Current", isDirectory: true),
            sourceAccess: access
        )
        let source = try #require(try await repository.all().first)

        let resolved = try await repository.renewBookmarkIfStale(
            source,
            sourceAccess: access
        )

        #expect(resolved == source)
        #expect(try await repository.all() == [source])
        #expect(access.createdBookmarkCount == 1)
        #expect(access.startCount == 0)
        #expect(access.stopCount == 0)
    }

    @Test func concurrentReaddWinsOverStaleRenewal() async throws {
        let db = try TestDatabase.make()
        let repository = SourceRootRepository(dbWriter: db)
        let access = StaleBookmarkSourceAccess(blockAccess: true)
        let originalURL = URL(
            fileURLWithPath: "/Volumes/Original",
            isDirectory: true
        )
        let relocatedURL = URL(
            fileURLWithPath: "/Volumes/Renamed",
            isDirectory: true
        )
        let source = try await repository.add(
            url: originalURL,
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 100)
        )
        access.markStale(source.bookmarkData, resolvingTo: relocatedURL)

        async let renewal = repository.renewBookmarkIfStale(
            source,
            sourceAccess: access
        )
        await access.waitUntilAccessStarts()
        let replacement = try await repository.add(
            url: relocatedURL,
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 200)
        )
        await access.releaseAccess()

        let renewalResult = try await renewal
        let stored = try #require(try await repository.all().first)
        #expect(renewalResult == replacement)
        #expect(stored == replacement)
        #expect(stored.bookmarkData == replacement.bookmarkData)
    }

    @Test func repositoryUpdatesLastScan() async throws {
        let db = try TestDatabase.make()
        let repository = SourceRootRepository(dbWriter: db)
        let access = FakeSourceAccess(url: URL(fileURLWithPath: "/Volumes/Test"))
        let source = try await repository.add(url: access.url, sourceAccess: access)
        let scanDate = Date(timeIntervalSince1970: 200)

        try await repository.updateLastScan(id: source.id, at: scanDate)

        let storedSources = try await repository.all()
        let storedSource = try #require(storedSources.first)
        #expect(storedSource.lastScanAt == scanDate)
    }

    @Test func repositoryRemovesSource() async throws {
        let db = try TestDatabase.make()
        let repository = SourceRootRepository(dbWriter: db)
        let access = FakeSourceAccess(url: URL(fileURLWithPath: "/Volumes/Test"))
        let source = try await repository.add(url: access.url, sourceAccess: access)

        try await repository.remove(id: source.id)

        let storedSources = try await repository.all()
        #expect(storedSources.isEmpty)
    }

    @Test func defaultAccessCreatesAndResolvesLocalBookmark() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = DefaultSourceAccess()

        let bookmark = try access.createBookmark(for: directory)
        let resolved = try access.resolve(bookmark)

        #expect(resolved.url.standardizedFileURL == directory.standardizedFileURL)
        #expect(!resolved.bookmarkWasStale)
    }

    @Test func defaultAccessBalancesLifetimeAfterSuccessfulOperation() async throws {
        let probe = AccessLifecycleProbe(url: URL(fileURLWithPath: "/Volumes/Test"))
        let access = makeDefaultAccess(probe: probe)

        let result = try await access.withAccess(to: Data("bookmark".utf8)) { url in
            url.lastPathComponent
        }

        #expect(result == "Test")
        #expect(probe.startCount == 1)
        #expect(probe.stopCount == 1)
    }

    @Test func defaultAccessStopsAfterThrownOperation() async {
        let probe = AccessLifecycleProbe(url: URL(fileURLWithPath: "/Volumes/Test"))
        let access = makeDefaultAccess(probe: probe)

        await #expect(throws: ProbeError.self) {
            try await access.withAccess(to: Data("bookmark".utf8)) { _ in
                throw ProbeError()
            }
        }

        #expect(probe.startCount == 1)
        #expect(probe.stopCount == 1)
    }

    @Test func defaultAccessDoesNotStopWhenSecurityScopeWasNotStarted() async throws {
        let probe = AccessLifecycleProbe(
            url: URL(fileURLWithPath: "/Volumes/Test"),
            startSucceeds: false
        )
        let access = makeDefaultAccess(probe: probe)

        let result = try await access.withAccess(to: Data("bookmark".utf8)) { _ in
            "completed"
        }

        #expect(result == "completed")
        #expect(probe.startCount == 1)
        #expect(probe.stopCount == 0)
    }

    private func makeDefaultAccess(probe: AccessLifecycleProbe) -> DefaultSourceAccess {
        DefaultSourceAccess(
            resolveBookmark: { _ in
                ResolvedSource(url: probe.url, bookmarkWasStale: false)
            },
            startAccessing: { url in probe.start(url) },
            stopAccessing: { url in probe.stop(url) }
        )
    }
}

private struct ProbeError: Error {}

private final class FakeSourceAccess: SourceAccessing, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var bookmarkCount = 0

    init(url: URL) {
        self.url = url
    }

    var createdBookmarkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bookmarkCount
    }

    func createBookmark(for url: URL) throws -> Data {
        lock.lock()
        bookmarkCount += 1
        lock.unlock()
        return Data("bookmark".utf8)
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        ResolvedSource(url: url, bookmarkWasStale: false)
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await operation(url)
    }
}

private final class RotatingBookmarkSourceAccess: SourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var nextBookmarkID = 0
    private var bookmarkedURLs: [Data: URL] = [:]
    private var resolutionIsEnabled = true

    func disableResolution() {
        lock.lock()
        resolutionIsEnabled = false
        lock.unlock()
    }

    func createBookmark(for url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        nextBookmarkID += 1
        let bookmark = Data("bookmark-\(nextBookmarkID)".utf8)
        bookmarkedURLs[bookmark] = url
        return bookmark
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        lock.lock()
        defer { lock.unlock() }
        guard resolutionIsEnabled, let url = bookmarkedURLs[bookmark] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return ResolvedSource(url: url, bookmarkWasStale: false)
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let resolved = try resolve(bookmark)
        return try await operation(resolved.url)
    }
}

private final class StaleBookmarkSourceAccess: SourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let accessGate: AccessGate?
    private var nextBookmarkID = 0
    private var bookmarkedURLs: [Data: URL] = [:]
    private var staleBookmarks = Set<Data>()
    private var starts = 0
    private var stops = 0

    init(blockAccess: Bool = false) {
        accessGate = blockAccess ? AccessGate() : nil
    }

    var createdBookmarkCount: Int {
        lock.withLock { nextBookmarkID }
    }

    var startCount: Int {
        lock.withLock { starts }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    func markStale(_ bookmark: Data, resolvingTo url: URL) {
        lock.withLock {
            bookmarkedURLs[bookmark] = url
            staleBookmarks.insert(bookmark)
        }
    }

    func createBookmark(for url: URL) throws -> Data {
        lock.withLock {
            nextBookmarkID += 1
            let bookmark = Data("bookmark-\(nextBookmarkID)".utf8)
            bookmarkedURLs[bookmark] = url
            return bookmark
        }
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        try lock.withLock {
            guard let url = bookmarkedURLs[bookmark] else {
                throw CocoaError(.fileNoSuchFile)
            }
            return ResolvedSource(
                url: url,
                bookmarkWasStale: staleBookmarks.contains(bookmark)
            )
        }
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let resolved = try resolve(bookmark)
        lock.withLock { starts += 1 }
        defer { lock.withLock { stops += 1 } }
        await accessGate?.waitUntilReleased()
        return try await operation(resolved.url)
    }

    func waitUntilAccessStarts() async {
        await accessGate?.waitUntilStarted()
    }

    func releaseAccess() async {
        await accessGate?.release()
    }
}

private actor AccessGate {
    private var isStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        isStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class AccessLifecycleProbe: @unchecked Sendable {
    let url: URL
    private let startSucceeds: Bool
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    init(url: URL, startSucceeds: Bool = true) {
        self.url = url
        self.startSucceeds = startSucceeds
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func start(_ url: URL) -> Bool {
        lock.lock()
        starts += 1
        lock.unlock()
        return startSucceeds
    }

    func stop(_ url: URL) {
        lock.lock()
        stops += 1
        lock.unlock()
    }
}
