import Foundation
import Testing
@testable import LinkLoomApp
@testable import LinkLoomCore

@Suite("App composition")
struct AppCompositionTests {
    @Test func dossierServiceLoadsSummariesExactlyOnce() async throws {
        let expected = try dossierSummary()
        let calls = CallCounter()
        let service = dossierService(
            summaries: {
                await calls.increment()
                return [expected]
            }
        )

        let result = try await service.summaries()

        #expect(result == [expected])
        #expect(await calls.count == 1)
    }

    @Test func dossierServiceLoadsEntryDispositionForExactDocument() async throws {
        let documentID = UUID(uuidString: "00000000-0000-0000-0000-000000000611")!
        let recorder = DossierServiceRecorder()
        let service = dossierService(entry: { id in
            await recorder.recordEntry(id)
            return .create
        })

        let result = try await service.entryDisposition(for: documentID)

        #expect(result == .create)
        #expect(await recorder.entryIDs == [documentID])
    }

    @Test func dossierServiceLoadsSnapshotForExactDossier() async throws {
        let expected = try dossierSnapshot()
        let recorder = DossierServiceRecorder()
        let service = dossierService(snapshot: { id in
            await recorder.recordSnapshot(id)
            return expected
        })

        let result = try await service.snapshot(id: expected.dossier.id)

        #expect(result == expected)
        #expect(await recorder.snapshotIDs == [expected.dossier.id])
    }

    @Test func dossierServiceCreatesOrOpensForExactAnchorOnce() async throws {
        let expected = try dossierSnapshot()
        let recorder = DossierServiceRecorder()
        let service = dossierService(createOrOpen: { id in
            await recorder.recordOpen(id)
            return .opened(expected)
        })

        let result = try await service.createOrOpen(
            anchorDocumentID: expected.dossier.anchorDocumentID
        )

        #expect(result == .opened(expected))
        #expect(await recorder.openIDs == [expected.dossier.anchorDocumentID])
    }

    @Test func dossierServiceExcludesWithExactSupportOnce() async throws {
        let expected = try dossierSnapshot()
        let support = try dossierSupport()
        let documentID = UUID(uuidString: "00000000-0000-0000-0000-000000000612")!
        let recorder = DossierServiceRecorder()
        let service = dossierService(exclude: { dossierID, memberID, value in
            await recorder.recordExclusion(dossierID, memberID, value)
            return expected
        })

        let result = try await service.excludeMember(
            dossierID: expected.dossier.id,
            documentID: documentID,
            expectedSupport: support
        )

        #expect(result == expected)
        #expect(await recorder.exclusionDossierIDs == [expected.dossier.id])
        #expect(await recorder.exclusionDocumentIDs == [documentID])
        #expect(await recorder.exclusionSupports == [support])
    }

    @Test func dossierServiceResetsExactRevisionOnce() async throws {
        let expected = try dossierSnapshot()
        let documentID = UUID(uuidString: "00000000-0000-0000-0000-000000000613")!
        let revisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000614")!
        let recorder = DossierServiceRecorder()
        let service = dossierService(reset: { dossierID, memberID, revision in
            await recorder.recordReset(dossierID, memberID, revision)
            return expected
        })

        let result = try await service.resetExclusion(
            dossierID: expected.dossier.id,
            documentID: documentID,
            expectedRevisionID: revisionID
        )

        #expect(result == expected)
        #expect(await recorder.resetDossierIDs == [expected.dossier.id])
        #expect(await recorder.resetDocumentIDs == [documentID])
        #expect(await recorder.resetRevisionIDs == [revisionID])
    }

