import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Person dossier repository domain")
struct PersonDossierRepositoryDomainTests {
    private let sourceRootID = UUID(uuidString: "72000000-0000-0000-0000-000000000001")!
    private let documentID = UUID(uuidString: "72000000-0000-0000-0000-000000000002")!
    private let invoiceID = UUID(uuidString: "72000000-0000-0000-0000-000000000003")!
    private let dossierID = UUID(uuidString: "72000000-0000-0000-0000-000000000004")!

    @Test func selectionCopiesCompleteCurrentFindingIdentity() throws {
        let finding = try PersonDossierFixture.personFinding(role: .resident)
        let current = try current(id: documentID, findings: [finding])

        let selection = try PersonDossierAnchorSelection(
            document: current.document,
            snapshot: current.snapshot,
            finding: finding
        )

        #expect(selection.support.documentID == current.document.id)
        #expect(selection.support.contentHash == current.document.contentHash)
        #expect(selection.support.extractionVersion == current.snapshot.inputExtractionVersion)
        #expect(selection.support.dnaSchemaVersion == current.snapshot.schemaVersion)
        #expect(selection.support.dnaAnalyzerIdentifier == current.snapshot.analyzerIdentifier)
        #expect(selection.support.dnaAnalyzerVersion == current.snapshot.analyzerVersion)
        #expect(selection.support.dnaAnalyzedAt == current.snapshot.analyzedAt)
        #expect(selection.support.role == .resident)
        #expect(selection.support.normalizedName == "elise muster")
        #expect(selection.support.finding == finding)
    }

