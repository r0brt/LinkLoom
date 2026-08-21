import Foundation
import Testing
@testable import LinkLoomAppFeature
@testable import LinkLoomCore

@Suite("App startup controller")
struct AppStartupControllerTests {
    @Test @MainActor func startupFailurePublishesRecoverableStateAndReportsDiagnostic() async {
        var reportedError: StartupTestError?
        let controller = AppStartupController(
            makeModel: { throw StartupTestError.catalogUnavailable },
            prepareModel: { _ in },
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
        let controller = AppStartupController(
            makeModel: {
                attemptCount += 1
                if attemptCount == 1 {
                    throw StartupTestError.catalogUnavailable
                }
                return fixture.model
            },
            prepareModel: { _ in }
        )

        await controller.startIfNeeded()

        await controller.retry()

        #expect(controller.phase == .ready)
        #expect(controller.model === fixture.model)
        #expect(attemptCount == 2)
    }

    @Test @MainActor func terminationDuringBlockedStartupWaitsForRegisteredModelShutdown() async throws {
        let fixture = try StartupTestModelFixture()
        let preparation = StartupGate()
        let shutdown = BlockingStartupShutdown()
        let replies = StartupTerminationReplyRecorder()
        let coordinator = AppTerminationCoordinator {}
        let controller = AppStartupController(
            makeModel: { fixture.model },
            prepareModel: { _ in await preparation.waitUntilReleased() }
        )
        let start = Task { @MainActor in
            await controller.startIfNeeded { _ in
                coordinator.updateStopWatching {
                    await shutdown.run()
                }
            }
        }
        await preparation.waitUntilStarted()

        _ = coordinator.requestTermination { allowed in
            await replies.record(allowed)
        }
        await shutdown.waitUntilStarted()

        #expect(await replies.value == nil)
        #expect(controller.phase == .starting)
        await shutdown.release()
        await replies.waitUntilRecorded()
        #expect(await replies.value == true)

        await preparation.release()
        await start.value
    }

    @Test @MainActor func retryRegistersReplacementModelForTermination() async throws {
        let firstFixture = try StartupTestModelFixture()
        let secondFixture = try StartupTestModelFixture()
        let stoppedModels = StoppedModelRecorder()
        let replies = StartupTerminationReplyRecorder()
        let coordinator = AppTerminationCoordinator {}
        var attemptCount = 0
        let controller = AppStartupController(
            makeModel: {
                attemptCount += 1
                return attemptCount == 1 ? firstFixture.model : secondFixture.model
            },
            prepareModel: { model in
                if model === firstFixture.model {
                    throw StartupTestError.catalogUnavailable
                }
            }
        )
        let registerModel: @MainActor (AppModel) -> Void = { model in
            let modelID = ObjectIdentifier(model)
            coordinator.updateStopWatching {
                await stoppedModels.record(modelID)
            }
        }

        await controller.startIfNeeded(registerModel: registerModel)
        await controller.retry(registerModel: registerModel)
        _ = coordinator.requestTermination { allowed in
            await replies.record(allowed)
        }
        await replies.waitUntilRecorded()

        #expect(await stoppedModels.modelID == ObjectIdentifier(secondFixture.model))
        #expect(await replies.value == true)
    }

    @Test @MainActor func overlappingStartRequestsInvokeFactoryOnce() async throws {
        let fixture = try StartupTestModelFixture()
        let gate = StartupGate()
        var attemptCount = 0
        let controller = AppStartupController(
            makeModel: {
                attemptCount += 1
                return fixture.model
            },
            prepareModel: { _ in await gate.waitUntilReleased() }
        )

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
        let controller = AppStartupController(
            makeModel: {
                attemptCount += 1
                return fixture.model
            },
            prepareModel: { _ in }
        )

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

private actor BlockingStartupShutdown {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run() async {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor StartupTerminationReplyRecorder {
    private(set) var value: Bool?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ value: Bool) {
        self.value = value
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilRecorded() async {
        guard value == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor StoppedModelRecorder {
    private(set) var modelID: ObjectIdentifier?

    func record(_ modelID: ObjectIdentifier) {
        self.modelID = modelID
    }
}

private enum StartupTestError: Error, Equatable {
    case catalogUnavailable
}
