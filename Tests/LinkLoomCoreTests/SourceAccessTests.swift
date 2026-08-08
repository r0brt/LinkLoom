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
