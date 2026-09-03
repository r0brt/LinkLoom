import Foundation
import Testing
@testable import LinkLoomAppFeature
@testable import LinkLoomCore

@Suite("Dossier presentation")
struct DossierPresentationTests {
    @Test @MainActor
    func dossierWorkspaceViewTypesAreAvailable() {
        let _: (AppModel) -> CostsAndPaymentsDossierView = {
            CostsAndPaymentsDossierView(model: $0)
        }
        let _: (AppModel, FolderPicker) -> WorkspaceSidebar = {
            WorkspaceSidebar(model: $0, folderPicker: $1)
        }
    }

    @Test func dossierMemberPresentationExplainsRoleLocationAndAvailability() throws {
        let invoiceSourceID = uuid("91000000-0000-0000-0000-000000000001")
        let paymentSourceID = uuid("91000000-0000-0000-0000-000000000002")
        let payment = document(
            id: uuid("91000000-0000-0000-0000-000000000010"),
            sourceID: paymentSourceID,
            path: "payment.pdf"
        )
        let member = DossierMember(
            document: payment,
            sourceDisplayName: "Zahlungen",
            documentType: .paymentConfirmation,
            explanation: DossierMembershipExplanation(
                role: .payment,
                relationshipType: .paymentSettlesInvoice,
                signals: [
                    try signal(.referenceNumber),
                    try signal(.monetaryAmount),
                    try signal(.organization),
                ]
            ),
            support: nil
        )

        let presentation = DossierMemberPresentation(
            member: member,
            selectedSourceID: invoiceSourceID
        )

        #expect(presentation.roleTitle == "Zahlung")
        #expect(presentation.documentTypeTitle == "Zahlungsbestätigung")
        #expect(presentation.location == "Zahlungen · payment.pdf")
        #expect(presentation.availabilityTitle == "Verfügbar")
        #expect(presentation.signals.map(\.title) == [
            "Referenz", "Betrag und Währung", "Organisation",
        ])
    }

    @Test func dossierMemberPresentationLabelsAnchorAndUnavailableStates() {
        let sourceID = uuid("91000000-0000-0000-0000-000000000003")
        let anchor = DossierMember(
            document: document(
                id: uuid("91000000-0000-0000-0000-000000000011"),
                sourceID: sourceID,
                path: "invoice.pdf"
            ),
            sourceDisplayName: "Rechnungen",
            documentType: .invoice,
            explanation: DossierMembershipExplanation(
                role: .anchor,
                relationshipType: nil,
                signals: []
            ),
            support: nil
        )
        let missing = DossierMember(
            document: document(
                id: uuid("91000000-0000-0000-0000-000000000012"),
                sourceID: sourceID,
                path: "missing.pdf",
                availability: .missing
            ),
            sourceDisplayName: "Rechnungen",
            documentType: nil,
            explanation: DossierMembershipExplanation(
                role: .invoice,
                relationshipType: .paymentSettlesInvoice,
                signals: []
            ),
            support: nil
        )
        let unavailable = DossierMember(
            document: document(
                id: uuid("91000000-0000-0000-0000-000000000013"),
                sourceID: sourceID,
                path: "offline.pdf",
                availability: .unavailable
            ),
            sourceDisplayName: "Rechnungen",
            documentType: .invoice,
            explanation: DossierMembershipExplanation(
                role: .invoice,
                relationshipType: .paymentSettlesInvoice,
                signals: []
            ),
            support: nil
        )

        let anchorPresentation = DossierMemberPresentation(
            member: anchor,
            selectedSourceID: sourceID
        )
        let missingPresentation = DossierMemberPresentation(
            member: missing,
            selectedSourceID: sourceID
        )
        let unavailablePresentation = DossierMemberPresentation(
            member: unavailable,
            selectedSourceID: sourceID
        )

        #expect(anchorPresentation.roleTitle == "Ankerdokument")
        #expect(anchorPresentation.location == "invoice.pdf")
        #expect(missingPresentation.documentTypeTitle == "Nicht verfügbar")
        #expect(missingPresentation.availabilityTitle == "Fehlt")
        #expect(unavailablePresentation.availabilityTitle == "Vorübergehend nicht verfügbar")
    }

    @Test func dossierEntryPresentationUsesDeterministicGermanActionTitles() throws {
        let summary = try dossierSummary(
            id: uuid("91000000-0000-0000-0000-000000000020")
        )

        #expect(DossierEntryPresentation(disposition: .create).actionTitle == "Dossier erstellen")
        #expect(
            DossierEntryPresentation(disposition: .open(summary)).actionTitle
                == "Dossier öffnen"
        )
        #expect(
            DossierEntryPresentation(disposition: .choose([summary])).actionTitle
                == "Dossier auswählen"
        )
    }

    @Test func dossierAccessibilityIdentifiersUseLowercasePersistedUUIDs() {
        let dossierID = uuid("91000000-0000-0000-0000-0000000000AB")
        let documentID = uuid("91000000-0000-0000-0000-0000000000CD")

        #expect(
            DossierAccessibilityIdentifier.row(dossierID)
                == "dossier.row.91000000-0000-0000-0000-0000000000ab"
        )
        #expect(
            DossierAccessibilityIdentifier.member(documentID)
                == "dossier.member.91000000-0000-0000-0000-0000000000cd"
        )
        #expect(
            DossierAccessibilityIdentifier.removeMember(documentID)
                == "dossier.member.remove.91000000-0000-0000-0000-0000000000cd"
        )
        #expect(
            DossierAccessibilityIdentifier.correction(documentID)
                == "dossier.correction.91000000-0000-0000-0000-0000000000cd"
        )
        #expect(
            DossierAccessibilityIdentifier.resetCorrection(documentID)
                == "dossier.correction.reset.91000000-0000-0000-0000-0000000000cd"
        )
    }
}

