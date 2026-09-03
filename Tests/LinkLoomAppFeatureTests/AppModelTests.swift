import Combine
import Foundation
import Testing
@testable import LinkLoomAppFeature
@testable import LinkLoomCore

@Suite("Diagnostic app model", .serialized)
struct AppModelTests {
    @Test func staleInvoicePaymentDecisionInputHasStableDiagnosticReason() {
        let diagnostic = AppRuntimeDiagnostic(
            category: .invoicePaymentDecisionUpdate,
            error: InvoicePaymentDecisionRepositoryError.staleInput
        )

        #expect(diagnostic.reason == .staleDocument)
    }

    @Test @MainActor func reloadPublishesDossiersWithSourceWorkspace() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let summary = try testDossierSummary(
            anchor: fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        )
        let loader = ScriptedDossierLoader(
            summaries: .success([summary])
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dossierLoader: loader
        )

        try await model.reload()

        #expect(model.sources == [source])
        #expect(model.dossiers == [summary])
        #expect(model.workspaceSelection == .source(source.id))
    }

    @Test @MainActor func failedDossierReloadPublishesNoPartialSourceState() async throws {
        let fixture = try AppModelFixture()
        _ = try await fixture.addSource(named: "Archive")
        let loader = ScriptedDossierLoader(
            summaries: .failure(AppModelTestError.dossierLoadFailed)
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dossierLoader: loader
        )

        await #expect(throws: AppModelTestError.self) {
            try await model.reload()
        }

        #expect(model.sources.isEmpty)
        #expect(model.dossiers.isEmpty)
        #expect(model.workspaceSelection == nil)
    }

    @Test @MainActor func selectingSourceSetsExplicitSourceWorkspace() async throws {
        let fixture = try AppModelFixture()
        let first = try await fixture.addSource(named: "First")
        let second = try await fixture.addSource(named: "Second")
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
        #expect(model.workspaceSelection == .source(second.id))
        #expect(model.workspaceSelection != .source(first.id))
    }

    @Test @MainActor func selectingEligibleDocumentPublishesOnlyLatestEntryDisposition() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let first = fixture.document(sourceRootID: source.id, path: "first.pdf")
        let second = fixture.document(sourceRootID: source.id, path: "second.pdf")
        try await fixture.documents.save(first)
        try await fixture.documents.save(second)
        let firstDNA = try testDocumentDNA(document: first, type: .invoice)
        let secondDNA = try testDocumentDNA(document: second, type: .paymentConfirmation)
        let secondSummary = try testDossierSummary(anchor: second)
        let statuses = MutableDocumentDNAStatusLoader(statusesBySource: [source.id: [
            DocumentDNAAnalysisStatus(documentID: first.id, phase: .ready),
            DocumentDNAAnalysisStatus(documentID: second.id, phase: .ready),
        ]])
        let loader = ScriptedDossierLoader(
            entrySteps: [
                .blocked(.success(.create)),
                .disposition(.open(secondSummary)),
            ]
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: statuses,
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                first.id: [.snapshot(firstDNA)],
                second.id: [.snapshot(secondDNA)],
            ]),
            dossierLoader: loader
        )
        try await model.reload()

        let staleSelection = Task { await model.selectDocument(id: first.id) }
        await loader.waitUntilBlockedEntryStarts()
        await model.selectDocument(id: second.id)
        await loader.releaseBlockedEntry()
        await staleSelection.value

        #expect(model.dossierEntryState == .available(
            documentID: second.id,
            disposition: .open(secondSummary)
        ))
    }

    @Test @MainActor func entryCancellationClearsOnlyMatchingLoadingState() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        try await fixture.documents.save(document)
        let dna = try testDocumentDNA(document: document, type: .invoice)
        let statuses = MutableDocumentDNAStatusLoader(statusesBySource: [source.id: [
            DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready),
        ]])
        let loader = ScriptedDossierLoader(entrySteps: [.cancellation])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: statuses,
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                document.id: [.snapshot(dna)],
            ]),
            dossierLoader: loader
        )
        try await model.reload()

        await model.selectDocument(id: document.id)

        #expect(model.dossierEntryState == .none)
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func openedDossierPublishesWorkspaceSummaryAndSnapshotTogether() async throws {
        let context = try await DossierModelContext.make()
        let snapshot = try testDossierSnapshot(anchor: context.firstDocument)
        await context.service.setOpenSteps([.result(.opened(snapshot))])
        await context.service.setSummaries([try summary(for: snapshot)])

        await context.model.openOrCreateDossierForSelectedDocument()

        #expect(context.model.workspaceSelection == .dossier(snapshot.dossier.id))
        #expect(context.model.dossierDetailState == .available(snapshot))
        #expect(context.model.dossiers == [try summary(for: snapshot)])
        #expect(context.model.dossierChoices.isEmpty)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func ambiguousOpenPublishesChoicesWithoutChangingWorkspace() async throws {
        let context = try await DossierModelContext.make()
        let first = try testDossierSummary(anchor: context.firstDocument)
        let second = try testDossierSummary(anchor: context.secondDocument)
        await context.service.setOpenSteps([.result(.choose([first, second]))])
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState

        await context.model.openOrCreateDossierForSelectedDocument()

        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.dossierChoices == [first, second])
    }

    @Test @MainActor func choosingDossierPublishesOnlyCompleteLoadedSnapshot() async throws {
        let context = try await DossierModelContext.make()
        let first = try testDossierSummary(anchor: context.firstDocument)
        let selectedSnapshot = try testDossierSnapshot(anchor: context.secondDocument)
        let selected = try summary(for: selectedSnapshot)
        await context.service.setOpenSteps([.result(.choose([first, selected]))])
        await context.service.setSnapshotSteps([.result(selectedSnapshot)])
        await context.model.openOrCreateDossierForSelectedDocument()

        await context.model.chooseDossier(id: selected.id)

        #expect(context.model.workspaceSelection == .dossier(selected.id))
        #expect(context.model.dossierDetailState == .available(selectedSnapshot))
        #expect(context.model.dossierChoices.isEmpty)
        #expect(context.model.dossiers.contains(selected))
    }

    @Test @MainActor func dossierLoadFailureKeepsWorkspaceAndPreviousSnapshot() async throws {
        let context = try await DossierModelContext.make()
        let dossierID = UUID()
        await context.service.setSnapshotSteps([.failure])
        let workspace = context.model.workspaceSelection
        let previous = context.model.dossierDetailState.snapshot

        await context.model.selectDossier(id: dossierID)

        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == .failed(
            dossierID: dossierID,
            previous: previous
        ))
        #expect(context.model.lastErrorCode == "dossierLoadFailure")
    }

    @Test @MainActor func duplicateOpenIsSuppressedWhileFirstRequestIsInFlight() async throws {
        let context = try await DossierModelContext.make()
        let snapshot = try testDossierSnapshot(anchor: context.firstDocument)
        await context.service.setOpenSteps([.blocked(.success(.opened(snapshot)))])

        let first = Task { await context.model.openOrCreateDossierForSelectedDocument() }
        await context.service.waitUntilBlockedOperationStarts()
        await context.model.openOrCreateDossierForSelectedDocument()

        #expect(await context.service.openInvocationCount == 1)
        await context.service.releaseBlockedOperation()
        await first.value
    }

    @Test @MainActor func openFailureKeepsPreviousWorkspaceAndSnapshot() async throws {
        let context = try await DossierModelContext.make()
        await context.service.setOpenSteps([.failure])
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState

        await context.model.openOrCreateDossierForSelectedDocument()

        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.lastErrorCode == "dossierOpenFailure")
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func cancelledOpenKeepsPreviousWorkspaceWithoutDiagnostic() async throws {
        let context = try await DossierModelContext.make()
        await context.service.setOpenSteps([.cancellation])
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState

        await context.model.openOrCreateDossierForSelectedDocument()

        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func lateOpenCannotReplaceChangedDocumentSelection() async throws {
        let context = try await DossierModelContext.make()
        let snapshot = try testDossierSnapshot(anchor: context.firstDocument)
        await context.service.setOpenSteps([.blocked(.success(.opened(snapshot)))])
        let open = Task { await context.model.openOrCreateDossierForSelectedDocument() }
        await context.service.waitUntilBlockedOperationStarts()

        await context.model.selectDocument(id: context.secondDocument.id)
        await context.service.releaseBlockedOperation()
        await open.value

        #expect(context.model.workspaceSelection == .source(context.source.id))
        #expect(context.model.selectedDocumentID == context.secondDocument.id)
        #expect(context.model.dossierDetailState == .none)
    }

    @Test @MainActor func staleABAOpenCannotReplaceReselectedDocument() async throws {
        let context = try await DossierModelContext.make()
        let snapshot = try testDossierSnapshot(anchor: context.firstDocument)
        await context.service.setOpenSteps([.blocked(.success(.opened(snapshot)))])
        let open = Task { await context.model.openOrCreateDossierForSelectedDocument() }
        await context.service.waitUntilBlockedOperationStarts()

        await context.model.selectDocument(id: context.secondDocument.id)
        await context.model.selectDocument(id: context.firstDocument.id)
        await context.service.releaseBlockedOperation()
        await open.value

        #expect(context.model.workspaceSelection == .source(context.source.id))
        #expect(context.model.selectedDocumentID == context.firstDocument.id)
        #expect(context.model.dossierDetailState == .none)
    }

    @Test @MainActor func sameSourceDossierMemberUsesExistingDocumentFlow() async throws {
        let context = try await DossierNavigationContext.make(crossSource: false)

        await context.model.selectDossierMember(documentID: context.payment.id)

        #expect(context.model.workspaceSelection == .dossier(context.snapshot.dossier.id))
        #expect(context.model.selectedSourceID == context.payment.sourceRootID)
        #expect(context.model.selectedDocumentID == context.payment.id)
        #expect(context.model.documentDNADetailState == .available(context.paymentDNA))
        #expect(context.model.invoicePaymentCandidateState == .available(
            documentID: context.payment.id,
            candidates: [context.annotatedCandidate]
        ))
    }

    @Test @MainActor func crossSourceDossierMemberKeepsDossierWorkspace() async throws {
        let context = try await DossierNavigationContext.make(crossSource: true)

        await context.model.selectDossierMember(documentID: context.payment.id)

        #expect(context.model.workspaceSelection == .dossier(context.snapshot.dossier.id))
        #expect(context.model.selectedSourceID == context.payment.sourceRootID)
        #expect(context.model.selectedDocumentID == context.payment.id)
        #expect(context.model.documentDNADetailState == .available(context.paymentDNA))
    }

    @Test @MainActor func missingDossierMemberDocumentLeavesSelectionAtomic() async throws {
        let context = try await DossierNavigationContext.make(crossSource: true)
        let sourceID = context.model.selectedSourceID
        let documentID = context.model.selectedDocumentID
        try await context.fixture.sources.remove(id: context.payment.sourceRootID)

        await context.model.selectDossierMember(documentID: context.payment.id)

        #expect(context.model.workspaceSelection == .dossier(context.snapshot.dossier.id))
        #expect(context.model.selectedSourceID == sourceID)
        #expect(context.model.selectedDocumentID == documentID)
        #expect(context.model.lastErrorCode == "documentLoadFailure")
    }

    @Test @MainActor func changedHashDossierMemberLeavesSelectionAtomic() async throws {
        let context = try await DossierNavigationContext.make(crossSource: true)
        var changed = context.payment
        changed.contentHash = "changed-payment-hash"
        try await context.fixture.documents.save(changed)
        let documentID = context.model.selectedDocumentID

        await context.model.selectDossierMember(documentID: context.payment.id)

        #expect(context.model.workspaceSelection == .dossier(context.snapshot.dossier.id))
        #expect(context.model.selectedDocumentID == documentID)
        #expect(context.model.lastErrorCode == "documentLoadFailure")
    }

    @Test @MainActor func dossierMemberLoadFailureLeavesSelectionAtomic() async throws {
        let context = try await DossierNavigationContext.make(
            crossSource: true,
            paymentStatusBehavior: .failure
        )
        let sourceID = context.model.selectedSourceID
        let documentID = context.model.selectedDocumentID

        await context.model.selectDossierMember(documentID: context.payment.id)

        #expect(context.model.workspaceSelection == .dossier(context.snapshot.dossier.id))
        #expect(context.model.selectedSourceID == sourceID)
        #expect(context.model.selectedDocumentID == documentID)
        #expect(context.model.lastErrorCode == "documentLoadFailure")
    }

    @Test @MainActor func cancelledDossierMemberLoadLeavesSelectionWithoutFailure() async throws {
        let context = try await DossierNavigationContext.make(
            crossSource: true,
            paymentStatusBehavior: .cancellation
        )
        let sourceID = context.model.selectedSourceID
        let documentID = context.model.selectedDocumentID

        await context.model.selectDossierMember(documentID: context.payment.id)

        #expect(context.model.workspaceSelection == .dossier(context.snapshot.dossier.id))
        #expect(context.model.selectedSourceID == sourceID)
        #expect(context.model.selectedDocumentID == documentID)
        #expect(context.model.lastErrorCode == nil)
    }

    @Test @MainActor func staleABADossierMemberLoadCannotReplaceNewerSelection() async throws {
        let context = try await DossierNavigationContext.make(
            crossSource: true,
            paymentStatusBehavior: .blockedThenReady
        )
        let stale = Task {
            await context.model.selectDossierMember(documentID: context.payment.id)
        }
        await context.statuses.waitUntilBlockedLoadStarts()

        await context.model.selectDossierMember(documentID: context.invoice.id)
        await context.model.selectDossierMember(documentID: context.payment.id)
        await context.statuses.releaseBlockedLoad()
        await stale.value

        #expect(context.model.workspaceSelection == .dossier(context.snapshot.dossier.id))
        #expect(context.model.selectedDocumentID == context.payment.id)
        #expect(context.model.documentDNADetailState == .available(context.paymentDNA))
    }

    @Test @MainActor func counterpartFromDossierMemberRetainsDossierWorkspace() async throws {
        let context = try await DossierNavigationContext.make(crossSource: true)
        await context.model.selectDossierMember(documentID: context.payment.id)

        await context.model.showInvoicePaymentCounterpart(
            candidate: context.annotatedCandidate.candidate
        )

        #expect(context.model.workspaceSelection == .dossier(context.snapshot.dossier.id))
        #expect(context.model.selectedDocumentID == context.invoice.id)
    }

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
        let diagnostics = RuntimeDiagnosticRecorder()
        let source = try await fixture.addSource(named: "Archive")
        let existingDocument = fixture.document(sourceRootID: source.id, path: "existing.pdf")
        try await fixture.documents.save(existingDocument)
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner { throw AppModelTestError.scanFailed },
            ingestion: FakePendingIngester(),
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()

        await model.scanSelectedSource()

        #expect(model.scanState == .idle)
        #expect(model.lastErrorCode == "scanFailure")
        #expect(
            model.lastErrorMessage
                == "Die Analyse konnte nicht abgeschlossen werden. Bitte prüfe die Quelle und versuche es erneut."
        )
        #expect(model.documents == [existingDocument])
        #expect(diagnostics.values.map(\.category) == [.scan])
        #expect(diagnostics.values.map(\.reason) == [.unexpected])
    }

    @Test @MainActor func ingestionFailureAppearsWithoutRemovingExistingDocuments() async throws {
        let fixture = try AppModelFixture()
        let diagnostics = RuntimeDiagnosticRecorder()
        let source = try await fixture.addSource(named: "Archive")
        let existingDocument = fixture.document(
            sourceRootID: source.id,
            path: "existing.pdf"
        )
        try await fixture.documents.save(existingDocument)
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FailingPendingIngester(),
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()

        await model.scanSelectedSource()

        #expect(model.scanState == .idle)
        #expect(model.lastErrorCode == "scanFailure")
        #expect(model.documents == [existingDocument])
        #expect(diagnostics.values.map(\.category) == [.ingestion])
        #expect(diagnostics.values.map(\.reason) == [.sourceAccess])
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

    @Test @MainActor func addingDuplicateSourceSelectsExistingWithoutRestartingWatcher() async throws {
        let fixture = try AppModelFixture()
        let existing = try await fixture.addSource(named: "Archive")
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler,
            sourceResolver: { source in URL(fileURLWithPath: source.pathHint) }
        )
        try await model.reload()

        await model.addSource(
            fixture.directory.appendingPathComponent("Archive", isDirectory: true)
        )

        #expect(model.sources.count == 1)
        #expect(model.selectedSourceID == existing.id)
        #expect(await scheduler.startedSources == [
            WatchedSource(sourceID: existing.id, path: existing.pathHint),
        ])
        #expect(model.lastErrorCode == nil)
        await model.stopWatching()
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

    @Test @MainActor func reloadPublishesDNAStatusesOnlyForVisibleDocuments() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let visible = fixture.document(sourceRootID: source.id, path: "visible.pdf")
        try await fixture.documents.save(visible)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [
                DocumentDNAAnalysisStatus(documentID: visible.id, phase: .ready),
                DocumentDNAAnalysisStatus(
                    documentID: UUID(),
                    phase: .ready
                ),
            ],
        ])
        let model = fixture.model(dnaStatuses: dnaStatuses)

        try await model.reload()

        #expect(model.documents == [visible])
        #expect(model.documentDNAAnalysisPhases == [visible.id: .ready])
    }

    @Test @MainActor func selectingSourceReplacesDocumentDNAStatuses() async throws {
        let fixture = try AppModelFixture()
        let pair = try await TwoSourceDocuments.make(in: fixture)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            pair.first.id: [
                DocumentDNAAnalysisStatus(documentID: pair.firstDocument.id, phase: .pending),
            ],
            pair.second.id: [
                DocumentDNAAnalysisStatus(
                    documentID: pair.secondDocument.id,
                    phase: .failed(.invalidFinding)
                ),
            ],
        ])
        let model = fixture.model(dnaStatuses: dnaStatuses)
        try await model.reload()

        await model.selectSource(id: pair.second.id)

        #expect(model.documents == [pair.secondDocument])
        #expect(
            model.documentDNAAnalysisPhases
                == [pair.secondDocument.id: .failed(.invalidFinding)]
        )
    }

    @Test @MainActor func selectingReadyDocumentLoadsItsCurrentDNASnapshot() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        try await fixture.documents.save(document)
        let snapshot = try testDocumentDNA(document: document)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            document.id: [.snapshot(snapshot)],
        ])
        let model = fixture.model(dnaStatuses: dnaStatuses, dnaSnapshots: dnaSnapshots)
        try await model.reload()

        await model.selectDocument(id: document.id)

        #expect(model.selectedDocumentID == document.id)
        #expect(model.documentDNADetailState == .available(snapshot))
    }

    @Test @MainActor func candidateLoadFailureKeepsCurrentDNASnapshotVisible() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        try await fixture.documents.save(document)
        let snapshot = try testDocumentDNA(document: document)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            document.id: [.snapshot(snapshot)],
        ])
        let candidateLoader = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            document.id: [.failure],
        ])
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader,
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()

        await model.selectDocument(id: document.id)

        #expect(model.documentDNADetailState == .available(snapshot))
        #expect(model.invoicePaymentCandidateState == .failed(documentID: document.id))
        #expect(model.lastErrorCode == "invoicePaymentCandidateLoadFailure")
        #expect(diagnostics.values.map(\.category) == [.invoicePaymentCandidateLoad])
        #expect(diagnostics.values.map(\.reason) == [.unexpected])
    }

    @Test @MainActor func candidateLoadPublishesMixedDecisionsInStableOrder() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let firstPayment = fixture.document(
            sourceRootID: source.id,
            path: "z-confirmed-payment.pdf"
        )
        let secondPayment = fixture.document(
            sourceRootID: source.id,
            path: "a-undecided-payment.pdf"
        )
        let thirdPayment = fixture.document(
            sourceRootID: source.id,
            path: "m-excluded-payment.pdf"
        )
        try await fixture.documents.save(invoice)
        let snapshot = try testDocumentDNA(document: invoice)
        let annotated = [
            InvoicePaymentCandidateWithDecision(
                candidate: try testInvoicePaymentCandidate(
                    invoice: invoice,
                    payment: firstPayment
                ),
                decision: .confirmed
            ),
            InvoicePaymentCandidateWithDecision(
                candidate: try testInvoicePaymentCandidate(
                    invoice: invoice,
                    payment: secondPayment
                ),
                decision: .undecided
            ),
            InvoicePaymentCandidateWithDecision(
                candidate: try testInvoicePaymentCandidate(
                    invoice: invoice,
                    payment: thirdPayment
                ),
                decision: .excluded
            ),
        ]
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            invoice.id: [.snapshot(snapshot)],
        ])
        let candidateLoader = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            invoice.id: [.candidates(annotated)],
        ])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader
        )
        try await model.reload()

        await model.selectDocument(id: invoice.id)

        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: annotated)
        )
        #expect(annotated.map(\.candidate.payment.document.relativePath) == [
            "z-confirmed-payment.pdf",
            "a-undecided-payment.pdf",
            "m-excluded-payment.pdf",
        ])
        #expect(annotated.map(\.decision) == [.confirmed, .undecided, .excluded])
    }

    @Test @MainActor func counterpartNavigationSelectsDocumentWithinCurrentSource() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: source.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        try await fixture.documents.save(payment)
        let invoiceSnapshot = try testDocumentDNA(document: invoice)
        let paymentSnapshot = try testDocumentDNA(document: payment)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .confirmed
        )
        let targetAnnotation = InvoicePaymentCandidateWithDecision(
            candidate: annotated.candidate,
            decision: .undecided
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: MutableDocumentDNAStatusLoader(statusesBySource: [
                source.id: [invoice, payment].map {
                    DocumentDNAAnalysisStatus(documentID: $0.id, phase: .ready)
                },
            ]),
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                invoice.id: [.snapshot(invoiceSnapshot)],
                payment.id: [.snapshot(paymentSnapshot)],
            ]),
            invoicePaymentCandidates: ScriptedInvoicePaymentCandidateLoader(
                stepsByDocument: [
                    invoice.id: [.candidates([annotated])],
                    payment.id: [.candidates([targetAnnotation])],
                ]
            )
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)

        await model.showInvoicePaymentCounterpart(candidate: annotated.candidate)

        #expect(model.selectedSourceID == source.id)
        #expect(model.selectedDocumentID == payment.id)
        #expect(model.documentDNADetailState == .available(paymentSnapshot))
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: payment.id, candidates: [annotated])
        )
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func counterpartNavigationAtomicallySelectsDocumentAcrossSources() async throws {
        let fixture = try AppModelFixture()
        let invoiceSource = try await fixture.addSource(named: "Invoices")
        let paymentSource = try await fixture.addSource(named: "Payments")
        let invoice = fixture.document(sourceRootID: invoiceSource.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: paymentSource.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        try await fixture.documents.save(payment)
        let invoiceSnapshot = try testDocumentDNA(document: invoice)
        let paymentSnapshot = try testDocumentDNA(document: payment)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .excluded
        )
        let targetAnnotation = InvoicePaymentCandidateWithDecision(
            candidate: annotated.candidate,
            decision: .undecided
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: MutableDocumentDNAStatusLoader(statusesBySource: [
                invoiceSource.id: [
                    DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready),
                ],
                paymentSource.id: [
                    DocumentDNAAnalysisStatus(documentID: payment.id, phase: .ready),
                ],
            ]),
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                invoice.id: [.snapshot(invoiceSnapshot)],
                payment.id: [.snapshot(paymentSnapshot)],
            ]),
            invoicePaymentCandidates: ScriptedInvoicePaymentCandidateLoader(
                stepsByDocument: [
                    invoice.id: [.candidates([annotated])],
                    payment.id: [.candidates([targetAnnotation])],
                ]
            )
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)

        await model.showInvoicePaymentCounterpart(candidate: annotated.candidate)

        #expect(model.selectedSourceID == paymentSource.id)
        #expect(model.workspaceSelection == .source(paymentSource.id))
        #expect(model.documents == [payment])
        #expect(model.selectedDocumentID == payment.id)
        #expect(model.documentDNADetailState == .available(paymentSnapshot))
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: payment.id, candidates: [annotated])
        )
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func counterpartNavigationFollowsStableDocumentAfterPathChange() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: source.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        try await fixture.documents.save(payment)
        let movedPayment = DocumentRecord(
            id: payment.id,
            sourceRootID: payment.sourceRootID,
            relativePath: "moved/payment.pdf",
            contentHash: payment.contentHash,
            byteCount: payment.byteCount,
            modifiedAt: payment.modifiedAt,
            mediaType: payment.mediaType,
            status: payment.status,
            availability: payment.availability,
            pageCount: payment.pageCount,
            failureCode: payment.failureCode,
            lastSeenAt: payment.lastSeenAt,
            lastFingerprintAt: payment.lastFingerprintAt
        )
        let invoiceSnapshot = try testDocumentDNA(document: invoice)
        let paymentSnapshot = try testDocumentDNA(document: payment)
        let visible = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .confirmed
        )
        let movedCandidate = try testInvoicePaymentCandidate(
            invoice: invoice,
            payment: movedPayment
        )
        let reloaded = InvoicePaymentCandidateWithDecision(
            candidate: movedCandidate,
            decision: .undecided
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: MutableDocumentDNAStatusLoader(statusesBySource: [
                source.id: [invoice, payment].map {
                    DocumentDNAAnalysisStatus(documentID: $0.id, phase: .ready)
                },
            ]),
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                invoice.id: [.snapshot(invoiceSnapshot)],
                payment.id: [.snapshot(paymentSnapshot)],
            ]),
            invoicePaymentCandidates: ScriptedInvoicePaymentCandidateLoader(
                stepsByDocument: [
                    invoice.id: [.candidates([visible])],
                    payment.id: [.candidates([reloaded])],
                ]
            )
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)
        try await fixture.documents.save(movedPayment)

        await model.showInvoicePaymentCounterpart(candidate: visible.candidate)

        let expected = InvoicePaymentCandidateWithDecision(
            candidate: movedCandidate,
            decision: .confirmed
        )
        #expect(model.documents == [invoice, movedPayment])
        #expect(model.selectedDocumentID == movedPayment.id)
        #expect(model.documentDNADetailState == .available(paymentSnapshot))
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: movedPayment.id, candidates: [expected])
        )
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func counterpartNavigationIgnoresCandidateNoLongerInVisibleSnapshot() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let stalePayment = fixture.document(sourceRootID: source.id, path: "stale-payment.pdf")
        let currentPayment = fixture.document(sourceRootID: source.id, path: "current-payment.pdf")
        try await fixture.documents.save(invoice)
        let snapshot = try testDocumentDNA(document: invoice)
        let staleCandidate = try testInvoicePaymentCandidate(
            invoice: invoice,
            payment: stalePayment
        )
        let current = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(
                invoice: invoice,
                payment: currentPayment
            ),
            decision: .undecided
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: MutableDocumentDNAStatusLoader(statusesBySource: [
                source.id: [DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready)],
            ]),
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                invoice.id: [.snapshot(snapshot)],
            ]),
            invoicePaymentCandidates: ScriptedInvoicePaymentCandidateLoader(
                stepsByDocument: [invoice.id: [.candidates([current])]]
            )
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)

        await model.showInvoicePaymentCounterpart(candidate: staleCandidate)

        #expect(model.selectedSourceID == source.id)
        #expect(model.selectedDocumentID == invoice.id)
        #expect(model.documentDNADetailState == .available(snapshot))
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: [current])
        )
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func counterpartNavigationMissingDocumentLeavesSelectionAndReportsFailure() async throws {
        let fixture = try AppModelFixture()
        let invoiceSource = try await fixture.addSource(named: "Invoices")
        let paymentSource = try await fixture.addSource(named: "Payments")
        let invoice = fixture.document(sourceRootID: invoiceSource.id, path: "invoice.pdf")
        let missingPayment = fixture.document(
            sourceRootID: paymentSource.id,
            path: "missing-payment.pdf"
        )
        try await fixture.documents.save(invoice)
        let invoiceSnapshot = try testDocumentDNA(document: invoice)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(
                invoice: invoice,
                payment: missingPayment
            ),
            decision: .confirmed
        )
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: MutableDocumentDNAStatusLoader(statusesBySource: [
                invoiceSource.id: [
                    DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready),
                ],
                paymentSource.id: [
                    DocumentDNAAnalysisStatus(documentID: missingPayment.id, phase: .ready),
                ],
            ]),
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                invoice.id: [.snapshot(invoiceSnapshot)],
            ]),
            invoicePaymentCandidates: ScriptedInvoicePaymentCandidateLoader(
                stepsByDocument: [invoice.id: [.candidates([annotated])]]
            ),
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)

        await model.showInvoicePaymentCounterpart(candidate: annotated.candidate)

        #expect(model.selectedSourceID == invoiceSource.id)
        #expect(model.documents == [invoice])
        #expect(model.selectedDocumentID == invoice.id)
        #expect(model.documentDNADetailState == .available(invoiceSnapshot))
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: [annotated])
        )
        #expect(model.lastErrorCode == "invoicePaymentCounterpartNavigationFailure")
        #expect(diagnostics.values.map(\.category) == [.documentLoad])
    }

    @Test @MainActor func counterpartNavigationLoadFailureIsAtomic() async throws {
        let fixture = try AppModelFixture()
        let invoiceSource = try await fixture.addSource(named: "Invoices")
        let paymentSource = try await fixture.addSource(named: "Payments")
        let invoice = fixture.document(sourceRootID: invoiceSource.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: paymentSource.id, path: "payment.pdf")
        let invoiceSnapshot = try testDocumentDNA(document: invoice)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .excluded
        )
        let loader = ToggleFailingDocumentLoader(documentsBySource: [
            invoiceSource.id: [invoice],
            paymentSource.id: [payment],
        ])
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: MutableDocumentDNAStatusLoader(statusesBySource: [
                invoiceSource.id: [
                    DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready),
                ],
                paymentSource.id: [
                    DocumentDNAAnalysisStatus(documentID: payment.id, phase: .ready),
                ],
            ]),
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                invoice.id: [.snapshot(invoiceSnapshot)],
            ]),
            invoicePaymentCandidates: ScriptedInvoicePaymentCandidateLoader(
                stepsByDocument: [invoice.id: [.candidates([annotated])]]
            ),
            documentLoader: { try await loader.load(sourceID: $0) },
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)
        await loader.fail(sourceID: paymentSource.id)

        await model.showInvoicePaymentCounterpart(candidate: annotated.candidate)

        #expect(model.selectedSourceID == invoiceSource.id)
        #expect(model.documents == [invoice])
        #expect(model.selectedDocumentID == invoice.id)
        #expect(model.documentDNADetailState == .available(invoiceSnapshot))
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: [annotated])
        )
        #expect(model.lastErrorCode == "invoicePaymentCounterpartNavigationFailure")
        #expect(diagnostics.values.map(\.category) == [.documentLoad])
    }

    @Test @MainActor func counterpartNavigationRejectsCandidateThatBecomesStaleDuringLoad() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: source.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        try await fixture.documents.save(payment)
        let invoiceSnapshot = try testDocumentDNA(document: invoice)
        let paymentSnapshot = try testDocumentDNA(document: payment)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .confirmed
        )
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: MutableDocumentDNAStatusLoader(statusesBySource: [
                source.id: [invoice, payment].map {
                    DocumentDNAAnalysisStatus(documentID: $0.id, phase: .ready)
                },
            ]),
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                invoice.id: [.snapshot(invoiceSnapshot)],
                payment.id: [.snapshot(paymentSnapshot)],
            ]),
            invoicePaymentCandidates: ScriptedInvoicePaymentCandidateLoader(
                stepsByDocument: [
                    invoice.id: [.candidates([annotated])],
                    payment.id: [.candidates([])],
                ]
            )
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)

        await model.showInvoicePaymentCounterpart(candidate: annotated.candidate)

        #expect(model.selectedDocumentID == invoice.id)
        #expect(model.documentDNADetailState == .available(invoiceSnapshot))
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: [annotated])
        )
        #expect(model.lastErrorCode == "invoicePaymentCounterpartNavigationFailure")
    }

    @Test @MainActor func cancelledCounterpartNavigationPreservesSelectionWithoutFailure() async throws {
        let fixture = try AppModelFixture()
        let invoiceSource = try await fixture.addSource(named: "Invoices")
        let paymentSource = try await fixture.addSource(named: "Payments")
        let invoice = fixture.document(sourceRootID: invoiceSource.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: paymentSource.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        try await fixture.documents.save(payment)
        let invoiceSnapshot = try testDocumentDNA(document: invoice)
        let paymentSnapshot = try testDocumentDNA(document: payment)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .confirmed
        )
        let statuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [
            invoiceSource.id: [.statuses([
                DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready),
            ])],
            paymentSource.id: [.blocked(.success([
                DocumentDNAAnalysisStatus(documentID: payment.id, phase: .ready),
            ]))],
        ])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: statuses,
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                invoice.id: [.snapshot(invoiceSnapshot)],
                payment.id: [.snapshot(paymentSnapshot)],
            ]),
            invoicePaymentCandidates: ScriptedInvoicePaymentCandidateLoader(
                stepsByDocument: [
                    invoice.id: [.candidates([annotated])],
                    payment.id: [.candidates([annotated])],
                ]
            )
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)
        let navigation = Task {
            await model.showInvoicePaymentCounterpart(candidate: annotated.candidate)
        }
        await statuses.waitUntilBlockedLoadStarts()

        #expect(model.invoicePaymentCounterpartNavigatingCandidate == annotated.candidate)
        navigation.cancel()
        await statuses.releaseBlockedLoad()
        await navigation.value

        #expect(model.selectedSourceID == invoiceSource.id)
        #expect(model.selectedDocumentID == invoice.id)
        #expect(model.documentDNADetailState == .available(invoiceSnapshot))
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: [annotated])
        )
        #expect(model.invoicePaymentCounterpartNavigatingCandidate == nil)
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func decisionUpdateCannotStartDuringCounterpartNavigation() async throws {
        let fixture = try AppModelFixture()
        let invoiceSource = try await fixture.addSource(named: "Invoices")
        let paymentSource = try await fixture.addSource(named: "Payments")
        let invoice = fixture.document(sourceRootID: invoiceSource.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: paymentSource.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        try await fixture.documents.save(payment)
        let invoiceSnapshot = try testDocumentDNA(document: invoice)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .confirmed
        )
        let statuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [
            invoiceSource.id: [.statuses([
                DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready),
            ])],
            paymentSource.id: [.blocked(.success([
                DocumentDNAAnalysisStatus(documentID: payment.id, phase: .ready),
            ]))],
        ])
        let updater = ScriptedInvoicePaymentDecisionUpdater(steps: [.success])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: statuses,
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                invoice.id: [.snapshot(invoiceSnapshot)],
            ]),
            invoicePaymentCandidates: ScriptedInvoicePaymentCandidateLoader(
                stepsByDocument: [invoice.id: [.candidates([annotated])]]
            ),
            invoicePaymentDecisions: updater
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)
        let navigation = Task {
            await model.showInvoicePaymentCounterpart(candidate: annotated.candidate)
        }
        await statuses.waitUntilBlockedLoadStarts()

        await model.updateInvoicePaymentDecision(
            candidate: annotated.candidate,
            command: .set(.excluded)
        )

        #expect(await updater.invocations.isEmpty)
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: [annotated])
        )

        navigation.cancel()
        await statuses.releaseBlockedLoad()
        await navigation.value
    }

    @Test @MainActor func staleABACounterpartNavigationCannotReplaceReselectedDocument() async throws {
        let fixture = try AppModelFixture()
        let invoiceSource = try await fixture.addSource(named: "Invoices")
        let paymentSource = try await fixture.addSource(named: "Payments")
        let invoice = fixture.document(sourceRootID: invoiceSource.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: paymentSource.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        try await fixture.documents.save(payment)
        let invoiceSnapshot = try testDocumentDNA(document: invoice)
        let paymentSnapshot = try testDocumentDNA(document: payment)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .excluded
        )
        let statuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [
            invoiceSource.id: [.statuses([
                DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready),
            ])],
            paymentSource.id: [.blocked(.success([
                DocumentDNAAnalysisStatus(documentID: payment.id, phase: .ready),
            ]))],
        ])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: statuses,
            dnaSnapshots: ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                invoice.id: [.snapshot(invoiceSnapshot), .snapshot(invoiceSnapshot)],
                payment.id: [.snapshot(paymentSnapshot)],
            ]),
            invoicePaymentCandidates: ScriptedInvoicePaymentCandidateLoader(
                stepsByDocument: [
                    invoice.id: [.candidates([annotated]), .candidates([annotated])],
                    payment.id: [.candidates([annotated])],
                ]
            )
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)
        let staleNavigation = Task {
            await model.showInvoicePaymentCounterpart(candidate: annotated.candidate)
        }
        await statuses.waitUntilBlockedLoadStarts()

        await model.selectDocument(id: nil)
        await model.selectDocument(id: invoice.id)
        await statuses.releaseBlockedLoad()
        await staleNavigation.value

        #expect(model.selectedSourceID == invoiceSource.id)
        #expect(model.selectedDocumentID == invoice.id)
        #expect(model.documentDNADetailState == .available(invoiceSnapshot))
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: [annotated])
        )
        #expect(model.invoicePaymentCounterpartNavigatingCandidate == nil)
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func successfulDecisionUpdateCommitsAfterPersistenceInStableOrder() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let payments = ["first.pdf", "second.pdf", "third.pdf"].map {
            fixture.document(sourceRootID: source.id, path: $0)
        }
        try await fixture.documents.save(invoice)
        let snapshot = try testDocumentDNA(document: invoice)
        let annotated = try zip(
            payments,
            [
                InvoicePaymentCandidateDecisionState.confirmed,
                .undecided,
                .excluded,
            ]
        ).map { payment, decision in
            InvoicePaymentCandidateWithDecision(
                candidate: try testInvoicePaymentCandidate(
                    invoice: invoice,
                    payment: payment
                ),
                decision: decision
            )
        }
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            invoice.id: [.snapshot(snapshot)],
        ])
        let candidateLoader = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            invoice.id: [.candidates(annotated)],
        ])
        let updater = ScriptedInvoicePaymentDecisionUpdater(steps: [
            .blocked(.success(())),
        ])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader,
            invoicePaymentDecisions: updater
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)
        let target = annotated[1].candidate

        let update = Task {
            await model.updateInvoicePaymentDecision(
                candidate: target,
                command: .set(.confirmed)
            )
        }
        await updater.waitUntilBlockedUpdateStarts()

        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: annotated)
        )
        #expect(model.invoicePaymentDecisionUpdatingCandidate == target)

        await updater.releaseBlockedUpdate()
        await update.value

        guard case .available(let documentID, let updated) = model.invoicePaymentCandidateState
        else {
            Issue.record("Expected available invoice-payment candidates")
            return
        }
        #expect(documentID == invoice.id)
        #expect(updated.map(\.candidate) == annotated.map(\.candidate))
        #expect(updated.map(\.decision) == [.confirmed, .confirmed, .excluded])
        #expect(model.invoicePaymentDecisionUpdatingCandidate == nil)
        #expect(await updater.invocations == [
            .init(candidate: target, command: .set(.confirmed)),
        ])
    }

    @Test @MainActor func decisionUpdateCanExcludeAndResetCurrentCandidate() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: source.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        let snapshot = try testDocumentDNA(document: invoice)
        let candidate = try testInvoicePaymentCandidate(invoice: invoice, payment: payment)
        let initial = InvoicePaymentCandidateWithDecision(
            candidate: candidate,
            decision: .undecided
        )
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            invoice.id: [.snapshot(snapshot)],
        ])
        let candidateLoader = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            invoice.id: [.candidates([initial])],
        ])
        let updater = ScriptedInvoicePaymentDecisionUpdater(steps: [.success, .success])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader,
            invoicePaymentDecisions: updater
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)

        await model.updateInvoicePaymentDecision(
            candidate: candidate,
            command: .set(.excluded)
        )

        #expect(
            model.invoicePaymentCandidateState
                == .available(
                    documentID: invoice.id,
                    candidates: [
                        InvoicePaymentCandidateWithDecision(
                            candidate: candidate,
                            decision: .excluded
                        ),
                    ]
                )
        )

        await model.updateInvoicePaymentDecision(candidate: candidate, command: .reset)

        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: [initial])
        )
    }

    @Test @MainActor func failedDecisionUpdatePreservesStateAndSuccessfulRetryClearsFailure() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: source.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        let snapshot = try testDocumentDNA(document: invoice)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .undecided
        )
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            invoice.id: [.snapshot(snapshot)],
        ])
        let candidateLoader = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            invoice.id: [.candidates([annotated])],
        ])
        let updater = ScriptedInvoicePaymentDecisionUpdater(steps: [.failure, .success])
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader,
            invoicePaymentDecisions: updater,
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)

        await model.updateInvoicePaymentDecision(
            candidate: annotated.candidate,
            command: .set(.confirmed)
        )

        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: [annotated])
        )
        #expect(model.invoicePaymentDecisionUpdatingCandidate == nil)
        #expect(model.lastErrorCode == "invoicePaymentDecisionUpdateFailure")
        #expect(
            model.lastErrorMessage
                == "Die Entscheidung konnte nicht gespeichert werden. Bitte versuche es erneut."
        )
        #expect(diagnostics.values.map(\.category) == [.invoicePaymentDecisionUpdate])
        #expect(diagnostics.values.map(\.reason) == [.unexpected])

        await model.updateInvoicePaymentDecision(
            candidate: annotated.candidate,
            command: .set(.confirmed)
        )

        #expect(
            model.invoicePaymentCandidateState
                == .available(
                    documentID: invoice.id,
                    candidates: [
                        InvoicePaymentCandidateWithDecision(
                            candidate: annotated.candidate,
                            decision: .confirmed
                        ),
                    ]
                )
        )
        #expect(model.lastErrorCode == nil)
        #expect(diagnostics.values.count == 1)
    }

    @Test @MainActor func cancelledDecisionUpdatePreservesStateWithoutReportingFailure() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: source.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        let snapshot = try testDocumentDNA(document: invoice)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .undecided
        )
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            invoice.id: [.snapshot(snapshot)],
        ])
        let candidateLoader = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            invoice.id: [.candidates([annotated])],
        ])
        let updater = ScriptedInvoicePaymentDecisionUpdater(steps: [.cancellation])
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader,
            invoicePaymentDecisions: updater,
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)

        await model.updateInvoicePaymentDecision(
            candidate: annotated.candidate,
            command: .set(.confirmed)
        )

        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: invoice.id, candidates: [annotated])
        )
        #expect(model.invoicePaymentDecisionUpdatingCandidate == nil)
        #expect(model.lastErrorCode == nil)
        #expect(diagnostics.values.isEmpty)
    }

    @Test @MainActor func duplicateDecisionUpdateIsIgnoredWhilePersistenceIsInFlight() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: source.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        let snapshot = try testDocumentDNA(document: invoice)
        let annotated = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(invoice: invoice, payment: payment),
            decision: .undecided
        )
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            invoice.id: [.snapshot(snapshot)],
        ])
        let candidateLoader = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            invoice.id: [.candidates([annotated])],
        ])
        let updater = ScriptedInvoicePaymentDecisionUpdater(steps: [
            .blocked(.success(())),
            .success,
        ])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader,
            invoicePaymentDecisions: updater
        )
        try await model.reload()
        await model.selectDocument(id: invoice.id)

        let firstUpdate = Task {
            await model.updateInvoicePaymentDecision(
                candidate: annotated.candidate,
                command: .set(.confirmed)
            )
        }
        await updater.waitUntilBlockedUpdateStarts()

        await model.updateInvoicePaymentDecision(
            candidate: annotated.candidate,
            command: .set(.excluded)
        )

        let invocationsBeforeRelease = await updater.invocations
        await updater.releaseBlockedUpdate()
        await firstUpdate.value

        #expect(invocationsBeforeRelease == [
            .init(candidate: annotated.candidate, command: .set(.confirmed)),
        ])
    }

    @Test @MainActor func staleDecisionCompletionCannotOverlapOrOverwriteReselectedDocument() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let firstInvoice = fixture.document(sourceRootID: source.id, path: "first-invoice.pdf")
        let firstPayment = fixture.document(sourceRootID: source.id, path: "first-payment.pdf")
        let secondInvoice = fixture.document(sourceRootID: source.id, path: "second-invoice.pdf")
        let secondPayment = fixture.document(sourceRootID: source.id, path: "second-payment.pdf")
        try await fixture.documents.save(firstInvoice)
        try await fixture.documents.save(secondInvoice)
        let firstSnapshot = try testDocumentDNA(document: firstInvoice)
        let secondSnapshot = try testDocumentDNA(document: secondInvoice)
        let firstCandidate = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(
                invoice: firstInvoice,
                payment: firstPayment
            ),
            decision: .undecided
        )
        let secondCandidate = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(
                invoice: secondInvoice,
                payment: secondPayment
            ),
            decision: .undecided
        )
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [firstInvoice, secondInvoice].map {
                DocumentDNAAnalysisStatus(documentID: $0.id, phase: .ready)
            },
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            firstInvoice.id: [.snapshot(firstSnapshot), .snapshot(firstSnapshot)],
            secondInvoice.id: [.snapshot(secondSnapshot)],
        ])
        let candidateLoader = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            firstInvoice.id: [.candidates([firstCandidate]), .candidates([firstCandidate])],
            secondInvoice.id: [.candidates([secondCandidate])],
        ])
        let updater = ScriptedInvoicePaymentDecisionUpdater(steps: [
            .blocked(.success(())),
            .success,
        ])
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader,
            invoicePaymentDecisions: updater,
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()
        await model.selectDocument(id: firstInvoice.id)

        let staleUpdate = Task {
            await model.updateInvoicePaymentDecision(
                candidate: firstCandidate.candidate,
                command: .set(.confirmed)
            )
        }
        await updater.waitUntilBlockedUpdateStarts()

        await model.selectDocument(id: secondInvoice.id)
        await model.selectDocument(id: firstInvoice.id)
        #expect(model.isInvoicePaymentDecisionUpdateInFlight)
        #expect(model.invoicePaymentDecisionUpdatingCandidate == nil)
        await model.updateInvoicePaymentDecision(
            candidate: firstCandidate.candidate,
            command: .set(.excluded)
        )

        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: firstInvoice.id, candidates: [firstCandidate])
        )
        #expect(await updater.invocations == [
            .init(candidate: firstCandidate.candidate, command: .set(.confirmed)),
        ])

        await updater.releaseBlockedUpdate()
        await staleUpdate.value

        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: firstInvoice.id, candidates: [firstCandidate])
        )
        #expect(model.invoicePaymentDecisionUpdatingCandidate == nil)
        #expect(!model.isInvoicePaymentDecisionUpdateInFlight)
        #expect(diagnostics.values.isEmpty)

        await model.updateInvoicePaymentDecision(
            candidate: firstCandidate.candidate,
            command: .set(.excluded)
        )

        let expected = InvoicePaymentCandidateWithDecision(
            candidate: firstCandidate.candidate,
            decision: .excluded
        )
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: firstInvoice.id, candidates: [expected])
        )
        #expect(await updater.invocations == [
            .init(candidate: firstCandidate.candidate, command: .set(.confirmed)),
            .init(candidate: firstCandidate.candidate, command: .set(.excluded)),
        ])
    }

    @Test @MainActor func staleCandidateResultCannotReplaceNewerDocumentSelection() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let first = fixture.document(sourceRootID: source.id, path: "first.pdf")
        let second = fixture.document(sourceRootID: source.id, path: "second.pdf")
        let firstPayment = fixture.document(sourceRootID: source.id, path: "first-payment.pdf")
        let secondPayment = fixture.document(sourceRootID: source.id, path: "second-payment.pdf")
        try await fixture.documents.save(first)
        try await fixture.documents.save(second)
        let firstSnapshot = try testDocumentDNA(document: first)
        let secondSnapshot = try testDocumentDNA(document: second)
        let firstCandidate = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(
                invoice: first,
                payment: firstPayment
            ),
            decision: .excluded
        )
        let secondCandidate = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(
                invoice: second,
                payment: secondPayment
            ),
            decision: .confirmed
        )
        let statuses = [first, second].map {
            DocumentDNAAnalysisStatus(documentID: $0.id, phase: .ready)
        }
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: statuses,
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            first.id: [.snapshot(firstSnapshot)],
            second.id: [.snapshot(secondSnapshot)],
        ])
        let candidateLoader = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            first.id: [.blocked(.success([firstCandidate]))],
            second.id: [.candidates([secondCandidate])],
        ])
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader,
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()
        let staleSelection = Task { await model.selectDocument(id: first.id) }
        await candidateLoader.waitUntilBlockedLoadStarts()

        await model.selectDocument(id: second.id)
        await candidateLoader.releaseBlockedLoad()
        await staleSelection.value

        #expect(model.selectedDocumentID == second.id)
        #expect(model.documentDNADetailState == .available(secondSnapshot))
        #expect(
            model.invoicePaymentCandidateState
                == .available(documentID: second.id, candidates: [secondCandidate])
        )
        #expect(diagnostics.values.isEmpty)
    }

    @Test @MainActor func cancelledCandidateLoadDoesNotStayLoading() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let invoice = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        let payment = fixture.document(sourceRootID: source.id, path: "payment.pdf")
        try await fixture.documents.save(invoice)
        let snapshot = try testDocumentDNA(document: invoice)
        let candidate = InvoicePaymentCandidateWithDecision(
            candidate: try testInvoicePaymentCandidate(
                invoice: invoice,
                payment: payment
            ),
            decision: .undecided
        )
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: invoice.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            invoice.id: [.snapshot(snapshot)],
        ])
        let candidateLoader = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            invoice.id: [.blocked(.success([candidate]))],
        ])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader
        )
        try await model.reload()
        let selection = Task { await model.selectDocument(id: invoice.id) }
        await candidateLoader.waitUntilBlockedLoadStarts()

        selection.cancel()
        await candidateLoader.releaseBlockedLoad()
        await selection.value

        #expect(model.selectedDocumentID == invoice.id)
        #expect(model.documentDNADetailState == .available(snapshot))
        #expect(model.invoicePaymentCandidateState == .none)
    }

    @Test @MainActor func staleDocumentDNAResultCannotReplaceOrFailNewerSelection() async throws {
        for staleLoadFails in [false, true] {
            let fixture = try AppModelFixture()
            let source = try await fixture.addSource(named: "Archive")
            let first = fixture.document(sourceRootID: source.id, path: "first.pdf")
            let second = fixture.document(sourceRootID: source.id, path: "second.pdf")
            try await fixture.documents.save(first)
            try await fixture.documents.save(second)
            let firstSnapshot = try testDocumentDNA(document: first)
            let secondSnapshot = try testDocumentDNA(document: second)
            let staleResult: Result<DocumentDNA?, AppModelTestError> = staleLoadFails
                ? .failure(.documentDNASnapshotLoadFailed)
                : .success(firstSnapshot)
            let statuses = [first, second].map {
                DocumentDNAAnalysisStatus(documentID: $0.id, phase: .ready)
            }
            let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
                source.id: statuses,
            ])
            let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                first.id: [.blocked(staleResult)],
                second.id: [.snapshot(secondSnapshot)],
            ])
            let diagnostics = RuntimeDiagnosticRecorder()
            let model = AppModel(
                sources: fixture.sources,
                documents: fixture.documents,
                sourceAccess: fixture.sourceAccess,
                catalog: FakeCatalogScanner(),
                ingestion: FakePendingIngester(),
                dnaStatuses: dnaStatuses,
                dnaSnapshots: dnaSnapshots,
                reportRuntimeFailure: { diagnostics.record($0) }
            )
            try await model.reload()
            let staleSelection = Task { await model.selectDocument(id: first.id) }
            await dnaSnapshots.waitUntilBlockedLoadStarts()

            await model.selectDocument(id: second.id)
            await dnaSnapshots.releaseBlockedLoad()
            await staleSelection.value

            #expect(model.selectedDocumentID == second.id)
            #expect(model.documentDNADetailState == .available(secondSnapshot))
            #expect(diagnostics.values.isEmpty)
        }
    }

    @Test @MainActor func nonReadyDocumentDoesNotExposeStoredDNASnapshot() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "failed.pdf")
        try await fixture.documents.save(document)
        let snapshot = try testDocumentDNA(document: document)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [
                DocumentDNAAnalysisStatus(
                    documentID: document.id,
                    phase: .failed(.analysisFailure)
                ),
            ],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            document.id: [.snapshot(snapshot)],
        ])
        let model = fixture.model(dnaStatuses: dnaStatuses, dnaSnapshots: dnaSnapshots)
        try await model.reload()

        await model.selectDocument(id: document.id)

        #expect(model.selectedDocumentID == document.id)
        #expect(model.documentDNADetailState == .unavailable(documentID: document.id))
    }

    @Test @MainActor func retryingSelectedFailedDocumentRefreshesItsReadyDNA() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "failed.pdf")
        try await fixture.documents.save(document)
        let snapshot = try testDocumentDNA(document: document)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [
                DocumentDNAAnalysisStatus(
                    documentID: document.id,
                    phase: .failed(.analysisFailure)
                ),
            ],
        ])
        let retryer = RecordingDocumentDNAFailureRetryer { documentID, sourceRootID in
            await dnaStatuses.setStatuses(
                [DocumentDNAAnalysisStatus(documentID: documentID, phase: .ready)],
                sourceRootID: sourceRootID
            )
        }
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            document.id: [.snapshot(snapshot)],
        ])
        let model = fixture.model(
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            dnaRetryer: retryer
        )
        try await model.reload()
        await model.selectDocument(id: document.id)

        await model.retrySelectedDocumentDNA()

        #expect(await retryer.requests == [
            DocumentDNARetryRequest(documentID: document.id, sourceRootID: source.id),
        ])
        #expect(model.documentDNARetryingDocumentID == nil)
        #expect(model.documentDNAAnalysisPhases == [document.id: .ready])
        #expect(model.selectedDocumentID == document.id)
        #expect(model.documentDNADetailState == .available(snapshot))
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func retryIgnoresMissingNonVisibleOrNonFailedSelection() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let pending = fixture.document(sourceRootID: source.id, path: "pending.pdf")
        try await fixture.documents.save(pending)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: pending.id, phase: .pending)],
        ])
        let retryer = RecordingDocumentDNAFailureRetryer()
        let model = fixture.model(dnaStatuses: dnaStatuses, dnaRetryer: retryer)
        try await model.reload()

        await model.retrySelectedDocumentDNA()
        await model.selectDocument(id: UUID())
        await model.retrySelectedDocumentDNA()
        await model.selectDocument(id: pending.id)
        await model.retrySelectedDocumentDNA()

        #expect(await retryer.requests.isEmpty)
        #expect(model.documentDNARetryingDocumentID == nil)
    }

    @Test @MainActor func duplicateDocumentDNARetryIsSuppressed() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "failed.pdf")
        try await fixture.documents.save(document)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [
                DocumentDNAAnalysisStatus(
                    documentID: document.id,
                    phase: .failed(.analysisFailure)
                ),
            ],
        ])
        let retryer = BlockingDocumentDNAFailureRetryer()
        let model = fixture.model(dnaStatuses: dnaStatuses, dnaRetryer: retryer)
        try await model.reload()
        await model.selectDocument(id: document.id)

        let firstRetry = Task { await model.retrySelectedDocumentDNA() }
        await retryer.waitUntilRetryStarts()
        #expect(model.documentDNARetryingDocumentID == document.id)
        await model.retrySelectedDocumentDNA()
        await retryer.release()
        await firstRetry.value

        #expect(await retryer.requests.count == 1)
        #expect(model.documentDNARetryingDocumentID == nil)
    }

    @Test @MainActor func deterministicDocumentDNARetryFailureRemainsRetryable() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "failed.pdf")
        try await fixture.documents.save(document)
        let failedStatus = DocumentDNAAnalysisStatus(
            documentID: document.id,
            phase: .failed(.analysisFailure)
        )
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [failedStatus],
        ])
        let retryer = RecordingDocumentDNAFailureRetryer()
        let model = fixture.model(dnaStatuses: dnaStatuses, dnaRetryer: retryer)
        try await model.reload()
        await model.selectDocument(id: document.id)

        await model.retrySelectedDocumentDNA()
        await model.retrySelectedDocumentDNA()

        #expect(await retryer.requests.count == 2)
        #expect(model.documentDNAAnalysisPhases == [document.id: failedStatus.phase])
        #expect(model.selectedDocumentID == document.id)
        #expect(model.documentDNADetailState == .unavailable(documentID: document.id))
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func documentDNARetryFailurePreservesPresentationAndReportsSafeReason() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "failed.pdf")
        try await fixture.documents.save(document)
        let failedStatus = DocumentDNAAnalysisStatus(
            documentID: document.id,
            phase: .failed(.analysisFailure)
        )
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [failedStatus],
        ])
        let retryer = RecordingDocumentDNAFailureRetryer { _, _ in
            throw DocumentDNAAnalysisRunError(
                reason: .persistence,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        }
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaRetryer: retryer,
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()
        await model.selectDocument(id: document.id)

        await model.retrySelectedDocumentDNA()

        #expect(model.documents == [document])
        #expect(model.documentDNAAnalysisPhases == [document.id: failedStatus.phase])
        #expect(model.selectedDocumentID == document.id)
        #expect(model.documentDNADetailState == .unavailable(documentID: document.id))
        #expect(model.lastErrorCode == "documentDNARetryFailure")
        #expect(
            model.lastErrorMessage
                == "Document DNA konnte nicht erneut analysiert werden. Bitte versuche es erneut."
        )
        #expect(diagnostics.values.map(\.category) == [.documentDNARetry])
        #expect(diagnostics.values.map(\.reason) == [.persistence])
    }

    @Test @MainActor func refreshFailureAfterSuccessfulDocumentDNARetryIsNotMutationFailure() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "failed.pdf")
        try await fixture.documents.save(document)
        let failedStatus = DocumentDNAAnalysisStatus(
            documentID: document.id,
            phase: .failed(.analysisFailure)
        )
        let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [source.id: [
            .statuses([failedStatus]),
            .failure,
        ]])
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaRetryer: RecordingDocumentDNAFailureRetryer(),
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()
        await model.selectDocument(id: document.id)

        await model.retrySelectedDocumentDNA()

        #expect(model.documents == [document])
        #expect(model.documentDNAAnalysisPhases == [document.id: failedStatus.phase])
        #expect(model.selectedDocumentID == document.id)
        #expect(model.lastErrorCode == "incrementalRefreshFailure")
        #expect(diagnostics.values.map(\.category) == [.incrementalRefresh])
    }

    @Test @MainActor func cancelledDocumentDNARetryClearsProgressWithoutDiagnostic() async throws {
        for usesTypedRunError in [false, true] {
            let fixture = try AppModelFixture()
            let source = try await fixture.addSource(named: "Archive")
            let document = fixture.document(sourceRootID: source.id, path: "failed.pdf")
            try await fixture.documents.save(document)
            let failedStatus = DocumentDNAAnalysisStatus(
                documentID: document.id,
                phase: .failed(.analysisFailure)
            )
            let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
                source.id: [failedStatus],
            ])
            let diagnostics = RuntimeDiagnosticRecorder()
            let model = AppModel(
                sources: fixture.sources,
                documents: fixture.documents,
                sourceAccess: fixture.sourceAccess,
                catalog: FakeCatalogScanner(),
                ingestion: FakePendingIngester(),
                dnaStatuses: dnaStatuses,
                dnaRetryer: RecordingDocumentDNAFailureRetryer { _, _ in
                    if usesTypedRunError {
                        throw DocumentDNAAnalysisRunError(
                            reason: .cancelled,
                            partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
                        )
                    }
                    throw CancellationError()
                },
                reportRuntimeFailure: { diagnostics.record($0) }
            )
            try await model.reload()
            await model.selectDocument(id: document.id)

            await model.retrySelectedDocumentDNA()

            #expect(model.documentDNARetryingDocumentID == nil)
            #expect(model.documentDNAAnalysisPhases == [document.id: failedStatus.phase])
            #expect(model.selectedDocumentID == document.id)
            #expect(model.lastErrorCode == nil)
            #expect(diagnostics.values.isEmpty)
        }
    }

    @Test @MainActor func cancellingRetryAtSameSelectionCannotRefreshPresentation() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "failed.pdf")
        try await fixture.documents.save(document)
        let failedStatus = DocumentDNAAnalysisStatus(
            documentID: document.id,
            phase: .failed(.analysisFailure)
        )
        let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [source.id: [
            .statuses([failedStatus]),
            .statuses([DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)]),
        ]])
        let retryer = BlockingDocumentDNAFailureRetryer()
        let model = fixture.model(dnaStatuses: dnaStatuses, dnaRetryer: retryer)
        try await model.reload()
        await model.selectDocument(id: document.id)
        let retry = Task { await model.retrySelectedDocumentDNA() }
        await retryer.waitUntilRetryStarts()

        retry.cancel()
        await retryer.release()
        await retry.value

        #expect(model.documentDNAAnalysisPhases == [document.id: failedStatus.phase])
        #expect(model.selectedDocumentID == document.id)
        #expect(model.documentDNADetailState == .unavailable(documentID: document.id))
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func staleABADocumentDNARetryCannotPublishSuccessOrFailure() async throws {
        for retryFails in [false, true] {
            let fixture = try AppModelFixture()
            let source = try await fixture.addSource(named: "Archive")
            let first = fixture.document(sourceRootID: source.id, path: "first.pdf")
            let second = fixture.document(sourceRootID: source.id, path: "second.pdf")
            try await fixture.documents.save(first)
            try await fixture.documents.save(second)
            let firstFailed = DocumentDNAAnalysisStatus(
                documentID: first.id,
                phase: .failed(.analysisFailure)
            )
            let secondReady = DocumentDNAAnalysisStatus(documentID: second.id, phase: .ready)
            let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [source.id: [
                .statuses([firstFailed, secondReady]),
                .statuses([
                    DocumentDNAAnalysisStatus(documentID: first.id, phase: .ready),
                    secondReady,
                ]),
            ]])
            let retryer = BlockingDocumentDNAFailureRetryer(
                result: retryFails
                    ? .failure(.documentDNASnapshotLoadFailed)
                    : .success(())
            )
            let secondSnapshot = try testDocumentDNA(document: second)
            let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                second.id: [.snapshot(secondSnapshot)],
            ])
            let diagnostics = RuntimeDiagnosticRecorder()
            let model = AppModel(
                sources: fixture.sources,
                documents: fixture.documents,
                sourceAccess: fixture.sourceAccess,
                catalog: FakeCatalogScanner(),
                ingestion: FakePendingIngester(),
                dnaStatuses: dnaStatuses,
                dnaSnapshots: dnaSnapshots,
                dnaRetryer: retryer,
                reportRuntimeFailure: { diagnostics.record($0) }
            )
            try await model.reload()
            await model.selectDocument(id: first.id)
            let retry = Task { await model.retrySelectedDocumentDNA() }
            await retryer.waitUntilRetryStarts()

            await model.selectDocument(id: second.id)
            await model.selectDocument(id: first.id)
            await retryer.release()
            await retry.value

            #expect(model.documentDNAAnalysisPhases == [
                first.id: firstFailed.phase,
                second.id: secondReady.phase,
            ])
            #expect(model.selectedDocumentID == first.id)
            #expect(model.documentDNADetailState == .unavailable(documentID: first.id))
            #expect(diagnostics.values.isEmpty)
        }
    }

    @Test @MainActor func changingDocumentClearsDocumentDNARetryFailure() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let failed = fixture.document(sourceRootID: source.id, path: "failed.pdf")
        let pending = fixture.document(sourceRootID: source.id, path: "pending.pdf")
        try await fixture.documents.save(failed)
        try await fixture.documents.save(pending)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [
                DocumentDNAAnalysisStatus(
                    documentID: failed.id,
                    phase: .failed(.analysisFailure)
                ),
                DocumentDNAAnalysisStatus(documentID: pending.id, phase: .pending),
            ],
        ])
        let model = fixture.model(
            dnaStatuses: dnaStatuses,
            dnaRetryer: RecordingDocumentDNAFailureRetryer { _, _ in
                throw AppModelTestError.documentDNAStatusLoadFailed
            }
        )
        try await model.reload()
        await model.selectDocument(id: failed.id)
        await model.retrySelectedDocumentDNA()
        #expect(model.lastErrorCode == "documentDNARetryFailure")

        await model.selectDocument(id: pending.id)

        #expect(model.selectedDocumentID == pending.id)
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func staleOrCancelledDocumentDNARetryCannotReplaceNewerSelection() async throws {
        for mode in 0 ..< 3 {
            let fixture = try AppModelFixture()
            let source = try await fixture.addSource(named: "Archive")
            let failed = fixture.document(sourceRootID: source.id, path: "failed.pdf")
            let ready = fixture.document(sourceRootID: source.id, path: "ready.pdf")
            try await fixture.documents.save(failed)
            try await fixture.documents.save(ready)
            let readySnapshot = try testDocumentDNA(document: ready)
            let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
                source.id: [
                    DocumentDNAAnalysisStatus(
                        documentID: failed.id,
                        phase: .failed(.analysisFailure)
                    ),
                    DocumentDNAAnalysisStatus(documentID: ready.id, phase: .ready),
                ],
            ])
            let retryer = BlockingDocumentDNAFailureRetryer(
                result: mode == 1
                    ? .failure(.documentDNASnapshotLoadFailed)
                    : .success(())
            )
            let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                ready.id: [.snapshot(readySnapshot)],
            ])
            let diagnostics = RuntimeDiagnosticRecorder()
            let model = AppModel(
                sources: fixture.sources,
                documents: fixture.documents,
                sourceAccess: fixture.sourceAccess,
                catalog: FakeCatalogScanner(),
                ingestion: FakePendingIngester(),
                dnaStatuses: dnaStatuses,
                dnaSnapshots: dnaSnapshots,
                dnaRetryer: retryer,
                reportRuntimeFailure: { diagnostics.record($0) }
            )
            try await model.reload()
            await model.selectDocument(id: failed.id)
            let retry = Task { await model.retrySelectedDocumentDNA() }
            await retryer.waitUntilRetryStarts()

            await model.selectDocument(id: ready.id)
            if mode == 2 {
                retry.cancel()
            }
            await retryer.release()
            await retry.value

            #expect(model.selectedDocumentID == ready.id)
            #expect(model.documentDNADetailState == .available(readySnapshot))
            #expect(diagnostics.values.isEmpty)
        }
    }

    @Test @MainActor func currentDocumentDNALoadFailurePreservesSourcePresentation() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        try await fixture.documents.save(document)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            document.id: [.failure],
        ])
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()

        await model.selectDocument(id: document.id)

        #expect(model.selectedSourceID == source.id)
        #expect(model.documents == [document])
        #expect(model.selectedDocumentID == document.id)
        #expect(model.documentDNADetailState == .failed(documentID: document.id))
        #expect(model.lastErrorCode == "documentDNADetailLoadFailure")
        #expect(diagnostics.values.map(\.category) == [.documentDNADetailLoad])
        #expect(diagnostics.values.map(\.reason) == [.unexpected])
    }

    @Test @MainActor func cancelledDocumentDNALoadDoesNotLeaveInspectorLoading() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        try await fixture.documents.save(document)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            document.id: [.cancellation],
        ])
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()

        await model.selectDocument(id: document.id)

        #expect(model.selectedDocumentID == document.id)
        #expect(model.documentDNADetailState == .unavailable(documentID: document.id))
        #expect(diagnostics.values.isEmpty)
    }

    @Test @MainActor func cancelledBlockedDocumentDNALoadCannotStayLoading() async throws {
        for blockedLoadFails in [false, true] {
            let fixture = try AppModelFixture()
            let source = try await fixture.addSource(named: "Archive")
            let document = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
            try await fixture.documents.save(document)
            let snapshot = try testDocumentDNA(document: document)
            let blockedResult: Result<DocumentDNA?, AppModelTestError> = blockedLoadFails
                ? .failure(.documentDNASnapshotLoadFailed)
                : .success(snapshot)
            let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
                source.id: [DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)],
            ])
            let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
                document.id: [.blocked(blockedResult)],
            ])
            let model = fixture.model(dnaStatuses: dnaStatuses, dnaSnapshots: dnaSnapshots)
            try await model.reload()
            let selection = Task { await model.selectDocument(id: document.id) }
            await dnaSnapshots.waitUntilBlockedLoadStarts()

            selection.cancel()
            await dnaSnapshots.releaseBlockedLoad()
            await selection.value

            #expect(model.selectedDocumentID == document.id)
            #expect(model.documentDNADetailState == .unavailable(documentID: document.id))
        }
    }

    @Test @MainActor func newDocumentSelectionClearsPriorDNALoadFailure() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let first = fixture.document(sourceRootID: source.id, path: "first.pdf")
        let second = fixture.document(sourceRootID: source.id, path: "second.pdf")
        try await fixture.documents.save(first)
        try await fixture.documents.save(second)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [
                DocumentDNAAnalysisStatus(documentID: first.id, phase: .ready),
                DocumentDNAAnalysisStatus(documentID: second.id, phase: .pending),
            ],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            first.id: [.failure],
        ])
        let model = fixture.model(dnaStatuses: dnaStatuses, dnaSnapshots: dnaSnapshots)
        try await model.reload()
        await model.selectDocument(id: first.id)
        #expect(model.lastErrorCode == "documentDNADetailLoadFailure")

        await model.selectDocument(id: second.id)

        #expect(model.selectedDocumentID == second.id)
        #expect(model.documentDNADetailState == .unavailable(documentID: second.id))
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func sourcePresentationRefreshClearsSelectedDocumentDNA() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        try await fixture.documents.save(document)
        let snapshot = try testDocumentDNA(document: document)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            document.id: [.snapshot(snapshot)],
        ])
        let model = fixture.model(dnaStatuses: dnaStatuses, dnaSnapshots: dnaSnapshots)
        try await model.reload()
        await model.selectDocument(id: document.id)

        await model.selectSource(id: source.id)

        #expect(model.selectedDocumentID == nil)
        #expect(model.documentDNADetailState == .none)
    }

    @Test @MainActor func reloadClearsObsoleteDocumentDNALoadFailure() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "invoice.pdf")
        try await fixture.documents.save(document)
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)],
        ])
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            document.id: [.failure],
        ])
        let model = fixture.model(dnaStatuses: dnaStatuses, dnaSnapshots: dnaSnapshots)
        try await model.reload()
        await model.selectDocument(id: document.id)
        #expect(model.lastErrorCode == "documentDNADetailLoadFailure")

        try await model.reload()

        #expect(model.selectedDocumentID == nil)
        #expect(model.documentDNADetailState == .none)
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func documentDNAStatusFailurePreservesVisibleSourceState() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = fixture.document(sourceRootID: source.id, path: "ready.pdf")
        try await fixture.documents.save(document)
        let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [source.id: [
            .statuses([DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)]),
            .failure,
        ]])
        let model = fixture.model(dnaStatuses: dnaStatuses)
        try await model.reload()

        await model.selectSource(id: source.id)

        #expect(model.documents == [document])
        #expect(model.documentDNAAnalysisPhases == [document.id: .ready])
        #expect(model.lastErrorCode == "documentLoadFailure")
    }

    @Test @MainActor func staleABADNAStatusResultCannotOverwriteNewerSelection() async throws {
        let staleResults: [Result<[DocumentDNAAnalysisStatus], AppModelTestError>] = [
            .success([]),
            .failure(.documentDNAStatusLoadFailed),
        ]
        for staleResult in staleResults {
            let fixture = try AppModelFixture()
            let pair = try await TwoSourceDocuments.make(in: fixture)
            let current = DocumentDNAAnalysisStatus(
                documentID: pair.secondDocument.id,
                phase: .ready
            )
            let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [
                pair.first.id: [.statuses([])],
                pair.second.id: [.blocked(staleResult), .statuses([current])],
            ])
            let model = fixture.model(dnaStatuses: dnaStatuses)
            try await model.reload()
            let staleSelection = Task { await model.selectSource(id: pair.second.id) }
            await dnaStatuses.waitUntilBlockedLoadStarts()

            await model.selectSource(id: pair.first.id)
            await model.selectSource(id: pair.second.id)
            await dnaStatuses.releaseBlockedLoad()
            await staleSelection.value

            #expect(model.selectedSourceID == pair.second.id)
            #expect(model.documents == [pair.secondDocument])
            #expect(model.documentDNAAnalysisPhases == [current.documentID: current.phase])
            #expect(model.lastErrorCode == nil)
        }
    }

    @Test @MainActor func crossSourceDNAStatusFailureKeepsPresentedSelectionCoherent() async throws {
        let fixture = try AppModelFixture()
        let pair = try await TwoSourceDocuments.make(in: fixture)
        let ready = DocumentDNAAnalysisStatus(
            documentID: pair.firstDocument.id,
            phase: .ready
        )
        let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [
            pair.first.id: [.statuses([ready])],
            pair.second.id: [.failure],
        ])
        let model = fixture.model(dnaStatuses: dnaStatuses)
        try await model.reload()

        await model.selectSource(id: pair.second.id)

        #expect(model.selectedSourceID == pair.first.id)
        #expect(model.documents == [pair.firstDocument])
        #expect(model.documentDNAAnalysisPhases == [ready.documentID: ready.phase])
        #expect(model.lastErrorCode == "documentLoadFailure")
    }

    @Test @MainActor func addingSourcePublishesSelectionOnlyAfterDNAStatusSucceeds() async throws {
        let results: [Result<[DocumentDNAAnalysisStatus], AppModelTestError>] = [
            .success([]), .failure(.documentDNAStatusLoadFailed),
        ]
        for result in results {
            let fixture = try AppModelFixture()
            let first = try await fixture.addSource(named: "First")
            let document = fixture.document(sourceRootID: first.id, path: "first.pdf")
            try await fixture.documents.save(document)
            let ready = DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)
            let dnaStatuses = ScriptedDocumentDNAStatusLoader(
                stepsBySource: [first.id: [.statuses([ready])]],
                defaultSteps: [.blocked(result)]
            )
            let scheduler = FakeSourceWatchScheduler()
            let model = AppModel(
                sources: fixture.sources,
                documents: fixture.documents,
                sourceAccess: fixture.sourceAccess,
                catalog: FakeCatalogScanner(),
                ingestion: FakePendingIngester(),
                dnaStatuses: dnaStatuses,
                watchScheduler: scheduler,
                sourceResolver: { _ in fixture.directory }
            )
            try await model.reload()
            let add = Task {
                await model.addSource(
                    fixture.directory.appendingPathComponent("Second", isDirectory: true)
                )
            }
            await dnaStatuses.waitUntilBlockedLoadStarts()

            #expect(model.selectedSourceID == first.id)
            #expect(model.documents == [document])
            #expect(model.documentDNAAnalysisPhases == [ready.documentID: ready.phase])
            #expect(await scheduler.startedSourceRecords.count == 2)
            await dnaStatuses.releaseBlockedLoad()
            await add.value

            if case .success = result {
                #expect(model.selectedSourceID != first.id)
                #expect(model.documents.isEmpty)
                #expect(model.documentDNAAnalysisPhases.isEmpty)
            } else {
                #expect(model.selectedSourceID == first.id)
                #expect(model.documents == [document])
                #expect(model.documentDNAAnalysisPhases == [ready.documentID: ready.phase])
                #expect(model.lastErrorCode == "documentLoadFailure")
            }
            #expect(model.sources.count == 2)
        }
    }

    @Test @MainActor func removingSelectedSourceClearsPresentationBeforeFallbackLoad() async throws {
        let results: [Result<[DocumentDNAAnalysisStatus], AppModelTestError>] = [
            .success([]), .failure(.documentDNAStatusLoadFailed),
        ]
        for result in results {
            let fixture = try AppModelFixture()
            let pair = try await TwoSourceDocuments.make(in: fixture)
            let firstReady = DocumentDNAAnalysisStatus(
                documentID: pair.firstDocument.id,
                phase: .ready
            )
            let secondReady = DocumentDNAAnalysisStatus(
                documentID: pair.secondDocument.id,
                phase: .ready
            )
            let fallbackResult = result.map { _ in [secondReady] }
            let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [
                pair.first.id: [.statuses([firstReady])],
                pair.second.id: [.blocked(fallbackResult)],
            ])
            let model = fixture.model(dnaStatuses: dnaStatuses)
            try await model.reload()
            let remove = Task { await model.removeSource(pair.first) }
            await dnaStatuses.waitUntilBlockedLoadStarts()

            #expect(model.selectedSourceID == nil)
            #expect(model.documents.isEmpty)
            #expect(model.documentDNAAnalysisPhases.isEmpty)
            await dnaStatuses.releaseBlockedLoad()
            await remove.value

            if case .success = result {
                #expect(model.selectedSourceID == pair.second.id)
                #expect(model.documents == [pair.secondDocument])
                #expect(model.documentDNAAnalysisPhases == [secondReady.documentID: secondReady.phase])
            } else {
                #expect(model.selectedSourceID == nil)
                #expect(model.documents.isEmpty)
                #expect(model.documentDNAAnalysisPhases.isEmpty)
                #expect(model.lastErrorCode == "documentLoadFailure")
            }
        }
    }

    @Test @MainActor func reloadStagesFallbackUntilDNAStatusSucceeds() async throws {
        let fixture = try AppModelFixture()
        let pair = try await TwoSourceDocuments.make(in: fixture)
        let firstReady = DocumentDNAAnalysisStatus(
            documentID: pair.firstDocument.id,
            phase: .ready
        )
        let secondReady = DocumentDNAAnalysisStatus(
            documentID: pair.secondDocument.id,
            phase: .ready
        )
        let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [
            pair.first.id: [.statuses([firstReady])],
            pair.second.id: [.blocked(.success([secondReady]))],
        ])
        let model = fixture.model(dnaStatuses: dnaStatuses)
        try await model.reload()
        try await fixture.sources.remove(id: pair.first.id)
        let reload = Task { try await model.reload() }
        await dnaStatuses.waitUntilBlockedLoadStarts()

        #expect(model.sources.contains { $0.id == pair.first.id })
        #expect(model.selectedSourceID == pair.first.id)
        #expect(model.documents == [pair.firstDocument])
        await dnaStatuses.releaseBlockedLoad()
        try await reload.value

        #expect(model.sources == [pair.second])
        #expect(model.selectedSourceID == pair.second.id)
        #expect(model.documents == [pair.secondDocument])
        #expect(model.documentDNAAnalysisPhases == [secondReady.documentID: secondReady.phase])
    }

    @Test @MainActor func staleReloadResultCannotReplaceOrFailNewerPresentation() async throws {
        for staleResult in [
            Result<[DocumentDNAAnalysisStatus], AppModelTestError>.success([]),
            .failure(.documentDNAStatusLoadFailed),
        ] {
            let fixture = try AppModelFixture()
            let source = try await fixture.addSource(named: "Archive")
            let document = fixture.document(sourceRootID: source.id, path: "document.pdf")
            try await fixture.documents.save(document)
            let ready = DocumentDNAAnalysisStatus(documentID: document.id, phase: .ready)
            let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [
                source.id: [
                    .statuses([]), .blocked(staleResult), .statuses([ready]),
                ],
            ])
            let diagnostics = RuntimeDiagnosticRecorder()
            let model = AppModel(
                sources: fixture.sources,
                documents: fixture.documents,
                sourceAccess: fixture.sourceAccess,
                catalog: FakeCatalogScanner(),
                ingestion: FakePendingIngester(),
                dnaStatuses: dnaStatuses,
                reportRuntimeFailure: { diagnostics.record($0) }
            )
            try await model.reload()
            let staleReload = Task { try await model.reload() }
            await dnaStatuses.waitUntilBlockedLoadStarts()

            try await model.reload()
            await dnaStatuses.releaseBlockedLoad()
            try await staleReload.value

            #expect(model.selectedSourceID == source.id)
            #expect(model.documents == [document])
            #expect(model.documentDNAAnalysisPhases == [document.id: .ready])
            #expect(diagnostics.values.isEmpty)
        }
    }

    @Test @MainActor func reloadPropagatesCancellationError() async throws {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [
            source.id: [.statuses([]), .cancellation],
        ])
        let diagnostics = RuntimeDiagnosticRecorder()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()

        await #expect(throws: CancellationError.self) {
            try await model.reload()
        }
        #expect(diagnostics.values.map(\.category) == [.reload])
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

    @Test @MainActor func reloadRenewsStaleBookmarkBeforeStartingWatcher() async throws {
        let fixture = try AppModelFixture()
        let access = AppStaleBookmarkSourceAccess()
        let originalURL = fixture.directory.appendingPathComponent(
            "Original",
            isDirectory: true
        )
        let relocatedURL = fixture.directory.appendingPathComponent(
            "Renamed",
            isDirectory: true
        )
        let source = try await fixture.sources.add(
            url: originalURL,
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 100)
        )
        access.markStale(source.bookmarkData, resolvingTo: relocatedURL)
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: access,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler
        )

        try await model.reload()

        let stored = try #require(try await fixture.sources.all().first)
        #expect(stored.bookmarkData != source.bookmarkData)
        #expect(model.sources == [stored])
        #expect(await scheduler.startedSourceRecords == [stored])
        #expect(await scheduler.startedSources == [
            WatchedSource(sourceID: source.id, path: relocatedURL.path),
        ])
    }

    @Test @MainActor func overlappingReloadsStartPreparedSourceWatcherOnce() async throws {
        let fixture = try AppModelFixture()
        let access = AppStaleBookmarkSourceAccess(blockAccess: true)
        let sourceURL = fixture.directory.appendingPathComponent(
            "Archive",
            isDirectory: true
        )
        let source = try await fixture.sources.add(
            url: sourceURL,
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 100)
        )
        access.markStale(source.bookmarkData, resolvingTo: sourceURL)
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: access,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler
        )

        async let firstReload: Void = model.reload()
        async let secondReload: Void = model.reload()
        await access.waitUntilAccessCount(1)
        await access.releaseAccess()
        _ = try await (firstReload, secondReload)

        #expect(await scheduler.startedSourceRecords.count == 1)
        #expect(await scheduler.startedSourceRecords.first?.id == source.id)
    }

    @Test @MainActor func stopWatchingDuringBookmarkRenewalPreventsLateWatcherStart() async throws {
        let fixture = try AppModelFixture()
        let access = AppStaleBookmarkSourceAccess(blockAccess: true)
        let sourceURL = fixture.directory.appendingPathComponent(
            "Archive",
            isDirectory: true
        )
        let source = try await fixture.sources.add(
            url: sourceURL,
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 100)
        )
        access.markStale(source.bookmarkData, resolvingTo: sourceURL)
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: access,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler
        )

        async let reload: Void = model.reload()
        await access.waitUntilAccessCount(1)
        await model.stopWatching()
        await access.releaseAccess()
        try await reload

        #expect(await scheduler.startedSourceRecords.isEmpty)
        #expect(await scheduler.stopAllCount == 1)
    }

    @Test @MainActor func renewalFailureMarksOnlyAffectedSourceUnavailable() async throws {
        let fixture = try AppModelFixture()
        let access = AppStaleBookmarkSourceAccess()
        let unavailable = try await fixture.sources.add(
            url: fixture.directory.appendingPathComponent("Unavailable", isDirectory: true),
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 100)
        )
        let available = try await fixture.sources.add(
            url: fixture.directory.appendingPathComponent("Available", isDirectory: true),
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 200)
        )
        access.failResolution(of: unavailable.bookmarkData)
        let scheduler = FakeSourceWatchScheduler()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: access,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            watchScheduler: scheduler
        )

        try await model.reload()

        #expect(model.unavailableSourceIDs == [unavailable.id])
        #expect(await scheduler.startedSourceRecords == [available])
        #expect(try await fixture.sources.all() == [unavailable, available])
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

    @Test @MainActor func unavailableStateWaitsForWatcherBookkeepingBeforeReload() async throws {
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

        await scheduler.blockNextAvailabilityProbe()
        await scheduler.fail(sourceID: source.id)
        await scheduler.waitUntilAvailabilityProbeStarts()

        #expect(model.unavailableSourceIDs.isEmpty)
        await scheduler.releaseAvailabilityProbe()
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
        let dnaStatuses = MutableDocumentDNAStatusLoader(statusesBySource: [
            source.id: [],
        ])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory }
        )
        try await model.reload()
        let ready = fixture.document(sourceRootID: source.id, path: "new.pdf")
        try await fixture.documents.save(ready)
        await dnaStatuses.setStatuses(
            [DocumentDNAAnalysisStatus(documentID: ready.id, phase: .ready)],
            sourceRootID: source.id
        )
        try await fixture.sources.updateLastScan(
            id: source.id,
            at: Date(timeIntervalSince1970: 500)
        )

        scheduler.completeRescan(sourceID: source.id)
        await waitUntil {
            model.documents == [ready]
                && model.documentDNAAnalysisPhases == [ready.id: .ready]
                && model.sources.first?.lastScanAt != nil
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
        let fallbackStatus = DocumentDNAAnalysisStatus(
            documentID: fallbackDocument.id,
            phase: .ready
        )
        let dnaStatuses = ScriptedDocumentDNAStatusLoader(stepsBySource: [
            removed.id: [.statuses([])],
            fallback.id: [.blocked(.success([fallbackStatus]))],
        ])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            watchScheduler: scheduler,
            sourceResolver: { _ in fixture.directory }
        )
        try await model.reload()
        await model.selectSource(id: removed.id)
        try await fixture.sources.remove(id: removed.id)

        scheduler.completeRescan(sourceID: removed.id)
        await dnaStatuses.waitUntilBlockedLoadStarts()
        #expect(model.selectedSourceID == removed.id)
        #expect(model.documents == [removedDocument])
        await dnaStatuses.releaseBlockedLoad()
        await waitUntil {
            model.selectedSourceID == fallback.id && model.documents == [fallbackDocument]
        }

        #expect(model.documentDNAAnalysisPhases == [fallbackStatus.documentID: .ready])
    }

    @Test @MainActor func currentIncrementalRefreshFailurePreservesVisibleDocuments() async throws {
        let fixture = try AppModelFixture()
        let diagnostics = RuntimeDiagnosticRecorder()
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
            documentLoader: { sourceID in try await loader.load(sourceID: sourceID) },
            reportRuntimeFailure: { diagnostics.record($0) }
        )
        try await model.reload()

        scheduler.completeRescan(sourceID: source.id)
        await waitUntil { model.lastErrorCode == "incrementalRefreshFailure" }

        #expect(model.documents == [visible])
        #expect(
            model.lastErrorMessage
                == "Die Ansicht konnte nach der Analyse nicht aktualisiert werden. Bitte versuche es erneut."
        )
        #expect(diagnostics.values.map(\.category) == [.incrementalRefresh])
        #expect(diagnostics.values.map(\.reason) == [.unexpected])
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

        #expect(model.selectedSourceID == removed.id)
        #expect(model.documents == [visible])
        #expect(model.sources.contains { $0.id == removed.id })
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
    private(set) var startedSourceRecords: [SourceRootRecord] = []
    private(set) var stopAllCount = 0
    private var activeSourceIDs = Set<UUID>()
    private let rootUnavailableDuringStart: Bool
    private var availabilityProbeCount = 0
    private var shouldBlockNextAvailabilityProbe = false
    private var blockedAvailabilityProbeContinuation: CheckedContinuation<Void, Never>?
    private var availabilityProbeStartWaiters: [CheckedContinuation<Void, Never>] = []

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
        startedSourceRecords.append(source)
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

    func isWatching(sourceID: UUID) async -> Bool {
        availabilityProbeCount += 1
        if shouldBlockNextAvailabilityProbe {
            shouldBlockNextAvailabilityProbe = false
            await withCheckedContinuation { continuation in
                blockedAvailabilityProbeContinuation = continuation
                availabilityProbeStartWaiters.forEach { $0.resume() }
                availabilityProbeStartWaiters.removeAll()
            }
        }
        return activeSourceIDs.contains(sourceID)
    }

    func blockNextAvailabilityProbe() {
        shouldBlockNextAvailabilityProbe = true
    }

    func waitUntilAvailabilityProbeStarts() async {
        guard blockedAvailabilityProbeContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            availabilityProbeStartWaiters.append(continuation)
        }
    }

    func releaseAvailabilityProbe() {
        blockedAvailabilityProbeContinuation?.resume()
        blockedAvailabilityProbeContinuation = nil
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
        throw IngestionRunError(
            reason: .sourceAccess,
            partialReport: IngestionReport(completed: 0, failed: 0)
        )
    }
}