    @Test func selectionRejectsUnsupportedOrMismatchedInputs() throws {
        let primary = try PersonDossierFixture.personFinding(role: .resident)
        let authorized = try PersonDossierFixture.personFinding(role: .authorizedPerson)
        let nonPerson = try PersonDossierFixture.finding(
            kind: .organization,
            qualifier: nil,
            displayValue: "Care Home",
            normalizedValue: "care home"
        )
        let current = try current(id: documentID, findings: [primary, authorized, nonPerson])
        let uncontained = try PersonDossierFixture.personFinding(
            displayName: "Different Person",
            normalizedName: "different person",
            role: .resident
        )
        let mismatchedID = try snapshot(
            from: current.snapshot,
            documentID: UUID(uuidString: "72000000-0000-0000-0000-000000000099")!
        )
        let mismatchedHash = try snapshot(from: current.snapshot, contentHash: "different-hash")

        for (document, snapshot, finding) in [
            (current.document, current.snapshot, authorized),
            (current.document, current.snapshot, nonPerson),
            (current.document, current.snapshot, uncontained),
            (current.document, mismatchedID, primary),
            (current.document, mismatchedHash, primary),
        ] {
            #expect(throws: DossierValidationError.invalidRecord) {
                try PersonDossierAnchorSelection(
                    document: document,
                    snapshot: snapshot,
                    finding: finding
                )
            }
        }
    }

    @Test func summaryIdentityAndRepositoryChoicesCompareByValue() throws {
        let anchor = try anchor()
        let dossier = try DossierRecord(
            id: dossierID,
            kind: .personMatter,
            displayName: "Meine Mutter im Pflegeheim",
            anchor: .person(anchor),
            createdAt: PersonDossierFixture.date,
            updatedAt: PersonDossierFixture.date
        )
        let summary = PersonDossierSummary(dossier: dossier, anchor: anchor)

        #expect(summary.id == dossier.id)
        #expect(PersonDossierEntryDisposition.create == .create)
        #expect(PersonDossierEntryDisposition.open(summary) == .open(summary))
        #expect(PersonDossierEntryDisposition.choose([summary]) == .choose([summary]))
        #expect(PersonDossierOpenResult.choose([summary]) == .choose([summary]))
        #expect(PersonDossierCreationChoice.existing(dossierID: dossier.id)
            == .existing(dossierID: dossier.id))
        #expect(PersonDossierCreationChoice.new == .new)
    }

    @Test func authoritativeManualMemberUsesManualConfirmationForCommands() throws {
        let current = try current(
            id: documentID,
            findings: [try PersonDossierFixture.personFinding(role: .authorizedPerson)]
        )
        let confirmation = try confirmation(for: current.document.id)
        let payment = try paymentSupport(for: current.document)
        let member = try PersonDossierMember(
            document: current.document,
            sourceDisplayName: "Archive",
            documentType: .paymentConfirmation,
            section: .costsAndPayments,
            supports: [
                .confirmedPayment(payment),
                .manualConfirmation(confirmation: confirmation, currentCandidate: nil),
            ],
            isConfirmationAuthoritative: true,
            preferredPaymentSupport: payment
        )

        #expect(try member.commandSupport
            == .manualConfirmation(confirmation: confirmation, currentCandidate: nil))
    }

    @Test func automaticMemberUsesFirstCanonicalExactPrimarySupportForCommands() throws {
        let resident = try PersonDossierFixture.personFinding(role: .resident)
        let insured = try PersonDossierFixture.personFinding(role: .insuredPerson)
        let current = try current(id: documentID, findings: [resident, insured])
        let residentSupport = try PersonDossierFindingSupportIdentity(
            current: current,
            role: .resident,
            finding: resident
        )
        let insuredSupport = try PersonDossierFindingSupportIdentity(
            current: current,
            role: .insuredPerson,
            finding: insured
        )
        let member = try PersonDossierMember(
            document: current.document,
            sourceDisplayName: "Archive",
            documentType: .correspondence,
            section: .directDocuments,
            supports: [.exactPrimary(residentSupport), .exactPrimary(insuredSupport)],
            isConfirmationAuthoritative: false,
            preferredPaymentSupport: nil
        )

        #expect(try member.commandSupport == .exactPrimary(residentSupport))
    }

    @Test func relationshipOnlyMemberUsesPreferredConfirmedPaymentForCommands() throws {
        let current = try current(id: documentID, findings: [
            try PersonDossierFixture.personFinding(role: .resident),
        ])
        let payment = try paymentSupport(for: current.document)
        let member = try PersonDossierMember(
            document: current.document,
            sourceDisplayName: "Archive",
            documentType: .paymentConfirmation,
            section: .costsAndPayments,
            supports: [.confirmedPayment(payment)],
            isConfirmationAuthoritative: false,
            preferredPaymentSupport: payment
        )

        #expect(try member.commandSupport == .confirmedPayment(payment))
    }

    private func current(
        id: UUID,
        findings: [DocumentDNAFinding]
    ) throws -> CurrentDocumentDNA {
        try PersonDossierFixture.currentDocument(
            id: id,
            sourceRootID: sourceRootID,
            path: "document-\(id.uuidString).pdf",
            documentType: .paymentConfirmation,
            contentHash: "hash-\(id.uuidString)",
            extractionVersion: "text-v7",
            schemaVersion: 7,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "9",
            analyzedAt: PersonDossierFixture.date,
            personFindings: findings
        )
    }

    private func snapshot(
        from snapshot: DocumentDNA,
        documentID: UUID? = nil,
        contentHash: String? = nil
    ) throws -> DocumentDNA {
        try DocumentDNA(
            documentID: documentID ?? snapshot.documentID,
            schemaVersion: snapshot.schemaVersion,
            analyzerIdentifier: snapshot.analyzerIdentifier,
            analyzerVersion: snapshot.analyzerVersion,
            inputContentHash: contentHash ?? snapshot.inputContentHash,
            inputExtractionVersion: snapshot.inputExtractionVersion,
            findings: snapshot.findings,
            analyzedAt: snapshot.analyzedAt
        )
    }

    private func anchor() throws -> PersonDossierAnchor {
        let current = try current(
            id: documentID,
            findings: [try PersonDossierFixture.personFinding(role: .resident)]
        )
        let support = try PersonDossierFindingSupportIdentity(
            current: current,
            role: .resident,
            finding: try #require(current.snapshot.findings.last)
        )
        return try PersonDossierAnchor(
            id: UUID(uuidString: "72000000-0000-0000-0000-000000000005")!,
            displayName: support.finding.displayValue,
            normalizedName: support.normalizedName,
            primaryRole: support.role,
            originDocumentID: support.documentID,
            originContentHash: support.contentHash,
            originExtractionVersion: support.extractionVersion,
            originDNASchemaVersion: support.dnaSchemaVersion,
            originDNAAnalyzerIdentifier: support.dnaAnalyzerIdentifier,
            originDNAAnalyzerVersion: support.dnaAnalyzerVersion,
            originDNAAnalyzedAt: support.dnaAnalyzedAt,
            personEvidence: support.finding.evidence,
            birthDate: nil,
            createdAt: PersonDossierFixture.date,
            updatedAt: PersonDossierFixture.date
        )
    }

    private func confirmation(for documentID: UUID) throws -> DossierMembershipConfirmation {
        try DossierMembershipConfirmation(
            dossierID: dossierID,
            documentID: documentID,
            revisionID: UUID(uuidString: "72000000-0000-0000-0000-000000000006")!,
            confirmedAt: PersonDossierFixture.date,
            candidateKind: .secondaryRole,
            acceptedContentHash: "accepted-hash",
            acceptedExtractionVersion: "text-v7",
            acceptedDNASchemaVersion: 7,
            acceptedDNAAnalyzerIdentifier: "local-rules",
            acceptedDNAAnalyzerVersion: "9",
            acceptedDNAAnalyzedAt: PersonDossierFixture.date,
            acceptedRole: .authorizedPerson,
            acceptedNormalizedName: "elise muster"
        )
    }

    private func paymentSupport(
        for payment: DocumentRecord
    ) throws -> PersonDossierPaymentSupportIdentity {
        let key = try InvoicePaymentDecisionKey(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: invoiceID,
            paymentDocumentID: payment.id,
            invoiceContentHash: "invoice-hash",
            paymentContentHash: payment.contentHash
        )
        let relationship = DossierMembershipSupportIdentity(
            decisionKey: key,
            decisionUpdatedAt: PersonDossierFixture.date,
            invoiceDNAAnalyzedAt: PersonDossierFixture.date,
            paymentDNAAnalyzedAt: PersonDossierFixture.date,
            resolverVersion: "invoice-payment-v1"
        )
        let finding = try PersonDossierFixture.finding(
            kind: .organization,
            qualifier: nil,
            displayValue: "Care Home",
            normalizedValue: "care home"
        )
        return try PersonDossierPaymentSupportIdentity(
            invoiceDocumentID: invoiceID,
            invoiceMembershipBasis: .manualConfirmation(
                revisionID: UUID(uuidString: "72000000-0000-0000-0000-000000000007")!
            ),
            relationship: relationship,
            signals: [InvoicePaymentCandidateSignal(
                kind: .organization,
                invoiceFinding: finding,
                paymentFinding: finding
            )]
        )
    }
}
