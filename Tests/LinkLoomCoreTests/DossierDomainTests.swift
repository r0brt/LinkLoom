import Foundation
import Testing
@testable import LinkLoomCore

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
}
