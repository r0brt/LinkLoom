import Combine
import Foundation
import Testing
@testable import LinkLoomAppFeature
import LinkLoomCore

@Suite("Diagnostic app model", .serialized)
struct AppModelTests {
    @Test @MainActor func scanPublishesProgressAndReloadsDocuments() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let expectedDocument = fixture.document(sourceRootID: source.id, path: "ready.pdf")
        let scanner = FakeCatalogScanner {
            try await fixture.documents.save(expectedDocument)
        }
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: scanner,
            ingestion: FakePendingIngester()
        )
        try await model.reload()
        var observedStates: [AppScanState] = []
        let observation = model.$scanState.sink { observedStates.append($0) }

        await model.scanSelectedSource()
        _ = observation

        #expect(observedStates == [.idle, .scanning, .extracting, .idle])
        #expect(model.documents == [expectedDocument])
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func scanFailureAppearsWithoutRemovingExistingDocuments() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let existingDocument = fixture.document(sourceRootID: source.id, path: "existing.pdf")
        try await fixture.documents.save(existingDocument)
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner { throw AppModelTestError.scanFailed },
            ingestion: FakePendingIngester()
        )
        try await model.reload()

        await model.scanSelectedSource()

        #expect(model.scanState == .idle)
        #expect(model.lastErrorCode == "scanFailure")
        #expect(model.documents == [existingDocument])
    }

    @Test @MainActor func addingSourcePersistsAndSelectsIt() async throws {
        let fixture = try AppModelFixture()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester()
        )
        try await model.reload()
        let selectedURL = fixture.directory.appendingPathComponent("Selected", isDirectory: true)

        await model.addSource(selectedURL)

        let persisted = try #require(try await fixture.sources.all().first)
        #expect(model.sources == [persisted])
        #expect(model.selectedSourceID == persisted.id)
        #expect(persisted.displayName == "Selected")
        #expect(persisted.pathHint == selectedURL.path)
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func removingSelectedSourceClearsItsDocuments() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        try await fixture.documents.save(
            fixture.document(sourceRootID: source.id, path: "existing.pdf")
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester()
        )
        try await model.reload()

        await model.removeSource(source)

        #expect(try await fixture.sources.all().isEmpty)
        #expect(model.sources.isEmpty)
        #expect(model.selectedSourceID == nil)
        #expect(model.documents.isEmpty)
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func selectingSourceReloadsItsDocuments() async throws {
        let fixture = try AppModelFixture()
        _ = try await fixture.addSource(named: "First")
        let second = try await fixture.addSource(named: "Second")
        let secondDocument = fixture.document(
            sourceRootID: second.id,
            path: "second.pdf"
        )
        try await fixture.documents.save(secondDocument)
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester()
        )
        try await model.reload()

        await model.selectSource(id: second.id)

        #expect(model.selectedSourceID == second.id)
        #expect(model.documents == [secondDocument])
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func overlappingScanDoesNotStartTwiceOrPublishIdleEarly() async throws {
        let fixture = try AppModelFixture()
        _ = try await fixture.addSource(named: "Archive")
        let scanner = OverlappingCatalogScanner()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: scanner,
            ingestion: FakePendingIngester()
        )
        try await model.reload()
        let firstScan = Task { await model.scanSelectedSource() }
        await scanner.waitUntilFirstScanStarts()

        await model.scanSelectedSource()

        #expect(await scanner.callCount == 1)
        #expect(model.scanState == .scanning)
        await scanner.releaseFirstScan()
        await firstScan.value
        #expect(model.scanState == .idle)
    }

    @Test @MainActor func staleSourceLoadCannotOverwriteNewerSelection() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let second = try await fixture.addSource(named: "Second")
        let firstDocument = fixture.document(sourceRootID: first.id, path: "first.pdf")
        let secondDocument = fixture.document(sourceRootID: second.id, path: "second.pdf")
        let loader = ReorderedDocumentLoader(
            documentsBySource: [
                first.id: [firstDocument],
                second.id: [secondDocument],
            ],
            blockedSourceID: second.id
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            documentLoader: { sourceID in
                await loader.load(sourceID: sourceID)
            }
        )
        try await model.reload()
        let slowSelection = Task { await model.selectSource(id: second.id) }
        await loader.waitUntilBlockedLoadStarts()

        await model.selectSource(id: first.id)
        await loader.releaseBlockedLoad()
        await slowSelection.value

        #expect(model.selectedSourceID == first.id)
        #expect(model.documents == [firstDocument])
    }

    @Test @MainActor func activeScanKeepsOwnedSourceSelectedAndPersisted() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let second = try await fixture.addSource(named: "Second")
        let scanner = OverlappingCatalogScanner()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: scanner,
            ingestion: FakePendingIngester()
        )
        try await model.reload()
        let scan = Task { await model.scanSelectedSource() }
        await scanner.waitUntilFirstScanStarts()

        await model.selectSource(id: second.id)
        await model.removeSource(first)
        await model.addSource(
            fixture.directory.appendingPathComponent("Third", isDirectory: true)
        )

        #expect(model.selectedSourceID == first.id)
        #expect(try await fixture.sources.all() == [first, second])
        await scanner.releaseFirstScan()
        await scan.value
    }

    @Test @MainActor func staleSourceLoadCannotClearNewerSelectionError() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let second = try await fixture.addSource(named: "Second")
        let loader = StaleErrorDocumentLoader(
            currentSourceID: first.id,
            blockedSourceID: second.id
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            documentLoader: { sourceID in
                try await loader.load(sourceID: sourceID)
            }
        )
        try await model.reload()
        let staleSelection = Task { await model.selectSource(id: second.id) }
        await loader.waitUntilBlockedLoadStarts()

        await model.selectSource(id: first.id)
        #expect(model.lastErrorCode == "documentLoadFailure")
        await loader.releaseBlockedLoad()
        await staleSelection.value

        #expect(model.selectedSourceID == first.id)
        #expect(model.lastErrorCode == "documentLoadFailure")
    }

    @Test @MainActor func scanDoesNotStartWhileSourceMutationIsSuspended() async throws {
        let fixture = try AppModelFixture()
        _ = try await fixture.addSource(named: "First")
        let sourceAccess = BlockingBookmarkSourceAccess()
        let scanner = CountingCatalogScanner()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: sourceAccess,
            catalog: scanner,
            ingestion: FailingPendingIngester()
        )
        try await model.reload()
        let add = Task {
            await model.addSource(
                fixture.directory.appendingPathComponent("Second", isDirectory: true)
            )
        }
        await sourceAccess.waitUntilBookmarkCreationStarts()

        await model.scanSelectedSource()

        #expect(await scanner.callCount == 0)
        sourceAccess.releaseBookmarkCreation()
        await add.value
    }

    @Test @MainActor func reloadStartsWatchingEachResolvedSource() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let second = try await fixture.addSource(named: "Second")
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { source in
                URL(fileURLWithPath: "/resolved/\(source.displayName)")
            }
        )

        try await model.reload()

        #expect(await scheduler.startedSources == [
            WatchedSource(sourceID: first.id, path: "/resolved/First"),
            WatchedSource(sourceID: second.id, path: "/resolved/Second"),
        ])
    }

    @Test @MainActor func rootLifecycleEventsUpdateOnlySourceAvailabilityState() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in URL(fileURLWithPath: "/resolved/Archive") }
        )
        try await model.reload()

        scheduler.emit(DirectoryChange(sourceRootID: source.id, kind: .rootUnavailable))
        await waitUntil { model.unavailableSourceIDs == [source.id] }
        scheduler.emit(DirectoryChange(sourceRootID: source.id, kind: .rootAvailable))
        await waitUntil { model.unavailableSourceIDs.isEmpty }

        #expect(model.documents.isEmpty)
    }

    @Test @MainActor func reloadRestartsWatcherAfterUnexpectedFailure() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in URL(fileURLWithPath: "/resolved/Archive") }
        )
        try await model.reload()

        await scheduler.fail(sourceID: source.id)
        await waitUntil { model.unavailableSourceIDs == [source.id] }
        try await model.reload()

        #expect(await scheduler.startedSources.count == 2)
        #expect(model.unavailableSourceIDs.isEmpty)
    }

    @Test @MainActor func unavailableEventDuringStartWinsOverActiveWatcherState() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let scheduler = FakeSourceWatchScheduler(rootUnavailableDuringStart: true)
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in URL(fileURLWithPath: "/resolved/Archive") }
        )

        try await model.reload()

        #expect(await scheduler.isWatching(sourceID: source.id))
        #expect(model.unavailableSourceIDs == [source.id])
    }

    @Test @MainActor func selectedSourceRefreshesAfterIncrementalRescan() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory }
        )
        try await model.reload()
        let ready = fixture.document(sourceRootID: source.id, path: "new.pdf")
        try await fixture.documents.save(ready)
        try await fixture.sources.updateLastScan(
            id: source.id,
            at: Date(timeIntervalSince1970: 500)
        )

        scheduler.completeRescan(sourceID: source.id)
        await waitUntil {
            model.documents == [ready] && model.sources.first?.lastScanAt != nil
        }
    }

    @Test @MainActor func unselectedSourceCompletionKeepsSelectedDocuments() async throws {
        let fixture = try AppModelFixture()
        let selected = try await fixture.addSource(named: "Selected")
        let completed = try await fixture.addSource(named: "Completed")
        let visible = fixture.document(sourceRootID: selected.id, path: "visible.pdf")
        try await fixture.documents.save(visible)
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory }
        )
        try await model.reload()
        await model.selectSource(id: selected.id)
        let unrelated = fixture.document(sourceRootID: completed.id, path: "unrelated.pdf")
        try await fixture.documents.save(unrelated)
        try await fixture.sources.updateLastScan(
            id: completed.id,
            at: Date(timeIntervalSince1970: 500)
        )

        scheduler.completeRescan(sourceID: completed.id)
        await waitUntil {
            model.sources.first(where: { $0.id == completed.id })?.lastScanAt != nil
        }

        #expect(model.selectedSourceID == selected.id)
        #expect(model.documents == [visible])
    }

    @Test @MainActor func staleCompletionMetadataCannotOverwriteNewerSourceAddition() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let loader = TwoStageSourceLoader(staleSources: [first])
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory },
            sourceLoader: { try await loader.load() }
        )
        try await model.reload()

        scheduler.completeRescan(sourceID: first.id)
        await loader.waitUntilFirstLoadStarts()
        await model.addSource(
            fixture.directory.appendingPathComponent("Second", isDirectory: true)
        )
        let secondID = try #require(model.selectedSourceID)
        scheduler.completeRescan(sourceID: first.id)
        await loader.releaseFirstLoad()
        await loader.waitUntilSecondLoadStarts()

        #expect(model.sources.map(\.id).contains(secondID))
        #expect(model.selectedSourceID == secondID)
        await loader.releaseSecondLoad()
        await model.stopWatching()
    }

    @Test @MainActor func completionDuringSourceAdditionRunsAfterOperation() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let sourceAccess = BlockingBookmarkSourceAccess()
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory }
        )
        try await model.reload()
        try await fixture.sources.updateLastScan(
            id: first.id,
            at: Date(timeIntervalSince1970: 500)
        )
        let add = Task {
            await model.addSource(
                fixture.directory.appendingPathComponent("Second", isDirectory: true)
            )
        }
        await sourceAccess.waitUntilBookmarkCreationStarts()

        scheduler.completeRescan(sourceID: first.id)
        try await ContinuousClock().sleep(for: .milliseconds(20))
        #expect(model.sources.first?.lastScanAt == nil)
        sourceAccess.releaseBookmarkCreation()
        await add.value
        let secondID = try #require(model.selectedSourceID)
        await waitUntil {
            model.sources.first(where: { $0.id == first.id })?.lastScanAt != nil
        }

        #expect(model.sources.map(\.id).contains(secondID))
        #expect(model.selectedSourceID == secondID)
        await model.stopWatching()
    }

    @Test @MainActor func completionDuringFailedSourceAdditionRunsAfterOperation() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let sourceAccess = BlockingBookmarkSourceAccess(throwsAfterRelease: true)
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory }
        )
        try await model.reload()
        try await fixture.sources.updateLastScan(
            id: first.id,
            at: Date(timeIntervalSince1970: 500)
        )
        let add = Task {
            await model.addSource(
                fixture.directory.appendingPathComponent("Second", isDirectory: true)
            )
        }
        await sourceAccess.waitUntilBookmarkCreationStarts()

        scheduler.completeRescan(sourceID: first.id)
        try await ContinuousClock().sleep(for: .milliseconds(20))
        #expect(model.sources.first?.lastScanAt == nil)
        sourceAccess.releaseBookmarkCreation()
        await add.value
        await waitUntil { model.sources.first?.lastScanAt != nil }

        #expect(model.lastErrorCode == "sourceAddFailure")
        await model.stopWatching()
    }

    @Test @MainActor func shutdownRejectsQueuedCompletionAfterSourceOperation() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let sourceAccess = BlockingBookmarkSourceAccess()
        let completionLoader = ImmediateSourceSnapshotLoader(snapshot: [first])
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory },
            sourceLoader: { await completionLoader.load() }
        )
        try await model.reload()
        let add = Task {
            await model.addSource(
                fixture.directory.appendingPathComponent("Second", isDirectory: true)
            )
        }
        await sourceAccess.waitUntilBookmarkCreationStarts()
        scheduler.completeRescan(sourceID: first.id)
        try await ContinuousClock().sleep(for: .milliseconds(20))

        await model.stopWatching()
        sourceAccess.releaseBookmarkCreation()
        await add.value
        try await ContinuousClock().sleep(for: .milliseconds(20))

        #expect(await completionLoader.didRun == false)
    }

    @Test @MainActor func replacementDrainWaitsForCancelledDrainToFinish() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let sourceAccess = BlockingBookmarkSourceAccess()
        let catalog = BlockingCatalogScanner()
        let loader = CancellationResistantFirstSourceLoader(snapshot: [first])
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: sourceAccess,
            catalog: catalog,
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory },
            sourceLoader: { await loader.load() }
        )
        try await model.reload()
        let add = Task {
            await model.addSource(
                fixture.directory.appendingPathComponent("Second", isDirectory: true)
            )
        }
        await sourceAccess.waitUntilBookmarkCreationStarts()
        scheduler.completeRescan(sourceID: first.id)
        sourceAccess.releaseBookmarkCreation()
        await add.value
        await loader.waitUntilFirstLoadStarts()
        let scan = Task { await model.scanSelectedSource() }
        await catalog.waitUntilScanStarts()
        scheduler.completeRescan(sourceID: first.id)
        await catalog.releaseScan()
        await scan.value
        try await ContinuousClock().sleep(for: .milliseconds(20))
        await loader.releaseFirstLoad()

        try await waitUntilAsync { await loader.loadCount >= 2 }
        #expect(await loader.loadCount >= 2)
        await model.stopWatching()
    }

    @Test @MainActor func completionStartingDuringReloadRunsAfterReloadFinishes() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let second = try await fixture.addSource(named: "Second")
        var refreshedFirst = first
        refreshedFirst.lastScanAt = Date(timeIntervalSince1970: 500)
        let documentLoader = BlockingSecondDocumentLoader(initial: [], late: [])
        let completionLoader = ImmediateSourceSnapshotLoader(snapshot: [refreshedFirst, second])
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory },
            sourceLoader: { await completionLoader.load() },
            documentLoader: { sourceID in await documentLoader.load(sourceID: sourceID) }
        )
        try await model.reload()
        let reload = Task { try await model.reload() }
        await documentLoader.waitUntilSecondLoadStarts()

        scheduler.completeRescan(sourceID: first.id)
        try await ContinuousClock().sleep(for: .milliseconds(20))
        #expect(await completionLoader.didRun == false)
        await documentLoader.releaseSecondLoad()
        try await reload.value
        await waitUntil { model.sources == [refreshedFirst, second] }

        #expect(model.sources == [refreshedFirst, second])
        await model.stopWatching()
    }

    @Test @MainActor func completionCannotStartUntilAllOverlappingReloadsFinish() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let documentLoader = BlockingSelectedLoadDocumentLoader()
        let completionLoader = ImmediateSourceSnapshotLoader(snapshot: [source])
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory },
            sourceLoader: { await completionLoader.load() },
            documentLoader: { sourceID in await documentLoader.load(sourceID: sourceID) }
        )
        try await model.reload()
        await documentLoader.block(loadNumber: 2)
        let firstReload = Task { try await model.reload() }
        await documentLoader.waitUntilBlockedLoadStarts()

        let secondReload = Task { try await model.reload() }
        try await secondReload.value
        scheduler.completeRescan(sourceID: source.id)
        try await ContinuousClock().sleep(for: .milliseconds(20))

        #expect(await completionLoader.didRun == false)
        await documentLoader.releaseBlockedLoad()
        try await firstReload.value
        await model.stopWatching()
    }

    @Test @MainActor func completionReloadsDocumentsForFallbackSelection() async throws {
        let fixture = try AppModelFixture()
        let removed = try await fixture.addSource(named: "Removed")
        let fallback = try await fixture.addSource(named: "Fallback")
        let removedDocument = fixture.document(
            sourceRootID: removed.id,
            path: "removed.pdf"
        )
        let fallbackDocument = fixture.document(
            sourceRootID: fallback.id,
            path: "fallback.pdf"
        )
        try await fixture.documents.save(removedDocument)
        try await fixture.documents.save(fallbackDocument)
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory }
        )
        try await model.reload()
        await model.selectSource(id: removed.id)
        try await fixture.sources.remove(id: removed.id)

        scheduler.completeRescan(sourceID: removed.id)
        await waitUntil {
            model.selectedSourceID == fallback.id && model.documents == [fallbackDocument]
        }

        #expect(model.documents == [fallbackDocument])
    }

    @Test @MainActor func currentIncrementalRefreshFailurePreservesVisibleDocuments() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let visible = fixture.document(sourceRootID: source.id, path: "visible.pdf")
        let loader = FailingSecondDocumentLoader(documentsBySource: [
            source.id: [visible],
        ])
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory },
            documentLoader: { sourceID in try await loader.load(sourceID: sourceID) }
        )
        try await model.reload()

        scheduler.completeRescan(sourceID: source.id)
        await waitUntil { model.lastErrorCode == "incrementalRefreshFailure" }

        #expect(model.documents == [visible])
    }

    @Test @MainActor func fallbackDocumentFailurePublishesIncrementalRefreshError() async throws {
        let fixture = try AppModelFixture()
        let removed = try await fixture.addSource(named: "Removed")
        let fallback = try await fixture.addSource(named: "Fallback")
        let visible = fixture.document(sourceRootID: removed.id, path: "visible.pdf")
        let loader = ToggleFailingDocumentLoader(documentsBySource: [
            removed.id: [visible],
            fallback.id: [],
        ])
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory },
            documentLoader: { sourceID in try await loader.load(sourceID: sourceID) }
        )
        try await model.reload()
        await model.selectSource(id: removed.id)
        await loader.fail(sourceID: fallback.id)
        try await fixture.sources.remove(id: removed.id)

        scheduler.completeRescan(sourceID: removed.id)
        await waitUntil {
            model.lastErrorCode == "incrementalRefreshFailure"
        }

        #expect(model.selectedSourceID == fallback.id)
        #expect(model.documents == [visible])
    }

    @Test @MainActor func staleIncrementalRefreshFailureDoesNotPublishError() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let second = try await fixture.addSource(named: "Second")
        let firstDocument = fixture.document(sourceRootID: first.id, path: "first.pdf")
        let secondDocument = fixture.document(sourceRootID: second.id, path: "second.pdf")
        let loader = FailingSecondDocumentLoader(
            documentsBySource: [
                first.id: [firstDocument],
                second.id: [secondDocument],
            ],
            blocksSecondLoad: true
        )
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory },
            documentLoader: { sourceID in try await loader.load(sourceID: sourceID) }
        )
        try await model.reload()
        scheduler.completeRescan(sourceID: first.id)
        await loader.waitUntilSecondLoadStarts()

        await model.selectSource(id: second.id)
        await loader.releaseSecondLoad()
        try await fixture.sources.updateLastScan(
            id: second.id,
            at: Date(timeIntervalSince1970: 500)
        )
        scheduler.completeRescan(sourceID: second.id)
        await waitUntil {
            model.sources.first(where: { $0.id == second.id })?.lastScanAt != nil
        }

        #expect(model.selectedSourceID == second.id)
        #expect(model.documents == [secondDocument])
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func stopWatchingStopsEverySourceStream() async throws {
        let fixture = try AppModelFixture()
        _ = try await fixture.addSource(named: "Archive")
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in URL(fileURLWithPath: "/resolved/Archive") }
        )
        try await model.reload()

        await model.stopWatching()

        #expect(await scheduler.stopAllCount == 1)
    }

    @Test @MainActor func stopWatchingWaitsForCompletionObserverAndRejectsLateDocuments() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let visible = fixture.document(sourceRootID: source.id, path: "visible.pdf")
        let late = fixture.document(sourceRootID: source.id, path: "late.pdf")
        let loader = BlockingSecondDocumentLoader(initial: [visible], late: [late])
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory },
            documentLoader: { sourceID in await loader.load(sourceID: sourceID) }
        )
        try await model.reload()
        scheduler.completeRescan(sourceID: source.id)
        await loader.waitUntilSecondLoadStarts()
        let completion = CompletionFlag()

        let stop = Task {
            await model.stopWatching()
            await completion.record()
        }
        try await ContinuousClock().sleep(for: .milliseconds(20))

        #expect(await completion.didComplete == false)
        await loader.releaseSecondLoad()
        await stop.value
        #expect(model.documents == [visible])
    }

    @Test @MainActor func oldStopCannotStopRestartedWatchLifecycle() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let visible = fixture.document(sourceRootID: source.id, path: "visible.pdf")
        let loader = BlockingSecondDocumentLoader(initial: [visible], late: [visible])
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory },
            documentLoader: { sourceID in await loader.load(sourceID: sourceID) }
        )
        try await model.reload()
        scheduler.completeRescan(sourceID: source.id)
        await loader.waitUntilSecondLoadStarts()
        let stop = Task { await model.stopWatching() }
        await Task.yield()

        try await model.reload()
        await loader.releaseSecondLoad()
        await stop.value

        #expect(await scheduler.isWatching(sourceID: source.id))
        #expect(await scheduler.stopAllCount == 0)
        await model.stopWatching()
    }

    @Test @MainActor func terminationWaitsForWatcherShutdownBeforeReplying() async throws {
        let shutdown = BlockingShutdown()
        let replies = TerminationReplyRecorder()
        let coordinator = AppTerminationCoordinator {
            await shutdown.run()
        }

        let decision = coordinator.requestTermination { allowed in
            await replies.record(allowed)
        }
        await shutdown.waitUntilStarted()

        #expect(decision == .terminateLater)
        #expect(await replies.values.isEmpty)
        await shutdown.release()
        try await waitUntilAsync { await replies.values == [true] }
    }

    @MainActor
    private func waitUntil(
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for AppModel state")
                return
            }
            await Task.yield()
        }
    }
}

