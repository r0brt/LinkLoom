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
                SELECT id, kind, displayName, anchorDocumentID, personAnchorID,
                       createdAt, updatedAt
                FROM dossier
                ORDER BY createdAt, id
                """
        ).map { try decodeDossier(in: db, row: $0) }
    }

    static func record(in db: Database, id: UUID) throws -> DossierRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, kind, displayName, anchorDocumentID, personAnchorID,
                       createdAt, updatedAt
                FROM dossier
                WHERE id = ?
                """,
            arguments: [id]
        ) else {
            return nil
        }
        return try decodeDossier(in: db, row: row)
    }

    static func insertOrFetchAnchored(
        in db: Database, proposed: DossierRecord
    ) throws -> DossierRecord {
        let anchorDocumentID: UUID?
        let personAnchorID: UUID?
        switch proposed.anchor {
        case .document(let id):
            anchorDocumentID = id
            personAnchorID = nil
        case .person(let anchor):
            anchorDocumentID = nil
            personAnchorID = anchor.id
        }
        try db.execute(
            sql: """
                INSERT INTO dossier (
                    id, kind, displayName, anchorDocumentID, personAnchorID,
                    createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT DO NOTHING
                """,
            arguments: [
                proposed.id,
                proposed.kind.rawValue,
                proposed.displayName,
                anchorDocumentID,
                personAnchorID,
                proposed.createdAt,
                proposed.updatedAt,
            ]
        )
        let row: Row?
        switch proposed.anchor {
        case .document(let id):
            row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, kind, displayName, anchorDocumentID, personAnchorID,
                           createdAt, updatedAt
                    FROM dossier
                    WHERE anchorDocumentID = ?
                    """,
                arguments: [id]
            )
        case .person(let anchor):
            row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, kind, displayName, anchorDocumentID, personAnchorID,
                           createdAt, updatedAt
                    FROM dossier
                    WHERE personAnchorID = ?
                    """,
                arguments: [anchor.id]
            )
        }
        guard let row else {
            throw DossierStoreError.invalidStoredState
        }
        return try decodeDossier(in: db, row: row)
    }

    static func confirmations(
        in db: Database, dossierID: UUID
    ) throws -> [DossierMembershipConfirmation] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT dossierID, documentID, revisionID, confirmedAt,
                       candidateKind, acceptedContentHash, acceptedExtractionVersion,
                       acceptedDNASchemaVersion, acceptedDNAAnalyzerIdentifier,
                       acceptedDNAAnalyzerVersion, acceptedDNAAnalyzedAt,
                       acceptedRole, acceptedNormalizedName
                FROM dossierMembershipConfirmation
                WHERE dossierID = ?
                ORDER BY confirmedAt, documentID
                """,
            arguments: [dossierID]
        ).map(decodeConfirmation)
    }

    static func insertConfirmation(
        in db: Database, confirmation: DossierMembershipConfirmation
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO dossierMembershipConfirmation (
                    dossierID, documentID, revisionID, confirmedAt,
                    candidateKind, acceptedContentHash, acceptedExtractionVersion,
                    acceptedDNASchemaVersion, acceptedDNAAnalyzerIdentifier,
                    acceptedDNAAnalyzerVersion, acceptedDNAAnalyzedAt,
                    acceptedRole, acceptedNormalizedName
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                confirmation.dossierID,
                confirmation.documentID,
                confirmation.revisionID,
                confirmation.confirmedAt,
                confirmation.candidateKind.rawValue,
                confirmation.acceptedContentHash,
                confirmation.acceptedExtractionVersion,
                confirmation.acceptedDNASchemaVersion,
                confirmation.acceptedDNAAnalyzerIdentifier,
                confirmation.acceptedDNAAnalyzerVersion,
                confirmation.acceptedDNAAnalyzedAt,
                confirmation.acceptedRole.rawValue,
                confirmation.acceptedNormalizedName,
            ]
        )
    }

    static func deleteConfirmation(
        in db: Database, dossierID: UUID, documentID: UUID,
        expectedRevisionID: UUID
    ) throws -> Bool {
        try db.execute(
            sql: """
                DELETE FROM dossierMembershipConfirmation
                WHERE dossierID = ? AND documentID = ? AND revisionID = ?
                """,
            arguments: [dossierID, documentID, expectedRevisionID]
        )
        return db.changesCount == 1
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

    private static func decodeDossier(in db: Database, row: Row) throws -> DossierRecord {
        do {
            let kindValue = try row.decode(String.self, forColumn: "kind")
            guard let kind = DossierKind(rawValue: kindValue) else {
                throw DossierStoreError.invalidStoredState
            }
            let documentAnchorID = try row.decode(UUID?.self, forColumn: "anchorDocumentID")
            let personAnchorID = try row.decode(UUID?.self, forColumn: "personAnchorID")
            let anchor: DossierAnchor
            switch kind {
            case .costsAndPayments:
                guard let documentAnchorID, personAnchorID == nil else {
                    throw DossierStoreError.invalidStoredState
                }
                anchor = .document(documentAnchorID)
            case .personMatter:
                guard documentAnchorID == nil,
                      let personAnchorID,
                      let personAnchor = try PersonDossierAnchorStore.record(
                          in: db,
                          id: personAnchorID
                      ) else {
                    throw DossierStoreError.invalidStoredState
                }
                anchor = .person(personAnchor)
            }
            return try DossierRecord(
                id: row.decode(UUID.self, forColumn: "id"),
                kind: kind,
                displayName: row.decode(String.self, forColumn: "displayName"),
                anchor: anchor,
                createdAt: row.decode(Date.self, forColumn: "createdAt"),
                updatedAt: row.decode(Date.self, forColumn: "updatedAt")
            )
        } catch {
            throw DossierStoreError.invalidStoredState
        }
    }

    private static func decodeConfirmation(_ row: Row) throws -> DossierMembershipConfirmation {
        do {
            let candidateKindValue = try row.decode(String.self, forColumn: "candidateKind")
            let acceptedRoleValue = try row.decode(String.self, forColumn: "acceptedRole")
            guard let candidateKind = PersonDossierCandidateKind(rawValue: candidateKindValue),
                  let acceptedRole = PersonDossierRole(rawValue: acceptedRoleValue) else {
                throw DossierStoreError.invalidStoredState
            }
            return try DossierMembershipConfirmation(
                dossierID: row.decode(UUID.self, forColumn: "dossierID"),
                documentID: row.decode(UUID.self, forColumn: "documentID"),
                revisionID: row.decode(UUID.self, forColumn: "revisionID"),
                confirmedAt: row.decode(Date.self, forColumn: "confirmedAt"),
                candidateKind: candidateKind,
                acceptedContentHash: row.decode(String.self, forColumn: "acceptedContentHash"),
                acceptedExtractionVersion: row.decode(
                    String.self,
                    forColumn: "acceptedExtractionVersion"
                ),
                acceptedDNASchemaVersion: row.decode(
                    Int.self,
                    forColumn: "acceptedDNASchemaVersion"
                ),
                acceptedDNAAnalyzerIdentifier: row.decode(
                    String.self,
                    forColumn: "acceptedDNAAnalyzerIdentifier"
                ),
                acceptedDNAAnalyzerVersion: row.decode(
                    String.self,
                    forColumn: "acceptedDNAAnalyzerVersion"
                ),
                acceptedDNAAnalyzedAt: row.decode(
                    Date.self,
                    forColumn: "acceptedDNAAnalyzedAt"
                ),
                acceptedRole: acceptedRole,
                acceptedNormalizedName: row.decode(
                    String.self,
                    forColumn: "acceptedNormalizedName"
                )
            )
        } catch {
            throw DossierStoreError.invalidStoredState
        }
    }

    private static func decodeExclusion(_ row: Row) throws -> DossierMembershipExclusion {
        do {
            return DossierMembershipExclusion(
                dossierID: try row.decode(UUID.self, forColumn: "dossierID"),
                documentID: try row.decode(UUID.self, forColumn: "documentID"),
                revisionID: try row.decode(UUID.self, forColumn: "revisionID"),
                excludedAt: try row.decode(Date.self, forColumn: "excludedAt")
            )
        } catch {
            throw DossierStoreError.invalidStoredState
        }
    }
}
