import CoreGraphics
import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Document DNA repository")
struct DocumentDNARepositoryTests {
    @Test func pendingAnalysisReturnsOnlyAvailableReadyDocumentsWithExtraction() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()

        let pending = try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 10
        )

        #expect(pending.map(\.document.relativePath) == ["a-ready.pdf"])
        #expect(pending.map(\.document.contentHash) == ["hash-ready"])
        #expect(pending.map(\.extraction.analysisVersion) == ["text-v1"])
        #expect(pending.map { $0.extraction.extraction.pages.map(\.text) } == [[
            "Rechnung\nBewohnerin: Elise Muster",
        ]])
    }

    @Test func pendingAnalysisIsStableSourceScopedAndLimited() async throws {
        let fixture = try await DocumentDNARepositoryFixture.makeWithOrderedReadyDocuments()

        let pending = try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 2
        )
        let empty = try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 0
        )

        #expect(pending.map(\.document.relativePath) == ["a.pdf", "b.pdf"])
        #expect(empty.isEmpty)
    }

    @Test func pendingAnalysisSkipsCurrentSnapshotsAndExactBlockedAttempts() async throws {
        let fixture = try await DocumentDNARepositoryFixture.makeWithPendingStateCases()

        let pending = try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 20
        )

        #expect(pending.map(\.document.relativePath) == [
            "analyzer-changed.pdf",
            "content-changed.pdf",
            "extraction-changed.pdf",
            "no-snapshot.pdf",
            "schema-changed.pdf",
        ])
    }

    @Test func currentAnalysisStatusesProjectExactPhasesInStableSourceOrder() async throws {
        let fixture = try await DocumentDNARepositoryFixture.makeWithCurrentAnalysisStatuses()

        let statuses = try await fixture.repository.currentAnalysisStatuses(
            sourceRootID: fixture.source.id,
            target: fixture.target
        )

        #expect(statuses == [
            DocumentDNAAnalysisStatus(
                documentID: try #require(await fixture.documentID(relativePath: "a-pending.pdf")),
                phase: .pending
            ),
            DocumentDNAAnalysisStatus(
                documentID: try #require(await fixture.documentID(relativePath: "b-analyzing.pdf")),
                phase: .analyzing
            ),
            DocumentDNAAnalysisStatus(
                documentID: try #require(await fixture.documentID(relativePath: "c-ready.pdf")),
                phase: .ready
            ),
            DocumentDNAAnalysisStatus(
                documentID: try #require(await fixture.documentID(relativePath: "d-analysis-failure.pdf")),
                phase: .failed(.analysisFailure)
            ),
            DocumentDNAAnalysisStatus(
                documentID: try #require(await fixture.documentID(relativePath: "e-invalid-finding.pdf")),
                phase: .failed(.invalidFinding)
            ),
            DocumentDNAAnalysisStatus(
                documentID: try #require(await fixture.documentID(relativePath: "f-invalid-provenance.pdf")),
                phase: .failed(.invalidProvenance)
            ),
        ])
    }

    @Test func currentAnalysisStatusesTreatStaleAndIncompleteStatesAsPending() async throws {
        let fixture = try await DocumentDNARepositoryFixture.makeWithNonCurrentAnalysisStatuses()

        let statuses = try await fixture.repository.currentAnalysisStatuses(
            sourceRootID: fixture.source.id,
            target: fixture.target
        )

        #expect(statuses.map(\.phase) == [
            .pending,
            .pending,
            .pending,
            .pending,
            .pending,
        ])
    }

    @Test func currentAnalysisStatusesRejectInvalidStoredFailureCode() async throws {
        let fixture = try await DocumentDNARepositoryFixture.makeWithInvalidFailureCode()

        await #expect(throws: DocumentDNARepositoryError.invalidStoredState) {
            try await fixture.repository.currentAnalysisStatuses(
                sourceRootID: fixture.source.id,
                target: fixture.target
            )
        }
    }

    @Test func currentAnalysisStatusesDoNotMutatePersistence() async throws {
        let fixture = try await DocumentDNARepositoryFixture.makeWithCurrentAnalysisStatuses()
        let countsBefore = try await fixture.rowCounts()

        _ = try await fixture.repository.currentAnalysisStatuses(
            sourceRootID: fixture.source.id,
            target: fixture.target
        )

        #expect(try await fixture.rowCounts() == countsBefore)
    }

    @Test func targetRejectsInvalidVersionIdentity() {
        #expect(throws: DocumentDNARepositoryError.invalidTarget) {
            try DocumentDNAAnalysisTarget(
                schemaVersion: 0,
                analyzerIdentifier: "local-rules",
                analyzerVersion: "1"
            )
        }
        #expect(throws: DocumentDNARepositoryError.invalidTarget) {
            try DocumentDNAAnalysisTarget(
                schemaVersion: 1,
                analyzerIdentifier: " ",
                analyzerVersion: "1"
            )
        }
        #expect(throws: DocumentDNARepositoryError.invalidTarget) {
            try DocumentDNAAnalysisTarget(
                schemaVersion: 1,
                analyzerIdentifier: "local-rules",
                analyzerVersion: "\n"
            )
        }
    }

    @Test func beginAnalysisWritesExactAttemptAndBlocksPendingSelection() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let candidate = try #require(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 1
        ).first)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_100)

        try await fixture.repository.beginAnalysis(
            candidate,
            target: fixture.target,
            at: startedAt
        )

        #expect(try await fixture.analysisState(documentID: candidate.document.id) ==
            LiteralAnalysisState(
                schemaVersion: 1,
                analyzerIdentifier: "local-rules",
                analyzerVersion: "1",
                contentHash: "hash-ready",
                extractionVersion: "text-v1",
                status: "analyzing",
                failureCode: nil
            ))
        #expect(try await fixture.analysisStateUpdatedAt(
            documentID: candidate.document.id
        ) == startedAt)
        #expect(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 1
        ).isEmpty)
    }

    @Test(arguments: DocumentDNAAnalysisFailureCode.allCases)
    func markAnalysisFailedUpdatesOnlyExactAttempt(
        failureCode: DocumentDNAAnalysisFailureCode
    ) async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let prior = try await fixture.snapshot(analyzerVersion: "0")
        try await fixture.repository.replace(prior)
        let candidate = try #require(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 1
        ).first)
        try await fixture.repository.beginAnalysis(candidate, target: fixture.target, at: .now)
        let failedAt = Date(timeIntervalSince1970: 1_800_000_200)

        try await fixture.repository.markAnalysisFailed(
            candidate,
            target: fixture.target,
            failureCode: failureCode,
            at: failedAt
        )

        #expect(try await fixture.analysisState(documentID: candidate.document.id) ==
            LiteralAnalysisState(
                schemaVersion: 1,
                analyzerIdentifier: "local-rules",
                analyzerVersion: "1",
                contentHash: "hash-ready",
                extractionVersion: "text-v1",
                status: "failed",
                failureCode: failureCode.rawValue
            ))
        #expect(try await fixture.analysisStateUpdatedAt(
            documentID: candidate.document.id
        ) == failedAt)
        #expect(try await fixture.repository.storedSnapshot(documentID: candidate.document.id) == prior)
    }

    @Test func beginRejectsCandidateAfterContentHashChanges() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let candidate = try #require(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 1
        ).first)
        try await fixture.changeContentHash(to: "hash-superseded")

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await fixture.repository.beginAnalysis(candidate, target: fixture.target, at: .now)
        }
        #expect(try await fixture.analysisState(documentID: candidate.document.id) == nil)
        #expect(try await fixture.repository.storedSnapshot(documentID: candidate.document.id) == nil)
    }

    @Test func beginRejectsCandidateAfterExtractionVersionChanges() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let candidate = try #require(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 1
        ).first)
        try await fixture.changeExtractionVersion(to: "text-v2")

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await fixture.repository.beginAnalysis(candidate, target: fixture.target, at: .now)
        }
        #expect(try await fixture.analysisState(documentID: candidate.document.id) == nil)
        #expect(try await fixture.repository.storedSnapshot(documentID: candidate.document.id) == nil)
    }

    @Test func beginRejectsDocumentThatIsNotReadyOrAvailable() async throws {
        let notReady = try await DocumentDNARepositoryFixture.make()
        let notReadyCandidate = try #require(try await notReady.repository.pendingAnalysis(
            sourceRootID: notReady.source.id,
            target: notReady.target,
            limit: 1
        ).first)
        try await notReady.changeDocumentStatus(to: .discovered)

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await notReady.repository.beginAnalysis(
                notReadyCandidate,
                target: notReady.target,
                at: .now
            )
        }
        #expect(try await notReady.analysisState(documentID: notReadyCandidate.document.id) == nil)

        let unavailable = try await DocumentDNARepositoryFixture.make()
        let unavailableCandidate = try #require(try await unavailable.repository.pendingAnalysis(
            sourceRootID: unavailable.source.id,
            target: unavailable.target,
            limit: 1
        ).first)
        try await unavailable.changeDocumentAvailability(to: .unavailable)

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await unavailable.repository.beginAnalysis(
                unavailableCandidate,
                target: unavailable.target,
                at: .now
            )
        }
        #expect(try await unavailable.analysisState(documentID: unavailableCandidate.document.id) == nil)
    }

    @Test func beginRejectsCurrentSnapshotAndExactBlockedAttempt() async throws {
        let current = try await DocumentDNARepositoryFixture.make()
        let currentCandidate = try #require(try await current.repository.pendingAnalysis(
            sourceRootID: current.source.id,
            target: current.target,
            limit: 1
        ).first)
        let currentSnapshot = try await current.snapshot()
        try await current.repository.replace(currentSnapshot)

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await current.repository.beginAnalysis(
                currentCandidate,
                target: current.target,
                at: .now
            )
        }
        #expect(try await current.repository.storedSnapshot(
            documentID: currentCandidate.document.id
        ) == currentSnapshot)
        #expect(try await current.analysisState(documentID: currentCandidate.document.id)?.status == "ready")

        for status in ["failed", "analyzing"] {
            let blocked = try await DocumentDNARepositoryFixture.make()
            let blockedCandidate = try #require(try await blocked.repository.pendingAnalysis(
                sourceRootID: blocked.source.id,
                target: blocked.target,
                limit: 1
            ).first)
            try await blocked.insertAnalysisState(
                document: blockedCandidate.document,
                status: status,
                failureCode: status == "failed" ? "analysisFailure" : nil
            )
            let priorState = try await blocked.analysisState(documentID: blockedCandidate.document.id)

            await #expect(throws: DocumentDNARepositoryError.staleInput) {
                try await blocked.repository.beginAnalysis(
                    blockedCandidate,
                    target: blocked.target,
                    at: .now
                )
            }
            #expect(try await blocked.analysisState(documentID: blockedCandidate.document.id) == priorState)
            #expect(try await blocked.repository.storedSnapshot(
                documentID: blockedCandidate.document.id
            ) == nil)
        }
    }

    @Test func failedTransitionRejectsSupersededTupleAndTerminalState() async throws {
        let differentTarget = try await DocumentDNARepositoryFixture.make()
        let targetCandidate = try #require(try await differentTarget.repository.pendingAnalysis(
            sourceRootID: differentTarget.source.id,
            target: differentTarget.target,
            limit: 1
        ).first)
        try await differentTarget.repository.beginAnalysis(
            targetCandidate,
            target: differentTarget.target,
            at: .now
        )
        let targetState = try await differentTarget.analysisState(documentID: targetCandidate.document.id)

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await differentTarget.repository.markAnalysisFailed(
                targetCandidate,
                target: differentTarget.target(analyzerVersion: "2"),
                failureCode: .analysisFailure,
                at: .now
            )
        }
        #expect(try await differentTarget.analysisState(documentID: targetCandidate.document.id) == targetState)

        let differentContent = try await DocumentDNARepositoryFixture.make()
        let contentCandidate = try #require(try await differentContent.repository.pendingAnalysis(
            sourceRootID: differentContent.source.id,
            target: differentContent.target,
            limit: 1
        ).first)
        try await differentContent.repository.beginAnalysis(
            contentCandidate,
            target: differentContent.target,
            at: .now
        )
        var changedDocument = contentCandidate.document
        changedDocument.contentHash = "hash-different-candidate"
        let changedCandidate = PendingDocumentDNAAnalysis(
            document: changedDocument,
            extraction: contentCandidate.extraction
        )
        let contentState = try await differentContent.analysisState(documentID: contentCandidate.document.id)

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await differentContent.repository.markAnalysisFailed(
                changedCandidate,
                target: differentContent.target,
                failureCode: .analysisFailure,
                at: .now
            )
        }
        #expect(try await differentContent.analysisState(documentID: contentCandidate.document.id) == contentState)

        let changedExtraction = try await DocumentDNARepositoryFixture.make()
        let extractionCandidate = try #require(try await changedExtraction.repository.pendingAnalysis(
            sourceRootID: changedExtraction.source.id,
            target: changedExtraction.target,
            limit: 1
        ).first)
        try await changedExtraction.repository.beginAnalysis(
            extractionCandidate,
            target: changedExtraction.target,
            at: .now
        )
        try await changedExtraction.changeExtractionVersion(to: "text-v2")
        let extractionState = try await changedExtraction.analysisState(
            documentID: extractionCandidate.document.id
        )

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await changedExtraction.repository.markAnalysisFailed(
                extractionCandidate,
                target: changedExtraction.target,
                failureCode: .analysisFailure,
                at: .now
            )
        }
        #expect(try await changedExtraction.analysisState(
            documentID: extractionCandidate.document.id
        ) == extractionState)

        let terminal = try await DocumentDNARepositoryFixture.make()
        let terminalCandidate = try #require(try await terminal.repository.pendingAnalysis(
            sourceRootID: terminal.source.id,
            target: terminal.target,
            limit: 1
        ).first)
        try await terminal.repository.beginAnalysis(
            terminalCandidate,
            target: terminal.target,
            at: .now
        )
        try await terminal.changeAnalysisStateStatus(to: "ready")
        let terminalState = try await terminal.analysisState(documentID: terminalCandidate.document.id)

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await terminal.repository.markAnalysisFailed(
                terminalCandidate,
                target: terminal.target,
                failureCode: .analysisFailure,
                at: .now
            )
        }
        #expect(try await terminal.analysisState(documentID: terminalCandidate.document.id) == terminalState)
    }

    @Test func failedTransitionRejectsCandidateAfterSourceRootChanges() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let prior = try await fixture.snapshot(analyzerVersion: "0")
        try await fixture.repository.replace(prior)
        let candidate = try #require(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 1
        ).first)
        try await fixture.repository.beginAnalysis(candidate, target: fixture.target, at: .now)
        let priorState = try await fixture.analysisState(documentID: candidate.document.id)
        try await fixture.changeDocumentSourceRootID(to: fixture.otherSource.id)

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await fixture.repository.markAnalysisFailed(
                candidate,
                target: fixture.target,
                failureCode: .analysisFailure,
                at: .now
            )
        }
        #expect(try await fixture.analysisState(documentID: candidate.document.id) == priorState)
        #expect(try await fixture.repository.storedSnapshot(documentID: candidate.document.id) == prior)
    }

    @Test func interruptionRestorationIsExactAndIdempotent() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let candidate = try #require(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 1
        ).first)
        try await fixture.repository.beginAnalysis(candidate, target: fixture.target, at: .now)

        try await fixture.repository.restoreAnalysisAfterInterruption(
            candidate,
            target: fixture.target
        )
        try await fixture.repository.restoreAnalysisAfterInterruption(
            candidate,
            target: fixture.target
        )

        #expect(try await fixture.analysisState(documentID: candidate.document.id) == nil)
        #expect(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 1
        ).map(\.document.id) == [candidate.document.id])
    }

    @Test func interruptionRestorationPreservesDifferentTuplesAndTerminalStates() async throws {
        let differentTarget = try await DocumentDNARepositoryFixture.make()
        let targetCandidate = try #require(try await differentTarget.repository.pendingAnalysis(
            sourceRootID: differentTarget.source.id,
            target: differentTarget.target,
            limit: 1
        ).first)
        try await differentTarget.repository.beginAnalysis(
            targetCandidate,
            target: differentTarget.target,
            at: .now
        )
        try await differentTarget.repository.restoreAnalysisAfterInterruption(
            targetCandidate,
            target: try differentTarget.target(analyzerVersion: "2")
        )
        #expect(try await differentTarget.analysisState(
            documentID: targetCandidate.document.id
        ) == LiteralAnalysisState(
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            contentHash: "hash-ready",
            extractionVersion: "text-v1",
            status: "analyzing",
            failureCode: nil
        ))

        let differentInput = try await DocumentDNARepositoryFixture.make()
        let inputCandidate = try #require(try await differentInput.repository.pendingAnalysis(
            sourceRootID: differentInput.source.id,
            target: differentInput.target,
            limit: 1
        ).first)
        try await differentInput.repository.beginAnalysis(
            inputCandidate,
            target: differentInput.target,
            at: .now
        )
        var changedDocument = inputCandidate.document
        changedDocument.contentHash = "hash-different-candidate"
        let changedCandidate = PendingDocumentDNAAnalysis(
            document: changedDocument,
            extraction: inputCandidate.extraction
        )
        try await differentInput.repository.restoreAnalysisAfterInterruption(
            changedCandidate,
            target: differentInput.target
        )
        #expect(try await differentInput.analysisState(
            documentID: inputCandidate.document.id
        ) == LiteralAnalysisState(
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            contentHash: "hash-ready",
            extractionVersion: "text-v1",
            status: "analyzing",
            failureCode: nil
        ))

        for status in ["ready", "failed"] {
            let terminal = try await DocumentDNARepositoryFixture.make()
            let terminalCandidate = try #require(try await terminal.repository.pendingAnalysis(
                sourceRootID: terminal.source.id,
                target: terminal.target,
                limit: 1
            ).first)
            try await terminal.repository.beginAnalysis(
                terminalCandidate,
                target: terminal.target,
                at: .now
            )
            try await terminal.changeAnalysisStateStatus(
                to: status,
                failureCode: status == "failed" ? "analysisFailure" : nil
            )
            try await terminal.repository.restoreAnalysisAfterInterruption(
                terminalCandidate,
                target: terminal.target
            )
            #expect(try await terminal.analysisState(
                documentID: terminalCandidate.document.id
            ) == LiteralAnalysisState(
                schemaVersion: 1,
                analyzerIdentifier: "local-rules",
                analyzerVersion: "1",
                contentHash: "hash-ready",
                extractionVersion: "text-v1",
                status: status,
                failureCode: status == "failed" ? "analysisFailure" : nil
            ))
        }
    }

    @Test func recoveryRemovesOnlyAnalyzingAttemptsForRequestedSource() async throws {
        let fixture = try await DocumentDNARepositoryFixture.makeWithTwoSourcesAndStates()

        try await fixture.repository.recoverInterruptedAnalysis(sourceRootID: fixture.source.id)
        try await fixture.repository.recoverInterruptedAnalysis(sourceRootID: fixture.source.id)

        #expect(try await fixture.analysisStatus(relativePath: "source-a-analyzing.pdf") == nil)
        #expect(try await fixture.analysisStatus(relativePath: "source-a-failed.pdf") == "failed")
        #expect(try await fixture.analysisStatus(relativePath: "source-a-ready.pdf") == "ready")
        #expect(try await fixture.analysisStatus(relativePath: "source-b-analyzing.pdf") == "analyzing")
    }

    @Test func retryIsIdempotentAndClearsOnlyFailedState() async throws {
        let fixture = try await DocumentDNARepositoryFixture.makeWithRetryStates()
        let failedID = try #require(await fixture.documentID(relativePath: "failed.pdf"))

        try await fixture.repository.retryFailedAnalysis(documentID: failedID)
        try await fixture.repository.retryFailedAnalysis(documentID: failedID)

        #expect(try await fixture.analysisStatus(relativePath: "failed.pdf") == nil)
        #expect(try await fixture.analysisStatus(relativePath: "ready.pdf") == "ready")
        #expect(try await fixture.analysisStatus(relativePath: "analyzing.pdf") == "analyzing")
        #expect(try await fixture.repository.storedSnapshot(documentID: failedID) != nil)
    }

    @Test func replaceRoundTripsCompleteSnapshotAndMarksMatchingStateReady() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let snapshot = try await fixture.snapshot()

        try await fixture.repository.replace(snapshot)

        #expect(try await fixture.repository.storedSnapshot(documentID: snapshot.documentID) == snapshot)
        let state = try await fixture.analysisState(documentID: snapshot.documentID)
        #expect(state == LiteralAnalysisState(
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            contentHash: "hash-ready",
            extractionVersion: "text-v1",
            status: "ready",
            failureCode: nil
        ))
    }

    @Test func analyzedAtRoundTripsSubmillisecondPrecision() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let analyzedAt = Date(timeIntervalSinceReferenceDate: 123_456_789.123_456_7)
        let snapshot = try await fixture.snapshot(analyzedAt: analyzedAt)

        try await fixture.repository.replace(snapshot)

        let stored = try #require(try await fixture.repository.storedSnapshot(
            documentID: snapshot.documentID
        ))
        #expect(stored.analyzedAt == analyzedAt)
        #expect(stored == snapshot)
    }

    @Test func storedSnapshotDecodesLegacyGRDBDateText() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let analyzedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try await fixture.snapshot(analyzedAt: analyzedAt)
        try await fixture.repository.replace(snapshot)
        try await fixture.rewriteAnalyzedAtUsingLegacyGRDBDate(analyzedAt)

        #expect(try await fixture.repository.storedSnapshot(
            documentID: snapshot.documentID
        ) == snapshot)
    }

    @Test func readyStateKeepsGRDBDateStorageContract() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let snapshot = try await fixture.snapshot()

        try await fixture.repository.replace(snapshot)

        #expect(try await fixture.analysisStateUpdatedAt(
            documentID: snapshot.documentID
        ) == snapshot.analyzedAt)
    }

    @Test func replacementIsVersionIdempotentAndDoesNotAppendChildren() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let versionOne = try await fixture.snapshot()
        let versionTwoTarget = try fixture.target(analyzerVersion: "2")
        let versionTwo = try await fixture.snapshot(analyzerVersion: "2")

        try await fixture.repository.replace(versionOne)
        #expect(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 10
        ).isEmpty)
        #expect(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: versionTwoTarget,
            limit: 10
        ).map(\.document.id) == [versionOne.documentID])

        try await fixture.repository.replace(versionTwo)

        #expect(try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: versionTwoTarget,
            limit: 10
        ).isEmpty)
        #expect(try await fixture.rowCounts() == DNARowCounts(
            snapshots: 1,
            findings: 2,
            evidence: 2,
            states: 1
        ))
    }

    @Test func failedChildWriteRollsBackCompleteReplacement() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let original = try await fixture.snapshot()
        let replacement = try await fixture.snapshot(analyzerVersion: "2")
        try await fixture.repository.replace(original)
        try await fixture.installEvidenceRejectionTrigger()
        var didThrow = false

        do {
            try await fixture.repository.replace(replacement)
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try await fixture.repository.storedSnapshot(documentID: original.documentID) == original)
        #expect(try await fixture.analysisState(documentID: original.documentID)?.analyzerVersion == "1")
        #expect(try await fixture.rowCounts() == DNARowCounts(
            snapshots: 1,
            findings: 2,
            evidence: 2,
            states: 1
        ))
    }

    @Test func currentSnapshotRequiresMatchingTargetAndExtractionInput() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let snapshot = try await fixture.snapshot()
        try await fixture.repository.replace(snapshot)

        #expect(try await fixture.repository.currentSnapshot(
            documentID: snapshot.documentID,
            target: fixture.target
        ) == snapshot)
        #expect(try await fixture.repository.currentSnapshot(
            documentID: snapshot.documentID,
            target: fixture.target(analyzerVersion: "2")
        ) == nil)

        try await fixture.changeExtractionVersion(to: "text-v2")

        #expect(try await fixture.repository.currentSnapshot(
            documentID: snapshot.documentID,
            target: fixture.target
        ) == nil)
        #expect(try await fixture.repository.storedSnapshot(documentID: snapshot.documentID) == snapshot)
    }

    @Test func currentSnapshotRequiresMatchingCatalogContentHash() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let snapshot = try await fixture.snapshot()
        try await fixture.repository.replace(snapshot)

        try await fixture.changeContentHash(to: "hash-changed")

        #expect(try await fixture.repository.currentSnapshot(
            documentID: snapshot.documentID,
            target: fixture.target
        ) == nil)
        #expect(try await fixture.repository.storedSnapshot(documentID: snapshot.documentID) == snapshot)
    }

    @Test func staleContentHashRejectsFirstAndReplacementWrites() async throws {
        let replacementFixture = try await DocumentDNARepositoryFixture.make()
        let original = try await replacementFixture.snapshot()
        let staleReplacement = try await replacementFixture.snapshot(analyzerVersion: "2")
        try await replacementFixture.repository.replace(original)
        try await replacementFixture.changeContentHash(to: "hash-changed")

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await replacementFixture.repository.replace(staleReplacement)
        }
        #expect(try await replacementFixture.repository.storedSnapshot(
            documentID: original.documentID
        ) == original)

        let firstWriteFixture = try await DocumentDNARepositoryFixture.make()
        let staleFirstWrite = try await firstWriteFixture.snapshot()
        try await firstWriteFixture.changeContentHash(to: "hash-changed")

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await firstWriteFixture.repository.replace(staleFirstWrite)
        }
        #expect(try await firstWriteFixture.rowCounts() == DNARowCounts(
            snapshots: 0,
            findings: 0,
            evidence: 0,
            states: 0
        ))
    }

    @Test func staleExtractionVersionRejectsReplacementWithoutChangingDocumentStatus() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()
        let original = try await fixture.snapshot()
        let staleReplacement = try await fixture.snapshot(analyzerVersion: "2")
        try await fixture.repository.replace(original)
        try await fixture.changeExtractionVersion(to: "text-v2")

        await #expect(throws: DocumentDNARepositoryError.staleInput) {
            try await fixture.repository.replace(staleReplacement)
        }

        #expect(try await fixture.repository.storedSnapshot(documentID: original.documentID) == original)
        #expect(try await fixture.analysisState(documentID: original.documentID)?.analyzerVersion == "1")
        #expect(try await fixture.documentStatus() == .ready)
    }

    @Test func invalidProvenanceRejectsMissingPage() async throws {
        try await assertInvalidProvenance(DocumentDNAEvidence(
            pageIndex: 9,
            startUTF16: 0,
            lengthUTF16: 8,
            exactText: "Rechnung",
            ocrRegionIndexes: [0]
        ))
    }

    @Test func invalidProvenanceRejectsWrongExactText() async throws {
        try await assertInvalidProvenance(DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 0,
            lengthUTF16: 8,
            exactText: "Vertragx",
            ocrRegionIndexes: [0]
        ))
    }

    @Test func invalidProvenanceRejectsOutOfBoundsUTF16Range() async throws {
        try await assertInvalidProvenance(DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 100,
            lengthUTF16: 8,
            exactText: "Rechnung",
            ocrRegionIndexes: [0]
        ))
    }

    @Test func invalidProvenanceRejectsWrongOCRRegionIndexes() async throws {
        try await assertInvalidProvenance(DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 0,
            lengthUTF16: 8,
            exactText: "Rechnung",
            ocrRegionIndexes: [1]
        ))
    }

    @Test func invalidProvenanceRejectsMissingOCRRegionIndexes() async throws {
        try await assertInvalidProvenance(DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 0,
            lengthUTF16: 8,
            exactText: "Rechnung",
            ocrRegionIndexes: []
        ))
    }

    private func assertInvalidProvenance(_ evidence: DocumentDNAEvidence) async throws {
        let firstWriteFixture = try await DocumentDNARepositoryFixture.make()
        let invalidFirstWrite = try await firstWriteFixture.snapshot(
            classificationEvidence: evidence
        )

        await #expect(throws: DocumentDNARepositoryError.invalidProvenance) {
            try await firstWriteFixture.repository.replace(invalidFirstWrite)
        }
        #expect(try await firstWriteFixture.rowCounts() == DNARowCounts(
            snapshots: 0,
            findings: 0,
            evidence: 0,
            states: 0
        ))

        let replacementFixture = try await DocumentDNARepositoryFixture.make()
        let original = try await replacementFixture.snapshot()
        let invalidReplacement = try await replacementFixture.snapshot(
            analyzerVersion: "2",
            classificationEvidence: evidence
        )
        try await replacementFixture.repository.replace(original)

        await #expect(throws: DocumentDNARepositoryError.invalidProvenance) {
            try await replacementFixture.repository.replace(invalidReplacement)
        }
        #expect(try await replacementFixture.repository.storedSnapshot(
            documentID: original.documentID
        ) == original)
        #expect(try await replacementFixture.analysisState(
            documentID: original.documentID
        )?.analyzerVersion == "1")
    }
}

