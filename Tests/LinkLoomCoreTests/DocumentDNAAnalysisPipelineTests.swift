import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Document DNA analysis pipeline")
struct DocumentDNAAnalysisPipelineTests {
    @Test func overlappingInstancesSerializeSameSourceWithoutDuplicateAnalysis() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 2,
            analyzerStartsBlocked: true
        )
        let checkpoints = CoordinationCheckpointRecorder()
        let ownerPipeline = fixture.makeInjectedPipeline(
            coordinationEvent: checkpoints.handler(label: .owner)
        )
        let secondPipeline = fixture.makeInjectedPipeline(
            coordinationEvent: checkpoints.handler(label: .nextLive)
        )
        let first = Task {
            try await ownerPipeline.processPending(
                sourceRootID: fixture.source.id,
                limit: 1
            )
        }
        await fixture.analyzer.waitUntilFirstCallStarts()
        let second = Task {
            try await secondPipeline.processPending(
                sourceRootID: fixture.source.id,
                limit: 1
            )
        }
        await checkpoints.waitFor(label: .nextLive, event: .waiterRegistered)

        #expect(await fixture.analyzer.callCount == 1)
        #expect(checkpoints.acquiredLabels == [.owner])
        await fixture.analyzer.releaseAll()

        let reports = try await [first.value, second.value]
        #expect(reports == [
            DocumentDNAAnalysisReport(completed: 2, failed: 0),
            DocumentDNAAnalysisReport(completed: 0, failed: 0),
        ])
        #expect(await fixture.analyzer.callCount == 2)
        #expect(await fixture.analyzer.duplicateDocumentCalls == 0)
    }

    @Test func differentSourcesAnalyzeConcurrently() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 1,
            analyzerStartsBlocked: true
        )
        let secondSource = try await fixture.insertAdditionalSourceWithDocument()
        let checkpoints = CoordinationCheckpointRecorder()
        let firstPipeline = fixture.makeInjectedPipeline(
            coordinationEvent: checkpoints.handler(label: .firstSource)
        )
        let secondPipeline = fixture.makeInjectedPipeline(
            coordinationEvent: checkpoints.handler(label: .secondSource)
        )
        let first = Task {
            try await firstPipeline.processPending(
                sourceRootID: fixture.source.id,
                limit: 1
            )
        }
        await fixture.analyzer.waitUntilFirstCallStarts()
        let second = Task {
            try await secondPipeline.processPending(
                sourceRootID: secondSource.id,
                limit: 1
            )
        }
        await checkpoints.waitFor(label: .secondSource, event: .acquired)
        await fixture.analyzer.waitUntilCallCountStarts(2)

        #expect(checkpoints.acquiredLabels == [.firstSource, .secondSource])
        await fixture.analyzer.releaseAll()

        #expect(try await first.value == DocumentDNAAnalysisReport(completed: 1, failed: 0))
        #expect(try await second.value == DocumentDNAAnalysisReport(completed: 1, failed: 0))
        #expect(await fixture.analyzer.peakConcurrency == 2)
    }

    @Test func cancellingNonHeadWaiterPreservesLiveWaiterFIFO() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 1,
            analyzerStartsBlocked: true
        )
        let checkpoints = CoordinationCheckpointRecorder()
        let recorder = PipelineOperationRecorder()
        let ownerPipeline = fixture.makeInjectedPipeline(
            coordinationEvent: checkpoints.handler(label: .owner)
        )
        let firstLivePipeline = fixture.makeInjectedPipeline(
            pendingAnalysis: { _, _, _ in
                await recorder.record("first-live")
                return []
            },
            coordinationEvent: checkpoints.handler(label: .firstLive)
        )
        let cancelledPipeline = fixture.makeInjectedPipeline(
            pendingAnalysis: { _, _, _ in
                await recorder.record("cancelled")
                return []
            },
            coordinationEvent: checkpoints.handler(label: .cancelled)
        )
        let nextPipeline = fixture.makeInjectedPipeline(
            pendingAnalysis: { _, _, _ in
                await recorder.record("next-live")
                return []
            },
            coordinationEvent: checkpoints.handler(label: .nextLive)
        )
        let owner = Task {
            try await ownerPipeline.processPending(
                sourceRootID: fixture.source.id,
                limit: 1
            )
        }
        await fixture.analyzer.waitUntilFirstCallStarts()
        let firstLiveWaiter = Task {
            try await firstLivePipeline.processPending(
                sourceRootID: fixture.source.id,
                limit: 1
            )
        }
        await checkpoints.waitFor(label: .firstLive, event: .waiterRegistered)
        let cancelledWaiter = Task {
            try await cancelledPipeline.processPending(
                sourceRootID: fixture.source.id,
                limit: 1
            )
        }
        await checkpoints.waitFor(label: .cancelled, event: .waiterRegistered)
        let nextWaiter = Task {
            try await nextPipeline.processPending(
                sourceRootID: fixture.source.id,
                limit: 1
            )
        }
        await checkpoints.waitFor(label: .nextLive, event: .waiterRegistered)
        #expect(checkpoints.registeredLabels == [.firstLive, .cancelled, .nextLive])

        cancelledWaiter.cancel()

        let cancellation = await checkpoints.waitForFirst(event: .waiterCancelled)
        guard cancellation.label == .cancelled else {
            Issue.record("Cancellation removed \(cancellation.label) instead of cancelled")
            owner.cancel()
            firstLiveWaiter.cancel()
            nextWaiter.cancel()
            await fixture.analyzer.releaseAll()
            return
        }
        #expect(await fixture.analyzer.callCount == 1)
        #expect(await recorder.operations.isEmpty)
        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .cancelled,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await cancelledWaiter.value
        }
        #expect(checkpoints.acquiredLabels == [.owner])
        await fixture.analyzer.releaseAll()

        #expect(try await owner.value == DocumentDNAAnalysisReport(completed: 1, failed: 0))
        #expect(try await firstLiveWaiter.value == DocumentDNAAnalysisReport(
            completed: 0,
            failed: 0
        ))
        #expect(try await nextWaiter.value == DocumentDNAAnalysisReport(completed: 0, failed: 0))
        #expect(checkpoints.acquiredLabels == [.owner, .firstLive, .nextLive])
        #expect(await recorder.operations == ["first-live", "next-live"])
        #expect(await fixture.analyzer.callCount == 1)
        #expect(await fixture.analyzer.duplicateDocumentCalls == 0)
    }

    @Test func cancellingActiveOwnerTransfersBatonToNextWaiter() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 1,
            analyzerStartsBlocked: true
        )
        let checkpoints = CoordinationCheckpointRecorder()
        let ownerPipeline = fixture.makeInjectedPipeline(
            coordinationEvent: checkpoints.handler(label: .owner)
        )
        let nextPipeline = fixture.makeInjectedPipeline(
            coordinationEvent: checkpoints.handler(label: .nextLive)
        )
        let owner = Task {
            try await ownerPipeline.processPending(
                sourceRootID: fixture.source.id,
                limit: 1
            )
        }
        await fixture.analyzer.waitUntilFirstCallStarts()
        let nextWaiter = Task {
            try await nextPipeline.processPending(
                sourceRootID: fixture.source.id,
                limit: 1
            )
        }
        await checkpoints.waitFor(label: .nextLive, event: .waiterRegistered)

        owner.cancel()
        await fixture.analyzer.releaseAll()

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .cancelled,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await owner.value
        }
        await checkpoints.waitFor(label: .nextLive, event: .acquired)
        #expect(try await nextWaiter.value == DocumentDNAAnalysisReport(completed: 1, failed: 0))
        #expect(checkpoints.acquiredLabels == [.owner, .nextLive])
        #expect(await fixture.analyzer.callCount == 2)
        #expect(await fixture.analyzer.duplicateDocumentCalls == 0)
    }

    @Test func firstRunPersistsEveryPendingSnapshot() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 3)

        let report = try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 2
        )

        #expect(report == DocumentDNAAnalysisReport(completed: 3, failed: 0))
        #expect(await fixture.analyzer.callCount == 3)
        for documentID in fixture.documentIDs {
            #expect(try await fixture.repository.currentSnapshot(
                documentID: documentID,
                target: fixture.target
            ) != nil)
        }
    }

    @Test func unchangedRerunPerformsNoAnalyzerOrStateWork() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 3)

        _ = try await fixture.pipeline.processPending(sourceRootID: fixture.source.id, limit: 2)
        let callsAfterFirstRun = await fixture.analyzer.callCount
        let rowsAfterFirstRun = try await fixture.documentDNARowCount()

        let report = try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 2
        )

        #expect(report == DocumentDNAAnalysisReport(completed: 0, failed: 0))
        #expect(await fixture.analyzer.callCount == callsAfterFirstRun)
        #expect(try await fixture.documentDNARowCount() == rowsAfterFirstRun)
    }

    @Test func analyzerAndSchemaChangesEachReplaceExactlyOnce() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        _ = try await fixture.pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)

        let analyzerVersionTwoTarget = try DocumentDNAAnalysisTarget(
            schemaVersion: 1,
            analyzerIdentifier: "recording",
            analyzerVersion: "2"
        )
        let analyzerVersionTwoPipeline = fixture.makePipeline(target: analyzerVersionTwoTarget)
        let analyzerVersionTwoReport = try await analyzerVersionTwoPipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 1
        )
        #expect(analyzerVersionTwoReport == DocumentDNAAnalysisReport(completed: 1, failed: 0))

        let schemaVersionTwoTarget = try DocumentDNAAnalysisTarget(
            schemaVersion: 2,
            analyzerIdentifier: "recording",
            analyzerVersion: "2"
        )
        let schemaVersionTwoPipeline = fixture.makePipeline(target: schemaVersionTwoTarget)
        let schemaVersionTwoReport = try await schemaVersionTwoPipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 1
        )
        #expect(schemaVersionTwoReport == DocumentDNAAnalysisReport(completed: 1, failed: 0))
        #expect(try await schemaVersionTwoPipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 1
        ) == DocumentDNAAnalysisReport(completed: 0, failed: 0))
    }

    @Test func nonPositiveLimitPerformsNoRecoveryQueryOrAnalysis() async throws {
        let target = try DocumentDNAAnalysisTarget(
            schemaVersion: 1,
            analyzerIdentifier: "recording",
            analyzerVersion: "1"
        )
        let recorder = PipelineOperationRecorder()
        let pipeline = DocumentDNAAnalysisPipeline(
            analyzer: RecordingDocumentDNAAnalyzer(target: target),
            target: target,
            now: { DocumentDNAAnalysisPipelineFixture.date },
            pendingAnalysis: { _, _, _ in
                await recorder.record("pending")
                return []
            },
            recoverInterruptedAnalysis: { _ in
                await recorder.record("recovery")
            },
            beginAnalysis: { _, _, _ in
                await recorder.record("begin")
            },
            markAnalysisFailed: { _, _, _, _ in
                await recorder.record("fail")
            },
            restoreAnalysisAfterInterruption: { _, _ in
                await recorder.record("restore")
            },
            replace: { _ in
                await recorder.record("replace")
            }
        )

        let zeroReport = try await pipeline.processPending(sourceRootID: UUID(), limit: 0)
        let negativeReport = try await pipeline.processPending(sourceRootID: UUID(), limit: -1)

        #expect(zeroReport == DocumentDNAAnalysisReport(completed: 0, failed: 0))
        #expect(negativeReport == DocumentDNAAnalysisReport(completed: 0, failed: 0))
        #expect(await recorder.operations.isEmpty)
    }

    @Test func runStartRecoveryResumesOrphanedAnalyzingAttempt() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let candidate = try #require(try await fixture.pendingCandidates(limit: 1).first)
        try await fixture.repository.beginAnalysis(
            candidate,
            target: fixture.target,
            at: DocumentDNAAnalysisPipelineFixture.date
        )
        #expect(try await fixture.analysisStatus(documentID: candidate.document.id) == "analyzing")

        let report = try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 1
        )

        #expect(report == DocumentDNAAnalysisReport(completed: 1, failed: 0))
        #expect(await fixture.analyzer.callCount == 1)
        #expect(try await fixture.repository.currentSnapshot(
            documentID: candidate.document.id,
            target: fixture.target
        ) != nil)
    }

    @Test func recoveryCancellationThrowsCancelledBeforePendingQuery() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let recorder = PipelineOperationRecorder()
        let pipeline = fixture.makeInjectedPipeline(
            pendingAnalysis: { _, _, _ in
                await recorder.record("pending")
                return []
            },
            recoverInterruptedAnalysis: { _ in
                await recorder.record("recovery")
                throw CancellationError()
            }
        )

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .cancelled,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        #expect(await recorder.operations == ["recovery"])
    }

    @Test func recoveryFailureThrowsPersistenceAndReleasesCoordinator() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let recorder = PipelineOperationRecorder()
        let pipeline = fixture.makeInjectedPipeline(
            pendingAnalysis: { _, _, _ in
                await recorder.record("pending")
                return []
            },
            recoverInterruptedAnalysis: { _ in
                await recorder.record("recovery")
                throw SyntheticPersistenceError.failed
            }
        )

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .persistence,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        #expect(await recorder.operations == ["recovery"])
        #expect(try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 1
        ) == DocumentDNAAnalysisReport(completed: 1, failed: 0))
    }

    @Test func manualRetryMakesOnlyExactFailedDocumentEligible() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 2,
            analyzerOutcomes: [.success, .success],
            seedPriorSnapshots: true
        )
        let candidates = try await fixture.pendingCandidates(limit: 2)
        for candidate in candidates {
            try await fixture.repository.beginAnalysis(
                candidate,
                target: fixture.target,
                at: DocumentDNAAnalysisPipelineFixture.date
            )
            try await fixture.repository.markAnalysisFailed(
                candidate,
                target: fixture.target,
                failureCode: .analysisFailure,
                at: DocumentDNAAnalysisPipelineFixture.date
            )
        }
        #expect(try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 2
        ) == DocumentDNAAnalysisReport(completed: 0, failed: 0))

        try await fixture.repository.retryFailedAnalysis(documentID: fixture.documentIDs[0])

        #expect(try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 2
        ) == DocumentDNAAnalysisReport(completed: 1, failed: 0))
        #expect(await fixture.analyzer.callCount == 1)
        #expect(try await fixture.repository.currentSnapshot(
            documentID: fixture.documentIDs[0],
            target: fixture.target
        ) != nil)
        #expect(try await fixture.repository.currentSnapshot(
            documentID: fixture.documentIDs[1],
            target: fixture.target
        ) == nil)
        #expect(try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 2
        ) == DocumentDNAAnalysisReport(completed: 0, failed: 0))
    }

    @Test func realLocalAnalyzerPersistsLiteralSnapshotAndLeavesDocumentReady() async throws {
        let db = try TestDatabase.make()
        let source = SourceRootRecord(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            displayName: "Literal local analysis",
            pathHint: "/synthetic/literal-local-analysis",
            bookmarkData: Data("bookmark-literal-local-analysis".utf8),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let documentID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        let contentHash = "hash-literal-local-analysis"
        let extractionVersion = "text-v1"
        let analyzedAt = Date(timeIntervalSince1970: 1_800_000_001)
        let text = """
            Rechnung
            Rechnungssteller: Pflegezentrum Sonnenrain AG
            Bewohnerin: Elise Muster
            Rechnungsnummer: RE-2026-0815
            Total CHF 1200.00
            """
        let document = DocumentRecord(
            id: documentID,
            sourceRootID: source.id,
            relativePath: "literal-invoice.pdf",
            contentHash: contentHash,
            byteCount: 127,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastFingerprintAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await db.write { database in
            try source.insert(database)
            try document.insert(database)
        }
        try await ExtractionRepository(dbWriter: db).replace(
            documentID: documentID,
            analysisVersion: extractionVersion,
            extraction: ExtractedDocument(
                method: .embeddedPDFText,
                pages: [ExtractedPage(pageIndex: 0, text: text, regions: [])]
            ),
            at: analyzedAt
        )
        let target = try DocumentDNAAnalysisTarget(
            schemaVersion: LocalRulesDocumentDNAAnalyzer.schemaVersion,
            analyzerIdentifier: LocalRulesDocumentDNAAnalyzer.analyzerIdentifier,
            analyzerVersion: LocalRulesDocumentDNAAnalyzer.analyzerVersion
        )
        let repository = DocumentDNARepository(dbWriter: db)
        let pipeline = DocumentDNAAnalysisPipeline(
            repository: repository,
            analyzer: LocalRulesDocumentDNAAnalyzer(),
            target: target,
            now: { analyzedAt }
        )
        let expected = try DocumentDNA(
            documentID: documentID,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: contentHash,
            inputExtractionVersion: extractionVersion,
            findings: [
                try DocumentDNAFinding(
                    kind: .documentType,
                    qualifier: nil,
                    displayValue: "Rechnung",
                    normalizedValue: "invoice",
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [try DocumentDNAEvidence(
                        pageIndex: 0,
                        startUTF16: 0,
                        lengthUTF16: 8,
                        exactText: "Rechnung",
                        ocrRegionIndexes: []
                    )]
                ),
                try DocumentDNAFinding(
                    kind: .person,
                    qualifier: "resident",
                    displayValue: "Elise Muster",
                    normalizedValue: "elise muster",
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [try DocumentDNAEvidence(
                        pageIndex: 0,
                        startUTF16: 67,
                        lengthUTF16: 12,
                        exactText: "Elise Muster",
                        ocrRegionIndexes: []
                    )]
                ),
                try DocumentDNAFinding(
                    kind: .referenceNumber,
                    qualifier: "invoiceNumber",
                    displayValue: "RE-2026-0815",
                    normalizedValue: "RE-2026-0815",
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [try DocumentDNAEvidence(
                        pageIndex: 0,
                        startUTF16: 97,
                        lengthUTF16: 12,
                        exactText: "RE-2026-0815",
                        ocrRegionIndexes: []
                    )]
                ),
                try DocumentDNAFinding(
                    kind: .monetaryAmount,
                    qualifier: "CHF",
                    displayValue: "CHF 1200.00",
                    normalizedValue: "1200",
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [try DocumentDNAEvidence(
                        pageIndex: 0,
                        startUTF16: 116,
                        lengthUTF16: 11,
                        exactText: "CHF 1200.00",
                        ocrRegionIndexes: []
                    )]
                ),
            ],
            analyzedAt: analyzedAt
        )

        let report = try await pipeline.processPending(sourceRootID: source.id, limit: 1)
        let actual = try #require(try await repository.currentSnapshot(
            documentID: documentID,
            target: target
        ))
        let reloadedDocument = try #require(try await db.read { database in
            try DocumentRecord.fetchOne(database, key: documentID)
        })

        #expect(report == DocumentDNAAnalysisReport(completed: 1, failed: 0))
        #expect(actual == expected)
        #expect(reloadedDocument.status == .ready)
    }

    @Test func limitBoundsConcurrencyWithoutTruncatingLaterBatches() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 5,
            analysisDelay: .milliseconds(20)
        )

        let report = try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 2
        )

        #expect(report == DocumentDNAAnalysisReport(completed: 5, failed: 0))
        #expect(await fixture.analyzer.peakConcurrency == 2)
    }

    @Test func deterministicFailuresAreIsolatedWithStableCodes() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.makeWithAnalyzerOutcomes([
            .success,
            .validationFailure,
            .syntheticFailure,
        ])

        let report = try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 3
        )

        #expect(report == DocumentDNAAnalysisReport(completed: 1, failed: 2))
        #expect(try await fixture.failureCodesInPathOrder() == [
            nil, "invalidFinding", "analysisFailure",
        ])
        #expect(try await fixture.repository.currentSnapshot(
            documentID: fixture.documentIDs[0],
            target: fixture.target
        ) != nil)
        for documentID in fixture.documentIDs.dropFirst() {
            #expect(try await fixture.repository.storedSnapshot(documentID: documentID)?
                .analyzerVersion == "prior")
        }
    }

    @Test func invalidProvenanceIsDurablyFailedWithoutReplacingPriorSnapshot() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.makeWithAnalyzerOutcomes([
            .invalidProvenance,
        ])

        let report = try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 1
        )

        #expect(report == DocumentDNAAnalysisReport(completed: 0, failed: 1))
        #expect(try await fixture.failureCodesInPathOrder() == ["invalidProvenance"])
        #expect(try await fixture.repository.storedSnapshot(
            documentID: fixture.documentIDs[0]
        )?.analyzerVersion == "prior")
    }

    @Test func repositoryShapedAnalyzerErrorsRemainAnalysisFailures() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.makeWithAnalyzerOutcomes([
            .repositoryInvalidProvenanceFailure,
            .repositoryStaleFailure,
        ])

        let report = try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 2
        )

        #expect(report == DocumentDNAAnalysisReport(completed: 0, failed: 2))
        #expect(try await fixture.failureCodesInPathOrder() == [
            "analysisFailure", "analysisFailure",
        ])
    }

    @Test(arguments: SnapshotIdentityMismatch.allCases)
    func mismatchedAnalyzerSnapshotIdentityFailsOriginalAttempt(
        mismatch: SnapshotIdentityMismatch
    ) async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 1,
            seedPriorSnapshots: true
        )
        let documentID = fixture.documentIDs[0]
        let priorSnapshot = try #require(
            try await fixture.repository.storedSnapshot(documentID: documentID)
        )
        let analyzer = IdentityViolatingDocumentDNAAnalyzer(
            target: fixture.target,
            mismatch: mismatch
        )
        let queryGuard = BoundedPendingQuery(maximumCallCount: 2)
        let repository = fixture.repository
        let pipeline = fixture.makeInjectedPipeline(
            analyzer: analyzer,
            pendingAnalysis: { sourceRootID, target, limit in
                try await queryGuard.recordCall()
                return try await repository.pendingAnalysis(
                    sourceRootID: sourceRootID,
                    target: target,
                    limit: limit
                )
            }
        )

        let report = try await pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 1
        )

        #expect(report == DocumentDNAAnalysisReport(completed: 0, failed: 1))
        #expect(try await fixture.failureCodesInPathOrder() == ["analysisFailure"])
        #expect(try await fixture.repository.storedSnapshot(
            documentID: documentID
        ) == priorSnapshot)
        let rerun = fixture.makeInjectedPipeline(analyzer: analyzer)
        #expect(try await rerun.processPending(
            sourceRootID: fixture.source.id,
            limit: 1
        ) == DocumentDNAAnalysisReport(completed: 0, failed: 0))
    }

    @Test func mismatchedAnalyzerDocumentIDCannotWriteSiblingSnapshot() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 2,
            seedPriorSnapshots: true
        )
        let originalID = fixture.documentIDs[0]
        let siblingID = fixture.documentIDs[1]
        let originalPrior = try #require(
            try await fixture.repository.storedSnapshot(documentID: originalID)
        )
        let siblingPrior = try #require(
            try await fixture.repository.storedSnapshot(documentID: siblingID)
        )
        try await fixture.db.write { database in
            try database.execute(
                sql: "UPDATE document SET contentHash = ? WHERE id = ?",
                arguments: ["hash-0", siblingID]
            )
        }
        let analyzer = IdentityViolatingDocumentDNAAnalyzer(
            target: fixture.target,
            replacementDocumentID: siblingID
        )
        let repository = fixture.repository
        let originalOnlyPending: PendingAnalysisClosure = { sourceRootID, target, limit in
            let candidates = try await repository.pendingAnalysis(
                sourceRootID: sourceRootID,
                target: target,
                limit: max(limit, 2)
            )
            return Array(candidates.filter { $0.document.id == originalID }.prefix(limit))
        }
        let pipeline = fixture.makeInjectedPipeline(
            analyzer: analyzer,
            pendingAnalysis: originalOnlyPending
        )

        let report = try await pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 1
        )

        #expect(report == DocumentDNAAnalysisReport(completed: 0, failed: 1))
        #expect(try await fixture.failureCodesInPathOrder() == ["analysisFailure", nil])
        #expect(try await fixture.repository.storedSnapshot(
            documentID: originalID
        ) == originalPrior)
        #expect(try await fixture.repository.storedSnapshot(
            documentID: siblingID
        ) == siblingPrior)
        let rerun = fixture.makeInjectedPipeline(
            analyzer: analyzer,
            pendingAnalysis: originalOnlyPending
        )
        #expect(try await rerun.processPending(
            sourceRootID: fixture.source.id,
            limit: 1
        ) == DocumentDNAAnalysisReport(completed: 0, failed: 0))
    }

    @Test func initialPendingQueryFailureThrowsZeroPartialReport() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let pipeline = fixture.makeInjectedPipeline(
            pendingAnalysis: { _, _, _ in throw SyntheticPersistenceError.failed }
        )

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .pendingQuery,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
    }

    @Test func laterPendingQueryFailurePreservesCompletedBatchCount() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let candidate = try #require(try await fixture.pendingCandidates(limit: 1).first)
        let queries = PendingAnalysisSequence(firstBatch: [candidate])
        let pipeline = fixture.makeInjectedPipeline(
            pendingAnalysis: { _, _, _ in try await queries.next() }
        )

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .pendingQuery,
                partialReport: DocumentDNAAnalysisReport(completed: 1, failed: 0)
            )
        ) {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        #expect(await queries.callCount == 2)
    }

    @Test func beginPersistenceErrorIsTypedAndStopsBeforeAnotherQuery() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let queries = PendingAnalysisSequence(
            firstBatch: try await fixture.pendingCandidates(limit: 1),
            subsequentResult: []
        )
        let pipeline = fixture.makeInjectedPipeline(
            pendingAnalysis: { _, _, _ in try await queries.next() },
            beginAnalysis: { _, _, _ in throw SyntheticPersistenceError.failed }
        )

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .persistence,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        #expect(await queries.callCount == 1)
    }

    @Test func failedStatePersistenceErrorIsTyped() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.makeWithAnalyzerOutcomes([
            .validationFailure,
        ])
        let pipeline = fixture.makeInjectedPipeline(
            markAnalysisFailed: { _, _, _, _ in throw SyntheticPersistenceError.failed }
        )

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .persistence,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
    }

    @Test func replacementPersistenceErrorIsTyped() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let pipeline = fixture.makeInjectedPipeline(
            replace: { _ in throw SyntheticPersistenceError.failed }
        )

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .persistence,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
    }

    @Test func sameBatchPersistenceWinsAndDurableSiblingOutcomesCount() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 4,
            analyzerOutcomes: [.success, .validationFailure, .success, .success]
        )
        let candidates = try await fixture.pendingCandidates(limit: 4)
        let queries = PendingAnalysisSequence(firstBatch: candidates, subsequentResult: [])
        let persistenceID = fixture.documentIDs[2]
        let staleID = fixture.documentIDs[3]
        let repository = fixture.repository
        let pipeline = fixture.makeInjectedPipeline(
            pendingAnalysis: { _, _, _ in try await queries.next() },
            beginAnalysis: { candidate, target, date in
                switch candidate.document.id {
                case persistenceID:
                    throw SyntheticPersistenceError.failed
                case staleID:
                    throw DocumentDNARepositoryError.staleInput
                default:
                    try await repository.beginAnalysis(candidate, target: target, at: date)
                }
            }
        )

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .persistence,
                partialReport: DocumentDNAAnalysisReport(completed: 1, failed: 1)
            )
        ) {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 4)
        }
        #expect(await queries.callCount == 1)
    }

    @Test func contentChangeDuringAnalysisRejectsStaleSnapshot() async throws {
        let suspension = AnalyzerSuspensionGate()
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 1,
            seedPriorSnapshots: true,
            analyzerSuspension: suspension
        )
        let documentID = fixture.documentIDs[0]
        let priorSnapshot = try #require(
            try await fixture.repository.storedSnapshot(documentID: documentID)
        )
        let processing = Task {
            try await fixture.pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        await suspension.waitUntilStarted()

        try await fixture.db.write { database in
            try database.execute(
                sql: "UPDATE document SET contentHash = ? WHERE id = ?",
                arguments: ["hash-after-analysis-began", documentID]
            )
        }
        suspension.release()

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .staleInput,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await processing.value
        }
        #expect(try await fixture.repository.storedSnapshot(
            documentID: documentID
        ) == priorSnapshot)
        #expect(try await fixture.snapshotRowCounts() == SnapshotRowCounts(
            headers: 1,
            findings: 1,
            evidence: 1
        ))
    }

    @Test func extractionVersionChangeDuringAnalysisRejectsStaleSnapshot() async throws {
        let suspension = AnalyzerSuspensionGate()
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 1,
            seedPriorSnapshots: true,
            analyzerSuspension: suspension
        )
        let documentID = fixture.documentIDs[0]
        let priorSnapshot = try #require(
            try await fixture.repository.storedSnapshot(documentID: documentID)
        )
        let processing = Task {
            try await fixture.pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        await suspension.waitUntilStarted()

        try await ExtractionRepository(dbWriter: fixture.db).replace(
            documentID: documentID,
            analysisVersion: "text-v2",
            extraction: ExtractedDocument(
                method: .embeddedPDFText,
                pages: [ExtractedPage(
                    pageIndex: 0,
                    text: DocumentDNAAnalysisPipelineFixture.pageText,
                    regions: []
                )]
            ),
            at: DocumentDNAAnalysisPipelineFixture.date.addingTimeInterval(1)
        )
        suspension.release()

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .staleInput,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await processing.value
        }
        #expect(try await fixture.repository.storedSnapshot(
            documentID: documentID
        ) == priorSnapshot)
        #expect(try await fixture.snapshotRowCounts() == SnapshotRowCounts(
            headers: 1,
            findings: 1,
            evidence: 1
        ))
    }

    @Test func cancellationDuringAnalysisRestoresAttemptAndPreservesPriorSnapshot() async throws {
        let suspension = AnalyzerSuspensionGate()
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 1,
            seedPriorSnapshots: true,
            analyzerSuspension: suspension
        )
        let documentID = fixture.documentIDs[0]
        let priorSnapshot = try #require(
            try await fixture.repository.storedSnapshot(documentID: documentID)
        )
        let processing = Task {
            try await fixture.pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        await suspension.waitUntilStarted()
        #expect(try await fixture.analysisStatus(documentID: documentID) == "analyzing")

        processing.cancel()
        suspension.release()

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .cancelled,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await processing.value
        }
        #expect(try await fixture.analysisStatus(documentID: documentID) == nil)
        #expect(try await fixture.repository.storedSnapshot(
            documentID: documentID
        ) == priorSnapshot)
        #expect(try await fixture.pendingCandidates(limit: 1).map(\.document.id) == [documentID])
    }

    @Test func cancellationRestorationFailureMapsToPersistence() async throws {
        let suspension = AnalyzerSuspensionGate()
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
            documentCount: 1,
            seedPriorSnapshots: true,
            analyzerSuspension: suspension
        )
        let documentID = fixture.documentIDs[0]
        let pipeline = fixture.makeInjectedPipeline(
            restoreAnalysisAfterInterruption: { _, _ in
                throw SyntheticPersistenceError.failed
            }
        )
        let processing = Task {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        await suspension.waitUntilStarted()

        processing.cancel()
        suspension.release()

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .persistence,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await processing.value
        }
        #expect(try await fixture.analysisStatus(documentID: documentID) == "analyzing")
    }

    @Test func preCancelledRunCreatesNoAnalysisState() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let processing = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await fixture.pipeline.processPending(
                sourceRootID: fixture.source.id,
                limit: 1
            )
        }

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .cancelled,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await processing.value
        }
        #expect(try await fixture.analysisStatus(documentID: fixture.documentIDs[0]) == nil)
        #expect(await fixture.analyzer.callCount == 0)
    }

    @Test func cancellationBeforeBeginCreatesNoAnalysisState() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let candidate = try #require(try await fixture.pendingCandidates(limit: 1).first)
        let pendingGate = AsyncSuspensionGate()
        let pipeline = fixture.makeInjectedPipeline(
            pendingAnalysis: { _, _, _ in
                await pendingGate.suspend()
                return [candidate]
            }
        )
        let processing = Task {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        await pendingGate.waitUntilStarted()

        processing.cancel()
        await pendingGate.release()

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .cancelled,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await processing.value
        }
        #expect(try await fixture.analysisStatus(documentID: candidate.document.id) == nil)
        #expect(await fixture.analyzer.callCount == 0)
    }

    @Test func cancellationAfterBeginRestoresBeforeAnalyzerRuns() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let beginGate = AsyncSuspensionGate()
        let repository = fixture.repository
        let pipeline = fixture.makeInjectedPipeline(
            beginAnalysis: { candidate, target, date in
                try await repository.beginAnalysis(candidate, target: target, at: date)
                await beginGate.suspend()
            }
        )
        let documentID = fixture.documentIDs[0]
        let processing = Task {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        await beginGate.waitUntilStarted()
        #expect(try await fixture.analysisStatus(documentID: documentID) == "analyzing")

        processing.cancel()
        await beginGate.release()

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .cancelled,
                partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
            )
        ) {
            try await processing.value
        }
        #expect(try await fixture.analysisStatus(documentID: documentID) == nil)
        #expect(await fixture.analyzer.callCount == 0)
    }

    @Test func successfulReplaceCountsCompletedBeforeLaterCancellation() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 1)
        let replaceGate = AsyncSuspensionGate()
        let repository = fixture.repository
        let pipeline = fixture.makeInjectedPipeline(
            replace: { snapshot in
                try await repository.replace(snapshot)
                await replaceGate.suspend()
            }
        )
        let processing = Task {
            try await pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
        }
        await replaceGate.waitUntilStarted()

        processing.cancel()
        await replaceGate.release()

        await expectRunError(
            DocumentDNAAnalysisRunError(
                reason: .cancelled,
                partialReport: DocumentDNAAnalysisReport(completed: 1, failed: 0)
            )
        ) {
            try await processing.value
        }
        #expect(try await fixture.repository.currentSnapshot(
            documentID: fixture.documentIDs[0],
            target: fixture.target
        ) != nil)
    }
}

