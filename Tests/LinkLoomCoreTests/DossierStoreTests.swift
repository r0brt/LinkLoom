import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Dossier store")
struct DossierStoreTests {
    @Test func allAndRecordRoundTripInCreatedAtThenIDOrder() throws {
        let fixture = try DossierStoreFixture.make()
        let first = try fixture.dossier(
            id: fixture.firstDossierID,
            anchorDocumentID: fixture.anchorID
        )
        let second = try fixture.dossier(
            id: fixture.secondDossierID,
            anchorDocumentID: fixture.paymentID
        )

        try fixture.db.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: second)
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: first)

            #expect(try DossierStore.all(in: db) == [first, second])
            #expect(try DossierStore.record(in: db, id: first.id) == first)
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
}

private struct DossierStoreFixture {
    let db: DatabaseQueue
    let sourceID = UUID(uuidString: "90000000-0000-0000-0000-000000000001")!
    let anchorID = UUID(uuidString: "90000000-0000-0000-0000-000000000002")!
    let paymentID = UUID(uuidString: "90000000-0000-0000-0000-000000000003")!
    let firstDossierID = UUID(uuidString: "90000000-0000-0000-0000-000000000004")!
    let secondDossierID = UUID(uuidString: "90000000-0000-0000-0000-000000000005")!
    let firstRevisionID = UUID(uuidString: "90000000-0000-0000-0000-000000000006")!
    let secondRevisionID = UUID(uuidString: "90000000-0000-0000-0000-000000000007")!
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func make() throws -> Self {
        let fixture = Self(db: try TestDatabase.make())
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