    @Test func dossierServicePropagatesRepositoryFailureUnchanged() async {
        let service = dossierService(snapshot: { _ in
            throw CompositionTestError.dossierFailed
        })

        await #expect(throws: CompositionTestError.dossierFailed) {
            try await service.snapshot(id: UUID())
        }
    }

    @Test func dossierServiceHonorsCancellationBeforeEveryMutation() async throws {
        let mutationCalls = CallCounter()
        let service = dossierService(
            createOrOpen: { _ in
                await mutationCalls.increment()
                throw CompositionTestError.dossierFailed
            },
            exclude: { _, _, _ in
                await mutationCalls.increment()
                throw CompositionTestError.dossierFailed
            },
            reset: { _, _, _ in
                await mutationCalls.increment()
                throw CompositionTestError.dossierFailed
            }
        )
        let support = try dossierSupport()

        let opening = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.createOrOpen(anchorDocumentID: UUID())
        }
        let excluding = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.excludeMember(
                dossierID: UUID(),
                documentID: UUID(),
                expectedSupport: support
            )
        }
        let resetting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.resetExclusion(
                dossierID: UUID(),
                documentID: UUID(),
                expectedRevisionID: UUID()
            )
        }

        await #expect(throws: CancellationError.self) { try await opening.value }
        await #expect(throws: CancellationError.self) { try await excluding.value }
        await #expect(throws: CancellationError.self) { try await resetting.value }
        #expect(await mutationCalls.count == 0)
    }

    @Test func decisionUpdaterSavesExactCandidateKeyDecisionAndTimestamp() async throws {
        let recorder = DecisionUpdaterRecorder()
        let timestamp = Date(timeIntervalSince1970: 123)
        let updater = CurrentInvoicePaymentDecisionUpdater(
            saveDecision: { record in await recorder.recordSave(record) },
            deleteDecision: { key in await recorder.recordDelete(key) },
            now: { timestamp }
        )

        try await updater.update(
            candidate: invoicePaymentCandidate(suffix: 7),
            command: .set(.excluded)
        )

        let expectedKey = try InvoicePaymentDecisionKey(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000407"
            )!,
            paymentDocumentID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000507"
            )!,
            invoiceContentHash: "hash-invoice-7.pdf",
            paymentContentHash: "hash-payment-7.pdf"
        )
        #expect(await recorder.savedRecords == [
            InvoicePaymentDecisionRecord(
                key: expectedKey,
                decision: .excluded,
                updatedAt: timestamp
            ),
        ])
        #expect(await recorder.deletedKeys.isEmpty)
    }

    @Test func decisionUpdaterResetDeletesExactCandidateKeyWithoutSaving() async throws {
        let recorder = DecisionUpdaterRecorder()
        let updater = CurrentInvoicePaymentDecisionUpdater(
            saveDecision: { record in await recorder.recordSave(record) },
            deleteDecision: { key in await recorder.recordDelete(key) },
            now: { Date(timeIntervalSince1970: 123) }
        )

        try await updater.update(
            candidate: invoicePaymentCandidate(suffix: 8),
            command: .reset
        )

        let expectedKey = try InvoicePaymentDecisionKey(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000408"
            )!,
            paymentDocumentID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000508"
            )!,
            invoiceContentHash: "hash-invoice-8.pdf",
            paymentContentHash: "hash-payment-8.pdf"
        )
        #expect(await recorder.savedRecords.isEmpty)
        #expect(await recorder.deletedKeys == [expectedKey])
    }

    @Test func decisionUpdaterHonorsCancellationBeforeRepositoryMutation() async {
        let recorder = DecisionUpdaterRecorder()
        let updater = CurrentInvoicePaymentDecisionUpdater(
            saveDecision: { record in await recorder.recordSave(record) },
            deleteDecision: { key in await recorder.recordDelete(key) },
            now: { Date(timeIntervalSince1970: 123) }
        )
        let updating = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            try await updater.update(
                candidate: invoicePaymentCandidate(suffix: 9),
                command: .set(.confirmed)
            )
        }

        await #expect(throws: CancellationError.self) {
            try await updating.value
        }
        #expect(await recorder.savedRecords.isEmpty)
        #expect(await recorder.deletedKeys.isEmpty)
    }

    @Test func decisionUpdaterPropagatesRepositoryFailureUnchanged() async throws {
        let updater = CurrentInvoicePaymentDecisionUpdater(
            saveDecision: { _ in throw CompositionTestError.decisionUpdateFailed },
            deleteDecision: { _ in },
            now: { Date(timeIntervalSince1970: 123) }
        )

        await #expect(throws: CompositionTestError.decisionUpdateFailed) {
            try await updater.update(
                candidate: invoicePaymentCandidate(suffix: 10),
                command: .set(.confirmed)
            )
        }
    }

    @Test func candidateLoaderAnnotatesOneCompleteBatchAndPreservesOrder() async throws {
        let first = try invoicePaymentCandidate(suffix: 1)
        let second = try invoicePaymentCandidate(suffix: 2)
        let third = try invoicePaymentCandidate(suffix: 3)
        let candidates = [first, second, third]
        let expected = [
            InvoicePaymentCandidateWithDecision(candidate: first, decision: .confirmed),
            InvoicePaymentCandidateWithDecision(candidate: second, decision: .undecided),
            InvoicePaymentCandidateWithDecision(candidate: third, decision: .excluded),
        ]
        let recorder = CandidateLoaderRecorder()
        let selectedDocumentID = first.invoice.document.id
        let loader = CurrentInvoicePaymentCandidateLoader(
            lookupCandidates: { documentID in
                await recorder.recordLookup(documentID: documentID)
                return candidates
            },
            annotateCandidates: { batch in
                await recorder.recordAnnotation(batch: batch)
                return expected
            }
        )

        let annotated = try await loader.candidates(involving: selectedDocumentID)

        #expect(annotated == expected)
        #expect(await recorder.lookupDocumentIDs == [selectedDocumentID])
        #expect(await recorder.annotationBatches == [candidates])
    }

    @Test func candidateLoaderHonorsCancellationBetweenLookupAndAnnotation() async {
        let annotationCalls = CallCounter()
        let loader = CurrentInvoicePaymentCandidateLoader(
            lookupCandidates: { _ in
                withUnsafeCurrentTask { task in task?.cancel() }
                return []
            },
            annotateCandidates: { _ in
                await annotationCalls.increment()
                return []
            }
        )
        let loading = Task {
            try await loader.candidates(involving: UUID())
        }

        await #expect(throws: CancellationError.self) {
            try await loading.value
        }
        #expect(await annotationCalls.count == 0)
    }

    @Test func candidateLoaderPropagatesLookupFailureWithoutAnnotation() async {
        let annotationCalls = CallCounter()
        let loader = CurrentInvoicePaymentCandidateLoader(
            lookupCandidates: { _ in throw CompositionTestError.candidateLookupFailed },
            annotateCandidates: { _ in
                await annotationCalls.increment()
                return []
            }
        )

        await #expect(throws: CompositionTestError.candidateLookupFailed) {
            try await loader.candidates(involving: UUID())
        }
        #expect(await annotationCalls.count == 0)
    }

    @Test func candidateLoaderPropagatesBatchAnnotationFailure() async throws {
        let candidate = try invoicePaymentCandidate(suffix: 1)
        let loader = CurrentInvoicePaymentCandidateLoader(
            lookupCandidates: { _ in [candidate] },
            annotateCandidates: { _ in
                throw CompositionTestError.decisionAnnotationFailed
            }
        )

        await #expect(throws: CompositionTestError.decisionAnnotationFailed) {
            try await loader.candidates(involving: UUID())
        }
    }

    @Test func localProcessorRunsTextIngestionBeforeDNAAnalysis() async throws {
        let events = EventRecorder()
        let source = sourceRecord()
        let processor = LocalDocumentProcessor(
            ingest: { source in
                await events.append("ingest:\(source.id)")
            },
            analyzeDNA: { sourceID in
                await events.append("dna:\(sourceID)")
            }
        )

        try await processor.processPending(source: source)

        #expect(await events.snapshot() == [
            "ingest:\(source.id)",
            "dna:\(source.id)",
        ])
    }

    @Test func localProcessorDoesNotAnalyzeWhenTextIngestionFails() async {
        let dnaCalls = CallCounter()
        let processor = LocalDocumentProcessor(
            ingest: { _ in throw CompositionTestError.ingestionFailed },
            analyzeDNA: { _ in await dnaCalls.increment() }
        )

        await #expect(throws: CompositionTestError.ingestionFailed) {
            try await processor.processPending(source: sourceRecord())
        }
        #expect(await dnaCalls.count == 0)
    }

    @Test func localProcessorPropagatesDNAFailure() async {
        let processor = LocalDocumentProcessor(
            ingest: { _ in },
            analyzeDNA: { _ in throw CompositionTestError.dnaFailed }
        )

        await #expect(throws: CompositionTestError.dnaFailed) {
            try await processor.processPending(source: sourceRecord())
        }
    }

    @Test func localProcessorHonorsCancellationBetweenStages() async {
        let dnaCalls = CallCounter()
        let processor = LocalDocumentProcessor(
            ingest: { _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            },
            analyzeDNA: { _ in await dnaCalls.increment() }
        )

        let processing = Task {
            try await processor.processPending(source: sourceRecord())
        }

        await #expect(throws: CancellationError.self) {
            try await processing.value
        }
        #expect(await dnaCalls.count == 0)
    }

    @Test func localDNARetryerClearsExactFailureBeforeProcessingSourceQueue() async throws {
        let events = EventRecorder()
        let documentID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let retryer = LocalDocumentDNAFailureRetryer(
            clearFailedAnalysis: { id in await events.append("clear:\(id)") },
            processPending: { id in await events.append("process:\(id)") }
        )

        try await retryer.retryFailedAnalysis(
            documentID: documentID,
            sourceRootID: sourceID
        )

        #expect(await events.snapshot() == [
            "clear:\(documentID)",
            "process:\(sourceID)",
        ])
    }

    @Test func localDNARetryerDoesNotProcessWhenClearingFailureFails() async {
        let processCalls = CallCounter()
        let retryer = LocalDocumentDNAFailureRetryer(
            clearFailedAnalysis: { _ in throw CompositionTestError.dnaFailed },
            processPending: { _ in await processCalls.increment() }
        )

        await #expect(throws: CompositionTestError.dnaFailed) {
            try await retryer.retryFailedAnalysis(
                documentID: UUID(),
                sourceRootID: UUID()
            )
        }
        #expect(await processCalls.count == 0)
    }

    @Test func localDNARetryerHonorsCancellationBetweenStages() async {
        let processCalls = CallCounter()
        let retryer = LocalDocumentDNAFailureRetryer(
            clearFailedAnalysis: { _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            },
            processPending: { _ in await processCalls.increment() }
        )
        let retry = Task {
            try await retryer.retryFailedAnalysis(
                documentID: UUID(),
                sourceRootID: UUID()
            )
        }

        await #expect(throws: CancellationError.self) {
            try await retry.value
        }
        #expect(await processCalls.count == 0)
    }

    @Test func incrementalRescanRunsCatalogThenTextThenDNA() async throws {
        let events = EventRecorder()
        let source = sourceRecord()
        let processor = LocalDocumentProcessor(
            ingest: { _ in await events.append("ingest") },
            analyzeDNA: { _ in await events.append("dna") }
        )
        let rescanner = IncrementalRescanner(
            scanCatalog: { _ in await events.append("catalog") },
            processDocuments: { source in
                try await processor.processPending(source: source)
            }
        )

        try await rescanner.rescan(source: source)

        #expect(await events.snapshot() == ["catalog", "ingest", "dna"])
    }

    @Test func incrementalRescanHonorsCancellationAfterCatalog() async {
        let documentProcessingCalls = CallCounter()
        let rescanner = IncrementalRescanner(
            scanCatalog: { _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            },
            processDocuments: { _ in
                await documentProcessingCalls.increment()
            }
        )

        let rescanning = Task {
            try await rescanner.rescan(source: sourceRecord())
        }

        await #expect(throws: CancellationError.self) {
            try await rescanning.value
        }
        #expect(await documentProcessingCalls.count == 0)
    }

    @Test func incrementalRescanPropagatesDNAFailure() async {
        let events = EventRecorder()
        let processor = LocalDocumentProcessor(
            ingest: { _ in await events.append("ingest") },
            analyzeDNA: { _ in
                await events.append("dna")
                throw CompositionTestError.dnaFailed
            }
        )
        let rescanner = IncrementalRescanner(
            scanCatalog: { _ in await events.append("catalog") },
            processDocuments: { source in
                try await processor.processPending(source: source)
            }
        )

        await #expect(throws: CompositionTestError.dnaFailed) {
            try await rescanner.rescan(source: sourceRecord())
        }
        #expect(await events.snapshot() == ["catalog", "ingest", "dna"])
    }
}

