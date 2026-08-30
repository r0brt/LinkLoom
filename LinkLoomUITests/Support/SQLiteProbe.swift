import Foundation
import SQLite3

struct SmokeDatabaseEvidence: CustomStringConvertible {
    let sourceCount: Int
    let documentCount: Int
    let readyCount: Int
    let failedCount: Int
    let extractionCount: Int
    let extractedPageCount: Int
    let ftsCount: Int
    let unsupportedCount: Int
    let selectableTextMatchCount: Int
    let paymentTextMatchCount: Int
    let ocrTextMatchCount: Int
    let corruptFailureMatchCount: Int
    let dnaSnapshotCount: Int
    let dnaFindingCount: Int
    let dnaEvidenceCount: Int
    let dnaAnalysisStateCount: Int
    let dnaReadyStateCount: Int
    let dnaClassificationCount: Int
    let localRulesSnapshotCount: Int
    let coherentDNADocumentCount: Int

    var matchesCompletedWorkflow: Bool {
        sourceCount == 1
            && documentCount == 4
            && readyCount == 3
            && failedCount == 1
            && extractionCount == 3
            && extractedPageCount == 3
            && ftsCount == 3
            && unsupportedCount == 0
            && selectableTextMatchCount == 1
            && paymentTextMatchCount == 1
            && ocrTextMatchCount == 1
            && corruptFailureMatchCount == 1
            && dnaSnapshotCount == 3
            && dnaFindingCount == 9
            && dnaEvidenceCount == 8
            && dnaAnalysisStateCount == 3
            && dnaReadyStateCount == 3
            && dnaClassificationCount == 3
            && localRulesSnapshotCount == 3
            && coherentDNADocumentCount == 3
    }

    var matchesRemovedWorkflow: Bool {
        sourceCount == 0
            && documentCount == 0
            && extractionCount == 0
            && extractedPageCount == 0
            && ftsCount == 0
            && dnaSnapshotCount == 0
            && dnaFindingCount == 0
            && dnaEvidenceCount == 0
            && dnaAnalysisStateCount == 0
            && coherentDNADocumentCount == 0
    }

    var description: String {
        "source=\(sourceCount), document=\(documentCount), ready=\(readyCount), "
            + "failed=\(failedCount), extraction=\(extractionCount), "
            + "page=\(extractedPageCount), fts=\(ftsCount), "
            + "unsupported=\(unsupportedCount), selectableText=\(selectableTextMatchCount), "
            + "paymentText=\(paymentTextMatchCount), "
            + "ocrText=\(ocrTextMatchCount), corruptFailure=\(corruptFailureMatchCount), "
            + "dnaSnapshot=\(dnaSnapshotCount), dnaFinding=\(dnaFindingCount), "
            + "dnaEvidence=\(dnaEvidenceCount), dnaState=\(dnaAnalysisStateCount), "
            + "dnaReady=\(dnaReadyStateCount), "
            + "dnaClassification=\(dnaClassificationCount), "
            + "localRulesSnapshot=\(localRulesSnapshotCount), "
            + "coherentDNADocument=\(coherentDNADocumentCount)"
    }
}