@MainActor
private final class RuntimeDiagnosticRecorder {
    private(set) var values: [AppRuntimeDiagnostic] = []

    func record(_ diagnostic: AppRuntimeDiagnostic) {
        values.append(diagnostic)
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

    @MainActor
    func model(
        dnaStatuses: any DocumentDNAStatusLoading,
        dnaSnapshots: (any DocumentDNASnapshotLoading)? = nil,
        dnaRetryer: (any DocumentDNAFailureRetrying)? = nil
    ) -> AppModel {
        AppModel(
            sources: sources,
            documents: documents,
            sourceAccess: sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            dnaRetryer: dnaRetryer
        )
    }
}

private struct TwoSourceDocuments {
    let first: SourceRootRecord
    let second: SourceRootRecord
    let firstDocument: DocumentRecord
    let secondDocument: DocumentRecord

    static func make(in fixture: AppModelFixture) async throws -> Self {
        let first = try await fixture.addSource(named: "First")
        let second = try await fixture.addSource(named: "Second")
        let firstDocument = fixture.document(sourceRootID: first.id, path: "first.pdf")
        let secondDocument = fixture.document(sourceRootID: second.id, path: "second.pdf")
        try await fixture.documents.save(firstDocument)
        try await fixture.documents.save(secondDocument)
        return Self(
            first: first,
            second: second,
            firstDocument: firstDocument,
            secondDocument: secondDocument
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

private struct DocumentDNARetryRequest: Sendable, Equatable {
    let documentID: UUID
    let sourceRootID: UUID
}

private actor RecordingDocumentDNAFailureRetryer: DocumentDNAFailureRetrying {
    private(set) var requests: [DocumentDNARetryRequest] = []
    private let operation: @Sendable (UUID, UUID) async throws -> Void

    init(
        operation: @escaping @Sendable (UUID, UUID) async throws -> Void = { _, _ in }
    ) {
        self.operation = operation
    }

    func retryFailedAnalysis(documentID: UUID, sourceRootID: UUID) async throws {
        requests.append(DocumentDNARetryRequest(documentID: documentID, sourceRootID: sourceRootID))
        try await operation(documentID, sourceRootID)
    }
}

private actor BlockingDocumentDNAFailureRetryer: DocumentDNAFailureRetrying {
    private(set) var requests: [DocumentDNARetryRequest] = []
    private let result: Result<Void, AppModelTestError>
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: Result<Void, AppModelTestError> = .success(())) {
        self.result = result
    }

    func retryFailedAnalysis(documentID: UUID, sourceRootID: UUID) async throws {
        requests.append(DocumentDNARetryRequest(documentID: documentID, sourceRootID: sourceRootID))
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        try result.get()
    }

    func waitUntilRetryStarts() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor MutableDocumentDNAStatusLoader: DocumentDNAStatusLoading {
    private var statusesBySource: [UUID: [DocumentDNAAnalysisStatus]]

    init(statusesBySource: [UUID: [DocumentDNAAnalysisStatus]]) {
        self.statusesBySource = statusesBySource
    }

    func currentAnalysisStatuses(
        sourceRootID: UUID
    ) async throws -> [DocumentDNAAnalysisStatus] {
        statusesBySource[sourceRootID] ?? []
    }

    func setStatuses(
        _ statuses: [DocumentDNAAnalysisStatus],
        sourceRootID: UUID
    ) {
        statusesBySource[sourceRootID] = statuses
    }
}

private actor ScriptedDocumentDNAStatusLoader: DocumentDNAStatusLoading {
    enum Step: Sendable {
        case statuses([DocumentDNAAnalysisStatus])
        case failure
        case cancellation
        case blocked(Result<[DocumentDNAAnalysisStatus], AppModelTestError>)
    }

    private var stepsBySource: [UUID: [Step]]
    private var defaultSteps: [Step]
    private var blockedLoadStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        stepsBySource: [UUID: [Step]],
        defaultSteps: [Step] = [.statuses([])]
    ) {
        self.stepsBySource = stepsBySource
        self.defaultSteps = defaultSteps
    }

    func currentAnalysisStatuses(
        sourceRootID: UUID
    ) async throws -> [DocumentDNAAnalysisStatus] {
        let usesDefaultSteps = stepsBySource[sourceRootID] == nil
        var steps = stepsBySource[sourceRootID] ?? defaultSteps
        let step = steps.count > 1 ? steps.removeFirst() : steps[0]
        if usesDefaultSteps {
            defaultSteps = steps
        } else {
            stepsBySource[sourceRootID] = steps
        }
        switch step {
        case .statuses(let statuses):
            return statuses
        case .failure:
            throw AppModelTestError.documentDNAStatusLoadFailed
        case .cancellation:
            throw CancellationError()
        case .blocked(let result):
            blockedLoadStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { releaseWaiters.append($0) }
            return try result.get()
        }
    }

    func waitUntilBlockedLoadStarts() async {
        guard !blockedLoadStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedLoad() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor ScriptedDocumentDNASnapshotLoader: DocumentDNASnapshotLoading {
    enum Step: Sendable {
        case snapshot(DocumentDNA?)
        case failure
        case cancellation
        case blocked(Result<DocumentDNA?, AppModelTestError>)
    }

    private var stepsByDocument: [UUID: [Step]]
    private var blockedLoadStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(stepsByDocument: [UUID: [Step]]) {
        self.stepsByDocument = stepsByDocument
    }

    func currentSnapshot(documentID: UUID) async throws -> DocumentDNA? {
        var steps = stepsByDocument[documentID] ?? [.snapshot(nil)]
        let step = steps.count > 1 ? steps.removeFirst() : steps[0]
        stepsByDocument[documentID] = steps
        switch step {
        case .snapshot(let snapshot):
            return snapshot
        case .failure:
            throw AppModelTestError.documentDNASnapshotLoadFailed
        case .cancellation:
            throw CancellationError()
        case .blocked(let result):
            blockedLoadStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { releaseWaiters.append($0) }
            return try result.get()
        }
    }

    func waitUntilBlockedLoadStarts() async {
        guard !blockedLoadStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedLoad() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor ScriptedInvoicePaymentCandidateLoader: InvoicePaymentCandidateLoading {
    enum Step: Sendable {
        case candidates([InvoicePaymentCandidateWithDecision])
        case failure
        case blocked(Result<[InvoicePaymentCandidateWithDecision], AppModelTestError>)
    }

    private var stepsByDocument: [UUID: [Step]]
    private var blockedLoadStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(stepsByDocument: [UUID: [Step]]) {
        self.stepsByDocument = stepsByDocument
    }

    func candidates(involving documentID: UUID) async throws
        -> [InvoicePaymentCandidateWithDecision]
    {
        var steps = stepsByDocument[documentID] ?? [.candidates([])]
        let step = steps.count > 1 ? steps.removeFirst() : steps[0]
        stepsByDocument[documentID] = steps
        switch step {
        case .candidates(let candidates):
            return candidates
        case .failure:
            throw AppModelTestError.invoicePaymentCandidateLoadFailed
        case .blocked(let result):
            blockedLoadStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { releaseWaiters.append($0) }
            return try result.get()
        }
    }

    func waitUntilBlockedLoadStarts() async {
        guard !blockedLoadStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedLoad() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor ScriptedInvoicePaymentDecisionUpdater: InvoicePaymentDecisionUpdating {
    struct Invocation: Sendable, Equatable {
        let candidate: InvoicePaymentCandidate
        let command: InvoicePaymentDecisionCommand
    }

    enum Step: Sendable {
        case success
        case failure
        case cancellation
        case blocked(Result<Void, AppModelTestError>)
    }

    private var steps: [Step]
    private(set) var invocations: [Invocation] = []
    private var blockedUpdateStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func update(
        candidate: InvoicePaymentCandidate,
        command: InvoicePaymentDecisionCommand
    ) async throws {
        invocations.append(.init(candidate: candidate, command: command))
        let step = steps.isEmpty ? .success : steps.removeFirst()
        switch step {
        case .success:
            return
        case .failure:
            throw AppModelTestError.invoicePaymentDecisionUpdateFailed
        case .cancellation:
            throw CancellationError()
        case .blocked(let result):
            blockedUpdateStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { releaseWaiters.append($0) }
            return try result.get()
        }
    }

    func waitUntilBlockedUpdateStarts() async {
        guard !blockedUpdateStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedUpdate() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor ScriptedDossierLoader: DossierLoading {
    enum EntryStep: Sendable {
        case disposition(DossierEntryDisposition)
        case failure
        case cancellation
        case blocked(Result<DossierEntryDisposition, AppModelTestError>)
    }

    private let summariesResult: Result<[DossierSummary], AppModelTestError>
    private var entrySteps: [EntryStep]
    private var blockedEntryStarted = false
    private var entryStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var entryReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        summaries: Result<[DossierSummary], AppModelTestError> = .success([]),
        entrySteps: [EntryStep] = []
    ) {
        summariesResult = summaries
        self.entrySteps = entrySteps
    }

    func summaries() async throws -> [DossierSummary] {
        try summariesResult.get()
    }

    func entryDisposition(for documentID: UUID) async throws -> DossierEntryDisposition {
        let step = entrySteps.isEmpty ? .disposition(.create) : entrySteps.removeFirst()
        switch step {
        case .disposition(let disposition):
            return disposition
        case .failure:
            throw AppModelTestError.dossierLoadFailed
        case .cancellation:
            throw CancellationError()
        case .blocked(let result):
            blockedEntryStarted = true
            entryStartWaiters.forEach { $0.resume() }
            entryStartWaiters.removeAll()
            await withCheckedContinuation { entryReleaseWaiters.append($0) }
            return try result.get()
        }
    }

    func snapshot(id: UUID) async throws -> DossierSnapshot {
        throw AppModelTestError.dossierLoadFailed
    }

    func waitUntilBlockedEntryStarts() async {
        guard !blockedEntryStarted else { return }
        await withCheckedContinuation { entryStartWaiters.append($0) }
    }

    func releaseBlockedEntry() {
        entryReleaseWaiters.forEach { $0.resume() }
        entryReleaseWaiters.removeAll()
    }
}

@MainActor
private struct DossierModelContext {
    let fixture: AppModelFixture
    let source: SourceRootRecord
    let firstDocument: DocumentRecord
    let secondDocument: DocumentRecord
    let service: ScriptedDossierService
    let model: AppModel

    static func make() async throws -> Self {
        let fixture = try AppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let firstDocument = fixture.document(
            sourceRootID: source.id,
            path: "first-invoice.pdf"
        )
        let secondDocument = fixture.document(
            sourceRootID: source.id,
            path: "second-invoice.pdf"
        )
        try await fixture.documents.save(firstDocument)
        try await fixture.documents.save(secondDocument)
        let statuses = MutableDocumentDNAStatusLoader(statusesBySource: [source.id: [
            DocumentDNAAnalysisStatus(documentID: firstDocument.id, phase: .ready),
            DocumentDNAAnalysisStatus(documentID: secondDocument.id, phase: .ready),
        ]])
        let snapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            firstDocument.id: [.snapshot(try testDocumentDNA(
                document: firstDocument,
                type: .invoice
            ))],
            secondDocument.id: [.snapshot(try testDocumentDNA(
                document: secondDocument,
                type: .invoice
            ))],
        ])
        let service = ScriptedDossierService()
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: statuses,
            dnaSnapshots: snapshots,
            dossierLoader: service,
            dossierMutator: service
        )
        try await model.reload()
        await model.selectDocument(id: firstDocument.id)
        return Self(
            fixture: fixture,
            source: source,
            firstDocument: firstDocument,
            secondDocument: secondDocument,
            service: service,
            model: model
        )
    }
}

private enum DossierMemberStatusBehavior {
    case ready
    case failure
    case cancellation
    case blockedThenReady
}

@MainActor
private struct DossierNavigationContext {
    let fixture: AppModelFixture
    let invoiceSource: SourceRootRecord
    let paymentSource: SourceRootRecord
    let invoice: DocumentRecord
    let payment: DocumentRecord
    let invoiceDNA: DocumentDNA
    let paymentDNA: DocumentDNA
    let annotatedCandidate: InvoicePaymentCandidateWithDecision
    let snapshot: DossierSnapshot
    let statuses: ScriptedDocumentDNAStatusLoader
    let model: AppModel

    static func make(
        crossSource: Bool,
        paymentStatusBehavior: DossierMemberStatusBehavior = .ready
    ) async throws -> Self {
        let fixture = try AppModelFixture()
        let invoiceSource = try await fixture.addSource(named: "Invoices")
        let paymentSource = crossSource
            ? try await fixture.addSource(named: "Payments")
            : invoiceSource
        let invoice = fixture.document(
            sourceRootID: invoiceSource.id,
            path: "invoice.pdf"
        )
        let payment = fixture.document(
            sourceRootID: paymentSource.id,
            path: "payment.pdf"
        )
        try await fixture.documents.save(invoice)
        try await fixture.documents.save(payment)
        let invoiceDNA = try testDocumentDNA(document: invoice, type: .invoice)
        let paymentDNA = try testDocumentDNA(
            document: payment,
            type: .paymentConfirmation
        )
        let candidate = try testInvoicePaymentCandidate(
            invoice: invoice,
            payment: payment
        )
        let annotatedCandidate = InvoicePaymentCandidateWithDecision(
            candidate: candidate,
            decision: .confirmed
        )
        let snapshot = try testDossierSnapshot(
            anchor: invoice,
            member: payment,
            support: DossierMembershipSupportIdentity(
                decisionKey: try InvoicePaymentDecisionKey(
                    relationshipType: .paymentSettlesInvoice,
                    invoiceDocumentID: invoice.id,
                    paymentDocumentID: payment.id,
                    invoiceContentHash: invoice.contentHash,
                    paymentContentHash: payment.contentHash
                ),
                decisionUpdatedAt: Date(timeIntervalSince1970: 400),
                invoiceDNAAnalyzedAt: invoiceDNA.analyzedAt,
                paymentDNAAnalyzedAt: paymentDNA.analyzedAt,
                resolverVersion: candidate.resolverVersion
            )
        )
        let invoiceStatus = DocumentDNAAnalysisStatus(
            documentID: invoice.id,
            phase: .ready
        )
        let paymentStatus = DocumentDNAAnalysisStatus(
            documentID: payment.id,
            phase: .ready
        )
        var stepsBySource: [UUID: [ScriptedDocumentDNAStatusLoader.Step]] = [
            invoiceSource.id: [.statuses(
                crossSource ? [invoiceStatus] : [invoiceStatus, paymentStatus]
            )],
        ]
        if crossSource {
            switch paymentStatusBehavior {
            case .ready:
                stepsBySource[paymentSource.id] = [.statuses([paymentStatus])]
            case .failure:
                stepsBySource[paymentSource.id] = [.failure]
            case .cancellation:
                stepsBySource[paymentSource.id] = [.cancellation]
            case .blockedThenReady:
                stepsBySource[paymentSource.id] = [
                    .blocked(.success([paymentStatus])),
                    .statuses([paymentStatus]),
                ]
            }
        }
        let statuses = ScriptedDocumentDNAStatusLoader(stepsBySource: stepsBySource)
        let dnaSnapshots = ScriptedDocumentDNASnapshotLoader(stepsByDocument: [
            invoice.id: [.snapshot(invoiceDNA)],
            payment.id: [.snapshot(paymentDNA)],
        ])
        let candidates = ScriptedInvoicePaymentCandidateLoader(stepsByDocument: [
            invoice.id: [.candidates([annotatedCandidate])],
            payment.id: [.candidates([annotatedCandidate])],
        ])
        let service = ScriptedDossierService()
        await service.setSummaries([try summary(for: snapshot)])
        await service.setSnapshotSteps([.result(snapshot)])
        let model = AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: FakeCatalogScanner(),
            ingestion: FakePendingIngester(),
            dnaStatuses: statuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidates,
            dossierLoader: service,
            dossierMutator: service
        )
        try await model.reload()
        await model.selectSource(id: invoiceSource.id)
        await model.selectDocument(id: invoice.id)
        await model.selectDossier(id: snapshot.dossier.id)
        return Self(
            fixture: fixture,
            invoiceSource: invoiceSource,
            paymentSource: paymentSource,
            invoice: invoice,
            payment: payment,
            invoiceDNA: invoiceDNA,
            paymentDNA: paymentDNA,
            annotatedCandidate: annotatedCandidate,
            snapshot: snapshot,
            statuses: statuses,
            model: model
        )
    }
}

private actor ScriptedDossierService: DossierLoading, DossierMutating {
    enum OpenStep: Sendable {
        case result(DossierOpenResult)
        case failure
        case cancellation
        case blocked(Result<DossierOpenResult, AppModelTestError>)
    }

    enum SnapshotStep: Sendable {
        case result(DossierSnapshot)
        case failure
        case cancellation
        case blocked(Result<DossierSnapshot, AppModelTestError>)
    }

    private var openSteps: [OpenStep] = []
    private var snapshotSteps: [SnapshotStep] = []
    private var summariesValue: [DossierSummary] = []
    private var blockedOperationStarted = false
    private var operationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var openInvocationCount = 0

    func setOpenSteps(_ steps: [OpenStep]) {
        openSteps = steps
    }

    func setSnapshotSteps(_ steps: [SnapshotStep]) {
        snapshotSteps = steps
    }

    func setSummaries(_ summaries: [DossierSummary]) {
        summariesValue = summaries
    }

    func summaries() async throws -> [DossierSummary] { summariesValue }

    func entryDisposition(for documentID: UUID) async throws -> DossierEntryDisposition {
        .create
    }

    func snapshot(id: UUID) async throws -> DossierSnapshot {
        let step = snapshotSteps.isEmpty ? .failure : snapshotSteps.removeFirst()
        switch step {
        case .result(let snapshot):
            return snapshot
        case .failure:
            throw AppModelTestError.dossierLoadFailed
        case .cancellation:
            throw CancellationError()
        case .blocked(let result):
            await blockOperation()
            return try result.get()
        }
    }

    func createOrOpen(anchorDocumentID: UUID) async throws -> DossierOpenResult {
        openInvocationCount += 1
        let step = openSteps.isEmpty ? .failure : openSteps.removeFirst()
        switch step {
        case .result(let result):
            return result
        case .failure:
            throw AppModelTestError.dossierLoadFailed
        case .cancellation:
            throw CancellationError()
        case .blocked(let result):
            await blockOperation()
            return try result.get()
        }
    }

    func excludeMember(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: DossierMembershipSupportIdentity
    ) async throws -> DossierSnapshot {
        throw AppModelTestError.dossierMutationFailed
    }

    func resetExclusion(
        dossierID: UUID,
        documentID: UUID,
        expectedRevisionID: UUID
    ) async throws -> DossierSnapshot {
        throw AppModelTestError.dossierMutationFailed
    }

    func waitUntilBlockedOperationStarts() async {
        guard !blockedOperationStarted else { return }
        await withCheckedContinuation { operationStartWaiters.append($0) }
    }

    func releaseBlockedOperation() {
        operationReleaseWaiters.forEach { $0.resume() }
        operationReleaseWaiters.removeAll()
        blockedOperationStarted = false
    }

    private func blockOperation() async {
        blockedOperationStarted = true
        operationStartWaiters.forEach { $0.resume() }
        operationStartWaiters.removeAll()
        await withCheckedContinuation { operationReleaseWaiters.append($0) }
    }
}

private func testDocumentDNA(
    document: DocumentRecord,
    type: DocumentType = .unknown
) throws -> DocumentDNA {
    let displayValue = type == .unknown ? "" : type.rawValue
    let evidence = type == .unknown ? [] : [try DocumentDNAEvidence(
        pageIndex: 0,
        startUTF16: 0,
        lengthUTF16: displayValue.utf16.count,
        exactText: displayValue,
        ocrRegionIndexes: []
    )]
    let classification = try DocumentDNAFinding(
        kind: .documentType,
        qualifier: nil,
        displayValue: displayValue,
        normalizedValue: type.rawValue,
        secondaryNormalizedValue: nil,
        confidence: type == .unknown ? 0 : 0.9,
        evidence: evidence
    )
    return try DocumentDNA(
        documentID: document.id,
        schemaVersion: 1,
        analyzerIdentifier: "local-rules",
        analyzerVersion: "1",
        inputContentHash: document.contentHash,
        inputExtractionVersion: "text-v1",
        findings: [classification],
        analyzedAt: Date(timeIntervalSince1970: 300)
    )
}

private func testDossierSummary(anchor: DocumentRecord) throws -> DossierSummary {
    DossierSummary(
        dossier: try DossierRecord(
            id: UUID(),
            kind: .costsAndPayments,
            displayName: "Kosten und Zahlungen",
            anchorDocumentID: anchor.id,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        ),
        anchor: anchor
    )
}

private func testDossierSnapshot(
    anchor: DocumentRecord,
    dossierID: UUID = UUID()
) throws -> DossierSnapshot {
    let dossier = try DossierRecord(
        id: dossierID,
        kind: .costsAndPayments,
        displayName: "Kosten und Zahlungen",
        anchorDocumentID: anchor.id,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    return DossierSnapshot(
        dossier: dossier,
        members: [DossierMember(
            document: anchor,
            sourceDisplayName: "Archive",
            documentType: .invoice,
            explanation: DossierMembershipExplanation(
                role: .anchor,
                relationshipType: nil,
                signals: []
            ),
            support: nil
        )],
        corrections: [],
        token: DossierProjectionToken(
            dossierUpdatedAt: dossier.updatedAt,
            anchorContentHash: anchor.contentHash,
            memberSupports: [],
            exclusionRevisionIDs: []
        )
    )
}

private func testDossierSnapshot(
    anchor: DocumentRecord,
    member: DocumentRecord,
    support: DossierMembershipSupportIdentity,
    dossierID: UUID = UUID()
) throws -> DossierSnapshot {
    let base = try testDossierSnapshot(anchor: anchor, dossierID: dossierID)
    return DossierSnapshot(
        dossier: base.dossier,
        members: base.members + [DossierMember(
            document: member,
            sourceDisplayName: "Payments",
            documentType: .paymentConfirmation,
            explanation: DossierMembershipExplanation(
                role: .payment,
                relationshipType: .paymentSettlesInvoice,
                signals: []
            ),
            support: support
        )],
        corrections: [],
        token: DossierProjectionToken(
            dossierUpdatedAt: base.dossier.updatedAt,
            anchorContentHash: anchor.contentHash,
            memberSupports: [support],
            exclusionRevisionIDs: []
        )
    )
}

private func summary(for snapshot: DossierSnapshot) throws -> DossierSummary {
    let anchor = try #require(snapshot.members.first(where: {
        $0.document.id == snapshot.dossier.anchorDocumentID
    }))
    return DossierSummary(dossier: snapshot.dossier, anchor: anchor.document)
}

private func testInvoicePaymentCandidate(
    invoice: DocumentRecord,
    payment: DocumentRecord
) throws -> InvoicePaymentCandidate {
    try InvoicePaymentCandidate(
        invoice: CurrentDocumentDNA(
            document: invoice,
            snapshot: testDocumentDNA(document: invoice)
        ),
        payment: CurrentDocumentDNA(
            document: payment,
            snapshot: testDocumentDNA(document: payment)
        ),
        disposition: .automatic,
        resolverVersion: "invoice-payment-v1",
        signals: []
    )
}

private struct FakeSourceAccess: SourceAccessing {
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
        try await operation(URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)))
    }
}

private final class AppStaleBookmarkSourceAccess: SourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let accessGate: AppSourceAccessGate?
    private var nextBookmarkID = 0
    private var bookmarkedURLs: [Data: URL] = [:]
    private var staleBookmarks = Set<Data>()
    private var failingBookmarks = Set<Data>()