private enum CompositionTestError: Error {
    case ingestionFailed
    case dnaFailed
    case candidateLookupFailed
    case decisionAnnotationFailed
    case decisionUpdateFailed
    case dossierFailed
}

private actor DossierServiceRecorder {
    private(set) var entryIDs: [UUID] = []
    private(set) var snapshotIDs: [UUID] = []
    private(set) var openIDs: [UUID] = []
    private(set) var exclusionDossierIDs: [UUID] = []
    private(set) var exclusionDocumentIDs: [UUID] = []
    private(set) var exclusionSupports: [DossierMembershipSupportIdentity] = []
    private(set) var resetDossierIDs: [UUID] = []
    private(set) var resetDocumentIDs: [UUID] = []
    private(set) var resetRevisionIDs: [UUID] = []

    func recordEntry(_ id: UUID) { entryIDs.append(id) }
    func recordSnapshot(_ id: UUID) { snapshotIDs.append(id) }
    func recordOpen(_ id: UUID) { openIDs.append(id) }

    func recordExclusion(
        _ dossierID: UUID,
        _ documentID: UUID,
        _ support: DossierMembershipSupportIdentity
    ) {
        exclusionDossierIDs.append(dossierID)
        exclusionDocumentIDs.append(documentID)
        exclusionSupports.append(support)
    }

    func recordReset(_ dossierID: UUID, _ documentID: UUID, _ revisionID: UUID) {
        resetDossierIDs.append(dossierID)
        resetDocumentIDs.append(documentID)
        resetRevisionIDs.append(revisionID)
    }
}