private extension DossierPresentationTests {
    func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    func document(
        id: UUID,
        sourceID: UUID,
        path: String,
        availability: DocumentAvailability = .available
    ) -> DocumentRecord {
        DocumentRecord(
            id: id,
            sourceRootID: sourceID,
            relativePath: path,
            contentHash: "hash-\(path)",
            byteCount: 64,
            modifiedAt: Date(timeIntervalSince1970: 100),
            mediaType: .pdf,
            status: .ready,
            availability: availability,
            pageCount: 1,
            lastSeenAt: Date(timeIntervalSince1970: 100),
            lastFingerprintAt: Date(timeIntervalSince1970: 100)
        )
    }

    func signal(
        _ kind: InvoicePaymentCandidateSignalKind
    ) throws -> InvoicePaymentCandidateSignal {
        InvoicePaymentCandidateSignal(
            kind: kind,
            invoiceFinding: try finding(
                kind,
                displayValue: "Rechnung",
                isInvoice: true
            ),
            paymentFinding: try finding(
                kind,
                displayValue: "Zahlung",
                isInvoice: false
            )
        )
    }

    func finding(
        _ signalKind: InvoicePaymentCandidateSignalKind,
        displayValue: String,
        isInvoice: Bool
    ) throws -> DocumentDNAFinding {
        let kind: DocumentDNAFindingKind
        let qualifier: String
        switch signalKind {
        case .referenceNumber:
            kind = .referenceNumber
            qualifier = isInvoice
                ? DocumentDNAReferenceNumberKind.invoiceNumber.rawValue
                : DocumentDNAReferenceNumberKind.paymentReference.rawValue
        case .monetaryAmount:
            kind = .monetaryAmount
            qualifier = "CHF"
        case .organization:
            kind = .organization
            qualifier = isInvoice ? "issuer" : "payee"
        }
        return try DocumentDNAFinding(
            kind: kind,
            qualifier: qualifier,
            displayValue: displayValue,
            normalizedValue: signalKind == .monetaryAmount
                ? "1"
                : displayValue.lowercased(),
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: [try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: displayValue.utf16.count,
                exactText: displayValue,
                ocrRegionIndexes: []
            )]
        )
    }

    func dossierSummary(id: UUID) throws -> DossierSummary {
        let sourceID = uuid("91000000-0000-0000-0000-000000000004")
        let anchor = document(
            id: uuid("91000000-0000-0000-0000-000000000014"),
            sourceID: sourceID,
            path: "anchor.pdf"
        )
        return DossierSummary(
            dossier: try DossierRecord(
                id: id,
                kind: .costsAndPayments,
                displayName: "Kosten und Zahlungen",
                anchorDocumentID: anchor.id,
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            anchor: anchor
        )
    }
}