private actor BlockingShutdown {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run() async {
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor TerminationReplyRecorder {
    private(set) var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }
}

private func waitUntilAsync(
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
            throw AppModelTestError.timeout
        }
        _ = try await group.next()
        group.cancelAll()
    }
}

private struct WatchedSource: Sendable, Equatable {
    let sourceID: UUID
    let path: String
}

private actor FakeSourceWatchScheduler: SourceWatchScheduling {
    nonisolated let changes: AsyncStream<DirectoryChange>
    nonisolated let rescanCompletions: AsyncStream<UUID>
    nonisolated private let continuation: AsyncStream<DirectoryChange>.Continuation
    nonisolated private let completionContinuation: AsyncStream<UUID>.Continuation
    private(set) var startedSources: [WatchedSource] = []
    private(set) var stopAllCount = 0
    private var activeSourceIDs = Set<UUID>()
    private let rootUnavailableDuringStart: Bool
    private var availabilityProbeCount = 0

    init(rootUnavailableDuringStart: Bool = false) {
        let pair = AsyncStream<DirectoryChange>.makeStream()
        let completionPair = AsyncStream<UUID>.makeStream()
        changes = pair.stream
        rescanCompletions = completionPair.stream
        continuation = pair.continuation
        completionContinuation = completionPair.continuation
        self.rootUnavailableDuringStart = rootUnavailableDuringStart
    }

    func start(source: SourceRootRecord, url: URL) async {
        startedSources.append(WatchedSource(sourceID: source.id, path: url.path))
        activeSourceIDs.insert(source.id)
        if rootUnavailableDuringStart {
            continuation.yield(DirectoryChange(
                sourceRootID: source.id,
                kind: .rootUnavailable
            ))
            while availabilityProbeCount == 0 {
                await Task.yield()
            }
        }
    }

    func isWatching(sourceID: UUID) -> Bool {
        availabilityProbeCount += 1
        return activeSourceIDs.contains(sourceID)
    }

    func stop(sourceID: UUID) {
        activeSourceIDs.remove(sourceID)
    }

    func stopAll() {
        stopAllCount += 1
        activeSourceIDs.removeAll()
    }

    func fail(sourceID: UUID) {
        activeSourceIDs.remove(sourceID)
        continuation.yield(DirectoryChange(
            sourceRootID: sourceID,
            kind: .rootUnavailable
        ))
    }

    nonisolated func emit(_ change: DirectoryChange) {
        continuation.yield(change)
    }

    nonisolated func completeRescan(sourceID: UUID) {
        completionContinuation.yield(sourceID)
    }
}