private actor DecisionUpdaterRecorder {
    private(set) var savedRecords: [InvoicePaymentDecisionRecord] = []
    private(set) var deletedKeys: [InvoicePaymentDecisionKey] = []

    func recordSave(_ record: InvoicePaymentDecisionRecord) {
        savedRecords.append(record)
    }

    func recordDelete(_ key: InvoicePaymentDecisionKey) {
        deletedKeys.append(key)
    }
}

private actor CandidateLoaderRecorder {
    private(set) var lookupDocumentIDs: [UUID] = []
    private(set) var annotationBatches: [[InvoicePaymentCandidate]] = []

    func recordLookup(documentID: UUID) {
        lookupDocumentIDs.append(documentID)
    }

    func recordAnnotation(batch: [InvoicePaymentCandidate]) {
        annotationBatches.append(batch)
    }
}

private actor EventRecorder {
    private var recordedValues: [String] = []

    func append(_ value: String) {
        recordedValues.append(value)
    }

    func snapshot() -> [String] {
        recordedValues
    }
}

private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func dossierService(
    summaries: @escaping @Sendable () async throws -> [DossierSummary] = { [] },
    entry: @escaping @Sendable (UUID) async throws -> DossierEntryDisposition = { _ in
        .create
    },
    snapshot: @escaping @Sendable (UUID) async throws -> DossierSnapshot = { _ in
        throw CompositionTestError.dossierFailed
    },
    createOrOpen: @escaping @Sendable (UUID) async throws -> DossierOpenResult = { _ in
        throw CompositionTestError.dossierFailed
    },
    exclude: @escaping @Sendable (
        UUID, UUID, DossierMembershipSupportIdentity
    ) async throws -> DossierSnapshot = { _, _, _ in
        throw CompositionTestError.dossierFailed
    },
    reset: @escaping @Sendable (UUID, UUID, UUID) async throws -> DossierSnapshot = {
        _, _, _ in throw CompositionTestError.dossierFailed
    }
) -> CurrentDossierService {
    CurrentDossierService(
        summaries: summaries,
        entry: entry,
        snapshot: snapshot,
        createOrOpen: createOrOpen,
        exclude: exclude,
        reset: reset
    )
}