private struct LiteralAnalysisState: Equatable {
    let schemaVersion: Int
    let analyzerIdentifier: String
    let analyzerVersion: String
    let contentHash: String
    let extractionVersion: String
    let status: String
    let failureCode: String?
}

private struct DNARowCounts: Equatable {
    let snapshots: Int
    let findings: Int
    let evidence: Int
    let states: Int
}

private struct DocumentDNARepositoryFixture {
    static let pageText = "Rechnung\nBewohnerin: Elise Muster"
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    let db: DatabaseQueue
    let source: SourceRootRecord
    let otherSource: SourceRootRecord
    let repository: DocumentDNARepository
    let target: DocumentDNAAnalysisTarget

    static func make() async throws -> Self {
        var fixture = try await makeEmpty()
        _ = try await fixture.insertDocument(
            relativePath: "a-ready.pdf",
            contentHash: "hash-ready"
        )
        _ = try await fixture.insertDocument(
            relativePath: "b-discovered.pdf",
            contentHash: "hash-discovered",
            status: .discovered
        )
        _ = try await fixture.insertDocument(
            relativePath: "c-unavailable.pdf",
            contentHash: "hash-unavailable",
            availability: .unavailable
        )
        _ = try await fixture.insertDocument(
            relativePath: "d-no-extraction.pdf",
            contentHash: "hash-no-extraction",
            storesExtraction: false
        )
        _ = try await fixture.insertDocument(
            sourceRootID: fixture.otherSource.id,
            relativePath: "aa-other-source.pdf",
            contentHash: "hash-other"
        )
        return fixture
    }

