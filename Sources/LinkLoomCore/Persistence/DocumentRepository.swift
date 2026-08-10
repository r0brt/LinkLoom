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
            for document in documentsToSave {
                try document.save(db)
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
}
