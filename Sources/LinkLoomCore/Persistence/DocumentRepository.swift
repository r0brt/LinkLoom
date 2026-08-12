import Foundation
import GRDB

public actor DocumentRepository {
    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func all(sourceRootID: UUID) async throws -> [DocumentRecord] {
        try await dbWriter.read { db in
            try DocumentRecord
                .filter(Column("sourceRootID") == sourceRootID)
                .order(Column("relativePath"))
                .fetchAll(db)
        }
    }

    public func all() async throws -> [DocumentRecord] {
        try await dbWriter.read { db in
            try DocumentRecord
                .order(Column("sourceRootID"), Column("relativePath"))
                .fetchAll(db)
        }
    }

    public func pendingExtraction(limit: Int) async throws -> [DocumentRecord] {
        guard limit > 0 else { return [] }
        return try await dbWriter.read { db in
            try DocumentRecord
                .filter(Column("availability") == DocumentAvailability.available.rawValue)
                .filter(Column("status") == DocumentStatus.discovered.rawValue)
                .order(Column("sourceRootID"), Column("relativePath"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func pendingExtraction(
        sourceRootID: UUID,
        limit: Int
    ) async throws -> [DocumentRecord] {
        guard limit > 0 else { return [] }
        return try await dbWriter.read { db in
            try DocumentRecord
                .filter(Column("sourceRootID") == sourceRootID)
                .filter(Column("availability") == DocumentAvailability.available.rawValue)
                .filter(Column("status") == DocumentStatus.discovered.rawValue)
                .order(Column("relativePath"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func pendingExtraction(
        sourceRootID: UUID,
        analysisVersion: String,
        limit: Int
    ) async throws -> [DocumentRecord] {
        guard limit > 0 else { return [] }
        return try await dbWriter.read { db in
            try DocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT document.*
                    FROM document
                    LEFT JOIN documentExtraction
                        ON documentExtraction.documentID = document.id
                    WHERE document.sourceRootID = ?
                        AND document.availability = ?
                        AND (
                            document.status = ?
                            OR (
                                document.status = ?
                                AND (
                                    documentExtraction.analysisVersion IS NULL
                                    OR documentExtraction.analysisVersion <> ?
                                )
                            )
                        )
                    ORDER BY document.relativePath
                    LIMIT ?
                    """,
                arguments: [
                    sourceRootID,
                    DocumentAvailability.available,
                    DocumentStatus.discovered,
                    DocumentStatus.ready,
                    analysisVersion,
                    limit,
                ]
            )
        }
    }

    public func save(_ document: DocumentRecord) async throws {
        try await dbWriter.write { db in
            try document.save(db)
        }
    }

    func reconcile(
        sourceRootID: UUID,
        saving documentsToSave: [DocumentRecord],
        excludingDocumentIDs: Set<UUID>
    ) async throws -> Int {
        try await dbWriter.write { db in
            for incoming in documentsToSave {
                if var current = try DocumentRecord.fetchOne(db, key: incoming.id) {
                    let contentChanged = current.contentHash != incoming.contentHash
                    current.relativePath = incoming.relativePath
                    current.contentHash = incoming.contentHash
                    current.byteCount = incoming.byteCount
                    current.modifiedAt = incoming.modifiedAt
                    current.mediaType = incoming.mediaType
                    current.availability = incoming.availability
                    current.lastSeenAt = incoming.lastSeenAt
                    if contentChanged {
                        current.status = .discovered
                        current.pageCount = nil
                        current.failureCode = nil
                    }
                    try current.update(db)
                } else {
                    var inserted = incoming
                    inserted.status = .discovered
                    inserted.pageCount = nil
                    inserted.failureCode = nil
                    try inserted.insert(db)
                }
            }
            let documents = try DocumentRecord
                .filter(Column("sourceRootID") == sourceRootID)
                .fetchAll(db)
            let missingDocuments = documents.filter {
                !excludingDocumentIDs.contains($0.id)
            }
            for var document in missingDocuments {
                document.availability = .missing
                try document.update(db)
            }
            return missingDocuments.count
        }
    }

    public func markMissing(
        sourceRootID: UUID,
        excludingDocumentIDs: Set<UUID>
    ) async throws -> Int {
        try await dbWriter.write { db in
            let documents = try DocumentRecord
                .filter(Column("sourceRootID") == sourceRootID)
                .fetchAll(db)
            let missingDocuments = documents.filter {
                !excludingDocumentIDs.contains($0.id)
            }
            for var document in missingDocuments {
                document.availability = .missing
                try document.update(db)
            }
            return missingDocuments.count
        }
    }

    public func markAvailability(
        id: UUID,
        availability: DocumentAvailability
    ) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE document SET availability = ? WHERE id = ?",
                arguments: [availability, id]
            )
        }
    }

    public func markStatus(
        id: UUID,
        status: DocumentStatus,
        pageCount: Int? = nil,
        failureCode: String? = nil
    ) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE document SET status = ?, pageCount = ?, failureCode = ? WHERE id = ?",
                arguments: [status, pageCount, failureCode, id]
            )
        }
    }

    func recoverInterruptedExtraction(sourceRootID: UUID) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE document
                    SET status = ?, pageCount = NULL, failureCode = NULL
                    WHERE sourceRootID = ? AND status = ?
                    """,
                arguments: [
                    DocumentStatus.discovered,
                    sourceRootID,
                    DocumentStatus.extracting,
                ]
            )
        }
    }

    func restoreAfterInterruption(_ document: DocumentRecord) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE document
                    SET status = ?, pageCount = ?, failureCode = ?
                    WHERE id = ? AND status = ?
                    """,
                arguments: [
                    document.status,
                    document.pageCount,
                    document.failureCode,
                    document.id,
                    DocumentStatus.extracting,
                ]
            )
        }
    }
}