    static func makeWithOrderedReadyDocuments() async throws -> Self {
        var fixture = try await makeEmpty()
        for path in ["c.pdf", "a.pdf", "b.pdf"] {
            _ = try await fixture.insertDocument(
                relativePath: path,
                contentHash: "hash-\(path)"
            )
        }
        _ = try await fixture.insertDocument(
            sourceRootID: fixture.otherSource.id,
            relativePath: "0-other.pdf",
            contentHash: "hash-other"
        )
        return fixture
    }

    static func makeWithCurrentAnalysisStatuses() async throws -> Self {
        var fixture = try await makeEmpty()
        let ready = try await fixture.insertDocument(
            relativePath: "c-ready.pdf",
            contentHash: "hash-ready"
        )
        let invalidProvenance = try await fixture.insertDocument(
            relativePath: "f-invalid-provenance.pdf",
            contentHash: "hash-invalid-provenance"
        )
        _ = try await fixture.insertDocument(
            relativePath: "a-pending.pdf",
            contentHash: "hash-pending"
        )
        let analyzing = try await fixture.insertDocument(
            relativePath: "b-analyzing.pdf",
            contentHash: "hash-analyzing"
        )
        let analysisFailure = try await fixture.insertDocument(
            relativePath: "d-analysis-failure.pdf",
            contentHash: "hash-analysis-failure"
        )
        let invalidFinding = try await fixture.insertDocument(
            relativePath: "e-invalid-finding.pdf",
            contentHash: "hash-invalid-finding"
        )
        _ = try await fixture.insertDocument(
            relativePath: "0-discovered.pdf",
            contentHash: "hash-discovered",
            status: .discovered
        )
        _ = try await fixture.insertDocument(
            relativePath: "0-unavailable.pdf",
            contentHash: "hash-unavailable",
            availability: .unavailable
        )
        _ = try await fixture.insertDocument(
            relativePath: "0-no-extraction.pdf",
            contentHash: "hash-no-extraction",
            storesExtraction: false
        )
        _ = try await fixture.insertDocument(
            sourceRootID: fixture.otherSource.id,
            relativePath: "0-other-source.pdf",
            contentHash: "hash-other-source"
        )

        try await fixture.repository.replace(try await fixture.snapshot(document: ready))
        try await fixture.insertAnalysisState(document: analyzing, status: "analyzing")
        try await fixture.insertAnalysisState(
            document: analysisFailure,
            status: "failed",
            failureCode: DocumentDNAAnalysisFailureCode.analysisFailure.rawValue
        )
        try await fixture.insertAnalysisState(
            document: invalidFinding,
            status: "failed",
            failureCode: DocumentDNAAnalysisFailureCode.invalidFinding.rawValue
        )
        try await fixture.insertAnalysisState(
            document: invalidProvenance,
            status: "failed",
            failureCode: DocumentDNAAnalysisFailureCode.invalidProvenance.rawValue
        )
        return fixture
    }

