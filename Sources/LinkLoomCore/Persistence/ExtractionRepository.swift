import Foundation
import GRDB

public struct StoredExtraction: Sendable, Equatable {
    public let documentID: UUID
    public let analysisVersion: String
    public let extraction: ExtractedDocument
    public let updatedAt: Date

    public init(
        documentID: UUID,
        analysisVersion: String,
        extraction: ExtractedDocument,
        updatedAt: Date
    ) {
        self.documentID = documentID
        self.analysisVersion = analysisVersion
        self.extraction = extraction
        self.updatedAt = updatedAt
    }
}

public actor ExtractionRepository {
    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func replace(
        documentID: UUID,
        analysisVersion: String,
        extraction: ExtractedDocument,
        at date: Date = .now
    ) async throws {
        let encodedPages = try Self.encodedPages(extraction.pages)
        try await dbWriter.write { db in
            try Self.replace(
                in: db,
                documentID: documentID,
                analysisVersion: analysisVersion,
                extraction: extraction,
                encodedPages: encodedPages,
                date: date
            )
        }
    }

    func complete(
        documentID: UUID,
        expectedContentHash: String,
        analysisVersion: String,
        extraction: ExtractedDocument,
        at date: Date = .now
    ) async throws {
        let encodedPages = try Self.encodedPages(extraction.pages)
        try await dbWriter.write { db in
            try Self.replace(
                in: db,
                documentID: documentID,
                analysisVersion: analysisVersion,
                extraction: extraction,
                encodedPages: encodedPages,
                date: date
            )
            try db.execute(
                sql: """
                    UPDATE document
                    SET status = ?, pageCount = ?, failureCode = NULL
                    WHERE id = ? AND status = ? AND contentHash = ?
                    """,
                arguments: [
                    DocumentStatus.ready,
                    extraction.pages.count,
                    documentID,
                    DocumentStatus.extracting,
                    expectedContentHash,
                ]
            )
            guard db.changesCount == 1 else {
                throw ExtractionPersistenceError.staleDocument
            }
        }
    }

    public func extraction(documentID: UUID) async throws -> StoredExtraction? {
        try await dbWriter.read { db in
            guard let header = try Row.fetchOne(
                db,
                sql: """
                    SELECT documentID, analysisVersion, method, updatedAt
                    FROM documentExtraction
                    WHERE documentID = ?
                    """,
                arguments: [documentID]
            ) else {
                return nil
            }
            let storedDocumentID: UUID = header["documentID"]
            let analysisVersion: String = header["analysisVersion"]
            let methodRawValue: String = header["method"]
            let updatedAt: Date = header["updatedAt"]
            guard let method = ExtractionMethod(rawValue: methodRawValue) else {
                throw StoredExtractionError.invalidMethod(methodRawValue)
            }
            let pageRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT pageIndex, text, regionsJSON
                    FROM extractedPage
                    WHERE documentID = ?
                    ORDER BY pageIndex
                    """,
                arguments: [documentID]
            )
            let pages = try pageRows.map { row in
                let pageIndex: Int = row["pageIndex"]
                let text: String = row["text"]
                let regionsJSON: Data = row["regionsJSON"]
                return ExtractedPage(
                    pageIndex: pageIndex,
                    text: text,
                    regions: try JSONDecoder().decode([TextRegion].self, from: regionsJSON)
                )
            }
            return StoredExtraction(
                documentID: storedDocumentID,
                analysisVersion: analysisVersion,
                extraction: ExtractedDocument(method: method, pages: pages),
                updatedAt: updatedAt
            )
        }
    }

    private static func encodedPages(_ pages: [ExtractedPage]) throws -> [EncodedPage] {
        try pages.map { page in
            EncodedPage(
                pageIndex: page.pageIndex,
                text: page.text,
                regionsJSON: try JSONEncoder().encode(page.regions)
            )
        }
    }

    private static func replace(
        in db: Database,
        documentID: UUID,
        analysisVersion: String,
        extraction: ExtractedDocument,
        encodedPages: [EncodedPage],
        date: Date
    ) throws {
        try db.execute(
            sql: "DELETE FROM extractedPage WHERE documentID = ?",
            arguments: [documentID]
        )
        try db.execute(
            sql: "DELETE FROM extractionFTS WHERE documentID = ?",
            arguments: [documentID]
        )
        try db.execute(
            sql: """
                INSERT INTO documentExtraction
                    (documentID, analysisVersion, method, joinedText, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(documentID) DO UPDATE SET
                    analysisVersion = excluded.analysisVersion,
                    method = excluded.method,
                    joinedText = excluded.joinedText,
                    updatedAt = excluded.updatedAt
                """,
            arguments: [
                documentID,
                analysisVersion,
                extraction.method.rawValue,
                extraction.joinedText,
                date,
            ]
        )
        for page in encodedPages {
            try db.execute(
                sql: """
                    INSERT INTO extractedPage
                        (documentID, pageIndex, text, regionsJSON)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [documentID, page.pageIndex, page.text, page.regionsJSON]
            )
        }
        try db.execute(
            sql: "INSERT INTO extractionFTS (documentID, joinedText) VALUES (?, ?)",
            arguments: [documentID, extraction.joinedText]
        )
    }
}

enum ExtractionPersistenceError: Error {
    case staleDocument
}

private struct EncodedPage: Sendable {
    let pageIndex: Int
    let text: String
    let regionsJSON: Data
}

private enum StoredExtractionError: Error {
    case invalidMethod(String)
}
