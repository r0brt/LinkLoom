import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Document DNA analysis pipeline")
struct DocumentDNAAnalysisPipelineTests {
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
        analysisDelay: Duration = .zero
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
        let analyzer = RecordingDocumentDNAAnalyzer(target: target, delay: analysisDelay)
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

    func makePipeline(target: DocumentDNAAnalysisTarget) -> DocumentDNAAnalysisPipeline {
        DocumentDNAAnalysisPipeline(
            repository: repository,
            analyzer: RecordingDocumentDNAAnalyzer(target: target),
            target: target,
            now: { Self.date }
        )
    }

    func documentDNARowCount() async throws -> Int {
        try await db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM documentDNA") ?? 0
        }
    }
}

private actor RecordingDocumentDNAAnalyzer: DocumentDNAAnalyzing {
    private let target: DocumentDNAAnalysisTarget
    private let delay: Duration
    private let state = RecordingDocumentDNAAnalyzerState()

    init(target: DocumentDNAAnalysisTarget, delay: Duration = .zero) {
        self.target = target
        self.delay = delay
    }

    nonisolated func analyze(
        documentID: UUID,
        contentHash: String,
        extraction: StoredExtraction,
        analyzedAt: Date
    ) throws -> DocumentDNA {
        state.recordCall()
        defer { state.finishCall() }
        if delay > .zero {
            let components = delay.components
            Thread.sleep(forTimeInterval: Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000)
        }
        return try DocumentDNA(
            documentID: documentID,
            schemaVersion: target.schemaVersion,
            analyzerIdentifier: target.analyzerIdentifier,
            analyzerVersion: target.analyzerVersion,
            inputContentHash: contentHash,
            inputExtractionVersion: extraction.analysisVersion,
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
                    exactText: "Rechnung",
                    ocrRegionIndexes: []
                )]
            )],
            analyzedAt: analyzedAt
        )
    }

    var callCount: Int { state.callCount }

    var peakConcurrency: Int { state.peakConcurrency }
}

private final class RecordingDocumentDNAAnalyzerState: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var activeCalls = 0
    private var peakCalls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    var peakConcurrency: Int {
        lock.withLock { peakCalls }
    }

    func recordCall() {
        lock.withLock {
            calls += 1
            activeCalls += 1
            peakCalls = max(peakCalls, activeCalls)
        }
    }

    func finishCall() {
        lock.withLock {
            activeCalls -= 1
        }
    }
}

private actor PipelineOperationRecorder {
    private(set) var operations: [String] = []

    func record(_ operation: String) {
        operations.append(operation)
    }
}