final class SQLiteProbe {
    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database {
                sqlite3_close(database)
            }
            self.database = nil
            throw SQLiteProbeError.open(message)
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func collectEvidence() throws -> SmokeDatabaseEvidence {
        SmokeDatabaseEvidence(
            sourceCount: try scalar("SELECT COUNT(*) FROM sourceRoot"),
            documentCount: try scalar("SELECT COUNT(*) FROM document"),
            readyCount: try scalar("SELECT COUNT(*) FROM document WHERE status = 'ready'"),
            failedCount: try scalar("SELECT COUNT(*) FROM document WHERE status = 'failed'"),
            extractionCount: try scalar("SELECT COUNT(*) FROM documentExtraction"),
            extractedPageCount: try scalar("SELECT COUNT(*) FROM extractedPage"),
            ftsCount: try scalar("SELECT COUNT(*) FROM extractionFTS"),
            unsupportedCount: try scalar(
                "SELECT COUNT(*) FROM document WHERE relativePath = 'unsupported.txt'"
            ),
            selectableTextMatchCount: try scalar("""
                SELECT COUNT(*)
                FROM document AS d
                JOIN documentExtraction AS e ON e.documentID = d.id
                WHERE d.relativePath = 'selectable.pdf'
                  AND instr(e.joinedText, 'Rechnung') > 0
                """),
            paymentTextMatchCount: try scalar("""
                SELECT COUNT(*)
                FROM document AS d
                JOIN documentExtraction AS e ON e.documentID = d.id
                WHERE d.relativePath = 'payments/payment-confirmation.pdf'
                  AND instr(e.joinedText, 'Zahlungsbestätigung') > 0
                  AND instr(e.joinedText, 'INV-2026-001') > 0
                """),
            ocrTextMatchCount: try scalar("""
                SELECT COUNT(*)
                FROM document AS d
                JOIN documentExtraction AS e ON e.documentID = d.id
                WHERE d.relativePath = 'scan.png'
                  AND instr(lower(e.joinedText), 'linkloom') > 0
                  AND instr(e.joinedText, '2026') > 0
                """),
            corruptFailureMatchCount: try scalar("""
                SELECT COUNT(*)
                FROM document
                WHERE relativePath = 'corrupt.pdf'
                  AND failureCode = 'unreadableDocument'
                """),
            dnaSnapshotCount: try scalar("SELECT COUNT(*) FROM documentDNA"),
            dnaFindingCount: try scalar("SELECT COUNT(*) FROM documentDNAFinding"),
            dnaEvidenceCount: try scalar("SELECT COUNT(*) FROM documentDNAEvidence"),
            dnaAnalysisStateCount: try scalar(
                "SELECT COUNT(*) FROM documentDNAAnalysisState"
            ),
            dnaReadyStateCount: try scalar("""
                SELECT COUNT(*)
                FROM documentDNAAnalysisState
                WHERE status = 'ready'
                  AND targetSchemaVersion = 1
                  AND targetAnalyzerIdentifier = 'local-rules'
                  AND targetAnalyzerVersion = '2'
                """),
            dnaClassificationCount: try scalar("""
                SELECT COUNT(*)
                FROM documentDNAFinding
                WHERE kind = 'documentType'
                """),
            localRulesSnapshotCount: try scalar("""
                SELECT COUNT(*)
                FROM documentDNA
                WHERE schemaVersion = 1
                  AND analyzerIdentifier = 'local-rules'
                  AND analyzerVersion = '2'
                """),
            coherentDNADocumentCount: try scalar("""
                SELECT COUNT(DISTINCT document.id)
                FROM document
                JOIN documentExtraction
                  ON documentExtraction.documentID = document.id
                JOIN documentDNA
                  ON documentDNA.documentID = document.id
                JOIN documentDNAAnalysisState
                  ON documentDNAAnalysisState.documentID = document.id
                WHERE document.status = 'ready'
                  AND document.availability = 'available'
                  AND documentDNA.schemaVersion = 1
                  AND documentDNA.analyzerIdentifier = 'local-rules'
                  AND documentDNA.analyzerVersion = '2'
                  AND documentDNA.inputContentHash = document.contentHash
                  AND documentDNA.inputExtractionVersion =
                    documentExtraction.analysisVersion
                  AND documentDNAAnalysisState.targetSchemaVersion =
                    documentDNA.schemaVersion
                  AND documentDNAAnalysisState.targetAnalyzerIdentifier =
                    documentDNA.analyzerIdentifier
                  AND documentDNAAnalysisState.targetAnalyzerVersion =
                    documentDNA.analyzerVersion
                  AND documentDNAAnalysisState.inputContentHash =
                    documentDNA.inputContentHash
                  AND documentDNAAnalysisState.inputExtractionVersion =
                    documentDNA.inputExtractionVersion
                  AND documentDNAAnalysisState.status = 'ready'
                  AND documentDNAAnalysisState.failureCode IS NULL
                """)
        )
    }

    private func scalar(_ sql: String) throws -> Int {
        guard let database else {
            throw SQLiteProbeError.closed
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteProbeError.query(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteProbeError.query(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

enum SQLiteTestDatabaseMutator {
    static func makeSelectableDocumentDNAFailureRetryable(databaseURL: URL) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteProbeError.open(message)
        }
        defer { sqlite3_close(database) }

        try execute("PRAGMA foreign_keys = ON", in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", in: database)
        do {
            try execute(
                """
                DELETE FROM documentDNA
                WHERE documentID = (
                    SELECT id FROM document WHERE relativePath = 'selectable.pdf'
                )
                """,
                in: database
            )
            guard sqlite3_changes(database) == 1 else {
                throw SQLiteProbeError.mutation("Expected one selectable DNA snapshot")
            }
            try execute(
                """
                UPDATE documentDNAAnalysisState
                SET status = 'failed', failureCode = 'analysisFailure'
                WHERE documentID = (
                    SELECT id FROM document WHERE relativePath = 'selectable.pdf'
                )
                """,
                in: database
            )
            guard sqlite3_changes(database) == 1 else {
                throw SQLiteProbeError.mutation("Expected one selectable DNA analysis state")
            }
            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SQLiteProbeError.query(message)
        }
    }
}

private enum SQLiteProbeError: Error {
    case open(String)
    case query(String)
    case closed
    case mutation(String)
}
