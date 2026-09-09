import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Dossier store")
struct DossierStoreTests {
    @Test func allAndRecordRoundTripDocumentAndPersonAnchors() throws {
        let fixture = try DossierStoreFixture.make()
        let costs = try fixture.dossier(
            id: fixture.firstDossierID,
            anchorDocumentID: fixture.anchorID
        )
        let person = try fixture.personDossier(
            id: fixture.secondDossierID,
            anchor: fixture.persistedPersonAnchor
        )

        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: person)
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: costs)

            #expect(try DossierStore.all(in: db) == [costs, person])
            #expect(try DossierStore.record(in: db, id: person.id) == person)
            #expect(try DossierStore.record(in: db, id: UUID()) == nil)
        }
    }

    @Test func insertOrFetchAnchoredIsIdempotent() throws {
        let fixture = try DossierStoreFixture.make()
        let proposed = try fixture.dossier(id: fixture.firstDossierID)
        try fixture.db.write { db in
            let first = try DossierStore.insertOrFetchAnchored(in: db, proposed: proposed)
            let second = try DossierStore.insertOrFetchAnchored(
                in: db, proposed: try fixture.dossier(id: fixture.secondDossierID)
            )
            #expect(first == proposed)
            #expect(second == proposed)
            #expect(try DossierStore.all(in: db) == [proposed])
        }
    }

    @Test func insertOrFetchPersonDossierIsIdempotentByPersonAnchor() throws {
        let fixture = try DossierStoreFixture.make()
        let first = try fixture.personDossier(
            id: fixture.firstDossierID,
            anchor: fixture.persistedPersonAnchor
        )
        let replacement = try fixture.personDossier(
            id: fixture.secondDossierID,
            anchor: fixture.persistedPersonAnchor
        )

        try fixture.db.write { db in
            let storedFirst = try DossierStore.insertOrFetchAnchored(in: db, proposed: first)
            let storedReplacement = try DossierStore.insertOrFetchAnchored(
                in: db,
                proposed: replacement
            )
            #expect(storedFirst == first)
            #expect(storedReplacement == first)
            #expect(try DossierStore.all(in: db) == [first])
        }
    }

    @Test func personDossierReadsTheTypedDossierForPersonAnchor() throws {
        let fixture = try DossierStoreFixture.make()
        let person = try fixture.personDossier(
            id: fixture.firstDossierID,
            anchor: fixture.persistedPersonAnchor
        )

        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: person)

            #expect(try DossierStore.personDossier(
                in: db,
                personAnchorID: fixture.persistedPersonAnchor.id
            ) == person)
            #expect(try DossierStore.personDossier(in: db, personAnchorID: UUID()) == nil)
        }
    }

    @Test func personDossierRequiresPreviouslyStoredPersonAnchor() throws {
        let fixture = try DossierStoreFixture.make()
        let person = try fixture.personDossier(
            id: fixture.firstDossierID,
            anchor: try fixture.personAnchor(id: fixture.unstoredPersonAnchorID)
        )

        try fixture.db.write { db in
            #expect(throws: DatabaseError.self) {
                try DossierStore.insertOrFetchAnchored(in: db, proposed: person)
            }
            let stored = try DossierStore.all(in: db)
            #expect(stored.isEmpty)
        }
    }

    @Test func malformedTypedDossierRowsMapToInvalidStoredState() throws {
        let fixture = try DossierStoreFixture.make()

        try fixture.db.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = TRUE")
            try db.execute(
                sql: """
                    INSERT INTO dossier (
                        id, kind, displayName, anchorDocumentID, personAnchorID,
                        createdAt, updatedAt
                    ) VALUES (?, 'costsAndPayments', 'Invalid costs', ?, ?, ?, ?)
                    """,
                arguments: [
                    fixture.firstDossierID,
                    fixture.anchorID,
                    fixture.persistedPersonAnchor.id,
                    fixture.date,
                    fixture.date,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO dossier (
                        id, kind, displayName, anchorDocumentID, personAnchorID,
                        createdAt, updatedAt
                    ) VALUES (?, 'personMatter', 'Invalid person', ?, NULL, ?, ?)
                    """,
                arguments: [
                    fixture.secondDossierID,
                    fixture.paymentID,
                    fixture.date,
                    fixture.date,
                ]
            )

            for id in [fixture.firstDossierID, fixture.secondDossierID] {
                #expect(throws: DossierStoreError.invalidStoredState) {
                    try DossierStore.record(in: db, id: id)
                }
            }
            #expect(throws: DossierStoreError.invalidStoredState) {
                try DossierStore.personDossier(
                    in: db,
                    personAnchorID: fixture.persistedPersonAnchor.id
                )
            }

            try db.execute(sql: "DELETE FROM dossier")
            let person = try fixture.personDossier(
                id: fixture.firstDossierID,
                anchor: fixture.persistedPersonAnchor
            )
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: person)
            try db.execute(
                sql: """
                    UPDATE personDossierAnchorEvidence
                    SET ocrRegionIndexesJSON = ?
                    WHERE personAnchorID = ? AND subject = 'person'
                    """,
                arguments: [Data("not-json".utf8), fixture.persistedPersonAnchor.id]
            )
            #expect(throws: DossierStoreError.invalidStoredState) {
                try DossierStore.record(in: db, id: person.id)
            }
        }
    }

    @Test func confirmationsRoundTripInConfirmedAtThenDocumentOrder() throws {
        let fixture = try DossierStoreFixture.make()
        let dossier = try fixture.personDossier(
            id: fixture.firstDossierID,
            anchor: fixture.persistedPersonAnchor
        )
        let first = try fixture.confirmation(
            dossierID: dossier.id,
            documentID: fixture.anchorID,
            revisionID: fixture.firstRevisionID,
            confirmedAt: fixture.date
        )
        let second = try fixture.confirmation(
            dossierID: dossier.id,
            documentID: fixture.paymentID,
            revisionID: fixture.secondRevisionID,
            confirmedAt: fixture.date,
            candidateKind: .birthDateConflict,
            acceptedRole: .resident
        )
        let earlier = try fixture.confirmation(
            dossierID: dossier.id,
            documentID: fixture.thirdDocumentID,
            revisionID: fixture.thirdRevisionID,
            confirmedAt: fixture.date.addingTimeInterval(-1)
        )

        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: dossier)
            try DossierStore.insertConfirmation(in: db, confirmation: second)
            try DossierStore.insertConfirmation(in: db, confirmation: earlier)
            try DossierStore.insertConfirmation(in: db, confirmation: first)

            #expect(try DossierStore.confirmations(in: db, dossierID: dossier.id) == [
                earlier, first, second,
            ])
        }
    }

    @Test func duplicateConfirmationMembershipIsRejected() throws {
        let fixture = try DossierStoreFixture.make()
        let dossier = try fixture.personDossier(
            id: fixture.firstDossierID,
            anchor: fixture.persistedPersonAnchor
        )
        let first = try fixture.confirmation(dossierID: dossier.id)
        let duplicateMembership = try fixture.confirmation(
            dossierID: dossier.id,
            revisionID: fixture.secondRevisionID
        )

        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: dossier)
            try DossierStore.insertConfirmation(in: db, confirmation: first)
            #expect(throws: DatabaseError.self) {
                try DossierStore.insertConfirmation(in: db, confirmation: duplicateMembership)
            }
        }
    }

    @Test func deleteConfirmationRequiresExactRevision() throws {
        let fixture = try DossierStoreFixture.make()
        let dossier = try fixture.personDossier(
            id: fixture.firstDossierID,
            anchor: fixture.persistedPersonAnchor
        )
        let confirmation = try fixture.confirmation(dossierID: dossier.id)

        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: dossier)
            try DossierStore.insertConfirmation(in: db, confirmation: confirmation)
            #expect(try !DossierStore.deleteConfirmation(
                in: db,
                dossierID: dossier.id,
                documentID: confirmation.documentID,
                expectedRevisionID: fixture.secondRevisionID
            ))
            #expect(try DossierStore.deleteConfirmation(
                in: db,
                dossierID: dossier.id,
                documentID: confirmation.documentID,
                expectedRevisionID: confirmation.revisionID
            ))
        }
    }

    @Test func malformedConfirmationMapsToInvalidStoredState() throws {
        let fixture = try DossierStoreFixture.make()
        let dossier = try fixture.personDossier(
            id: fixture.firstDossierID,
            anchor: fixture.persistedPersonAnchor
        )
        let valid = try fixture.confirmation(dossierID: dossier.id)

        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: dossier)
            try db.execute(sql: "PRAGMA ignore_check_constraints = TRUE")

            for (column, malformedValue) in [
                ("revisionID", "not-a-uuid"),
                ("candidateKind", "unsupported"),
                ("confirmedAt", "not-a-date"),
                ("candidateKind", PersonDossierCandidateKind.birthDateConflict.rawValue),
                ("acceptedNormalizedName", " \t\n"),
            ] {
                try DossierStore.insertConfirmation(in: db, confirmation: valid)
                try db.execute(
                    sql: """
                        UPDATE dossierMembershipConfirmation
                        SET \(column) = ?
                        WHERE dossierID = ? AND documentID = ?
                        """,
                    arguments: [malformedValue, dossier.id, valid.documentID]
                )
                #expect(throws: DossierStoreError.invalidStoredState) {
                    try DossierStore.confirmations(in: db, dossierID: dossier.id)
                }
                try db.execute(
                    sql: "DELETE FROM dossierMembershipConfirmation WHERE dossierID = ?",
                    arguments: [dossier.id]
                )
            }
        }
    }

    @Test func exclusionsAreOrderedByExcludedAtThenDocumentID() throws {
        let fixture = try DossierStoreFixture.make()
        let dossier = try fixture.dossier(id: fixture.firstDossierID)
        let first = fixture.exclusion(
            dossierID: dossier.id,
            documentID: fixture.anchorID,
            revisionID: fixture.firstRevisionID
        )
        let second = fixture.exclusion(
            dossierID: dossier.id,
            documentID: fixture.paymentID,
            revisionID: fixture.secondRevisionID
        )

        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: dossier)
            try DossierStore.insertExclusion(in: db, exclusion: second)
            try DossierStore.insertExclusion(in: db, exclusion: first)

            #expect(try DossierStore.exclusions(in: db, dossierID: dossier.id) == [first, second])
        }
    }

    @Test func insertExclusionDoesNotSilentlyIgnoreDuplicateMembership() throws {
        let fixture = try DossierStoreFixture.make()
        let dossier = try fixture.dossier(id: fixture.firstDossierID)
        let exclusion = fixture.exclusion(dossierID: dossier.id)

        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: dossier)
            try DossierStore.insertExclusion(in: db, exclusion: exclusion)

            #expect(throws: (any Error).self) {
                try DossierStore.insertExclusion(in: db, exclusion: exclusion)
            }
        }
    }

    @Test func deleteExclusionRequiresExactRevision() throws {
        let fixture = try DossierStoreFixture.make()
        try fixture.db.write { db in
            let dossier = try DossierStore.insertOrFetchAnchored(
                in: db, proposed: try fixture.dossier(id: fixture.firstDossierID)
            )
            let exclusion = fixture.exclusion(dossierID: dossier.id)
            try DossierStore.insertExclusion(in: db, exclusion: exclusion)
            #expect(try !DossierStore.deleteExclusion(
                in: db, dossierID: dossier.id, documentID: fixture.paymentID,
                expectedRevisionID: UUID()
            ))
            #expect(try DossierStore.deleteExclusion(
                in: db, dossierID: dossier.id, documentID: fixture.paymentID,
                expectedRevisionID: exclusion.revisionID
            ))
        }
    }

    @Test func invalidStoredDossierStateIsRejected() throws {
        let fixture = try DossierStoreFixture.make()
        try fixture.db.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = TRUE")
            try db.execute(
                sql: """
                    INSERT INTO dossier (
                        id, kind, displayName, anchorDocumentID, createdAt, updatedAt
                    ) VALUES (?, 'unsupported', 'Invalid', ?, ?, ?)
                    """,
                arguments: [
                    fixture.firstDossierID,
                    fixture.anchorID,
                    fixture.date,
                    fixture.date,
                ]
            )

            #expect(throws: DossierStoreError.invalidStoredState) {
                try DossierStore.all(in: db)
            }
        }
    }

    @Test func malformedDossierUUIDIsRejected() throws {
        let fixture = try DossierStoreFixture.make()
        try fixture.db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dossier (
                        id, kind, displayName, anchorDocumentID, createdAt, updatedAt
                    ) VALUES ('not-a-uuid', 'costsAndPayments', 'Malformed', ?, ?, ?)
                    """,
                arguments: [fixture.anchorID, fixture.date, fixture.date]
            )

            #expect(throws: DossierStoreError.invalidStoredState) {
                try DossierStore.all(in: db)
            }
        }
    }

    @Test func malformedDossierDateIsRejected() throws {
        let fixture = try DossierStoreFixture.make()
        try fixture.db.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = TRUE")
            try db.execute(
                sql: """
                    INSERT INTO dossier (
                        id, kind, displayName, anchorDocumentID, createdAt, updatedAt
                    ) VALUES (?, 'costsAndPayments', 'Malformed', ?, 'not-a-date', ?)
                    """,
                arguments: [fixture.firstDossierID, fixture.anchorID, fixture.date]
            )

            #expect(throws: DossierStoreError.invalidStoredState) {
                try DossierStore.record(in: db, id: fixture.firstDossierID)
            }
        }
    }

    @Test func malformedExclusionUUIDIsRejected() throws {
        let fixture = try DossierStoreFixture.make()
        let dossier = try fixture.dossier(id: fixture.firstDossierID)
        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: dossier)
            try db.execute(
                sql: """
                    INSERT INTO dossierMembershipExclusion (
                        dossierID, documentID, revisionID, excludedAt
                    ) VALUES (?, ?, 'not-a-uuid', ?)
                    """,
                arguments: [dossier.id, fixture.paymentID, fixture.date]
            )

            #expect(throws: DossierStoreError.invalidStoredState) {
                try DossierStore.exclusions(in: db, dossierID: dossier.id)
            }
        }
    }

    @Test func malformedExclusionDateIsRejected() throws {
        let fixture = try DossierStoreFixture.make()
        let dossier = try fixture.dossier(id: fixture.firstDossierID)
        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: dossier)
            try db.execute(
                sql: """
                    INSERT INTO dossierMembershipExclusion (
                        dossierID, documentID, revisionID, excludedAt
                    ) VALUES (?, ?, ?, 'not-a-date')
                    """,
                arguments: [dossier.id, fixture.paymentID, fixture.firstRevisionID]
            )

            #expect(throws: DossierStoreError.invalidStoredState) {
                try DossierStore.exclusions(in: db, dossierID: dossier.id)
            }
        }
    }
}