    init(blockAccess: Bool = false) {
        accessGate = blockAccess ? AppSourceAccessGate() : nil
    }

    func waitUntilAccessCount(_ expectedCount: Int) async {
        await accessGate?.waitUntilAccessCount(expectedCount)
    }

    func releaseAccess() async {
        await accessGate?.release()
    }

    func markStale(_ bookmark: Data, resolvingTo url: URL) {
        lock.withLock {
            bookmarkedURLs[bookmark] = url
            staleBookmarks.insert(bookmark)
        }
    }

    func failResolution(of bookmark: Data) {
        _ = lock.withLock { failingBookmarks.insert(bookmark) }
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
            if failingBookmarks.contains(bookmark) {
                throw CocoaError(.fileReadNoPermission)
            }
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
        await accessGate?.waitUntilReleased()
        return try await operation(resolve(bookmark).url)
    }
}

private actor AppSourceAccessGate {
    private var accessCount = 0
    private var isReleased = false
    private var accessCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilAccessCount(_ expectedCount: Int) async {
        guard accessCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            accessCountWaiters.append((expectedCount, continuation))
        }
    }

    func waitUntilReleased() async {
        accessCount += 1
        let readyWaiters = accessCountWaiters.filter { $0.0 <= accessCount }
        accessCountWaiters.removeAll { $0.0 <= accessCount }
        readyWaiters.forEach { $0.1.resume() }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum AppModelTestError: Error, Sendable {
    case scanFailed
    case documentLoadFailed
    case documentDNAStatusLoadFailed
    case documentDNASnapshotLoadFailed
    case invoicePaymentCandidateLoadFailed
    case invoicePaymentDecisionUpdateFailed
    case dossierLoadFailed
    case dossierMutationFailed
    case unusedSourceResolution
    case timeout
}