private struct DocumentDNAAnalysisPipelineFixture {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let pageText = "Rechnung\nBewohnerin: Elise Muster"

    let db: DatabaseQueue
    let source: SourceRootRecord
    let repository: DocumentDNARepository
    let target: DocumentDNAAnalysisTarget
    let analyzer: RecordingDocumentDNAAnalyzer
    let pipeline: DocumentDNAAnalysisPipeline
    let documentIDs: [UUID]

    static func make(
        documentCount: Int,
        analysisDelay: Duration = .zero,
        analyzerOutcomes: [SyntheticAnalyzerOutcome]? = nil,
        seedPriorSnapshots: Bool = false,
        analyzerSuspension: AnalyzerSuspensionGate? = nil,
        analyzerStartsBlocked: Bool = false
    ) async throws -> Self {
        let db = try TestDatabase.make()
        let source = SourceRootRecord(
            displayName: "Synthetic care documents",
            pathHint: "/synthetic/care",
            bookmarkData: Data("bookmark-care".utf8),
            createdAt: date
        )
        let target = try DocumentDNAAnalysisTarget(
            schemaVersion: 1,
            analyzerIdentifier: "recording",
            analyzerVersion: "1"
        )
        try await db.write { database in
            try source.insert(database)
        }

        let extractions = ExtractionRepository(dbWriter: db)
        var documentIDs: [UUID] = []
        for index in 0..<documentCount {
            let document = DocumentRecord(
                sourceRootID: source.id,
                relativePath: String(format: "document-%02d.pdf", index),
                contentHash: "hash-\(index)",
                byteCount: 128,
                modifiedAt: date,
                mediaType: .pdf,
                status: .ready,
                availability: .available,
                pageCount: 1,
                lastSeenAt: date,
                lastFingerprintAt: date
            )
            try await db.write { database in
                try document.insert(database)
            }
            try await extractions.replace(
                documentID: document.id,
                analysisVersion: "text-v1",
                extraction: ExtractedDocument(
                    method: .embeddedPDFText,
                    pages: [ExtractedPage(pageIndex: 0, text: pageText, regions: [])]
                ),
                at: date
            )
            documentIDs.append(document.id)
        }

        let repository = DocumentDNARepository(dbWriter: db)
        if seedPriorSnapshots {
            for (index, documentID) in documentIDs.enumerated() {
                try await repository.replace(try makeDocumentDNASnapshot(
                    documentID: documentID,
                    target: DocumentDNAAnalysisTarget(
                        schemaVersion: 1,
                        analyzerIdentifier: "recording",
                        analyzerVersion: "prior"
                    ),
                    contentHash: "hash-\(index)",
                    extractionVersion: "text-v1",
                    analyzedAt: date
                ))
            }
        }
        let outcomesByDocumentID = Dictionary(uniqueKeysWithValues: zip(
            documentIDs,
            analyzerOutcomes ?? Array(repeating: .success, count: documentIDs.count)
        ))
        let analyzer = RecordingDocumentDNAAnalyzer(
            target: target,
            delay: analysisDelay,
            outcomesByDocumentID: outcomesByDocumentID,
            suspension: analyzerSuspension ?? (analyzerStartsBlocked
                ? AnalyzerSuspensionGate()
                : nil)
        )
        let pipeline = DocumentDNAAnalysisPipeline(
            repository: repository,
            analyzer: analyzer,
            target: target,
            now: { date }
        )
        return Self(
            db: db,
            source: source,
            repository: repository,
            target: target,
            analyzer: analyzer,
            pipeline: pipeline,
            documentIDs: documentIDs
        )
    }

