import Foundation
import Testing
@testable import LinkLoomCore

private let personEvidence = try! DocumentDNAEvidence(
    pageIndex: 0,
    startUTF16: 12,
    lengthUTF16: 12,
    exactText: "Elise Muster",
    ocrRegionIndexes: [1, 2]
)

private func personAnchor(
    id: UUID = UUID(),
    originDocumentID: UUID = UUID(),
    normalizedName: String = "elise muster",
    role: PersonDossierRole = .resident,
    birthDate: PersonDossierBirthDate? = nil
) throws -> PersonDossierAnchor {
    try PersonDossierAnchor(
        id: id,
        displayName: "Elise Muster",
        normalizedName: normalizedName,
        primaryRole: role,
        originDocumentID: originDocumentID,
        originContentHash: "hash-origin",
        originExtractionVersion: "text-v1",
        originDNASchemaVersion: 1,
        originDNAAnalyzerIdentifier: "local-rules",
        originDNAAnalyzerVersion: "2",
        originDNAAnalyzedAt: Date(timeIntervalSince1970: 100),
        personEvidence: [personEvidence],
        birthDate: birthDate,
        createdAt: Date(timeIntervalSince1970: 110),
        updatedAt: Date(timeIntervalSince1970: 110)
    )
}

@Suite("Dossier domain")
struct DossierDomainTests {
    @Test func dossierRejectsBlankNameAndBackwardsUpdateTime() {
        let createdAt = Date(timeIntervalSince1970: 100)
        #expect(throws: DossierValidationError.invalidRecord) {
            try DossierRecord(
                id: UUID(), kind: .costsAndPayments, displayName: " \n",
                anchorDocumentID: UUID(), createdAt: createdAt, updatedAt: createdAt
            )
        }
        #expect(throws: DossierValidationError.invalidRecord) {
            try DossierRecord(
                id: UUID(), kind: .costsAndPayments,
                displayName: "Kosten und Zahlungen", anchorDocumentID: UUID(),
                createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(-1)
            )
        }
    }

    @Test func exclusionIdentityIsIndependentOfDocumentContent() {
        let dossierID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let documentID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let revisionID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let exclusion = DossierMembershipExclusion(
            dossierID: dossierID, documentID: documentID, revisionID: revisionID,
            excludedAt: Date(timeIntervalSince1970: 200)
        )
        #expect(exclusion.dossierID == dossierID)
        #expect(exclusion.documentID == documentID)
        #expect(exclusion.revisionID == revisionID)
    }

    @Test func personAnchorAcceptsEveryPrimaryRoleAndRejectsSecondaryRole() throws {
        for role in PersonDossierRole.allCases where role.isPrimary {
            #expect(try personAnchor(role: role).primaryRole == role)
        }
        #expect(throws: DossierValidationError.invalidRecord) {
            try personAnchor(role: .authorizedPerson)
        }
    }

    @Test func personAnchorRequiresNonBlankIdentityAndEvidenceAndMonotonicDates() {
        #expect(throws: DossierValidationError.invalidRecord) {
            try PersonDossierAnchor(
                id: UUID(), displayName: " ", normalizedName: "elise muster",
                primaryRole: .resident, originDocumentID: UUID(),
                originContentHash: "hash", originExtractionVersion: "text-v1",
                originDNASchemaVersion: 1, originDNAAnalyzerIdentifier: "local-rules",
                originDNAAnalyzerVersion: "2", originDNAAnalyzedAt: .distantPast,
                personEvidence: [personEvidence], birthDate: nil,
                createdAt: Date(timeIntervalSince1970: 2),
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        }
        #expect(throws: DossierValidationError.invalidRecord) {
            try PersonDossierAnchor(
                id: UUID(), displayName: "Elise Muster", normalizedName: " ",
                primaryRole: .resident, originDocumentID: UUID(),
                originContentHash: "hash", originExtractionVersion: "text-v1",
                originDNASchemaVersion: 1, originDNAAnalyzerIdentifier: "local-rules",
                originDNAAnalyzerVersion: "2", originDNAAnalyzedAt: .distantPast,
                personEvidence: [], birthDate: nil,
                createdAt: .distantPast, updatedAt: .distantPast
            )
        }
    }

    @Test func birthDateRequiresOneCivilDateAndEvidence() throws {
        let evidence = try DocumentDNAEvidence(
            pageIndex: 0, startUTF16: 30, lengthUTF16: 10,
            exactText: "03.04.1940", ocrRegionIndexes: []
        )
        let birthDate = try PersonDossierBirthDate(
            displayValue: "03.04.1940",
            normalizedValue: "1940-04-03",
            evidence: [evidence]
        )
        #expect(birthDate.normalizedValue == "1940-04-03")
        #expect(throws: DossierValidationError.invalidRecord) {
            try PersonDossierBirthDate(
                displayValue: "31.02.1940",
                normalizedValue: "1940-02-31",
                evidence: [evidence]
            )
        }
    }

    @Test func dossierRequiresAnchorMatchingItsKind() throws {
        let anchor = try personAnchor()
        let timestamp = Date(timeIntervalSince1970: 200)
        let person = try DossierRecord(
            id: UUID(), kind: .personMatter,
            displayName: "Meine Mutter im Pflegeheim",
            anchor: .person(anchor), createdAt: timestamp, updatedAt: timestamp
        )
        #expect(person.personAnchor == anchor)
        #expect(person.documentAnchorID == nil)
        #expect(throws: DossierValidationError.invalidRecord) {
            try DossierRecord(
                id: UUID(), kind: .costsAndPayments,
                displayName: "Kosten und Zahlungen",
                anchor: .person(anchor), createdAt: timestamp, updatedAt: timestamp
            )
        }
    }

    @Test func confirmationRequiresCandidateKindAndRoleToAgree() throws {
        let valid = try DossierMembershipConfirmation(
            dossierID: UUID(), documentID: UUID(), revisionID: UUID(),
            confirmedAt: Date(timeIntervalSince1970: 300),
            candidateKind: .secondaryRole,
            acceptedContentHash: "hash-candidate",
            acceptedExtractionVersion: "text-v1",
            acceptedDNASchemaVersion: 1,
            acceptedDNAAnalyzerIdentifier: "local-rules",
            acceptedDNAAnalyzerVersion: "2",
            acceptedDNAAnalyzedAt: Date(timeIntervalSince1970: 290),
            acceptedRole: .authorizedPerson,
            acceptedNormalizedName: "elise muster"
        )
        #expect(valid.candidateKind == .secondaryRole)
        #expect(throws: DossierValidationError.invalidRecord) {
            try DossierMembershipConfirmation(
                dossierID: UUID(), documentID: UUID(), revisionID: UUID(),
                confirmedAt: Date(timeIntervalSince1970: 300),
                candidateKind: .birthDateConflict,
                acceptedContentHash: "hash-candidate",
                acceptedExtractionVersion: "text-v1",
                acceptedDNASchemaVersion: 1,
                acceptedDNAAnalyzerIdentifier: "local-rules",
                acceptedDNAAnalyzerVersion: "2",
                acceptedDNAAnalyzedAt: Date(timeIntervalSince1970: 290),
                acceptedRole: .authorizedPerson,
                acceptedNormalizedName: "elise muster"
            )
        }
    }
}