    static func makeWithNonCurrentAnalysisStatuses() async throws -> Self {
        var fixture = try await makeEmpty()
        let targetChanged = try await fixture.insertDocument(
            relativePath: "a-target-changed.pdf",
            contentHash: "hash-target"
        )
        let contentChanged = try await fixture.insertDocument(
            relativePath: "b-content-changed.pdf",
            contentHash: "hash-content"
        )
        let extractionChanged = try await fixture.insertDocument(
            relativePath: "c-extraction-changed.pdf",
            contentHash: "hash-extraction"
        )
        let readyWithoutSnapshot = try await fixture.insertDocument(
            relativePath: "d-ready-without-snapshot.pdf",
            contentHash: "hash-ready-without-snapshot"
        )
        let snapshotWithoutReady = try await fixture.insertDocument(
            relativePath: "e-snapshot-without-ready.pdf",
            contentHash: "hash-snapshot-without-ready"
        )

        try await fixture.insertAnalysisState(
            document: targetChanged,
            status: "analyzing",
            analyzerVersion: "0"
        )
        try await fixture.insertAnalysisState(
            document: contentChanged,
            status: "failed",
            failureCode: DocumentDNAAnalysisFailureCode.analysisFailure.rawValue,
            inputContentHash: "hash-before-change"
        )
        try await fixture.insertAnalysisState(
            document: extractionChanged,
            status: "analyzing",
            inputExtractionVersion: "text-v0"
        )
        try await fixture.insertAnalysisState(document: readyWithoutSnapshot, status: "ready")
        try await fixture.insertSnapshotHeader(
            document: snapshotWithoutReady,
            schemaVersion: fixture.target.schemaVersion,
            analyzerIdentifier: fixture.target.analyzerIdentifier,
            analyzerVersion: fixture.target.analyzerVersion,
            inputContentHash: snapshotWithoutReady.contentHash,
            inputExtractionVersion: "text-v1"
        )
        return fixture
    }

