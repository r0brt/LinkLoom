import Foundation
@testable import LinkLoomCore

struct CostsAndPaymentsDossierAppModelValues {
    let snapshot: DossierSnapshot

    static func make() throws -> Self {
        let anchorID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
        let sourceID = UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
        let timestamp = Date(timeIntervalSince1970: 100)
        let dossier = try DossierRecord(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000003")!,
            kind: .costsAndPayments,
            displayName: "Kosten und Zahlungen",
            anchorDocumentID: anchorID,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let anchor = DocumentRecord(
            id: anchorID,
            sourceRootID: sourceID,
            relativePath: "invoice.pdf",
            contentHash: "invoice-hash",
            byteCount: 10,
            modifiedAt: timestamp,
            mediaType: .pdf,
            status: .ready,
            pageCount: 1,
            lastSeenAt: timestamp
        )
        return Self(snapshot: DossierSnapshot(
            dossier: dossier,
            members: [DossierMember(
                document: anchor,
                sourceDisplayName: "Archive",
                documentType: .invoice,
                explanation: DossierMembershipExplanation(
                    role: .anchor,
                    relationshipType: nil,
                    signals: []
                ),
                support: nil
            )],
            corrections: [],
            token: DossierProjectionToken(
                dossierUpdatedAt: timestamp,
                anchorContentHash: anchor.contentHash,
                memberSupports: [],
                exclusionRevisionIDs: []
            )
        ))
    }
}

struct PersonDossierAppModelValues {
    let snapshot: PersonDossierSnapshot

    static func make() throws -> Self {
        let originID = UUID(uuidString: "72000000-0000-0000-0000-000000000001")!
        let sourceID = UUID(uuidString: "72000000-0000-0000-0000-000000000002")!
        let anchorID = UUID(uuidString: "72000000-0000-0000-0000-000000000003")!
        let dossierID = UUID(uuidString: "72000000-0000-0000-0000-000000000004")!
        let timestamp = Date(timeIntervalSince1970: 200)
        let evidence = try DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 0,
            lengthUTF16: 12,
            exactText: "Elise Muster",
            ocrRegionIndexes: []
        )
        let origin = DocumentRecord(
            id: originID,
            sourceRootID: sourceID,
            relativePath: "person.pdf",
            contentHash: "person-hash",
            byteCount: 20,
            modifiedAt: timestamp,
            mediaType: .pdf,
            status: .ready,
            pageCount: 1,
            lastSeenAt: timestamp
        )
        let anchor = try PersonDossierAnchor(
            id: anchorID,
            displayName: "Elise Muster",
            normalizedName: "elise muster",
            primaryRole: .resident,
            originDocumentID: originID,
            originContentHash: origin.contentHash,
            originExtractionVersion: "text-v1",
            originDNASchemaVersion: 1,
            originDNAAnalyzerIdentifier: "local-rules",
            originDNAAnalyzerVersion: "1",
            originDNAAnalyzedAt: timestamp,
            personEvidence: [evidence],
            birthDate: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let dossier = try DossierRecord(
            id: dossierID,
            kind: .personMatter,
            displayName: "Elise Muster",
            anchor: .person(anchor),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let projectionIdentity = PersonDossierDocumentProjectionIdentity(
            document: origin,
            dnaAnalyzedAt: timestamp
        )
        return Self(snapshot: PersonDossierSnapshot(
            dossier: dossier,
            anchor: anchor,
            origin: try PersonDossierOriginState(
                validity: .current,
                document: origin,
                sourceDisplayName: "Archive"
            ),
            directMembers: [],
            costsAndPayments: [],
            suggestions: [],
            corrections: [],
            token: PersonDossierProjectionToken(
                dossierUpdatedAt: timestamp,
                anchorUpdatedAt: timestamp,
                originValidity: .current,
                documents: [projectionIdentity],
                memberSupports: [],
                suggestionSupports: [],
                confirmationRevisionIDs: [],
                exclusionRevisionIDs: []
            )
        ))
    }
}
