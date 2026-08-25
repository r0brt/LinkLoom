import Foundation
import GRDB

public struct DocumentDNAAnalysisTarget: Sendable, Equatable {
    public let schemaVersion: Int
    public let analyzerIdentifier: String
    public let analyzerVersion: String

    public init(
        schemaVersion: Int,
        analyzerIdentifier: String,
        analyzerVersion: String
    ) throws {
        guard schemaVersion > 0,
              !analyzerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !analyzerVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DocumentDNARepositoryError.invalidTarget
        }
        self.schemaVersion = schemaVersion
        self.analyzerIdentifier = analyzerIdentifier
        self.analyzerVersion = analyzerVersion
    }
}

public struct PendingDocumentDNAAnalysis: Sendable, Equatable {
    public let document: DocumentRecord
    public let extraction: StoredExtraction

    public init(document: DocumentRecord, extraction: StoredExtraction) {
        self.document = document
        self.extraction = extraction
    }
}

public enum DocumentDNARepositoryError: Error, Sendable, Equatable {
    case invalidTarget
    case staleInput
    case invalidProvenance
}

public actor DocumentDNARepository {
    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func pendingAnalysis(
        sourceRootID: UUID,
        target: DocumentDNAAnalysisTarget,
        limit: Int
    ) async throws -> [PendingDocumentDNAAnalysis] {
        guard limit > 0 else { return [] }
        return try await dbWriter.read { db in
            let documents = try DocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT document.*
                    FROM document
                    JOIN documentExtraction
                        ON documentExtraction.documentID = document.id
                    WHERE document.sourceRootID = ?
                        AND document.availability = ?
                        AND document.status = ?
                        AND NOT EXISTS (
                            SELECT 1
                            FROM documentDNA
                            WHERE documentDNA.documentID = document.id
                                AND documentDNA.schemaVersion = ?
                                AND documentDNA.analyzerIdentifier = ?
                                AND documentDNA.analyzerVersion = ?
                                AND documentDNA.inputContentHash = document.contentHash
                                AND documentDNA.inputExtractionVersion =
                                    documentExtraction.analysisVersion
                        )
                        AND NOT EXISTS (
                            SELECT 1
                            FROM documentDNAAnalysisState
                            WHERE documentDNAAnalysisState.documentID = document.id
                                AND documentDNAAnalysisState.targetSchemaVersion = ?
                                AND documentDNAAnalysisState.targetAnalyzerIdentifier = ?
                                AND documentDNAAnalysisState.targetAnalyzerVersion = ?
                                AND documentDNAAnalysisState.inputContentHash =
                                    document.contentHash
                                AND documentDNAAnalysisState.inputExtractionVersion =
                                    documentExtraction.analysisVersion
                                AND documentDNAAnalysisState.status IN ('failed', 'analyzing')
                        )
                    ORDER BY document.relativePath
                    LIMIT ?
                    """,
                arguments: [
                    sourceRootID,
                    DocumentAvailability.available,
                    DocumentStatus.ready,
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                    limit,
                ]
            )
            return try documents.map { document in
                guard let extraction = try ExtractionRepository.extraction(
                    in: db,
                    documentID: document.id
                ) else {
                    throw DocumentDNARepositoryError.staleInput
                }
                return PendingDocumentDNAAnalysis(
                    document: document,
                    extraction: extraction
                )
            }
        }
    }

    public func replace(_ snapshot: DocumentDNA) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM documentDNA WHERE documentID = ?",
                arguments: [snapshot.documentID]
            )
            try db.execute(
                sql: """
                    INSERT INTO documentDNA (
                        documentID, schemaVersion, analyzerIdentifier, analyzerVersion,
                        inputContentHash, inputExtractionVersion, analyzedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    snapshot.documentID,
                    snapshot.schemaVersion,
                    snapshot.analyzerIdentifier,
                    snapshot.analyzerVersion,
                    snapshot.inputContentHash,
                    snapshot.inputExtractionVersion,
                    snapshot.analyzedAt,
                ]
            )
            for (sortOrder, finding) in snapshot.findings.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO documentDNAFinding (
                            documentID, kind, qualifier, displayValue, normalizedValue,
                            secondaryNormalizedValue, confidence, sortOrder
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        snapshot.documentID,
                        finding.kind.rawValue,
                        finding.qualifier,
                        finding.displayValue,
                        finding.normalizedValue,
                        finding.secondaryNormalizedValue,
                        finding.confidence,
                        sortOrder,
                    ]
                )
                let findingID = db.lastInsertedRowID
                for (evidenceOrder, evidence) in finding.evidence.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO documentDNAEvidence (
                                findingID, evidenceOrder, pageIndex, startUTF16,
                                lengthUTF16, exactText, ocrRegionIndexesJSON
                            ) VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            findingID,
                            evidenceOrder,
                            evidence.pageIndex,
                            evidence.startUTF16,
                            evidence.lengthUTF16,
                            evidence.exactText,
                            try JSONEncoder().encode(evidence.ocrRegionIndexes),
                        ]
                    )
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO documentDNAAnalysisState (
                        documentID, targetSchemaVersion, targetAnalyzerIdentifier,
                        targetAnalyzerVersion, inputContentHash, inputExtractionVersion,
                        status, failureCode, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, 'ready', NULL, ?)
                    ON CONFLICT(documentID) DO UPDATE SET
                        targetSchemaVersion = excluded.targetSchemaVersion,
                        targetAnalyzerIdentifier = excluded.targetAnalyzerIdentifier,
                        targetAnalyzerVersion = excluded.targetAnalyzerVersion,
                        inputContentHash = excluded.inputContentHash,
                        inputExtractionVersion = excluded.inputExtractionVersion,
                        status = excluded.status,
                        failureCode = NULL,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [
                    snapshot.documentID,
                    snapshot.schemaVersion,
                    snapshot.analyzerIdentifier,
                    snapshot.analyzerVersion,
                    snapshot.inputContentHash,
                    snapshot.inputExtractionVersion,
                    snapshot.analyzedAt,
                ]
            )
        }
    }

    public func storedSnapshot(documentID: UUID) async throws -> DocumentDNA? {
        try await dbWriter.read { db in
            try Self.snapshot(in: db, documentID: documentID)
        }
    }

    public func currentSnapshot(
        documentID: UUID,
        target: DocumentDNAAnalysisTarget
    ) async throws -> DocumentDNA? {
        try await dbWriter.read { db in
            let isCurrent = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM documentDNA
                        JOIN document
                            ON document.id = documentDNA.documentID
                        JOIN documentExtraction
                            ON documentExtraction.documentID = document.id
                        WHERE documentDNA.documentID = ?
                            AND documentDNA.schemaVersion = ?
                            AND documentDNA.analyzerIdentifier = ?
                            AND documentDNA.analyzerVersion = ?
                            AND documentDNA.inputContentHash = document.contentHash
                            AND documentDNA.inputExtractionVersion =
                                documentExtraction.analysisVersion
                    )
                    """,
                arguments: [
                    documentID,
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                ]
            ) ?? false
            guard isCurrent else { return nil }
            return try Self.snapshot(in: db, documentID: documentID)
        }
    }

    private static func snapshot(
        in db: Database,
        documentID: UUID
    ) throws -> DocumentDNA? {
        guard let header = try Row.fetchOne(
            db,
            sql: """
                SELECT schemaVersion, analyzerIdentifier, analyzerVersion,
                       inputContentHash, inputExtractionVersion, analyzedAt
                FROM documentDNA
                WHERE documentID = ?
                """,
            arguments: [documentID]
        ) else {
            return nil
        }
        let findingRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, kind, qualifier, displayValue, normalizedValue,
                       secondaryNormalizedValue, confidence
                FROM documentDNAFinding
                WHERE documentID = ?
                ORDER BY sortOrder
                """,
            arguments: [documentID]
        )
        let findings = try findingRows.map { findingRow in
            let findingID: Int64 = findingRow["id"]
            let kindValue: String = findingRow["kind"]
            guard let kind = DocumentDNAFindingKind(rawValue: kindValue) else {
                throw DocumentDNAValidationError.invalidFinding
            }
            let evidenceRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT pageIndex, startUTF16, lengthUTF16, exactText,
                           ocrRegionIndexesJSON
                    FROM documentDNAEvidence
                    WHERE findingID = ?
                    ORDER BY evidenceOrder
                    """,
                arguments: [findingID]
            )
            let evidence = try evidenceRows.map { evidenceRow in
                let indexesJSON: Data = evidenceRow["ocrRegionIndexesJSON"]
                return try DocumentDNAEvidence(
                    pageIndex: evidenceRow["pageIndex"],
                    startUTF16: evidenceRow["startUTF16"],
                    lengthUTF16: evidenceRow["lengthUTF16"],
                    exactText: evidenceRow["exactText"],
                    ocrRegionIndexes: try JSONDecoder().decode(
                        [Int].self,
                        from: indexesJSON
                    )
                )
            }
            return try DocumentDNAFinding(
                kind: kind,
                qualifier: findingRow["qualifier"],
                displayValue: findingRow["displayValue"],
                normalizedValue: findingRow["normalizedValue"],
                secondaryNormalizedValue: findingRow["secondaryNormalizedValue"],
                confidence: findingRow["confidence"],
                evidence: evidence
            )
        }
        let schemaVersion: Int = header["schemaVersion"]
        let analyzerIdentifier: String = header["analyzerIdentifier"]
        let analyzerVersion: String = header["analyzerVersion"]
        let inputContentHash: String = header["inputContentHash"]
        let inputExtractionVersion: String = header["inputExtractionVersion"]
        let analyzedAt: Date = header["analyzedAt"]
        return try DocumentDNA(
            documentID: documentID,
            schemaVersion: schemaVersion,
            analyzerIdentifier: analyzerIdentifier,
            analyzerVersion: analyzerVersion,
            inputContentHash: inputContentHash,
            inputExtractionVersion: inputExtractionVersion,
            findings: findings,
            analyzedAt: analyzedAt
        )
    }
}