    static func makeWithInvalidFailureCode() async throws -> Self {
        var fixture = try await makeEmpty()
        let document = try await fixture.insertDocument(
            relativePath: "invalid-failure-code.pdf",
            contentHash: "hash-invalid-failure-code"
        )
        try await fixture.insertAnalysisState(
            document: document,
            status: "failed",
            failureCode: "contains-private-details"
        )
        return fixture
    }

    static func makeWithPendingStateCases() async throws -> Self {
        var fixture = try await makeEmpty()
        let analyzerChanged = try await fixture.insertDocument(
            relativePath: "analyzer-changed.pdf",
            contentHash: "hash-analyzer"
        )
        let contentChanged = try await fixture.insertDocument(
            relativePath: "content-changed.pdf",
            contentHash: "hash-content"
        )
        let extractionChanged = try await fixture.insertDocument(
            relativePath: "extraction-changed.pdf",
            contentHash: "hash-extraction"
        )
        _ = try await fixture.insertDocument(
            relativePath: "no-snapshot.pdf",
            contentHash: "hash-none"
        )
        let schemaChanged = try await fixture.insertDocument(
            relativePath: "schema-changed.pdf",
            contentHash: "hash-schema"
        )
        let analyzing = try await fixture.insertDocument(
            relativePath: "blocked-analyzing.pdf",
            contentHash: "hash-analyzing"
        )
        let failed = try await fixture.insertDocument(
            relativePath: "blocked-failed.pdf",
            contentHash: "hash-failed"
        )
        let current = try await fixture.insertDocument(
            relativePath: "current.pdf",
            contentHash: "hash-current"
        )

        try await fixture.insertSnapshotHeader(
            document: analyzerChanged,
            schemaVersion: 1,
            analyzerIdentifier: "old-rules",
            analyzerVersion: "1",
            inputContentHash: analyzerChanged.contentHash,
            inputExtractionVersion: "text-v1"
        )
        try await fixture.insertSnapshotHeader(
            document: contentChanged,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: "hash-before-change",
            inputExtractionVersion: "text-v1"
        )
        try await fixture.insertSnapshotHeader(
            document: extractionChanged,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: extractionChanged.contentHash,
            inputExtractionVersion: "text-v0"
        )
        try await fixture.insertSnapshotHeader(
            document: schemaChanged,
            schemaVersion: 2,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: schemaChanged.contentHash,
            inputExtractionVersion: "text-v1"
        )
        try await fixture.insertSnapshotHeader(
            document: current,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: current.contentHash,
            inputExtractionVersion: "text-v1"
        )
        try await fixture.insertAnalysisState(document: analyzing, status: "analyzing")
        try await fixture.insertAnalysisState(
            document: failed,
            status: "failed",
            failureCode: "syntheticFailure"
        )
        return fixture
    }

