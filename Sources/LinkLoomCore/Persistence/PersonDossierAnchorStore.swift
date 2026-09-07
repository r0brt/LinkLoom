import Foundation
import GRDB

enum PersonDossierAnchorStoreError: Error, Equatable {
    case invalidStoredState
}

enum PersonDossierAnchorStore {
    static func record(in db: Database, id: UUID) throws -> PersonDossierAnchor? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, displayName, normalizedName, primaryRole,
                       originDocumentID, originContentHash, originExtractionVersion,
                       originDNASchemaVersion, originDNAAnalyzerIdentifier,
                       originDNAAnalyzerVersion, originDNAAnalyzedAt,
                       birthDateDisplayValue, birthDateNormalizedValue,
                       createdAt, updatedAt
                FROM personDossierAnchor
                WHERE id = ?
                """,
            arguments: [id]
        ) else {
            return nil
        }
        return try decodeAnchor(in: db, row: row)
    }

    static func insertOrFetch(
        in db: Database,
        proposed: PersonDossierAnchor
    ) throws -> PersonDossierAnchor {
        try db.execute(
            sql: """
                INSERT INTO personDossierAnchor (
                    id, displayName, normalizedName, primaryRole,
                    originDocumentID, originContentHash, originExtractionVersion,
                    originDNASchemaVersion, originDNAAnalyzerIdentifier,
                    originDNAAnalyzerVersion, originDNAAnalyzedAt,
                    birthDateDisplayValue, birthDateNormalizedValue,
                    createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(originDocumentID, primaryRole, normalizedName) DO NOTHING
                """,
            arguments: [
                proposed.id, proposed.displayName, proposed.normalizedName,
                proposed.primaryRole.rawValue, proposed.originDocumentID,
                proposed.originContentHash, proposed.originExtractionVersion,
                proposed.originDNASchemaVersion, proposed.originDNAAnalyzerIdentifier,
                proposed.originDNAAnalyzerVersion, proposed.originDNAAnalyzedAt,
                proposed.birthDate?.displayValue, proposed.birthDate?.normalizedValue,
                proposed.createdAt, proposed.updatedAt,
            ]
        )
        let inserted = db.changesCount == 1
        if inserted {
            try insertEvidence(
                proposed.personEvidence,
                subject: .person,
                personAnchorID: proposed.id,
                in: db
            )
            if let birthDate = proposed.birthDate {
                try insertEvidence(
                    birthDate.evidence,
                    subject: .birthDate,
                    personAnchorID: proposed.id,
                    in: db
                )
            }
        }

        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, displayName, normalizedName, primaryRole,
                       originDocumentID, originContentHash, originExtractionVersion,
                       originDNASchemaVersion, originDNAAnalyzerIdentifier,
                       originDNAAnalyzerVersion, originDNAAnalyzedAt,
                       birthDateDisplayValue, birthDateNormalizedValue,
                       createdAt, updatedAt
                FROM personDossierAnchor
                WHERE originDocumentID = ? AND primaryRole = ? AND normalizedName = ?
                """,
            arguments: [
                proposed.originDocumentID,
                proposed.primaryRole.rawValue,
                proposed.normalizedName,
            ]
        ) else {
            throw PersonDossierAnchorStoreError.invalidStoredState
        }
        return try decodeAnchor(in: db, row: row)
    }

    private static func insertEvidence(
        _ values: [DocumentDNAEvidence],
        subject: EvidenceSubject,
        personAnchorID: UUID,
        in db: Database
    ) throws {
        for (order, evidence) in values.enumerated() {
            let regionData = try JSONEncoder().encode(evidence.ocrRegionIndexes)
            try db.execute(
                sql: """
                    INSERT INTO personDossierAnchorEvidence (
                        personAnchorID, subject, evidenceOrder, pageIndex,
                        startUTF16, lengthUTF16, exactText, ocrRegionIndexesJSON
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    personAnchorID, subject.rawValue, order, evidence.pageIndex,
                    evidence.startUTF16, evidence.lengthUTF16, evidence.exactText,
                    regionData,
                ]
            )
        }
    }

    private static func decodeAnchor(in db: Database, row: Row) throws -> PersonDossierAnchor {
        do {
            let id = try row.decode(UUID.self, forColumn: "id")
            let roleValue = try row.decode(String.self, forColumn: "primaryRole")
            guard let primaryRole = PersonDossierRole(rawValue: roleValue) else {
                throw PersonDossierAnchorStoreError.invalidStoredState
            }
            let birthDateDisplayValue = try row.decode(String?.self, forColumn: "birthDateDisplayValue")
            let birthDateNormalizedValue = try row.decode(String?.self, forColumn: "birthDateNormalizedValue")

            let evidenceRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT subject, evidenceOrder, pageIndex, startUTF16,
                           lengthUTF16, exactText, ocrRegionIndexesJSON
                    FROM personDossierAnchorEvidence
                    WHERE personAnchorID = ?
                    ORDER BY subject, evidenceOrder
                    """,
                arguments: [id]
            )
            var personEvidence: [DocumentDNAEvidence] = []
            var birthDateEvidence: [DocumentDNAEvidence] = []
            var nextOrder = [EvidenceSubject.person: 0, .birthDate: 0]
            for evidenceRow in evidenceRows {
                let subjectValue = try evidenceRow.decode(String.self, forColumn: "subject")
                guard let subject = EvidenceSubject(rawValue: subjectValue),
                      let expectedOrder = nextOrder[subject],
                      try evidenceRow.decode(Int.self, forColumn: "evidenceOrder") == expectedOrder
                else {
                    throw PersonDossierAnchorStoreError.invalidStoredState
                }
                let regionData = try evidenceRow.decode(Data.self, forColumn: "ocrRegionIndexesJSON")
                let evidence = try DocumentDNAEvidence(
                    pageIndex: evidenceRow.decode(Int.self, forColumn: "pageIndex"),
                    startUTF16: evidenceRow.decode(Int.self, forColumn: "startUTF16"),
                    lengthUTF16: evidenceRow.decode(Int.self, forColumn: "lengthUTF16"),
                    exactText: evidenceRow.decode(String.self, forColumn: "exactText"),
                    ocrRegionIndexes: try JSONDecoder().decode([Int].self, from: regionData)
                )
                nextOrder[subject] = expectedOrder + 1
                switch subject {
                case .person:
                    personEvidence.append(evidence)
                case .birthDate:
                    birthDateEvidence.append(evidence)
                }
            }

            guard !personEvidence.isEmpty else {
                throw PersonDossierAnchorStoreError.invalidStoredState
            }
            let birthDate: PersonDossierBirthDate?
            switch (birthDateDisplayValue, birthDateNormalizedValue) {
            case let (.some(displayValue), .some(normalizedValue)):
                guard !birthDateEvidence.isEmpty else {
                    throw PersonDossierAnchorStoreError.invalidStoredState
                }
                birthDate = try PersonDossierBirthDate(
                    displayValue: displayValue,
                    normalizedValue: normalizedValue,
                    evidence: birthDateEvidence
                )
            case (nil, nil):
                guard birthDateEvidence.isEmpty else {
                    throw PersonDossierAnchorStoreError.invalidStoredState
                }
                birthDate = nil
            default:
                throw PersonDossierAnchorStoreError.invalidStoredState
            }

            return try PersonDossierAnchor(
                id: id,
                displayName: row.decode(String.self, forColumn: "displayName"),
                normalizedName: row.decode(String.self, forColumn: "normalizedName"),
                primaryRole: primaryRole,
                originDocumentID: row.decode(UUID.self, forColumn: "originDocumentID"),
                originContentHash: row.decode(String.self, forColumn: "originContentHash"),
                originExtractionVersion: row.decode(String.self, forColumn: "originExtractionVersion"),
                originDNASchemaVersion: row.decode(Int.self, forColumn: "originDNASchemaVersion"),
                originDNAAnalyzerIdentifier: row.decode(String.self, forColumn: "originDNAAnalyzerIdentifier"),
                originDNAAnalyzerVersion: row.decode(String.self, forColumn: "originDNAAnalyzerVersion"),
                originDNAAnalyzedAt: row.decode(Date.self, forColumn: "originDNAAnalyzedAt"),
                personEvidence: personEvidence,
                birthDate: birthDate,
                createdAt: row.decode(Date.self, forColumn: "createdAt"),
                updatedAt: row.decode(Date.self, forColumn: "updatedAt")
            )
        } catch {
            throw PersonDossierAnchorStoreError.invalidStoredState
        }
    }

    private enum EvidenceSubject: String {
        case person
        case birthDate
    }
}
