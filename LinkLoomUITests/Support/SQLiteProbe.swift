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
    let ocrTextMatchCount: Int
    let corruptFailureMatchCount: Int
    let dnaSnapshotCount: Int
    let dnaFindingCount: Int
    let dnaEvidenceCount: Int
    let dnaAnalysisStateCount: Int
    let dnaReadyStateCount: Int
    let dnaClassificationCount: Int
    let localRulesSnapshotCount: Int

    var matchesCompletedWorkflow: Bool {
        sourceCount == 1
            && documentCount == 3
            && readyCount == 2
            && failedCount == 1
            && extractionCount == 2
            && extractedPageCount == 2
            && ftsCount == 2
            && unsupportedCount == 0
            && selectableTextMatchCount == 1
            && ocrTextMatchCount == 1
            && corruptFailureMatchCount == 1
            && dnaSnapshotCount == 2
            && dnaFindingCount == 2
            && dnaEvidenceCount == 0
            && dnaAnalysisStateCount == 2
            && dnaReadyStateCount == 2
            && dnaClassificationCount == 2
            && localRulesSnapshotCount == 2
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
    }

    var description: String {
        "source=\(sourceCount), document=\(documentCount), ready=\(readyCount), "
            + "failed=\(failedCount), extraction=\(extractionCount), "
            + "page=\(extractedPageCount), fts=\(ftsCount), "
            + "unsupported=\(unsupportedCount), selectableText=\(selectableTextMatchCount), "
            + "ocrText=\(ocrTextMatchCount), corruptFailure=\(corruptFailureMatchCount), "
            + "dnaSnapshot=\(dnaSnapshotCount), dnaFinding=\(dnaFindingCount), "
            + "dnaEvidence=\(dnaEvidenceCount), dnaState=\(dnaAnalysisStateCount), "
            + "dnaReady=\(dnaReadyStateCount), "
            + "dnaClassification=\(dnaClassificationCount), "
            + "localRulesSnapshot=\(localRulesSnapshotCount)"
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
                  AND instr(e.joinedText, 'Selectable LinkLoom smoke text') > 0
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
                  AND targetAnalyzerVersion = '1'
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
                  AND analyzerVersion = '1'
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

private enum SQLiteProbeError: Error {
    case open(String)
    case query(String)
    case closed
}