private func dossierSummary() throws -> DossierSummary {
    let anchor = candidateDocument(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
        sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!,
        path: "invoice.pdf"
    )
    return DossierSummary(
        dossier: try DossierRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000603")!,
            kind: .costsAndPayments,
            displayName: "Kosten und Zahlungen",
            anchorDocumentID: anchor.id,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        ),
        anchor: anchor
    )
}

private func dossierSnapshot() throws -> DossierSnapshot {
    let summary = try dossierSummary()
    return DossierSnapshot(
        dossier: summary.dossier,
        members: [DossierMember(
            document: summary.anchor,
            sourceDisplayName: "Rechnungen",
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
            dossierUpdatedAt: summary.dossier.updatedAt,
            anchorContentHash: summary.anchor.contentHash,
            memberSupports: [],
            exclusionRevisionIDs: []
        )
    )
}

private func dossierSupport() throws -> DossierMembershipSupportIdentity {
    DossierMembershipSupportIdentity(
        decisionKey: try InvoicePaymentDecisionKey(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000601"
            )!,
            paymentDocumentID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000604"
            )!,
            invoiceContentHash: "hash-invoice.pdf",
            paymentContentHash: "hash-payment.pdf"
        ),
        decisionUpdatedAt: Date(timeIntervalSince1970: 11),
        invoiceDNAAnalyzedAt: Date(timeIntervalSince1970: 12),
        paymentDNAAnalyzedAt: Date(timeIntervalSince1970: 13),
        resolverVersion: "1"
    )
}

