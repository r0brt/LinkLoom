import Foundation
import GRDB

enum DossierStoreError: Error, Equatable {
    case invalidStoredState
}

enum DossierStore {
    static func all(in db: Database) throws -> [DossierRecord] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, kind, displayName, anchorDocumentID, createdAt, updatedAt
                FROM dossier
                ORDER BY createdAt, id
                """
        ).map(decodeDossier)
    }

    static func record(in db: Database, id: UUID) throws -> DossierRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, kind, displayName, anchorDocumentID, createdAt, updatedAt
                FROM dossier
                WHERE id = ?
                """,
            arguments: [id]
        ) else {
            return nil
        }
        return try decodeDossier(row)
    }

    static func insertOrFetchAnchored(
        in db: Database, proposed: DossierRecord
    ) throws -> DossierRecord {
        try db.execute(
            sql: """
                INSERT INTO dossier (
                    id, kind, displayName, anchorDocumentID, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(kind, anchorDocumentID) DO NOTHING
                """,
            arguments: [
                proposed.id,
                proposed.kind.rawValue,
                proposed.displayName,
                proposed.anchorDocumentID,
                proposed.createdAt,
                proposed.updatedAt,
            ]
        )
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, kind, displayName, anchorDocumentID, createdAt, updatedAt
                FROM dossier
                WHERE kind = ? AND anchorDocumentID = ?
                """,
            arguments: [proposed.kind.rawValue, proposed.anchorDocumentID]
        ) else {
            throw DossierStoreError.invalidStoredState
        }
        return try decodeDossier(row)
    }

    static func exclusions(
        in db: Database, dossierID: UUID
    ) throws -> [DossierMembershipExclusion] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT dossierID, documentID, revisionID, excludedAt
                FROM dossierMembershipExclusion
                WHERE dossierID = ?
                ORDER BY excludedAt, documentID
                """,
            arguments: [dossierID]
        ).map(decodeExclusion)
    }

    static func insertExclusion(
        in db: Database, exclusion: DossierMembershipExclusion
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO dossierMembershipExclusion (
                    dossierID, documentID, revisionID, excludedAt
                ) VALUES (?, ?, ?, ?)
                """,
            arguments: [
                exclusion.dossierID,
                exclusion.documentID,
                exclusion.revisionID,
                exclusion.excludedAt,
            ]
        )
    }

    static func deleteExclusion(
        in db: Database, dossierID: UUID, documentID: UUID,
        expectedRevisionID: UUID
    ) throws -> Bool {
        try db.execute(
            sql: """
                DELETE FROM dossierMembershipExclusion
                WHERE dossierID = ? AND documentID = ? AND revisionID = ?
                """,
            arguments: [dossierID, documentID, expectedRevisionID]
        )
        return db.changesCount == 1
    }

    private static func decodeDossier(_ row: Row) throws -> DossierRecord {
        let kindValue: String = row["kind"]
        guard let kind = DossierKind(rawValue: kindValue) else {
            throw DossierStoreError.invalidStoredState
        }
        do {
            return try DossierRecord(
                id: row["id"],
                kind: kind,
                displayName: row["displayName"],
                anchorDocumentID: row["anchorDocumentID"],
                createdAt: row["createdAt"],
                updatedAt: row["updatedAt"]
            )
        } catch {
            throw DossierStoreError.invalidStoredState
        }
    }

    private static func decodeExclusion(_ row: Row) -> DossierMembershipExclusion {
        DossierMembershipExclusion(
            dossierID: row["dossierID"],
            documentID: row["documentID"],
            revisionID: row["revisionID"],
            excludedAt: row["excludedAt"]
        )
    }
}
