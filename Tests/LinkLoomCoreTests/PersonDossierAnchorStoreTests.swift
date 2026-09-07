import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Person dossier anchor store")
struct PersonDossierAnchorStoreTests {
    @Test func insertOrFetchIsIdempotentForStableOriginIdentity() throws {
        let fixture = try PersonDossierAnchorStoreFixture.make()
        let first = try fixture.anchor(
            id: fixture.firstAnchorID,
            displayName: "Elise Muster"
        )
        let replacement = try fixture.anchor(
            id: fixture.secondAnchorID,
            displayName: "Elise Example"
        )

        try fixture.db.write { db in
            let storedFirst = try PersonDossierAnchorStore.insertOrFetch(in: db, proposed: first)
            let storedReplacement = try PersonDossierAnchorStore.insertOrFetch(
                in: db,
                proposed: replacement
            )
            let anchorCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personDossierAnchor")
            let evidenceCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM personDossierAnchorEvidence"
            )
            #expect(storedFirst == first)
            #expect(storedReplacement == first)
            #expect(anchorCount == 1)
            #expect(evidenceCount == first.personEvidence.count)
        }
    }

    @Test func sameNormalizedNameFromDifferentOriginsCreatesDistinctAnchors() throws {
        let fixture = try PersonDossierAnchorStoreFixture.make()
        let first = try fixture.anchor(id: fixture.firstAnchorID)
        let second = try fixture.anchor(
            id: fixture.secondAnchorID,
            originDocumentID: fixture.secondOriginDocumentID
        )

        try fixture.db.write { db in
            let storedFirst = try PersonDossierAnchorStore.insertOrFetch(in: db, proposed: first)
            let storedSecond = try PersonDossierAnchorStore.insertOrFetch(in: db, proposed: second)
            let anchorCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personDossierAnchor")
            #expect(storedFirst == first)
            #expect(storedSecond == second)
            #expect(anchorCount == 2)
        }
    }

    @Test func recordRoundTripsPersonAndBirthDateEvidenceInOrder() throws {
        let fixture = try PersonDossierAnchorStoreFixture.make()
        let anchor = try fixture.anchor(
            id: fixture.firstAnchorID,
            personEvidence: [
                fixture.evidence(pageIndex: 9, exactText: "Elise Muster"),
                fixture.evidence(pageIndex: 2, exactText: "E. Muster"),
            ],
            birthDate: try PersonDossierBirthDate(
                displayValue: "01.02.1940",
                normalizedValue: "1940-02-01",
                evidence: [
                    fixture.evidence(pageIndex: 7, exactText: "01.02.1940"),
                ]
            )
        )

        try fixture.db.write { db in
            _ = try PersonDossierAnchorStore.insertOrFetch(in: db, proposed: anchor)
            let stored = try PersonDossierAnchorStore.record(in: db, id: anchor.id)
            #expect(stored == anchor)
        }
    }

    @Test func insertOrFetchRollsBackAnchorWhenEvidenceInsertFails() throws {
        let fixture = try PersonDossierAnchorStoreFixture.make()
        let anchor = try fixture.anchor(id: fixture.firstAnchorID)

        try fixture.db.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_person_dossier_anchor_evidence
                BEFORE INSERT ON personDossierAnchorEvidence
                BEGIN
                    SELECT RAISE(ABORT, 'blocked person dossier anchor evidence');
                END
                """)
        }

        #expect(throws: DatabaseError.self) {
            try fixture.db.write { db in
                _ = try PersonDossierAnchorStore.insertOrFetch(in: db, proposed: anchor)
            }
        }

        try fixture.db.read { db in
            let anchorCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personDossierAnchor")
            let evidenceCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM personDossierAnchorEvidence"
            )
            #expect(anchorCount == 0)
            #expect(evidenceCount == 0)
        }

        try fixture.db.write { db in
            try db.execute(sql: "DROP TRIGGER reject_person_dossier_anchor_evidence")
            #expect(try PersonDossierAnchorStore.insertOrFetch(in: db, proposed: anchor) == anchor)
        }
    }

    @Test func recordRejectsMalformedUUIDRoleDateAndEvidenceJSON() throws {
        let fixture = try PersonDossierAnchorStoreFixture.make()
        try fixture.db.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = TRUE")
            for (id, column, value) in [
                (fixture.firstAnchorID, "originDocumentID", "not-a-uuid"),
                (fixture.secondAnchorID, "primaryRole", "unsupported"),
                (fixture.thirdAnchorID, "originDNAAnalyzedAt", "not-a-date"),
            ] {
                try fixture.insertRawAnchor(in: db, id: id, originDocumentID: id)
                try fixture.insertRawEvidence(in: db, personAnchorID: id)
                try db.execute(
                    sql: "UPDATE personDossierAnchor SET \(column) = ? WHERE id = ?",
                    arguments: [value, id]
                )
            }
            try fixture.insertRawAnchor(
                in: db,
                id: fixture.fourthAnchorID,
                originDocumentID: fixture.fourthAnchorID
            )
            try fixture.insertRawEvidence(in: db, personAnchorID: fixture.fourthAnchorID)
            try db.execute(
                sql: "UPDATE personDossierAnchorEvidence SET ocrRegionIndexesJSON = ? WHERE personAnchorID = ?",
                arguments: [Data("not-json".utf8), fixture.fourthAnchorID]
            )

            for id in [
                fixture.firstAnchorID, fixture.secondAnchorID,
                fixture.thirdAnchorID, fixture.fourthAnchorID,
            ] {
                #expect(throws: PersonDossierAnchorStoreError.invalidStoredState) {
                    try PersonDossierAnchorStore.record(in: db, id: id)
                }
            }
        }
    }

    @Test func recordRejectsMissingOrUnexpectedEvidenceSubjects() throws {
        let fixture = try PersonDossierAnchorStoreFixture.make()
        try fixture.db.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = TRUE")
            try fixture.insertRawAnchor(
                in: db,
                id: fixture.firstAnchorID,
                originDocumentID: fixture.firstAnchorID
            )
            try fixture.insertRawAnchor(
                in: db,
                id: fixture.secondAnchorID,
                originDocumentID: fixture.secondAnchorID,
                birthDateDisplayValue: "01.02.1940",
                birthDateNormalizedValue: "1940-02-01"
            )
            try fixture.insertRawEvidence(
                in: db,
                personAnchorID: fixture.secondAnchorID,
                subject: "unexpected"
            )
            try fixture.insertRawAnchor(
                in: db,
                id: fixture.thirdAnchorID,
                originDocumentID: fixture.thirdAnchorID
            )
            try fixture.insertRawEvidence(in: db, personAnchorID: fixture.thirdAnchorID)
            try fixture.insertRawEvidence(
                in: db,
                personAnchorID: fixture.thirdAnchorID,
                subject: "birthDate"
            )

            try fixture.insertRawAnchor(
                in: db,
                id: fixture.fourthAnchorID,
                originDocumentID: fixture.fourthAnchorID,
                birthDateDisplayValue: "01.02.1940",
                birthDateNormalizedValue: "1940-02-01"
            )
            try fixture.insertRawEvidence(in: db, personAnchorID: fixture.fourthAnchorID)

            for id in [
                fixture.firstAnchorID, fixture.secondAnchorID,
                fixture.thirdAnchorID, fixture.fourthAnchorID,
            ] {
                #expect(throws: PersonDossierAnchorStoreError.invalidStoredState) {
                    try PersonDossierAnchorStore.record(in: db, id: id)
                }
            }
        }
    }

    @Test func recordRejectsNonContiguousSubjectLocalEvidenceOrder() throws {
        let fixture = try PersonDossierAnchorStoreFixture.make()
        try fixture.db.write { db in
            try fixture.insertRawAnchor(
                in: db,
                id: fixture.firstAnchorID,
                originDocumentID: fixture.firstAnchorID
            )
            try fixture.insertRawEvidence(
                in: db,
                personAnchorID: fixture.firstAnchorID,
                evidenceOrder: 1
            )

            #expect(throws: PersonDossierAnchorStoreError.invalidStoredState) {
                try PersonDossierAnchorStore.record(in: db, id: fixture.firstAnchorID)
            }
        }
    }
}

private struct PersonDossierAnchorStoreFixture {
    let db: DatabaseQueue
    let firstAnchorID = UUID(uuidString: "a0000000-0000-0000-0000-000000000001")!
    let secondAnchorID = UUID(uuidString: "a0000000-0000-0000-0000-000000000002")!
    let thirdAnchorID = UUID(uuidString: "a0000000-0000-0000-0000-000000000003")!
    let fourthAnchorID = UUID(uuidString: "a0000000-0000-0000-0000-000000000004")!
    let firstOriginDocumentID = UUID(uuidString: "b0000000-0000-0000-0000-000000000001")!
    let secondOriginDocumentID = UUID(uuidString: "b0000000-0000-0000-0000-000000000002")!
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func make() throws -> Self {
        Self(db: try TestDatabase.make())
    }

    func anchor(
        id: UUID,
        displayName: String = "Elise Muster",
        originDocumentID: UUID? = nil,
        personEvidence: [DocumentDNAEvidence]? = nil,
        birthDate: PersonDossierBirthDate? = nil
    ) throws -> PersonDossierAnchor {
        try PersonDossierAnchor(
            id: id,
            displayName: displayName,
            normalizedName: "elise muster",
            primaryRole: .resident,
            originDocumentID: originDocumentID ?? firstOriginDocumentID,
            originContentHash: "origin-hash",
            originExtractionVersion: "text-v1",
            originDNASchemaVersion: 1,
            originDNAAnalyzerIdentifier: "local-rules",
            originDNAAnalyzerVersion: "1",
            originDNAAnalyzedAt: date,
            personEvidence: personEvidence ?? [evidence(pageIndex: 0, exactText: "Elise Muster")],
            birthDate: birthDate,
            createdAt: date,
            updatedAt: date
        )
    }

    func evidence(pageIndex: Int, exactText: String) -> DocumentDNAEvidence {
        try! DocumentDNAEvidence(
            pageIndex: pageIndex,
            startUTF16: 0,
            lengthUTF16: exactText.utf16.count,
            exactText: exactText,
            ocrRegionIndexes: [1, 3]
        )
    }

    func insertRawAnchor(
        in db: Database,
        id: UUID,
        originDocumentID: UUID? = nil,
        birthDateDisplayValue: String? = nil,
        birthDateNormalizedValue: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO personDossierAnchor (
                    id, displayName, normalizedName, primaryRole,
                    originDocumentID, originContentHash, originExtractionVersion,
                    originDNASchemaVersion, originDNAAnalyzerIdentifier,
                    originDNAAnalyzerVersion, originDNAAnalyzedAt,
                    birthDateDisplayValue, birthDateNormalizedValue, createdAt, updatedAt
                ) VALUES (?, 'Elise Muster', 'elise muster', 'resident', ?, 'origin-hash', 'text-v1',
                          1, 'local-rules', '1', ?, ?, ?, ?, ?)
            """,
            arguments: [
                id, originDocumentID ?? firstOriginDocumentID, date, birthDateDisplayValue,
                birthDateNormalizedValue, date, date,
            ]
        )
    }

    func insertRawEvidence(
        in db: Database,
        personAnchorID: UUID,
        subject: String = "person",
        evidenceOrder: Int = 0
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO personDossierAnchorEvidence (
                    personAnchorID, subject, evidenceOrder, pageIndex,
                    startUTF16, lengthUTF16, exactText, ocrRegionIndexesJSON
                ) VALUES (?, ?, ?, 0, 0, 12, 'Elise Muster', ?)
                """,
            arguments: [personAnchorID, subject, evidenceOrder, Data("[1,3]".utf8)]
        )
    }
}