private func sourceRecord() -> SourceRootRecord {
    SourceRootRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        displayName: "Archive",
        pathHint: "/tmp/archive",
        bookmarkData: Data([0x01]),
        createdAt: Date(timeIntervalSince1970: 1)
    )
}

private func invoicePaymentCandidate(suffix: UInt8) throws -> InvoicePaymentCandidate {
    let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    let invoice = candidateDocument(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, suffix)),
        sourceID: sourceID,
        path: "invoice-\(suffix).pdf"
    )
    let payment = candidateDocument(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, suffix)),
        sourceID: sourceID,
        path: "payment-\(suffix).pdf"
    )
    return InvoicePaymentCandidate(
        invoice: try CurrentDocumentDNA(
            document: invoice,
            snapshot: candidateSnapshot(document: invoice)
        ),
        payment: try CurrentDocumentDNA(
            document: payment,
            snapshot: candidateSnapshot(document: payment)
        ),
        disposition: .automatic,
        resolverVersion: InvoicePaymentCandidateResolver.version,
        signals: []
    )
}

private func candidateDocument(id: UUID, sourceID: UUID, path: String) -> DocumentRecord {
    DocumentRecord(
        id: id,
        sourceRootID: sourceID,
        relativePath: path,
        contentHash: "hash-\(path)",
        byteCount: 1,
        modifiedAt: Date(timeIntervalSince1970: 1),
        mediaType: .pdf,
        status: .ready,
        availability: .available,
        pageCount: 1,
        lastSeenAt: Date(timeIntervalSince1970: 1),
        lastFingerprintAt: Date(timeIntervalSince1970: 1)
    )
}

private func candidateSnapshot(document: DocumentRecord) throws -> DocumentDNA {
    try DocumentDNA(
        documentID: document.id,
        schemaVersion: 1,
        analyzerIdentifier: "local-rules",
        analyzerVersion: "1",
        inputContentHash: document.contentHash,
        inputExtractionVersion: "text-v1",
        findings: [try DocumentDNAFinding(
            kind: .documentType,
            qualifier: nil,
            displayValue: "",
            normalizedValue: DocumentType.unknown.rawValue,
            secondaryNormalizedValue: nil,
            confidence: 0,
            evidence: []
        )],
        analyzedAt: Date(timeIntervalSince1970: 1)
    )
}