    static func makeWithAnalyzerOutcomes(
        _ outcomes: [SyntheticAnalyzerOutcome]
    ) async throws -> Self {
        try await make(
            documentCount: outcomes.count,
            analyzerOutcomes: outcomes,
            seedPriorSnapshots: true
        )
    }

    func makePipeline(target: DocumentDNAAnalysisTarget) -> DocumentDNAAnalysisPipeline {
        DocumentDNAAnalysisPipeline(
            repository: repository,
            analyzer: RecordingDocumentDNAAnalyzer(target: target),
            target: target,
            now: { Self.date }
        )
    }

    func makeInjectedPipeline(
        analyzer: (any DocumentDNAAnalyzing)? = nil,
        pendingAnalysis: PendingAnalysisClosure? = nil,
        recoverInterruptedAnalysis: RecoveryClosure? = nil,
        beginAnalysis: BeginAnalysisClosure? = nil,
        markAnalysisFailed: MarkAnalysisFailedClosure? = nil,
        restoreAnalysisAfterInterruption: RestoreAnalysisClosure? = nil,
        replace: ReplaceSnapshotClosure? = nil,
        coordinationEvent: @escaping CoordinationEventClosure = { _ in }
    ) -> DocumentDNAAnalysisPipeline {
        let repository = repository
        return DocumentDNAAnalysisPipeline(
            analyzer: analyzer ?? self.analyzer,
            target: target,
            now: { Self.date },
            pendingAnalysis: pendingAnalysis ?? { sourceRootID, target, limit in
                try await repository.pendingAnalysis(
                    sourceRootID: sourceRootID,
                    target: target,
                    limit: limit
                )
            },
            recoverInterruptedAnalysis: recoverInterruptedAnalysis ?? { sourceRootID in
                try await repository.recoverInterruptedAnalysis(sourceRootID: sourceRootID)
            },
            beginAnalysis: beginAnalysis ?? { candidate, target, date in
                try await repository.beginAnalysis(candidate, target: target, at: date)
            },
            markAnalysisFailed: markAnalysisFailed ?? { candidate, target, code, date in
                try await repository.markAnalysisFailed(
                    candidate,
                    target: target,
                    failureCode: code,
                    at: date
                )
            },
            restoreAnalysisAfterInterruption: restoreAnalysisAfterInterruption
                ?? { candidate, target in
                    try await repository.restoreAnalysisAfterInterruption(
                        candidate,
                        target: target
                    )
                },
            replace: replace ?? { snapshot in
                try await repository.replace(snapshot)
            },
            coordinationEvent: coordinationEvent
        )
    }

