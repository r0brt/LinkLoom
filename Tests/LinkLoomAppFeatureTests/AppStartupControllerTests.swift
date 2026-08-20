import Foundation
import Testing
@testable import LinkLoomAppFeature
@testable import LinkLoomCore

@Suite("App startup controller")
struct AppStartupControllerTests {
    @Test @MainActor func startupFailurePublishesRecoverableStateAndReportsDiagnostic() async {
        var reportedError: StartupTestError?
        let controller = AppStartupController(
            start: { throw StartupTestError.catalogUnavailable },
            reportFailure: { error in
                reportedError = error as? StartupTestError
            }
        )

        await controller.startIfNeeded()

        #expect(controller.phase == .failed(.localCatalogUnavailable))
        #expect(controller.model == nil)
        #expect(reportedError == .catalogUnavailable)
    }

    @Test @MainActor func retryAfterFailurePublishesReadyModel() async throws {
        let fixture = try StartupTestModelFixture()
        var attemptCount = 0
        let controller = AppStartupController {
            attemptCount += 1
            if attemptCount == 1 {
                throw StartupTestError.catalogUnavailable
            }
            return fixture.model
        }
        await controller.startIfNeeded()

        await controller.retry()

        #expect(controller.phase == .ready)
        #expect(controller.model === fixture.model)
        #expect(attemptCount == 2)
    }

    @Test @MainActor func overlappingStartRequestsInvokeFactoryOnce() async throws {
        let fixture = try StartupTestModelFixture()
        let gate = StartupGate()
        var attemptCount = 0
        let controller = AppStartupController {
            attemptCount += 1
            await gate.waitUntilReleased()
            return fixture.model
        }

        let firstStart = Task { @MainActor in
            await controller.startIfNeeded()
        }
        await gate.waitUntilStarted()
        await controller.startIfNeeded()

        #expect(controller.phase == .starting)
        #expect(attemptCount == 1)
        await gate.release()
        await firstStart.value

        #expect(controller.phase == .ready)
        #expect(controller.model === fixture.model)
        #expect(attemptCount == 1)
    }

    @Test @MainActor func startAfterReadyDoesNotReloadModel() async throws {
        let fixture = try StartupTestModelFixture()
        var attemptCount = 0
        let controller = AppStartupController {
            attemptCount += 1
            return fixture.model
        }

        await controller.startIfNeeded()
        await controller.startIfNeeded()

        #expect(controller.phase == .ready)
        #expect(attemptCount == 1)
    }
}

@MainActor
private final class StartupTestModelFixture {
    let directory: URL
    let model: AppModel

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkLoomStartupTests-\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.makeQueue(
            at: directory.appendingPathComponent("linkloom.sqlite")
        )
        model = AppModel(
            sources: SourceRootRepository(dbWriter: database),
            documents: DocumentRepository(dbWriter: database),
            sourceAccess: StartupSourceAccess(),
            catalog: StartupCatalogScanner(),
            ingestion: StartupPendingIngester()
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct StartupSourceAccess: SourceAccessing {
    func createBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        ResolvedSource(
            url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)),
            bookmarkWasStale: false
        )
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await operation(URL(
            fileURLWithPath: String(decoding: bookmark, as: UTF8.self)
        ))
    }
}

private struct StartupCatalogScanner: CatalogScanning {
    func scan(source: SourceRootRecord) async throws {}
}

private struct StartupPendingIngester: PendingIngesting {
    func processPending(source: SourceRootRecord) async throws {}
}

private actor StartupGate {
    private var accessCount = 0
    private var isStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilReleased() async {
        accessCount += 1
        guard accessCount == 1 else { return }
        isStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private enum StartupTestError: Error, Equatable {
    case catalogUnavailable
}
