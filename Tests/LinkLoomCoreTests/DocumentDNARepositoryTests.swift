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

    private func insertAnalysisState(
        document: DocumentRecord,
        status: String,
        failureCode: String? = nil
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
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                    document.contentHash,
                    "text-v1",
                    status,
                    failureCode,
                    Self.date,
                ]
            )
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
