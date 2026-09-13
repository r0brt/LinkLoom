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

        let anchorDocumentID = try #require(expected.dossier.documentAnchorID)
        let result = try await service.createOrOpen(anchorDocumentID: anchorDocumentID)

        #expect(result == .opened(expected))
        #expect(await recorder.openIDs == [anchorDocumentID])
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

    @Test func personDossierServiceForwardsReadsExactlyOnce() async throws {
        let values = try PersonCompositionValues.make()
        let recorder = PersonDossierServiceRecorder()
        let service = personDossierService(
            summaries: {
                await recorder.recordSummaries()
                return [values.summary]
            },
            snapshot: { id in
                await recorder.recordSnapshot(id)
                return values.snapshot
            }
        )

        #expect(try await service.personDossierSummaries() == [values.summary])
        #expect(try await service.personDossierSnapshot(id: values.summary.id) == values.snapshot)
        #expect(await recorder.summaryCalls == 1)
        #expect(await recorder.snapshotIDs == [values.summary.id])
    }

    @Test func personDossierServiceForwardsEveryExactMutationInput() async throws {
        let values = try PersonCompositionValues.make()
        let recorder = PersonDossierServiceRecorder()
        let service = personDossierService(recorder: recorder, returning: values.snapshot)

        _ = try await service.createOrOpenPersonDossier(from: values.selection)
        _ = try await service.chooseOrCreatePersonDossier(
            from: values.selection,
            choice: .new
        )
        _ = try await service.acceptPersonSuggestion(
            dossierID: values.snapshot.dossier.id,
            documentID: values.suggestion.id,
            expectedSupport: values.suggestion.commandSupport,
            expectedToken: values.snapshot.token
        )
        _ = try await service.rejectPersonSuggestion(
            dossierID: values.snapshot.dossier.id,
            documentID: values.suggestion.id,
            expectedSupport: values.suggestion.commandSupport,
            expectedToken: values.snapshot.token
        )
        _ = try await service.removePersonMember(
            dossierID: values.snapshot.dossier.id,
            documentID: values.member.id,
            expectedSupport: try values.member.commandSupport,
            expectedToken: values.snapshot.token
        )
        _ = try await service.resetPersonCorrection(
            dossierID: values.snapshot.dossier.id,
            documentID: values.correction.id,
            expectedDecision: values.correction.decision,
            expectedToken: values.snapshot.token
        )

        #expect(await recorder.openSelections == [values.selection])
        #expect(await recorder.choices == [.new])
        #expect(await recorder.acceptedSupports == [values.suggestion.commandSupport])
        #expect(await recorder.rejectedSupports == [values.suggestion.commandSupport])
        #expect(await recorder.removedSupports == [try values.member.commandSupport])
        #expect(await recorder.resetDecisions == [values.correction.decision])
        #expect(await recorder.tokens == Array(repeating: values.snapshot.token, count: 4))
    }

    @Test func personDossierServiceHonorsCancellationBeforeEveryMutation() async throws {
        let values = try PersonCompositionValues.make()
        let recorder = PersonDossierServiceRecorder()
        let service = personDossierService(recorder: recorder, returning: values.snapshot)
        let memberSupport = try values.member.commandSupport
        let mutations: [@Sendable () async throws -> Void] = [
            {
                let operation = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    _ = try await service.createOrOpenPersonDossier(from: values.selection)
                }
                try await operation.value
            },
            {
                let operation = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    _ = try await service.chooseOrCreatePersonDossier(
                        from: values.selection,
                        choice: .new
                    )
                }
                try await operation.value
            },
            {
                let operation = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    _ = try await service.acceptPersonSuggestion(
                        dossierID: values.snapshot.dossier.id,
                        documentID: values.suggestion.id,
                        expectedSupport: values.suggestion.commandSupport,
                        expectedToken: values.snapshot.token
                    )
                }
                try await operation.value
            },
            {
                let operation = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    _ = try await service.rejectPersonSuggestion(
                        dossierID: values.snapshot.dossier.id,
                        documentID: values.suggestion.id,
                        expectedSupport: values.suggestion.commandSupport,
                        expectedToken: values.snapshot.token
                    )
                }
                try await operation.value
            },
            {
                let operation = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    _ = try await service.removePersonMember(
                        dossierID: values.snapshot.dossier.id,
                        documentID: values.member.id,
                        expectedSupport: memberSupport,
                        expectedToken: values.snapshot.token
                    )
                }
                try await operation.value
            },
            {
                let operation = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    _ = try await service.resetPersonCorrection(
                        dossierID: values.snapshot.dossier.id,
                        documentID: values.correction.id,
                        expectedDecision: values.correction.decision,
                        expectedToken: values.snapshot.token
                    )
                }
                try await operation.value
            },
        ]

        for mutation in mutations {
            await #expect(throws: CancellationError.self) {
                try await mutation()
            }
        }
        #expect(await recorder.mutationCallCount == 0)
    }

    @Test func personDossierServicePropagatesRepositoryFailuresUnchanged() async throws {
        let values = try PersonCompositionValues.make()
        let service = personDossierService(
            summaries: { throw CompositionTestError.dossierFailed },
            accept: { _, _, _, _ in throw CompositionTestError.dossierFailed }
        )

        await #expect(throws: CompositionTestError.dossierFailed) {
            try await service.personDossierSummaries()
        }
        await #expect(throws: CompositionTestError.dossierFailed) {
            try await service.acceptPersonSuggestion(
                dossierID: values.snapshot.dossier.id,
                documentID: values.suggestion.id,
                expectedSupport: values.suggestion.commandSupport,
                expectedToken: values.snapshot.token
            )
        }
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