private actor CountingCatalogScanner: CatalogScanning {
    private(set) var callCount = 0

    func scan(source: SourceRootRecord) async throws {
        callCount += 1
    }
}

private actor BlockingCatalogScanner: CatalogScanning {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func scan(source: SourceRootRecord) async {
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilScanStarts() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseScan() {
        continuation?.resume()
        continuation = nil
    }
}

private struct FailingPendingIngester: PendingIngesting {
    func processPending(source: SourceRootRecord) async throws {
        throw AppModelTestError.ingestionFailed
    }
}

private final class BlockingBookmarkSourceAccess: SourceAccessing, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private let throwsAfterRelease: Bool

    init(throwsAfterRelease: Bool = false) {
        self.throwsAfterRelease = throwsAfterRelease
    }

    func createBookmark(for url: URL) throws -> Data {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
        if throwsAfterRelease {
            throw AppModelTestError.scanFailed
        }
        return Data(url.path.utf8)
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        throw AppModelTestError.unusedSourceResolution
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await operation(URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)))
    }

    func waitUntilBookmarkCreationStarts() async {
        while true {
            let didStart = condition.withLock { started }
            if didStart { return }
            await Task.yield()
        }
    }

    func releaseBookmarkCreation() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor StaleErrorDocumentLoader {
    private let currentSourceID: UUID
    private let blockedSourceID: UUID
    private var currentSourceLoadCount = 0
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(currentSourceID: UUID, blockedSourceID: UUID) {
        self.currentSourceID = currentSourceID
        self.blockedSourceID = blockedSourceID
    }

    func load(sourceID: UUID) async throws -> [DocumentRecord] {
        if sourceID == currentSourceID {
            currentSourceLoadCount += 1
            if currentSourceLoadCount > 1 {
                throw AppModelTestError.documentLoadFailed
            }
            return []
        }
        if sourceID == blockedSourceID {
            for waiter in startWaiters {
                waiter.resume()
            }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        return []
    }

    func waitUntilBlockedLoadStarts() async {
        guard blockedContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseBlockedLoad() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor ReorderedDocumentLoader {
    private let documentsBySource: [UUID: [DocumentRecord]]
    private let blockedSourceID: UUID
    private var shouldBlock = true
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        documentsBySource: [UUID: [DocumentRecord]],
        blockedSourceID: UUID
    ) {
        self.documentsBySource = documentsBySource
        self.blockedSourceID = blockedSourceID
    }

    func load(sourceID: UUID) async -> [DocumentRecord] {
        if sourceID == blockedSourceID, shouldBlock {
            shouldBlock = false
            for waiter in startWaiters {
                waiter.resume()
            }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        return documentsBySource[sourceID] ?? []
    }

    func waitUntilBlockedLoadStarts() async {
        guard shouldBlock else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseBlockedLoad() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor TwoStageSourceLoader {
    private let staleSources: [SourceRootRecord]
    private var loadCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var secondContinuation: CheckedContinuation<Void, Never>?
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(staleSources: [SourceRootRecord]) {
        self.staleSources = staleSources
    }

    func load() async throws -> [SourceRootRecord] {
        loadCount += 1
        if loadCount == 1 {
            firstStartWaiters.forEach { $0.resume() }
            firstStartWaiters.removeAll()
            await withCheckedContinuation { firstContinuation = $0 }
        } else {
            secondStartWaiters.forEach { $0.resume() }
            secondStartWaiters.removeAll()
            await withCheckedContinuation { secondContinuation = $0 }
        }
        return staleSources
    }

    func waitUntilFirstLoadStarts() async {
        guard loadCount == 0 else { return }
        await withCheckedContinuation { firstStartWaiters.append($0) }
    }

    func waitUntilSecondLoadStarts() async {
        guard loadCount < 2 else { return }
        await withCheckedContinuation { secondStartWaiters.append($0) }
    }

    func releaseFirstLoad() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    func releaseSecondLoad() {
        secondContinuation?.resume()
        secondContinuation = nil
    }
}

private actor ImmediateSourceSnapshotLoader {
    private let snapshot: [SourceRootRecord]
    private(set) var didRun = false

    init(snapshot: [SourceRootRecord]) {
        self.snapshot = snapshot
    }

    func load() -> [SourceRootRecord] {
        didRun = true
        return snapshot
    }
}

private actor CancellationResistantFirstSourceLoader {
    private let snapshot: [SourceRootRecord]
    private(set) var loadCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(snapshot: [SourceRootRecord]) {
        self.snapshot = snapshot
    }

    func load() async -> [SourceRootRecord] {
        loadCount += 1
        guard loadCount == 1 else { return snapshot }
        firstStartWaiters.forEach { $0.resume() }
        firstStartWaiters.removeAll()
        await withCheckedContinuation { firstContinuation = $0 }
        return snapshot
    }

    func waitUntilFirstLoadStarts() async {
        guard loadCount == 0 else { return }
        await withCheckedContinuation { firstStartWaiters.append($0) }
    }

    func releaseFirstLoad() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor BlockingSelectedLoadDocumentLoader {
    private var loadCount = 0
    private var blockedLoadNumber: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load(sourceID: UUID) async -> [DocumentRecord] {
        loadCount += 1
        guard loadCount == blockedLoadNumber else { return [] }
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return []
    }

    func block(loadNumber: Int) {
        blockedLoadNumber = loadNumber
    }

    func waitUntilBlockedLoadStarts() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedLoad() {
        continuation?.resume()
        continuation = nil
    }
}

private actor BlockingSecondDocumentLoader {
    private let initial: [DocumentRecord]
    private let late: [DocumentRecord]
    private var loadCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(initial: [DocumentRecord], late: [DocumentRecord]) {
        self.initial = initial
        self.late = late
    }

    func load(sourceID: UUID) async -> [DocumentRecord] {
        loadCount += 1
        guard loadCount == 2 else {
            return loadCount == 1 ? initial : late
        }
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return late
    }

    func waitUntilSecondLoadStarts() async {
        guard loadCount < 2 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseSecondLoad() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FailingSecondDocumentLoader {
    private let documentsBySource: [UUID: [DocumentRecord]]
    private let blocksSecondLoad: Bool
    private var loadCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        documentsBySource: [UUID: [DocumentRecord]],
        blocksSecondLoad: Bool = false
    ) {
        self.documentsBySource = documentsBySource
        self.blocksSecondLoad = blocksSecondLoad
    }

    func load(sourceID: UUID) async throws -> [DocumentRecord] {
        loadCount += 1
        guard loadCount == 2 else { return documentsBySource[sourceID] ?? [] }
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if blocksSecondLoad {
            await withCheckedContinuation { continuation = $0 }
        }
        throw AppModelTestError.documentLoadFailed
    }

    func waitUntilSecondLoadStarts() async {
        guard loadCount < 2 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseSecondLoad() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ToggleFailingDocumentLoader {
    private let documentsBySource: [UUID: [DocumentRecord]]
    private var failingSourceID: UUID?

    init(documentsBySource: [UUID: [DocumentRecord]]) {
        self.documentsBySource = documentsBySource
    }

    func load(sourceID: UUID) async throws -> [DocumentRecord] {
        if sourceID == failingSourceID {
            throw AppModelTestError.documentLoadFailed
        }
        return documentsBySource[sourceID] ?? []
    }

    func fail(sourceID: UUID) {
        failingSourceID = sourceID
    }
}

private actor CompletionFlag {
    private(set) var didComplete = false

    func record() {
        didComplete = true
    }
}

private actor OverlappingCatalogScanner: CatalogScanning {
    private(set) var callCount = 0
    private var firstScanContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func scan(source: SourceRootRecord) async throws {
        callCount += 1
        guard callCount == 1 else { return }
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstScanContinuation = continuation
        }
    }

    func waitUntilFirstScanStarts() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstScan() {
        firstScanContinuation?.resume()
        firstScanContinuation = nil
    }
}

private final class AppModelFixture: @unchecked Sendable {
    let directory: URL
    let sources: SourceRootRepository
    let documents: DocumentRepository
    let sourceAccess = FakeSourceAccess()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkLoomAppModelTests-\(UUID().uuidString)", isDirectory: true)
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
            sourceAccess: sourceAccess,
            now: Date(timeIntervalSince1970: 100)
        )
    }

    func document(sourceRootID: UUID, path: String) -> DocumentRecord {
        DocumentRecord(
            sourceRootID: sourceRootID,
            relativePath: path,
            contentHash: "hash-\(path)",
            byteCount: 10,
            modifiedAt: Date(timeIntervalSince1970: 200),
            mediaType: .pdf,
            status: .ready,
            pageCount: 1,
            lastSeenAt: Date(timeIntervalSince1970: 200)
        )
    }
}

private struct FakeCatalogScanner: CatalogScanning {
    private let operation: @Sendable () async throws -> Void

    init(operation: @escaping @Sendable () async throws -> Void = {}) {
        self.operation = operation
    }

    func scan(source: SourceRootRecord) async throws {
        try await operation()
    }
}

private struct FakePendingIngester: PendingIngesting {
    func processPending(source: SourceRootRecord) async throws {}
}

private struct FakeSourceAccess: SourceAccessing {
    func createBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        throw AppModelTestError.unusedSourceResolution
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await operation(URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)))
    }
}

private enum AppModelTestError: Error {
    case scanFailed
    case documentLoadFailed
    case ingestionFailed
    case unusedSourceResolution
    case timeout
}
