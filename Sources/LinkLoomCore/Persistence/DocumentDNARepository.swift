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

public struct DocumentDNAFindingMatch: Sendable, Equatable {
    public let document: DocumentRecord
    public let finding: DocumentDNAFinding

    public init(document: DocumentRecord, finding: DocumentDNAFinding) {
        self.document = document
        self.finding = finding
    }
}

private struct DocumentDNAFindingMatchAccumulator {
    let document: DocumentRecord
    let kind: DocumentDNAFindingKind
    let qualifier: String?
    let displayValue: String
    let normalizedValue: String
    let secondaryNormalizedValue: String?
    let confidence: Double
    var evidence: [DocumentDNAEvidence] = []

    init(document: DocumentRecord, row: Row) throws {
        let kindValue: String = row["kind"]
        guard let kind = DocumentDNAFindingKind(rawValue: kindValue) else {
            throw DocumentDNAValidationError.invalidFinding
        }
        self.document = document
        self.kind = kind
        qualifier = row["qualifier"]
        displayValue = row["displayValue"]
        normalizedValue = row["normalizedValue"]
        secondaryNormalizedValue = row["secondaryNormalizedValue"]
        confidence = row["confidence"]
    }

    func match() throws -> DocumentDNAFindingMatch {
        DocumentDNAFindingMatch(
            document: document,
            finding: try DocumentDNAFinding(
                kind: kind,
                qualifier: qualifier,
                displayValue: displayValue,
                normalizedValue: normalizedValue,
                secondaryNormalizedValue: secondaryNormalizedValue,
                confidence: confidence,
                evidence: evidence
            )
        )
    }
}

public enum DocumentDNAAnalysisFailureCode: String, Sendable, Equatable, CaseIterable {
    case analysisFailure
    case invalidFinding
    case invalidProvenance
}

public enum DocumentDNARepositoryError: Error, Sendable, Equatable {
    case invalidTarget
    case staleInput
    case invalidProvenance
    case invalidStoredState
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