    static func makeWithTwoSourcesAndStates() async throws -> Self {
        var fixture = try await makeEmpty()
        let sourceAAnalyzing = try await fixture.insertDocument(
            relativePath: "source-a-analyzing.pdf",
            contentHash: "hash-source-a-analyzing"
        )
        let sourceAFailed = try await fixture.insertDocument(
            relativePath: "source-a-failed.pdf",
            contentHash: "hash-source-a-failed"
        )
        let sourceAReady = try await fixture.insertDocument(
            relativePath: "source-a-ready.pdf",
            contentHash: "hash-source-a-ready"
        )
        let sourceBAnalyzing = try await fixture.insertDocument(
            sourceRootID: fixture.otherSource.id,
            relativePath: "source-b-analyzing.pdf",
            contentHash: "hash-source-b-analyzing"
        )
        try await fixture.insertAnalysisState(document: sourceAAnalyzing, status: "analyzing")
        try await fixture.insertAnalysisState(
            document: sourceAFailed,
            status: "failed",
            failureCode: "analysisFailure"
        )
        try await fixture.insertAnalysisState(document: sourceAReady, status: "ready")
        try await fixture.insertAnalysisState(document: sourceBAnalyzing, status: "analyzing")
        return fixture
    }

    static func makeWithRetryStates() async throws -> Self {
        var fixture = try await makeEmpty()
        let failed = try await fixture.insertDocument(
            relativePath: "failed.pdf",
            contentHash: "hash-failed"
        )
        let ready = try await fixture.insertDocument(
            relativePath: "ready.pdf",
            contentHash: "hash-ready"
        )
        let analyzing = try await fixture.insertDocument(
            relativePath: "analyzing.pdf",
            contentHash: "hash-analyzing"
        )
        try await fixture.repository.replace(try await fixture.snapshot(document: failed))
        try await fixture.changeAnalysisStateStatus(
            documentID: failed.id,
            to: "failed",
            failureCode: "analysisFailure"
        )
        try await fixture.insertAnalysisState(document: ready, status: "ready")
        try await fixture.insertAnalysisState(document: analyzing, status: "analyzing")
        return fixture
    }

