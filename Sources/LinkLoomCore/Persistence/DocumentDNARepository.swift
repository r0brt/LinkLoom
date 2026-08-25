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
}