private struct DossierStoreFixture {
    let db: DatabaseQueue
    let sourceID = UUID(uuidString: "90000000-0000-0000-0000-000000000001")!
    let anchorID = UUID(uuidString: "90000000-0000-0000-0000-000000000002")!
    let paymentID = UUID(uuidString: "90000000-0000-0000-0000-000000000003")!
    let thirdDocumentID = UUID(uuidString: "90000000-0000-0000-0000-00000000000a")!
    let firstDossierID = UUID(uuidString: "90000000-0000-0000-0000-000000000004")!
    let secondDossierID = UUID(uuidString: "90000000-0000-0000-0000-000000000005")!
    let firstRevisionID = UUID(uuidString: "90000000-0000-0000-0000-000000000006")!
    let secondRevisionID = UUID(uuidString: "90000000-0000-0000-0000-000000000007")!
    let thirdRevisionID = UUID(uuidString: "90000000-0000-0000-0000-00000000000b")!
    let persistedPersonAnchorID = UUID(uuidString: "90000000-0000-0000-0000-000000000008")!
    let unstoredPersonAnchorID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let persistedPersonAnchor: PersonDossierAnchor

    static func make() throws -> Self {
        let fixture = Self(
            db: try TestDatabase.make(),
            persistedPersonAnchor: try makePersonAnchor(
                id: UUID(uuidString: "90000000-0000-0000-0000-000000000008")!
            )
        )
        try fixture.db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sourceRoot (
                        id, displayName, pathHint, bookmarkData, createdAt, lastScanAt
                    ) VALUES (?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    fixture.sourceID,
                    "Dossier store fixture",
                    "/synthetic/dossiers",
                    Data("dossier-bookmark".utf8),
                    fixture.date,
                ]
            )
            for (id, path, contentHash) in [
                (fixture.anchorID, "anchor.pdf", "hash-anchor"),
                (fixture.paymentID, "payment.pdf", "hash-payment"),
                (fixture.thirdDocumentID, "third.pdf", "hash-third"),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO document (
                            id, sourceRootID, relativePath, contentHash, byteCount,
                            modifiedAt, mediaType, status, availability, pageCount,
                            failureCode, lastSeenAt, lastFingerprintAt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        id,
                        fixture.sourceID,
                        path,
                        contentHash,
                        64,
                        fixture.date,
                        SupportedMediaType.pdf.rawValue,
                        DocumentStatus.ready.rawValue,
                        DocumentAvailability.available.rawValue,
                        1,
                        nil,
                        fixture.date,
                        fixture.date,
                    ]
                )
            }
            _ = try PersonDossierAnchorStore.insertOrFetch(
                in: db,
                proposed: fixture.persistedPersonAnchor
            )
        }
        return fixture
    }

    func dossier(
        id: UUID,
        anchorDocumentID: UUID? = nil
    ) throws -> DossierRecord {
        try DossierRecord(
            id: id,
            kind: .costsAndPayments,
            displayName: id == firstDossierID ? "Costs and payments" : "Replacement dossier",
            anchorDocumentID: anchorDocumentID ?? anchorID,
            createdAt: date,
            updatedAt: date
        )
    }

    func personDossier(
        id: UUID,
        anchor: PersonDossierAnchor
    ) throws -> DossierRecord {
        return try DossierRecord(
            id: id,
            kind: .personMatter,
            displayName: "Meine Mutter im Pflegeheim",
            anchor: .person(anchor),
            createdAt: date,
            updatedAt: date
        )
    }

    func personAnchor(id: UUID) throws -> PersonDossierAnchor {
        try Self.makePersonAnchor(id: id)
    }

    func confirmation(
        dossierID: UUID,
        documentID: UUID? = nil,
        revisionID: UUID? = nil,
        confirmedAt: Date? = nil,
        candidateKind: PersonDossierCandidateKind = .secondaryRole,
        acceptedRole: PersonDossierRole = .authorizedPerson
    ) throws -> DossierMembershipConfirmation {
        try DossierMembershipConfirmation(
            dossierID: dossierID,
            documentID: documentID ?? paymentID,
            revisionID: revisionID ?? firstRevisionID,
            confirmedAt: confirmedAt ?? date,
            candidateKind: candidateKind,
            acceptedContentHash: "hash-candidate",
            acceptedExtractionVersion: "text-v1",
            acceptedDNASchemaVersion: 1,
            acceptedDNAAnalyzerIdentifier: "local-rules",
            acceptedDNAAnalyzerVersion: "1",
            acceptedDNAAnalyzedAt: date.addingTimeInterval(-1),
            acceptedRole: acceptedRole,
            acceptedNormalizedName: "elise muster"
        )
    }

    private static func makePersonAnchor(id: UUID) throws -> PersonDossierAnchor {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let personEvidence = try DocumentDNAEvidence(
            pageIndex: 2,
            startUTF16: 4,
            lengthUTF16: 12,
            exactText: "Elise Muster",
            ocrRegionIndexes: [1, 3]
        )
        let birthDateEvidence = try DocumentDNAEvidence(
            pageIndex: 3,
            startUTF16: 8,
            lengthUTF16: 10,
            exactText: "01.02.1940",
            ocrRegionIndexes: [2]
        )
        return try PersonDossierAnchor(
            id: id,
            displayName: "Elise Muster",
            normalizedName: "elise muster",
            primaryRole: .resident,
            originDocumentID: UUID(uuidString: "90000000-0000-0000-0000-000000000002")!,
            originContentHash: "hash-anchor",
            originExtractionVersion: "text-v1",
            originDNASchemaVersion: 1,
            originDNAAnalyzerIdentifier: "local-rules",
            originDNAAnalyzerVersion: "1",
            originDNAAnalyzedAt: date,
            personEvidence: [personEvidence],
            birthDate: try PersonDossierBirthDate(
                displayValue: "01.02.1940",
                normalizedValue: "1940-02-01",
                evidence: [birthDateEvidence]
            ),
            createdAt: date,
            updatedAt: date
        )
    }

    func exclusion(
        dossierID: UUID,
        documentID: UUID? = nil,
        revisionID: UUID? = nil
    ) -> DossierMembershipExclusion {
        DossierMembershipExclusion(
            dossierID: dossierID,
            documentID: documentID ?? paymentID,
            revisionID: revisionID ?? firstRevisionID,
            excludedAt: date
        )
    }
}