    private static func makeEmpty() async throws -> Self {
        let db = try TestDatabase.make()
        let source = SourceRootRecord(
            displayName: "Synthetic care documents",
            pathHint: "/synthetic/care",
            bookmarkData: Data("bookmark-care".utf8),
            createdAt: date
        )
        let otherSource = SourceRootRecord(
            displayName: "Other synthetic documents",
            pathHint: "/synthetic/other",
            bookmarkData: Data("bookmark-other".utf8),
            createdAt: date
        )
        try await db.write { database in
            try source.insert(database)
            try otherSource.insert(database)
        }
        return Self(
            db: db,
            source: source,
            otherSource: otherSource,
            repository: DocumentDNARepository(dbWriter: db),
            target: try DocumentDNAAnalysisTarget(
                schemaVersion: 1,
                analyzerIdentifier: "local-rules",
                analyzerVersion: "1"
            )
        )
    }

    private mutating func insertDocument(
        sourceRootID: UUID? = nil,
        relativePath: String,
        contentHash: String,
        status: DocumentStatus = .ready,
        availability: DocumentAvailability = .available,
        storesExtraction: Bool = true
    ) async throws -> DocumentRecord {
        let document = DocumentRecord(
            sourceRootID: sourceRootID ?? source.id,
            relativePath: relativePath,
            contentHash: contentHash,
            byteCount: 128,
            modifiedAt: Self.date,
            mediaType: .pdf,
            status: status,
            availability: availability,
            pageCount: status == .ready ? 1 : nil,
            lastSeenAt: Self.date,
            lastFingerprintAt: Self.date
        )
        try await db.write { database in
            try document.insert(database)
        }
        if storesExtraction {
            try await ExtractionRepository(dbWriter: db).replace(
                documentID: document.id,
                analysisVersion: "text-v1",
                extraction: Self.extraction,
                at: Self.date
            )
        }
        return document
    }

    private func insertSnapshotHeader(
        document: DocumentRecord,
        schemaVersion: Int,
        analyzerIdentifier: String,
        analyzerVersion: String,
        inputContentHash: String,
        inputExtractionVersion: String
    ) async throws {
        try await db.write { database in
            try database.execute(
                sql: """
                    INSERT INTO documentDNA (
                        documentID, schemaVersion, analyzerIdentifier, analyzerVersion,
                        inputContentHash, inputExtractionVersion, analyzedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    document.id,
                    schemaVersion,
                    analyzerIdentifier,
                    analyzerVersion,
                    inputContentHash,
                    inputExtractionVersion,
                    Self.date,
                ]
            )
        }
    }

    func insertAnalysisState(
        document: DocumentRecord,
        status: String,
        failureCode: String? = nil,
        schemaVersion: Int? = nil,
        analyzerIdentifier: String? = nil,
        analyzerVersion: String? = nil,
        inputContentHash: String? = nil,
        inputExtractionVersion: String? = nil
    ) async throws {
        try await db.write { database in
            try database.execute(
                sql: """
                    INSERT INTO documentDNAAnalysisState (
                        documentID, targetSchemaVersion, targetAnalyzerIdentifier,
                        targetAnalyzerVersion, inputContentHash, inputExtractionVersion,
                        status, failureCode, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    document.id,
                    schemaVersion ?? target.schemaVersion,
                    analyzerIdentifier ?? target.analyzerIdentifier,
                    analyzerVersion ?? target.analyzerVersion,
                    inputContentHash ?? document.contentHash,
                    inputExtractionVersion ?? "text-v1",
                    status,
                    failureCode,
                    Self.date,
                ]
            )
        }
    }

    func target(analyzerVersion: String) throws -> DocumentDNAAnalysisTarget {
        try DocumentDNAAnalysisTarget(
            schemaVersion: target.schemaVersion,
            analyzerIdentifier: target.analyzerIdentifier,
            analyzerVersion: analyzerVersion
        )
    }

    func snapshot(
        analyzerVersion: String = "1",
        classificationEvidence: DocumentDNAEvidence? = nil,
        analyzedAt: Date? = nil
    ) async throws -> DocumentDNA {
        let document = try await readyDocument()
        return try await snapshot(
            document: document,
            analyzerVersion: analyzerVersion,
            classificationEvidence: classificationEvidence,
            analyzedAt: analyzedAt
        )
    }

