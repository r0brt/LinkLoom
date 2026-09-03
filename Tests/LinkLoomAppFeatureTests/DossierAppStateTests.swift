import Foundation
import Testing
@testable import LinkLoomAppFeature
@testable import LinkLoomCore

@Suite("Dossier app state")
struct DossierAppStateTests {
    @Test func detailStateRetainsOnlyCompletePreviousSnapshots() throws {
        let snapshot = try dossierStateSnapshot()

        #expect(DossierDetailState.none.snapshot == nil)
        #expect(DossierDetailState.loading(
            dossierID: snapshot.dossier.id,
            previous: snapshot
        ).snapshot == snapshot)
        #expect(DossierDetailState.available(snapshot).snapshot == snapshot)
        #expect(DossierDetailState.failed(
            dossierID: snapshot.dossier.id,
            previous: snapshot
        ).snapshot == snapshot)
    }

    @Test func staleDossierInputHasStablePrivacySafeReason() {
        let diagnostic = AppRuntimeDiagnostic(
            category: .dossierMutation,
            error: DossierRepositoryError.staleInput
        )

        #expect(diagnostic.reason == .staleDocument)
    }
}

private func dossierStateSnapshot() throws -> DossierSnapshot {
    let anchorID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
    let sourceID = UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
    let dossier = try DossierRecord(
        id: UUID(uuidString: "71000000-0000-0000-0000-000000000003")!,
        kind: .costsAndPayments,
        displayName: "Kosten und Zahlungen",
        anchorDocumentID: anchorID,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let anchor = DocumentRecord(
        id: anchorID,
        sourceRootID: sourceID,
        relativePath: "invoice.pdf",
        contentHash: "invoice-hash",
        byteCount: 10,
        modifiedAt: Date(timeIntervalSince1970: 100),
        mediaType: .pdf,
        status: .ready,
        pageCount: 1,
        lastSeenAt: Date(timeIntervalSince1970: 100)
    )
    return DossierSnapshot(
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
            dossierUpdatedAt: dossier.updatedAt,
            anchorContentHash: anchor.contentHash,
            memberSupports: [],
            exclusionRevisionIDs: []
        )
    )
}