    public func currentAnalysisStatuses(
        sourceRootID: UUID,
        target: DocumentDNAAnalysisTarget
    ) async throws -> [DocumentDNAAnalysisStatus] {
        try await dbWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT document.id AS documentID,
                           analysisState.status AS analysisStatus,
                           analysisState.failureCode AS analysisFailureCode,
                           documentDNA.documentID AS snapshotDocumentID
                    FROM document
                    JOIN documentExtraction
                        ON documentExtraction.documentID = document.id
                    LEFT JOIN documentDNAAnalysisState AS analysisState
                        ON analysisState.documentID = document.id
                        AND analysisState.targetSchemaVersion = ?
                        AND analysisState.targetAnalyzerIdentifier = ?
                        AND analysisState.targetAnalyzerVersion = ?
                        AND analysisState.inputContentHash = document.contentHash
                        AND analysisState.inputExtractionVersion =
                            documentExtraction.analysisVersion
                    LEFT JOIN documentDNA
                        ON documentDNA.documentID = document.id
                        AND documentDNA.schemaVersion = ?
                        AND documentDNA.analyzerIdentifier = ?
                        AND documentDNA.analyzerVersion = ?
                        AND documentDNA.inputContentHash = document.contentHash
                        AND documentDNA.inputExtractionVersion =
                            documentExtraction.analysisVersion
                    WHERE document.sourceRootID = ?
                        AND document.availability = ?
                        AND document.status = ?
                    ORDER BY document.relativePath, document.id
                    """,
                arguments: [
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                    sourceRootID,
                    DocumentAvailability.available,
                    DocumentStatus.ready,
                ]
            )
            return try rows.map { row in
                let documentID: UUID = row["documentID"]
                let analysisStatus: String? = row["analysisStatus"]
                let failureCodeValue: String? = row["analysisFailureCode"]
                let snapshotDocumentID: UUID? = row["snapshotDocumentID"]
                let phase: DocumentDNAAnalysisPhase
                switch analysisStatus {
                case "analyzing":
                    phase = .analyzing
                case "ready" where snapshotDocumentID != nil:
                    phase = .ready
                case "failed":
                    guard let failureCodeValue,
                          let failureCode = DocumentDNAAnalysisFailureCode(
                              rawValue: failureCodeValue
                          )
                    else {
                        throw DocumentDNARepositoryError.invalidStoredState
                    }
                    phase = .failed(failureCode)
                default:
                    phase = .pending
                }
                return DocumentDNAAnalysisStatus(documentID: documentID, phase: phase)
            }
        }
    }

    public func beginAnalysis(
        _ candidate: PendingDocumentDNAAnalysis,
        target: DocumentDNAAnalysisTarget,
        at date: Date
    ) async throws {
        try await dbWriter.write { db in
            guard try Self.isEligibleForAnalysis(
                in: db,
                candidate: candidate,
                target: target
            ) else {
                throw DocumentDNARepositoryError.staleInput
            }
            try db.execute(
                sql: """
                    INSERT INTO documentDNAAnalysisState (
                        documentID, targetSchemaVersion, targetAnalyzerIdentifier,
                        targetAnalyzerVersion, inputContentHash, inputExtractionVersion,
                        status, failureCode, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, 'analyzing', NULL, ?)
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
                    candidate.document.id,
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                    candidate.document.contentHash,
                    candidate.extraction.analysisVersion,
                    date,
                ]
            )
        }
    }

    public func markAnalysisFailed(
        _ candidate: PendingDocumentDNAAnalysis,
        target: DocumentDNAAnalysisTarget,
        failureCode: DocumentDNAAnalysisFailureCode,
        at date: Date
    ) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE documentDNAAnalysisState
                    SET status = 'failed', failureCode = ?, updatedAt = ?
                    WHERE documentID = ?
                        AND targetSchemaVersion = ?
                        AND targetAnalyzerIdentifier = ?
                        AND targetAnalyzerVersion = ?
                        AND inputContentHash = ?
                        AND inputExtractionVersion = ?
                        AND status = 'analyzing'
                        AND EXISTS (
                            SELECT 1
                            FROM document
                            JOIN documentExtraction
                                ON documentExtraction.documentID = document.id
                            WHERE document.id = documentDNAAnalysisState.documentID
                                AND document.sourceRootID = ?
                                AND document.status = 'ready'
                                AND document.availability = 'available'
                                AND document.contentHash =
                                    documentDNAAnalysisState.inputContentHash
                                AND documentExtraction.analysisVersion =
                                    documentDNAAnalysisState.inputExtractionVersion
                        )
                    """,
                arguments: [
                    failureCode.rawValue,
                    date,
                    candidate.document.id,
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                    candidate.document.contentHash,
                    candidate.extraction.analysisVersion,
                    candidate.document.sourceRootID,
                ]
            )
            guard db.changesCount == 1 else {
                throw DocumentDNARepositoryError.staleInput
            }
        }
    }

    public func restoreAnalysisAfterInterruption(
        _ candidate: PendingDocumentDNAAnalysis,
        target: DocumentDNAAnalysisTarget
    ) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    DELETE FROM documentDNAAnalysisState
                    WHERE documentID = ?
                        AND targetSchemaVersion = ?
                        AND targetAnalyzerIdentifier = ?
                        AND targetAnalyzerVersion = ?
                        AND inputContentHash = ?
                        AND inputExtractionVersion = ?
                        AND status = 'analyzing'
                    """,
                arguments: [
                    candidate.document.id,
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                    candidate.document.contentHash,
                    candidate.extraction.analysisVersion,
                ]
            )
        }
    }

    public func recoverInterruptedAnalysis(sourceRootID: UUID) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    DELETE FROM documentDNAAnalysisState
                    WHERE status = 'analyzing'
                        AND documentID IN (
                            SELECT id FROM document WHERE sourceRootID = ?
                        )
                    """,
                arguments: [sourceRootID]
            )
        }
    }

    public func retryFailedAnalysis(documentID: UUID) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    DELETE FROM documentDNAAnalysisState
                    WHERE documentID = ? AND status = 'failed'
                    """,
                arguments: [documentID]
            )
        }
    }

    public func replace(_ snapshot: DocumentDNA) async throws {
        try await dbWriter.write { db in
            let analyzedAtStorage = snapshot.analyzedAt.timeIntervalSinceReferenceDate
            guard let document = try DocumentRecord.fetchOne(db, key: snapshot.documentID),
                  document.status == .ready,
                  document.availability == .available,
                  document.contentHash == snapshot.inputContentHash,
                  let extraction = try ExtractionRepository.extraction(
                      in: db,
                      documentID: snapshot.documentID
                  ),
                  extraction.analysisVersion == snapshot.inputExtractionVersion
            else {
                throw DocumentDNARepositoryError.staleInput
            }
            try Self.validateTextProvenance(
                snapshot.findings.flatMap(\.evidence),
                pages: extraction.extraction.pages
            )
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
                    analyzedAtStorage,
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

    public func currentFindings(
        kind: DocumentDNAFindingKind,
        normalizedValue: String,
        target: DocumentDNAAnalysisTarget
    ) async throws -> [DocumentDNAFindingMatch] {
        try await dbWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT document.*, finding.id AS findingID, finding.kind,
                           finding.qualifier, finding.displayValue,
                           finding.normalizedValue, finding.secondaryNormalizedValue,
                           finding.confidence,
                           evidence.pageIndex AS evidencePageIndex,
                           evidence.startUTF16 AS evidenceStartUTF16,
                           evidence.lengthUTF16 AS evidenceLengthUTF16,
                           evidence.exactText AS evidenceExactText,
                           evidence.ocrRegionIndexesJSON AS evidenceOCRRegionIndexesJSON
                    FROM documentDNAFinding AS finding
                        INDEXED BY document_dna_finding_kind_value
                    JOIN documentDNA
                        ON documentDNA.documentID = finding.documentID
                    JOIN document
                        ON document.id = documentDNA.documentID
                    JOIN documentExtraction
                        ON documentExtraction.documentID = document.id
                    LEFT JOIN documentDNAEvidence AS evidence
                        ON evidence.findingID = finding.id
                    WHERE finding.kind = ?
                        AND finding.normalizedValue = ?
                        AND documentDNA.schemaVersion = ?
                        AND documentDNA.analyzerIdentifier = ?
                        AND documentDNA.analyzerVersion = ?
                        AND documentDNA.inputContentHash = document.contentHash
                        AND documentDNA.inputExtractionVersion =
                            documentExtraction.analysisVersion
                    ORDER BY document.sourceRootID, document.relativePath,
                             document.id, finding.sortOrder, finding.id,
                             evidence.evidenceOrder
                    """,
                arguments: [
                    kind.rawValue,
                    normalizedValue,
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                ]
            )
            var positionsByFindingID: [Int64: Int] = [:]
            var accumulators: [DocumentDNAFindingMatchAccumulator] = []
            for row in rows {
                let findingID: Int64 = row["findingID"]
                let position: Int
                if let existingPosition = positionsByFindingID[findingID] {
                    position = existingPosition
                } else {
                    position = accumulators.endIndex
                    positionsByFindingID[findingID] = position
                    accumulators.append(try DocumentDNAFindingMatchAccumulator(
                        document: DocumentRecord(row: row),
                        row: row
                    ))
                }
                guard let pageIndex: Int = row["evidencePageIndex"] else { continue }
                let indexesJSON: Data = row["evidenceOCRRegionIndexesJSON"]
                accumulators[position].evidence.append(try DocumentDNAEvidence(
                    pageIndex: pageIndex,
                    startUTF16: row["evidenceStartUTF16"],
                    lengthUTF16: row["evidenceLengthUTF16"],
                    exactText: row["evidenceExactText"],
                    ocrRegionIndexes: try JSONDecoder().decode([Int].self, from: indexesJSON)
                ))
            }
            return try accumulators.map { try $0.match() }
        }
    }

    /// Loads complete, target-current snapshots for an exact normalized reference.
    ///
    /// Qualifiers remain part of the returned findings but not lookup identity. The
    /// indexed lookup and snapshot reconstruction share one database read transaction.
    public func currentSnapshotsMatchingReference(
        _ normalizedValue: String,
        target: DocumentDNAAnalysisTarget
    ) async throws -> [CurrentDocumentDNA] {
        try await dbWriter.read { db in
            let documents = try DocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT document.*
                    FROM documentDNAFinding AS finding
                        INDEXED BY document_dna_finding_kind_value
                    JOIN documentDNA
                        ON documentDNA.documentID = finding.documentID
                    JOIN document
                        ON document.id = documentDNA.documentID
                    JOIN documentExtraction
                        ON documentExtraction.documentID = document.id
                    WHERE finding.kind = ?
                        AND finding.normalizedValue = ?
                        AND documentDNA.schemaVersion = ?
                        AND documentDNA.analyzerIdentifier = ?
                        AND documentDNA.analyzerVersion = ?
                        AND documentDNA.inputContentHash = document.contentHash
                        AND documentDNA.inputExtractionVersion =
                            documentExtraction.analysisVersion
                    ORDER BY document.sourceRootID, document.relativePath, document.id
                    """,
                arguments: [
                    DocumentDNAFindingKind.referenceNumber.rawValue,
                    normalizedValue,
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                ]
            )
            return try documents.map { document in
                guard let snapshot = try Self.snapshot(in: db, documentID: document.id) else {
                    throw DocumentDNARepositoryError.invalidStoredState
                }
                return try CurrentDocumentDNA(document: document, snapshot: snapshot)
            }
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
        let findings = try findingRows.map { try Self.finding(in: db, row: $0) }
        let schemaVersion: Int = header["schemaVersion"]
        let analyzerIdentifier: String = header["analyzerIdentifier"]
        let analyzerVersion: String = header["analyzerVersion"]
        let inputContentHash: String = header["inputContentHash"]
        let inputExtractionVersion: String = header["inputExtractionVersion"]
        let analyzedAtValue: DatabaseValue = header["analyzedAt"]
        let analyzedAt: Date
        if let interval = Double.fromDatabaseValue(analyzedAtValue) {
            analyzedAt = Date(timeIntervalSinceReferenceDate: interval)
        } else if let decodedDate = Date.fromDatabaseValue(analyzedAtValue) {
            analyzedAt = decodedDate
        } else {
            throw DocumentDNAValidationError.invalidSnapshot
        }
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

    private static func finding(in db: Database, row: Row) throws -> DocumentDNAFinding {
        let findingID: Int64 = row["id"]
        let kindValue: String = row["kind"]
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
                ocrRegionIndexes: try JSONDecoder().decode([Int].self, from: indexesJSON)
            )
        }
        return try DocumentDNAFinding(
            kind: kind,
            qualifier: row["qualifier"],
            displayValue: row["displayValue"],
            normalizedValue: row["normalizedValue"],
            secondaryNormalizedValue: row["secondaryNormalizedValue"],
            confidence: row["confidence"],
            evidence: evidence
        )
    }

    private static func isEligibleForAnalysis(
        in db: Database,
        candidate: PendingDocumentDNAAnalysis,
        target: DocumentDNAAnalysisTarget
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM document
                    JOIN documentExtraction
                        ON documentExtraction.documentID = document.id
                    WHERE document.id = ?
                        AND document.sourceRootID = ?
                        AND document.status = 'ready'
                        AND document.availability = 'available'
                        AND document.contentHash = ?
                        AND documentExtraction.analysisVersion = ?
                        AND NOT EXISTS (
                            SELECT 1 FROM documentDNA
                            WHERE documentDNA.documentID = document.id
                                AND documentDNA.schemaVersion = ?
                                AND documentDNA.analyzerIdentifier = ?
                                AND documentDNA.analyzerVersion = ?
                                AND documentDNA.inputContentHash = document.contentHash
                                AND documentDNA.inputExtractionVersion =
                                    documentExtraction.analysisVersion
                        )
                        AND NOT EXISTS (
                            SELECT 1 FROM documentDNAAnalysisState
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
                )
                """,
            arguments: [
                candidate.document.id,
                candidate.document.sourceRootID,
                candidate.document.contentHash,
                candidate.extraction.analysisVersion,
                target.schemaVersion,
                target.analyzerIdentifier,
                target.analyzerVersion,
                target.schemaVersion,
                target.analyzerIdentifier,
                target.analyzerVersion,
            ]
        ) ?? false
    }

    private static func validateTextProvenance(
        _ evidenceValues: [DocumentDNAEvidence],
        pages: [ExtractedPage]
    ) throws {
        for evidence in evidenceValues {
            guard let page = pages.first(where: { $0.pageIndex == evidence.pageIndex })
            else {
                throw DocumentDNARepositoryError.invalidProvenance
            }
            let text = page.text as NSString
            guard evidence.startUTF16 <= text.length,
                  evidence.lengthUTF16 <= text.length - evidence.startUTF16,
                  text.substring(with: NSRange(
                      location: evidence.startUTF16,
                      length: evidence.lengthUTF16
                  )) == evidence.exactText
            else {
                throw DocumentDNARepositoryError.invalidProvenance
            }
            let evidenceRange = NSRange(
                location: evidence.startUTF16,
                length: evidence.lengthUTF16
            )
            let intersectingRegionIndexes = page.regions.indices.filter { index in
                let precedingLength = page.regions[..<index].reduce(0) {
                    $0 + ($1.text as NSString).length + 1
                }
                let regionRange = NSRange(
                    location: precedingLength,
                    length: (page.regions[index].text as NSString).length
                )
                return NSIntersectionRange(evidenceRange, regionRange).length > 0
            }
            guard evidence.ocrRegionIndexes == intersectingRegionIndexes else {
                throw DocumentDNARepositoryError.invalidProvenance
            }
        }
    }
}