    func snapshot(
        document: DocumentRecord,
        analyzerVersion: String = "1",
        classificationEvidence: DocumentDNAEvidence? = nil,
        analyzedAt: Date? = nil
    ) async throws -> DocumentDNA {
        let classificationEvidence = try classificationEvidence ?? DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 0,
            lengthUTF16: 8,
            exactText: "Rechnung",
            ocrRegionIndexes: [0]
        )
        return try DocumentDNA(
            documentID: document.id,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: analyzerVersion,
            inputContentHash: document.contentHash,
            inputExtractionVersion: "text-v1",
            findings: [
                DocumentDNAFinding(
                    kind: .documentType,
                    qualifier: nil,
                    displayValue: "Rechnung",
                    normalizedValue: "invoice",
                    secondaryNormalizedValue: nil,
                    confidence: 0.95,
                    evidence: [classificationEvidence]
                ),
                DocumentDNAFinding(
                    kind: .person,
                    qualifier: nil,
                    displayValue: "Elise Muster",
                    normalizedValue: "elise muster",
                    secondaryNormalizedValue: nil,
                    confidence: 0.9,
                    evidence: [DocumentDNAEvidence(
                        pageIndex: 0,
                        startUTF16: 21,
                        lengthUTF16: 12,
                        exactText: "Elise Muster",
                        ocrRegionIndexes: [1]
                    )]
                ),
            ],
            analyzedAt: analyzedAt
                ?? Self.date.addingTimeInterval(analyzerVersion == "1" ? 0 : 1)
        )
    }

    func analysisState(documentID: UUID) async throws -> LiteralAnalysisState? {
        try await db.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT targetSchemaVersion, targetAnalyzerIdentifier,
                           targetAnalyzerVersion, inputContentHash,
                           inputExtractionVersion, status, failureCode
                    FROM documentDNAAnalysisState
                    WHERE documentID = ?
                    """,
                arguments: [documentID]
            ) else {
                return nil
            }
            return LiteralAnalysisState(
                schemaVersion: row["targetSchemaVersion"],
                analyzerIdentifier: row["targetAnalyzerIdentifier"],
                analyzerVersion: row["targetAnalyzerVersion"],
                contentHash: row["inputContentHash"],
                extractionVersion: row["inputExtractionVersion"],
                status: row["status"],
                failureCode: row["failureCode"]
            )
        }
    }

    func analysisStateUpdatedAt(documentID: UUID) async throws -> Date? {
        try await db.read { database in
            try Date.fetchOne(
                database,
                sql: """
                    SELECT updatedAt
                    FROM documentDNAAnalysisState
                    WHERE documentID = ?
                    """,
                arguments: [documentID]
            )
        }
    }

    func analysisStatus(relativePath: String) async throws -> String? {
        try await db.read { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT documentDNAAnalysisState.status
                    FROM documentDNAAnalysisState
                    JOIN document ON document.id = documentDNAAnalysisState.documentID
                    WHERE document.relativePath = ?
                    """,
                arguments: [relativePath]
            )
        }
    }

    func documentID(relativePath: String) async -> UUID? {
        try? await db.read { database in
            try UUID.fetchOne(
                database,
                sql: "SELECT id FROM document WHERE relativePath = ?",
                arguments: [relativePath]
            )
        }
    }

    func rowCounts() async throws -> DNARowCounts {
        try await db.read { database in
            DNARowCounts(
                snapshots: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM documentDNA"
                )!,
                findings: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM documentDNAFinding"
                )!,
                evidence: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM documentDNAEvidence"
                )!,
                states: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM documentDNAAnalysisState"
                )!
            )
        }
    }

    func installEvidenceRejectionTrigger() async throws {
        try await db.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_document_dna_evidence
                BEFORE INSERT ON documentDNAEvidence
                BEGIN
                    SELECT RAISE(ABORT, 'blocked DNA evidence');
                END
                """)
        }
    }

    func changeExtractionVersion(to analysisVersion: String) async throws {
        let document = try await readyDocument()
        try await db.write { database in
            try database.execute(
                sql: "UPDATE documentExtraction SET analysisVersion = ? WHERE documentID = ?",
                arguments: [analysisVersion, document.id]
            )
        }
    }

    func changeContentHash(to contentHash: String) async throws {
        let document = try await readyDocument()
        try await db.write { database in
            try database.execute(
                sql: "UPDATE document SET contentHash = ? WHERE id = ?",
                arguments: [contentHash, document.id]
            )
        }
    }

    func changeDocumentStatus(to status: DocumentStatus) async throws {
        let document = try await readyDocument()
        try await db.write { database in
            try database.execute(
                sql: "UPDATE document SET status = ? WHERE id = ?",
                arguments: [status, document.id]
            )
        }
    }

    func changeDocumentAvailability(to availability: DocumentAvailability) async throws {
        let document = try await readyDocument()
        try await db.write { database in
            try database.execute(
                sql: "UPDATE document SET availability = ? WHERE id = ?",
                arguments: [availability, document.id]
            )
        }
    }

    func changeDocumentSourceRootID(to sourceRootID: UUID) async throws {
        let document = try await readyDocument()
        try await db.write { database in
            try database.execute(
                sql: "UPDATE document SET sourceRootID = ? WHERE id = ?",
                arguments: [sourceRootID, document.id]
            )
        }
    }

    func changeAnalysisStateStatus(
        to status: String,
        failureCode: String? = nil
    ) async throws {
        let document = try await readyDocument()
        try await changeAnalysisStateStatus(
            documentID: document.id,
            to: status,
            failureCode: failureCode
        )
    }

    func changeAnalysisStateStatus(
        documentID: UUID,
        to status: String,
        failureCode: String? = nil
    ) async throws {
        try await db.write { database in
            try database.execute(
                sql: """
                    UPDATE documentDNAAnalysisState
                    SET status = ?, failureCode = ?
                    WHERE documentID = ?
                    """,
                arguments: [status, failureCode, documentID]
            )
        }
    }

    func documentStatus() async throws -> DocumentStatus {
        try await readyDocument().status
    }

    func rewriteAnalyzedAtUsingLegacyGRDBDate(_ date: Date) async throws {
        let document = try await readyDocument()
        try await db.write { database in
            try database.execute(
                sql: "UPDATE documentDNA SET analyzedAt = ? WHERE documentID = ?",
                arguments: [date, document.id]
            )
        }
    }

    private func readyDocument() async throws -> DocumentRecord {
        try await db.read { database in
            let document = try DocumentRecord.fetchOne(
                database,
                sql: "SELECT * FROM document WHERE relativePath = 'a-ready.pdf'"
            )
            return try #require(document)
        }
    }

    private static let extraction = ExtractedDocument(
        method: .visionOCR,
        pages: [ExtractedPage(
            pageIndex: 0,
            text: pageText,
            regions: [
                TextRegion(
                    text: "Rechnung",
                    confidence: 0.99,
                    boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.1)
                ),
                TextRegion(
                    text: "Bewohnerin: Elise Muster",
                    confidence: 0.98,
                    boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.6, height: 0.1)
                ),
            ]
        )]
    )
}