private actor PersonDossierServiceRecorder {
    private(set) var summaryCalls = 0
    private(set) var snapshotIDs: [UUID] = []
    private(set) var openSelections: [PersonDossierAnchorSelection] = []
    private(set) var choices: [PersonDossierCreationChoice] = []
    private(set) var acceptedSupports: [PersonDossierCandidateSupportIdentity] = []
    private(set) var rejectedSupports: [PersonDossierCandidateSupportIdentity] = []
    private(set) var removedSupports: [PersonDossierMembershipSupport] = []
    private(set) var resetDecisions: [PersonDossierCorrectionDecision] = []
    private(set) var tokens: [PersonDossierProjectionToken] = []

    var mutationCallCount: Int {
        openSelections.count + choices.count + acceptedSupports.count + rejectedSupports.count
            + removedSupports.count + resetDecisions.count
    }

    func recordSummaries() { summaryCalls += 1 }
    func recordSnapshot(_ id: UUID) { snapshotIDs.append(id) }
    func recordOpen(_ selection: PersonDossierAnchorSelection) { openSelections.append(selection) }
    func recordChoice(_ choice: PersonDossierCreationChoice) { choices.append(choice) }

    func recordAccept(
        _ support: PersonDossierCandidateSupportIdentity,
        token: PersonDossierProjectionToken
    ) {
        acceptedSupports.append(support)
        tokens.append(token)
    }

    func recordReject(
        _ support: PersonDossierCandidateSupportIdentity,
        token: PersonDossierProjectionToken
    ) {
        rejectedSupports.append(support)
        tokens.append(token)
    }

    func recordRemove(
        _ support: PersonDossierMembershipSupport,
        token: PersonDossierProjectionToken
    ) {
        removedSupports.append(support)
        tokens.append(token)
    }

    func recordReset(
        _ decision: PersonDossierCorrectionDecision,
        token: PersonDossierProjectionToken
    ) {
        resetDecisions.append(decision)
        tokens.append(token)
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

private func personDossierService(
    summaries: @escaping @Sendable () async throws -> [PersonDossierSummary] = { [] },
    snapshot: @escaping @Sendable (UUID) async throws -> PersonDossierSnapshot = { _ in
        throw CompositionTestError.dossierFailed
    },
    open: @escaping @Sendable (PersonDossierAnchorSelection) async throws
        -> PersonDossierOpenResult = { _ in throw CompositionTestError.dossierFailed },
    choose: @escaping @Sendable (
        PersonDossierAnchorSelection, PersonDossierCreationChoice
    ) async throws -> PersonDossierSnapshot = { _, _ in throw CompositionTestError.dossierFailed },
    accept: @escaping @Sendable (
        UUID, UUID, PersonDossierCandidateSupportIdentity, PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot = { _, _, _, _ in throw CompositionTestError.dossierFailed },
    reject: @escaping @Sendable (
        UUID, UUID, PersonDossierCandidateSupportIdentity, PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot = { _, _, _, _ in throw CompositionTestError.dossierFailed },
    remove: @escaping @Sendable (
        UUID, UUID, PersonDossierMembershipSupport, PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot = { _, _, _, _ in throw CompositionTestError.dossierFailed },
    reset: @escaping @Sendable (
        UUID, UUID, PersonDossierCorrectionDecision, PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot = { _, _, _, _ in throw CompositionTestError.dossierFailed }
) -> CurrentPersonDossierService {
    CurrentPersonDossierService(
        summaries: summaries,
        snapshot: snapshot,
        open: open,
        choose: choose,
        accept: accept,
        reject: reject,
        remove: remove,
        reset: reset
    )
}

private func personDossierService(
    recorder: PersonDossierServiceRecorder,
    returning snapshot: PersonDossierSnapshot
) -> CurrentPersonDossierService {
    personDossierService(
        summaries: { [] },
        snapshot: { _ in snapshot },
        open: { selection in
            await recorder.recordOpen(selection)
            return .opened(snapshot)
        },
        choose: { _, choice in
            await recorder.recordChoice(choice)
            return snapshot
        },
        accept: { _, _, support, token in
            await recorder.recordAccept(support, token: token)
            return snapshot
        },
        reject: { _, _, support, token in
            await recorder.recordReject(support, token: token)
            return snapshot
        },
        remove: { _, _, support, token in
            await recorder.recordRemove(support, token: token)
            return snapshot
        },
        reset: { _, _, decision, token in
            await recorder.recordReset(decision, token: token)
            return snapshot
        }
    )
}

private struct PersonCompositionValues {
    let selection: PersonDossierAnchorSelection
    let summary: PersonDossierSummary
    let snapshot: PersonDossierSnapshot
    let suggestion: PersonDossierSuggestion
    let member: PersonDossierMember
    let correction: PersonDossierCorrection

    static func make() throws -> Self {
        let timestamp = Date(timeIntervalSince1970: 300)
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let dossierID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
        let anchorID = UUID(uuidString: "00000000-0000-0000-0000-000000000703")!
        let origin = document(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000704")!,
            sourceID: sourceID,
            path: "origin.pdf",
            timestamp: timestamp
        )
        let primaryFinding = try finding(
            displayName: "Elise Muster",
            normalizedName: "elise muster",
            role: .resident
        )
        let originDNA = try dna(document: origin, finding: primaryFinding, timestamp: timestamp)
        let selection = try PersonDossierAnchorSelection(
            document: origin,
            snapshot: originDNA,
            finding: primaryFinding
        )
        let anchor = try PersonDossierAnchor(
            id: anchorID,
            displayName: "Elise Muster",
            normalizedName: "elise muster",
            primaryRole: .resident,
            originDocumentID: origin.id,
            originContentHash: origin.contentHash,
            originExtractionVersion: originDNA.inputExtractionVersion,
            originDNASchemaVersion: originDNA.schemaVersion,
            originDNAAnalyzerIdentifier: originDNA.analyzerIdentifier,
            originDNAAnalyzerVersion: originDNA.analyzerVersion,
            originDNAAnalyzedAt: timestamp,
            personEvidence: primaryFinding.evidence,
            birthDate: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let dossier = try DossierRecord(
            id: dossierID,
            kind: .personMatter,
            displayName: "Elise Muster",
            anchor: .person(anchor),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let summary = PersonDossierSummary(dossier: dossier, anchor: anchor)

        let suggestionDocument = document(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000705")!,
            sourceID: sourceID,
            path: "suggestion.pdf",
            timestamp: timestamp
        )
        let suggestionFinding = try finding(
            displayName: "Elise Muster",
            normalizedName: "elise muster",
            role: .authorizedPerson
        )
        let suggestionCurrent = try CurrentDocumentDNA(
            document: suggestionDocument,
            snapshot: try dna(
                document: suggestionDocument,
                finding: suggestionFinding,
                timestamp: timestamp
            )
        )
        let suggestionSupport = try PersonDossierCandidateSupportIdentity(
            kind: .secondaryRole,
            person: try PersonDossierFindingSupportIdentity(
                current: suggestionCurrent,
                role: .authorizedPerson,
                finding: suggestionFinding
            ),
            conflict: .none
        )
        let suggestion = try PersonDossierSuggestion(
            document: suggestionDocument,
            sourceDisplayName: "Archive",
            documentType: .correspondence,
            section: .directDocuments,
            kind: .secondaryRole,
            conflict: .none,
            currentSupports: [suggestionSupport],
            commandSupport: suggestionSupport
        )

        let memberDocument = document(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000706")!,
            sourceID: sourceID,
            path: "member.pdf",
            timestamp: timestamp
        )
        let memberFinding = try finding(
            displayName: "Elise Muster",
            normalizedName: "elise muster",
            role: .resident
        )
        let memberCurrent = try CurrentDocumentDNA(
            document: memberDocument,
            snapshot: try dna(document: memberDocument, finding: memberFinding, timestamp: timestamp)
        )
        let member = try PersonDossierMember(
            document: memberDocument,
            sourceDisplayName: "Archive",
            documentType: .correspondence,
            section: .directDocuments,
            supports: [.exactPrimary(try PersonDossierFindingSupportIdentity(
                current: memberCurrent,
                role: .resident,
                finding: memberFinding
            ))],
            isConfirmationAuthoritative: false,
            preferredPaymentSupport: nil
        )

        let correctionDocument = document(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000707")!,
            sourceID: sourceID,
            path: "correction.pdf",
            timestamp: timestamp
        )
        let correction = try PersonDossierCorrection(
            document: correctionDocument,
            sourceDisplayName: "Archive",
            documentType: .correspondence,
            decision: .exclusion(DossierMembershipExclusion(
                dossierID: dossierID,
                documentID: correctionDocument.id,
                revisionID: UUID(uuidString: "00000000-0000-0000-0000-000000000708")!,
                excludedAt: timestamp
            ))
        )
        let token = PersonDossierProjectionToken(
            dossierUpdatedAt: timestamp,
            anchorUpdatedAt: timestamp,
            originValidity: .current,
            documents: [
                PersonDossierDocumentProjectionIdentity(document: origin, dnaAnalyzedAt: timestamp),
                PersonDossierDocumentProjectionIdentity(document: suggestionDocument, dnaAnalyzedAt: timestamp),
                PersonDossierDocumentProjectionIdentity(document: memberDocument, dnaAnalyzedAt: timestamp),
                PersonDossierDocumentProjectionIdentity(document: correctionDocument, dnaAnalyzedAt: nil),
            ],
            memberSupports: [member.supports],
            suggestionSupports: [suggestionSupport],
            confirmationRevisionIDs: [],
            exclusionRevisionIDs: [try exclusionRevisionID(correction.decision)]
        )
        return Self(
            selection: selection,
            summary: summary,
            snapshot: PersonDossierSnapshot(
                dossier: dossier,
                anchor: anchor,
                origin: try PersonDossierOriginState(
                    validity: .current,
                    document: origin,
                    sourceDisplayName: "Archive"
                ),
                directMembers: [member],
                costsAndPayments: [],
                suggestions: [suggestion],
                corrections: [correction],
                token: token
            ),
            suggestion: suggestion,
            member: member,
            correction: correction
        )
    }

    private static func document(
        id: UUID,
        sourceID: UUID,
        path: String,
        timestamp: Date
    ) -> DocumentRecord {
        DocumentRecord(
            id: id,
            sourceRootID: sourceID,
            relativePath: path,
            contentHash: "hash-\(path)",
            byteCount: 20,
            modifiedAt: timestamp,
            mediaType: .pdf,
            status: .ready,
            pageCount: 1,
            lastSeenAt: timestamp
        )
    }

    private static func finding(
        displayName: String,
        normalizedName: String,
        role: PersonDossierRole
    ) throws -> DocumentDNAFinding {
        let evidence = try DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 0,
            lengthUTF16: displayName.utf16.count,
            exactText: displayName,
            ocrRegionIndexes: []
        )
        return try DocumentDNAFinding(
            kind: .person,
            qualifier: role.rawValue,
            displayValue: displayName,
            normalizedValue: normalizedName,
            secondaryNormalizedValue: nil,
            confidence: 0.9,
            evidence: [evidence]
        )
    }

    private static func dna(
        document: DocumentRecord,
        finding: DocumentDNAFinding,
        timestamp: Date
    ) throws -> DocumentDNA {
        try DocumentDNA(
            documentID: document.id,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: document.contentHash,
            inputExtractionVersion: "text-v1",
            findings: [
                try DocumentDNAFinding(
                    kind: .documentType,
                    qualifier: nil,
                    displayValue: "",
                    normalizedValue: DocumentType.unknown.rawValue,
                    secondaryNormalizedValue: nil,
                    confidence: 0,
                    evidence: []
                ),
                finding,
            ],
            analyzedAt: timestamp
        )
    }

    private static func exclusionRevisionID(
        _ decision: PersonDossierCorrectionDecision
    ) throws -> UUID {
        guard case let .exclusion(exclusion) = decision else {
            throw CompositionTestError.dossierFailed
        }
        return exclusion.revisionID
    }
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
