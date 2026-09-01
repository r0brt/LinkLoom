import Foundation
import Testing
@testable import LinkLoomApp
@testable import LinkLoomCore

@Suite("App composition")
struct AppCompositionTests {
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