    func pendingCandidates(limit: Int) async throws -> [PendingDocumentDNAAnalysis] {
        try await repository.pendingAnalysis(
            sourceRootID: source.id,
            target: target,
            limit: limit
        )
    }

    func insertAdditionalSourceWithDocument() async throws -> SourceRootRecord {
        let additionalSource = SourceRootRecord(
            displayName: "Additional synthetic care documents",
            pathHint: "/synthetic/additional-care",
            bookmarkData: Data("bookmark-additional-care".utf8),
            createdAt: Self.date
        )
        let document = DocumentRecord(
            sourceRootID: additionalSource.id,
            relativePath: "additional-document.pdf",
            contentHash: "hash-additional",
            byteCount: 128,
            modifiedAt: Self.date,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: Self.date,
            lastFingerprintAt: Self.date
        )
        try await db.write { database in
            try additionalSource.insert(database)
            try document.insert(database)
        }
        try await ExtractionRepository(dbWriter: db).replace(
            documentID: document.id,
            analysisVersion: "text-v1",
            extraction: ExtractedDocument(
                method: .embeddedPDFText,
                pages: [ExtractedPage(pageIndex: 0, text: Self.pageText, regions: [])]
            ),
            at: Self.date
        )
        return additionalSource
    }

    func documentDNARowCount() async throws -> Int {
        try await db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM documentDNA") ?? 0
        }
    }

    func failureCodesInPathOrder() async throws -> [String?] {
        try await db.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT documentDNAAnalysisState.failureCode
                    FROM document
                    LEFT JOIN documentDNAAnalysisState
                        ON documentDNAAnalysisState.documentID = document.id
                    WHERE document.sourceRootID = ?
                    ORDER BY document.relativePath
                    """,
                arguments: [source.id]
            ).map { row in
                let failureCode: String? = row["failureCode"]
                return failureCode
            }
        }
    }

    func snapshotRowCounts() async throws -> SnapshotRowCounts {
        try await db.read { database in
            try SnapshotRowCounts(
                headers: Int.fetchOne(database, sql: "SELECT COUNT(*) FROM documentDNA") ?? 0,
                findings: Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM documentDNAFinding"
                ) ?? 0,
                evidence: Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM documentDNAEvidence"
                ) ?? 0
            )
        }
    }

    func analysisStatus(documentID: UUID) async throws -> String? {
        try await db.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT status FROM documentDNAAnalysisState WHERE documentID = ?",
                arguments: [documentID]
            )
        }
    }
}

private actor RecordingDocumentDNAAnalyzer: DocumentDNAAnalyzing {
    private let target: DocumentDNAAnalysisTarget
    private let delay: Duration
    private let outcomesByDocumentID: [UUID: SyntheticAnalyzerOutcome]
    private let suspension: AnalyzerSuspensionGate?
    private let state = RecordingDocumentDNAAnalyzerState()

    init(
        target: DocumentDNAAnalysisTarget,
        delay: Duration = .zero,
        outcomesByDocumentID: [UUID: SyntheticAnalyzerOutcome] = [:],
        suspension: AnalyzerSuspensionGate? = nil
    ) {
        self.target = target
        self.delay = delay
        self.outcomesByDocumentID = outcomesByDocumentID
        self.suspension = suspension
    }

    nonisolated func analyze(
        documentID: UUID,
        contentHash: String,
        extraction: StoredExtraction,
        analyzedAt: Date
    ) throws -> DocumentDNA {
        state.recordCall(documentID: documentID)
        defer { state.finishCall(documentID: documentID) }
        suspension?.suspendAnalysis()
        if delay > .zero {
            let components = delay.components
            Thread.sleep(forTimeInterval: Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000)
        }
        switch outcomesByDocumentID[documentID] ?? .success {
        case .success:
            return try makeDocumentDNASnapshot(
                documentID: documentID,
                target: target,
                contentHash: contentHash,
                extractionVersion: extraction.analysisVersion,
                analyzedAt: analyzedAt
            )
        case .validationFailure:
            throw DocumentDNAValidationError.invalidFinding
        case .syntheticFailure:
            throw SyntheticAnalyzerError.rejected
        case .invalidProvenance:
            return try makeDocumentDNASnapshot(
                documentID: documentID,
                target: target,
                contentHash: contentHash,
                extractionVersion: extraction.analysisVersion,
                analyzedAt: analyzedAt,
                exactText: "Abgelehn"
            )
        case .repositoryInvalidProvenanceFailure:
            throw DocumentDNARepositoryError.invalidProvenance
        case .repositoryStaleFailure:
            throw DocumentDNARepositoryError.staleInput
        }
    }

    var callCount: Int { state.callCount }

    var peakConcurrency: Int { state.peakConcurrency }

    var duplicateDocumentCalls: Int { state.duplicateDocumentCalls }

    func waitUntilFirstCallStarts() async {
        await suspension?.waitUntilStarted()
    }

    func waitUntilCallCountStarts(_ expectedCount: Int) async {
        await state.waitUntilCallCount(expectedCount)
    }

    func releaseAll() async {
        suspension?.release()
    }
}

private enum SyntheticAnalyzerOutcome: Sendable {
    case success
    case validationFailure
    case syntheticFailure
    case invalidProvenance
    case repositoryInvalidProvenanceFailure
    case repositoryStaleFailure
}

private enum SyntheticAnalyzerError: Error {
    case rejected
}

private enum SyntheticPersistenceError: Error {
    case failed
}

enum SnapshotIdentityMismatch: CaseIterable, Sendable {
    case schemaVersion
    case analyzerIdentifier
    case analyzerVersion
    case inputContentHash
    case inputExtractionVersion
}

private struct IdentityViolatingDocumentDNAAnalyzer: DocumentDNAAnalyzing {
    let target: DocumentDNAAnalysisTarget
    var mismatch: SnapshotIdentityMismatch?
    var replacementDocumentID: UUID?

    init(
        target: DocumentDNAAnalysisTarget,
        mismatch: SnapshotIdentityMismatch? = nil,
        replacementDocumentID: UUID? = nil
    ) {
        self.target = target
        self.mismatch = mismatch
        self.replacementDocumentID = replacementDocumentID
    }

    func analyze(
        documentID: UUID,
        contentHash: String,
        extraction: StoredExtraction,
        analyzedAt: Date
    ) throws -> DocumentDNA {
        let returnedTarget = try DocumentDNAAnalysisTarget(
            schemaVersion: mismatch == .schemaVersion
                ? target.schemaVersion + 1
                : target.schemaVersion,
            analyzerIdentifier: mismatch == .analyzerIdentifier
                ? "wrong-analyzer"
                : target.analyzerIdentifier,
            analyzerVersion: mismatch == .analyzerVersion
                ? "wrong-version"
                : target.analyzerVersion
        )
        return try makeDocumentDNASnapshot(
            documentID: replacementDocumentID ?? documentID,
            target: returnedTarget,
            contentHash: mismatch == .inputContentHash
                ? "wrong-content-hash"
                : contentHash,
            extractionVersion: mismatch == .inputExtractionVersion
                ? "wrong-extraction-version"
                : extraction.analysisVersion,
            analyzedAt: analyzedAt
        )
    }
}

private actor BoundedPendingQuery {
    private let maximumCallCount: Int
    private var callCount = 0

    init(maximumCallCount: Int) {
        self.maximumCallCount = maximumCallCount
    }

    func recordCall() throws {
        callCount += 1
        guard callCount <= maximumCallCount else {
            throw SyntheticPersistenceError.failed
        }
    }
}

private struct SnapshotRowCounts: Equatable {
    let headers: Int
    let findings: Int
    let evidence: Int
}

private typealias PendingAnalysisClosure = @Sendable (
    UUID,
    DocumentDNAAnalysisTarget,
    Int
) async throws -> [PendingDocumentDNAAnalysis]
private typealias RecoveryClosure = @Sendable (UUID) async throws -> Void
private typealias CoordinationEventClosure = @Sendable (
    DocumentDNAAnalysisCoordinationEvent
) -> Void
private typealias BeginAnalysisClosure = @Sendable (
    PendingDocumentDNAAnalysis,
    DocumentDNAAnalysisTarget,
    Date
) async throws -> Void
private typealias MarkAnalysisFailedClosure = @Sendable (
    PendingDocumentDNAAnalysis,
    DocumentDNAAnalysisTarget,
    DocumentDNAAnalysisFailureCode,
    Date
) async throws -> Void
private typealias RestoreAnalysisClosure = @Sendable (
    PendingDocumentDNAAnalysis,
    DocumentDNAAnalysisTarget
) async throws -> Void
private typealias ReplaceSnapshotClosure = @Sendable (DocumentDNA) async throws -> Void

private actor PendingAnalysisSequence {
    private let firstBatch: [PendingDocumentDNAAnalysis]
    private let subsequentResult: [PendingDocumentDNAAnalysis]?
    private(set) var callCount = 0

    init(
        firstBatch: [PendingDocumentDNAAnalysis],
        subsequentResult: [PendingDocumentDNAAnalysis]? = nil
    ) {
        self.firstBatch = firstBatch
        self.subsequentResult = subsequentResult
    }

    func next() throws -> [PendingDocumentDNAAnalysis] {
        callCount += 1
        if callCount == 1 {
            return firstBatch
        }
        if let subsequentResult {
            return subsequentResult
        }
        throw SyntheticPersistenceError.failed
    }
}

private final class AnalyzerSuspensionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var started = false
    private var released = false
    private var waitingCount = 0
    private var startWaiter: CheckedContinuation<Void, Never>?

    func suspendAnalysis() {
        let state = lock.withLock { () -> (CheckedContinuation<Void, Never>?, Bool) in
            started = true
            let waiter = startWaiter
            startWaiter = nil
            guard !released else { return (waiter, false) }
            waitingCount += 1
            return (waiter, true)
        }
        state.0?.resume()
        if state.1 {
            releaseSemaphore.wait()
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if started {
                    return true
                }
                startWaiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func release() {
        let signalCount = lock.withLock {
            guard !released else { return 0 }
            released = true
            let count = waitingCount
            waitingCount = 0
            return count
        }
        for _ in 0..<signalCount {
            releaseSemaphore.signal()
        }
    }
}

private actor AsyncSuspensionGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private func expectRunError(
    _ expected: DocumentDNAAnalysisRunError,
    operation: () async throws -> DocumentDNAAnalysisReport
) async {
    do {
        _ = try await operation()
        Issue.record("Expected DocumentDNAAnalysisRunError")
    } catch let error as DocumentDNAAnalysisRunError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected DocumentDNAAnalysisRunError, received \(error)")
    }
}

private func makeDocumentDNASnapshot(
    documentID: UUID,
    target: DocumentDNAAnalysisTarget,
    contentHash: String,
    extractionVersion: String,
    analyzedAt: Date,
    exactText: String = "Rechnung"
) throws -> DocumentDNA {
    try DocumentDNA(
            documentID: documentID,
            schemaVersion: target.schemaVersion,
            analyzerIdentifier: target.analyzerIdentifier,
            analyzerVersion: target.analyzerVersion,
            inputContentHash: contentHash,
            inputExtractionVersion: extractionVersion,
            findings: [DocumentDNAFinding(
                kind: .documentType,
                qualifier: nil,
                displayValue: "Rechnung",
                normalizedValue: "invoice",
                secondaryNormalizedValue: nil,
                confidence: 0.95,
                evidence: [try DocumentDNAEvidence(
                    pageIndex: 0,
                    startUTF16: 0,
                    lengthUTF16: 8,
                    exactText: exactText,
                    ocrRegionIndexes: []
                )]
            )],
            analyzedAt: analyzedAt
        )
}

private final class CoordinationCheckpointRecorder: @unchecked Sendable {
    enum Label: String, Sendable {
        case owner
        case firstLive
        case cancelled
        case nextLive
        case firstSource
        case secondSource
    }

    struct Entry: Sendable, Equatable {
        let label: Label
        let event: DocumentDNAAnalysisCoordinationEvent
    }

    private struct Waiter {
        let label: Label?
        let event: DocumentDNAAnalysisCoordinationEvent
        let continuation: CheckedContinuation<Entry, Never>
    }

    private let lock = NSLock()
    private var recordedEntries: [Entry] = []
    private var waiters: [Waiter] = []

    var acquiredLabels: [Label] {
        lock.withLock {
            recordedEntries.compactMap { entry in
                entry.event == .acquired ? entry.label : nil
            }
        }
    }

    var registeredLabels: [Label] {
        lock.withLock {
            recordedEntries.compactMap { entry in
                entry.event == .waiterRegistered ? entry.label : nil
            }
        }
    }

    func handler(
        label: Label
    ) -> @Sendable (DocumentDNAAnalysisCoordinationEvent) -> Void {
        { [self] event in
            record(Entry(label: label, event: event))
        }
    }

    func waitFor(label: Label, event: DocumentDNAAnalysisCoordinationEvent) async {
        _ = await waitForEntry(label: label, event: event)
    }

    func waitForFirst(event: DocumentDNAAnalysisCoordinationEvent) async -> Entry {
        await waitForEntry(label: nil, event: event)
    }

    private func record(_ entry: Entry) {
        let readyWaiters = lock.withLock {
            recordedEntries.append(entry)
            let ready = waiters.filter { waiter in
                waiter.event == entry.event
                    && (waiter.label == nil || waiter.label == entry.label)
            }
            waiters.removeAll { waiter in
                waiter.event == entry.event
                    && (waiter.label == nil || waiter.label == entry.label)
            }
            return ready
        }
        for waiter in readyWaiters {
            waiter.continuation.resume(returning: entry)
        }
    }

    private func waitForEntry(
        label: Label?,
        event: DocumentDNAAnalysisCoordinationEvent
    ) async -> Entry {
        await withCheckedContinuation { continuation in
            let existing = lock.withLock { () -> Entry? in
                if let entry = recordedEntries.first(where: { entry in
                    entry.event == event && (label == nil || entry.label == label)
                }) {
                    return entry
                }
                waiters.append(Waiter(
                    label: label,
                    event: event,
                    continuation: continuation
                ))
                return nil
            }
            if let existing {
                continuation.resume(returning: existing)
            }
        }
    }
}

private final class RecordingDocumentDNAAnalyzerState: @unchecked Sendable {
    private struct CallCountWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var calls = 0
    private var activeCalls = 0
    private var peakCalls = 0
    private var activeDocumentIDs = Set<UUID>()
    private var duplicateCalls = 0
    private var callCountWaiters: [CallCountWaiter] = []

    var callCount: Int {
        lock.withLock { calls }
    }

    var peakConcurrency: Int {
        lock.withLock { peakCalls }
    }

    var duplicateDocumentCalls: Int {
        lock.withLock { duplicateCalls }
    }

    func recordCall(documentID: UUID) {
        let readyWaiters = lock.withLock {
            calls += 1
            activeCalls += 1
            peakCalls = max(peakCalls, activeCalls)
            if !activeDocumentIDs.insert(documentID).inserted {
                duplicateCalls += 1
            }
            let ready = callCountWaiters.filter { calls >= $0.expectedCount }
            callCountWaiters.removeAll { calls >= $0.expectedCount }
            return ready
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    func finishCall(documentID: UUID) {
        lock.withLock {
            activeCalls -= 1
            activeDocumentIDs.remove(documentID)
        }
    }

    func waitUntilCallCount(_ expectedCount: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard calls < expectedCount else { return true }
                callCountWaiters.append(CallCountWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                ))
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private actor PipelineOperationRecorder {
    private(set) var operations: [String] = []

    func record(_ operation: String) {
        operations.append(operation)
    }
}
