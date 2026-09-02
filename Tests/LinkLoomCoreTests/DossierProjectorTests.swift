import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Costs and payments dossier projector")
struct DossierProjectorTests {
    @Test func anchorRemainsVisibleWithoutCurrentDNA() throws {
        let fixture = try DossierProjectorFixture.anchorOnly(
            availability: .available,
            includesAnchorDNA: false
        )

        let snapshot = try CostsAndPaymentsDossierProjector().project(fixture.input)

        #expect(snapshot.members.map(\.document.id) == [fixture.invoiceID])
        #expect(snapshot.members[0].documentType == nil)
        #expect(snapshot.members[0].explanation == DossierMembershipExplanation(
            role: .anchor, relationshipType: nil, signals: []
        ))
        #expect(snapshot.members[0].support == nil)
    }

    @Test func confirmedDirectCounterpartHasExplainableSupport() throws {
        let fixture = try DossierProjectorFixture.confirmedPair()

        let snapshot = try CostsAndPaymentsDossierProjector().project(fixture.input)

        #expect(snapshot.members.map(\.document.id) == [fixture.invoiceID, fixture.paymentID])
        #expect(snapshot.members[0].explanation.role == .anchor)
        #expect(snapshot.members[1].explanation.role == .payment)
        #expect(snapshot.members[1].explanation.relationshipType == .paymentSettlesInvoice)
        #expect(snapshot.members[1].explanation.signals.map(\.kind)
            == [.referenceNumber, .monetaryAmount, .organization])
        #expect(snapshot.members[1].support == fixture.expectedSupport)
    }

    @Test func rejectsUndecidedExcludedAndContentStaleCandidates() throws {
        for fixture in [
            try DossierProjectorFixture.confirmedPair(decision: nil),
            try DossierProjectorFixture.confirmedPair(decision: .excluded),
            try DossierProjectorFixture.confirmedPair(contentStaleDecision: true),
        ] {
            let snapshot = try CostsAndPaymentsDossierProjector().project(fixture.input)

            #expect(snapshot.members.map(\.document.id) == [fixture.invoiceID])
            #expect(snapshot.corrections.isEmpty)
        }
    }

    @Test func exclusionSuppressesMembershipAndProjectsCorrection() throws {
        let fixture = try DossierProjectorFixture.confirmedPair(excludedPayment: true)

        let snapshot = try CostsAndPaymentsDossierProjector().project(fixture.input)

        #expect(snapshot.members.map(\.document.id) == [fixture.invoiceID])
        #expect(snapshot.corrections.map(\.document.id) == [fixture.paymentID])
        #expect(snapshot.corrections[0].documentType == .paymentConfirmation)
        #expect(snapshot.corrections[0].sourceDisplayName == "Payments")
        #expect(snapshot.corrections[0].exclusion.revisionID == fixture.exclusionRevisionID)
    }

    @Test func doesNotTraverseFromDirectMemberToSecondHop() throws {
        let fixture = try DossierProjectorFixture.secondHop()

        let snapshot = try CostsAndPaymentsDossierProjector().project(fixture.input)

        #expect(snapshot.members.map(\.document.id) == [
            fixture.invoiceID,
            fixture.paymentID,
        ])
    }

    @Test func deduplicatesRepeatedDirectCandidateByDocumentIdentity() throws {
        let fixture = try DossierProjectorFixture.confirmedPair(duplicateCandidate: true)

        let snapshot = try CostsAndPaymentsDossierProjector().project(fixture.input)

        #expect(snapshot.members.map(\.document.id) == [fixture.invoiceID, fixture.paymentID])
        #expect(snapshot.token.memberSupports == [fixture.expectedSupport!])
    }

    @Test func ordersMembersBySourceDisplayNameThenPathThenDocumentID() throws {
        let fixture = try DossierProjectorFixture.orderedCounterparts()

        let snapshot = try CostsAndPaymentsDossierProjector().project(fixture.input)

        #expect(snapshot.members.map(\.document.id) == [
            fixture.invoiceID,
            fixture.expectedCounterpartIDs[0],
            fixture.expectedCounterpartIDs[1],
            fixture.expectedCounterpartIDs[2],
            fixture.expectedCounterpartIDs[3],
        ])
    }

    @Test func preservesMissingAnchorAvailability() throws {
        let fixture = try DossierProjectorFixture.anchorOnly(
            availability: .missing,
            includesAnchorDNA: false
        )

        let snapshot = try CostsAndPaymentsDossierProjector().project(fixture.input)

        #expect(snapshot.members.count == 1)
        #expect(snapshot.members[0].document.availability == .missing)
    }

    @Test func projectsCurrentDocumentTypeOnlyWhenCurrentDNAExists() throws {
        let fixture = try DossierProjectorFixture.confirmedPair(
            excludedPayment: true
        )
        let input = CostsAndPaymentsDossierProjectionInput(
            dossier: fixture.input.dossier,
            anchor: fixture.input.anchor,
            documentsByID: fixture.input.documentsByID,
            currentDocumentsByID: [fixture.invoiceID: fixture.input.currentDocumentsByID[fixture.invoiceID]!],
            candidates: fixture.input.candidates,
            decisionsByKey: fixture.input.decisionsByKey,
            sourceDisplayNames: fixture.input.sourceDisplayNames,
            exclusions: fixture.input.exclusions
        )

        let snapshot = try CostsAndPaymentsDossierProjector().project(input)

        #expect(snapshot.members.map(\.document.id) == [fixture.invoiceID])
        #expect(snapshot.members[0].documentType == .invoice)
        #expect(snapshot.corrections[0].documentType == nil)
    }

    @Test func tokenUsesSortedMemberSupportsAndCorrectionRevisions() throws {
        let fixture = try DossierProjectorFixture.tokenOrdering()

        let snapshot = try CostsAndPaymentsDossierProjector().project(fixture.input)

        #expect(snapshot.token.dossierUpdatedAt == fixture.dossier.updatedAt)
        #expect(snapshot.token.anchorContentHash == "invoice-hash")
        #expect(snapshot.token.memberSupports.map(\.decisionKey.paymentDocumentID)
            == fixture.expectedSupportedPaymentIDs)
        #expect(snapshot.token.exclusionRevisionIDs == fixture.expectedExclusionRevisionIDs)
    }

    @Test func rejectsMissingAnchorStoredState() throws {
        let fixture = try DossierProjectorFixture.confirmedPair()
        let input = CostsAndPaymentsDossierProjectionInput(
            dossier: fixture.dossier,
            anchor: nil,
            documentsByID: fixture.input.documentsByID,
            currentDocumentsByID: fixture.input.currentDocumentsByID,
            candidates: fixture.input.candidates,
            decisionsByKey: fixture.input.decisionsByKey,
            sourceDisplayNames: fixture.input.sourceDisplayNames,
            exclusions: fixture.input.exclusions
        )

        #expect(throws: DossierProjectionError.invalidStoredState) {
            try CostsAndPaymentsDossierProjector().project(input)
        }
    }
}

private struct DossierProjectorFixture: Sendable {
    let dossier: DossierRecord
    let input: CostsAndPaymentsDossierProjectionInput
    let invoiceID: UUID
    let paymentID: UUID
    let exclusionRevisionID: UUID?
    let expectedSupport: DossierMembershipSupportIdentity?
    let expectedCounterpartIDs: [UUID]
    let expectedSupportedPaymentIDs: [UUID]
    let expectedExclusionRevisionIDs: [UUID]

    static func anchorOnly(
        availability: DocumentAvailability,
        includesAnchorDNA: Bool
    ) throws -> Self {
        let values = try makeDocuments(
            invoiceAvailability: availability,
            includePayment: false
        )
        return try makeFixture(
            values: values,
            currentDocuments: includesAnchorDNA ? [values.invoice] : [],
            candidates: [],
            decisionsByKey: [:],
            exclusions: []
        )
    }

    static func confirmedPair(
        decision: InvoicePaymentUserDecision? = .confirmed,
        excludedPayment: Bool = false,
        duplicateCandidate: Bool = false,
        contentStaleDecision: Bool = false
    ) throws -> Self {
        let values = try makeDocuments()
        let candidate = try candidate(invoice: values.invoice, payment: values.payment!)
        let key = try decisionKey(candidate)
        let decisionKey: InvoicePaymentDecisionKey
        if contentStaleDecision {
            decisionKey = try InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: values.invoice.document.id,
                paymentDocumentID: values.payment!.document.id,
                invoiceContentHash: "old-invoice-hash",
                paymentContentHash: values.payment!.document.contentHash
            )
        } else {
            decisionKey = key
        }
        let decisions = decision.map {
            [decisionKey: InvoicePaymentDecisionRecord(
                key: decisionKey,
                decision: $0,
                updatedAt: date(50)
            )]
        } ?? [:]
        let exclusion = excludedPayment ? DossierMembershipExclusion(
            dossierID: dossierID,
            documentID: values.payment!.document.id,
            revisionID: exclusionID,
            excludedAt: date(60)
        ) : nil
        return try makeFixture(
            values: values,
            currentDocuments: [values.invoice, values.payment!],
            candidates: duplicateCandidate ? [candidate, candidate] : [candidate],
            decisionsByKey: decisions,
            exclusions: exclusion.map { [$0] } ?? [],
            expectedSupport: decision == .confirmed && !contentStaleDecision
                ? support(candidate: candidate, key: key) : nil
        )
    }

    static func secondHop() throws -> Self {
        let values = try makeDocuments()
        let secondInvoice = try document(
            id: uuid("00000000-0000-0000-0000-000000000003"),
            sourceID: sourceID,
            path: "second-invoice.pdf",
            hash: "second-invoice-hash",
            type: .invoice,
            analyzedAt: date(30)
        )
        let direct = try candidate(invoice: values.invoice, payment: values.payment!)
        let indirect = try candidate(invoice: secondInvoice, payment: values.payment!)
        let directKey = try decisionKey(direct)
        let indirectKey = try decisionKey(indirect)
        return try makeFixture(
            values: values,
            currentDocuments: [values.invoice, values.payment!, secondInvoice],
            candidates: [direct, indirect],
            decisionsByKey: [
                directKey: InvoicePaymentDecisionRecord(
                    key: directKey, decision: .confirmed, updatedAt: date(50)
                ),
                indirectKey: InvoicePaymentDecisionRecord(
                    key: indirectKey, decision: .confirmed, updatedAt: date(51)
                ),
            ],
            exclusions: []
        )
    }

    static func orderedCounterparts() throws -> Self {
        let values = try makeDocuments()
        let samePathHighID = try document(
            id: uuid("00000000-0000-0000-0000-000000000010"),
            sourceID: sourceID,
            path: "same.pdf",
            hash: "payment-10",
            type: .paymentConfirmation,
            analyzedAt: date(35)
        )
        let samePathLowID = try document(
            id: uuid("00000000-0000-0000-0000-000000000009"),
            sourceID: sourceID,
            path: "same.pdf",
            hash: "payment-09",
            type: .paymentConfirmation,
            analyzedAt: date(34)
        )
        let earlyPath = try document(
            id: uuid("00000000-0000-0000-0000-000000000008"),
            sourceID: sourceID,
            path: "a.pdf",
            hash: "payment-08",
            type: .paymentConfirmation,
            analyzedAt: date(33)
        )
        let archiveSource = uuid("00000000-0000-0000-0000-000000000020")
        let archivePayment = try document(
            id: uuid("00000000-0000-0000-0000-000000000007"),
            sourceID: archiveSource,
            path: "z.pdf",
            hash: "payment-07",
            type: .paymentConfirmation,
            analyzedAt: date(32)
        )
        let counterparts = [samePathHighID, archivePayment, earlyPath, samePathLowID]
        let candidates = try counterparts.map {
            try candidate(invoice: values.invoice, payment: $0)
        }
        let decisions = try Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            let key = try decisionKey(candidate)
            return (key, InvoicePaymentDecisionRecord(
                key: key, decision: .confirmed, updatedAt: date(70)
            ))
        })
        return try makeFixture(
            values: values,
            additionalDocuments: counterparts,
            currentDocuments: [values.invoice] + counterparts,
            candidates: candidates,
            decisionsByKey: decisions,
            exclusions: [],
            sourceNames: [sourceID: "Payments", archiveSource: "Archive"],
            expectedCounterpartIDs: [
                archivePayment.document.id,
                earlyPath.document.id,
                samePathLowID.document.id,
                samePathHighID.document.id,
            ]
        )
    }

    static func tokenOrdering() throws -> Self {
        let fixture = try orderedCounterparts()
        let firstExcluded = DossierMembershipExclusion(
            dossierID: dossierID,
            documentID: fixture.expectedCounterpartIDs[2],
            revisionID: uuid("00000000-0000-0000-0000-000000000041"),
            excludedAt: date(100)
        )
        let secondExcluded = DossierMembershipExclusion(
            dossierID: dossierID,
            documentID: fixture.expectedCounterpartIDs[0],
            revisionID: uuid("00000000-0000-0000-0000-000000000040"),
            excludedAt: date(99)
        )
        let input = CostsAndPaymentsDossierProjectionInput(
            dossier: fixture.input.dossier,
            anchor: fixture.input.anchor,
            documentsByID: fixture.input.documentsByID,
            currentDocumentsByID: fixture.input.currentDocumentsByID,
            candidates: fixture.input.candidates,
            decisionsByKey: fixture.input.decisionsByKey,
            sourceDisplayNames: fixture.input.sourceDisplayNames,
            exclusions: [firstExcluded, secondExcluded]
        )
        return DossierProjectorFixture(
            dossier: fixture.dossier,
            input: input,
            invoiceID: fixture.invoiceID,
            paymentID: fixture.paymentID,
            exclusionRevisionID: nil,
            expectedSupport: nil,
            expectedCounterpartIDs: fixture.expectedCounterpartIDs,
            expectedSupportedPaymentIDs: [
                fixture.expectedCounterpartIDs[1],
                fixture.expectedCounterpartIDs[3],
            ],
            expectedExclusionRevisionIDs: [
                secondExcluded.revisionID,
                firstExcluded.revisionID,
            ]
        )
    }

    private static func makeFixture(
        values: Documents,
        additionalDocuments: [CurrentDocumentDNA] = [],
        currentDocuments: [CurrentDocumentDNA],
        candidates: [InvoicePaymentCandidate],
        decisionsByKey: [InvoicePaymentDecisionKey: InvoicePaymentDecisionRecord],
        exclusions: [DossierMembershipExclusion],
        sourceNames: [UUID: String] = [sourceID: "Invoices"],
        expectedSupport: DossierMembershipSupportIdentity? = nil,
        expectedCounterpartIDs: [UUID] = [],
        expectedSupportedPaymentIDs: [UUID] = [],
        expectedExclusionRevisionIDs: [UUID] = []
    ) throws -> Self {
        let allDocuments = [values.invoice] + (values.payment.map { [$0] } ?? [])
            + additionalDocuments
        let documentsByID = Dictionary(uniqueKeysWithValues: allDocuments.map {
            ($0.document.id, $0.document)
        })
        let input = CostsAndPaymentsDossierProjectionInput(
            dossier: dossier,
            anchor: values.invoice.document,
            documentsByID: documentsByID,
            currentDocumentsByID: Dictionary(uniqueKeysWithValues: currentDocuments.map {
                ($0.document.id, $0)
            }),
            candidates: candidates,
            decisionsByKey: decisionsByKey,
            sourceDisplayNames: sourceNames.merging([paymentSourceID: "Payments"]) {
                current, _ in current
            },
            exclusions: exclusions
        )
        return DossierProjectorFixture(
            dossier: dossier,
            input: input,
            invoiceID: values.invoice.document.id,
            paymentID: values.payment?.document.id ?? uuid("00000000-0000-0000-0000-000000000002"),
            exclusionRevisionID: exclusions.first?.revisionID,
            expectedSupport: expectedSupport,
            expectedCounterpartIDs: expectedCounterpartIDs,
            expectedSupportedPaymentIDs: expectedSupportedPaymentIDs,
            expectedExclusionRevisionIDs: expectedExclusionRevisionIDs
        )
    }

    private static func makeDocuments(
        invoiceAvailability: DocumentAvailability = .available,
        includePayment: Bool = true
    ) throws -> Documents {
        let invoice = try document(
            id: invoiceID,
            sourceID: sourceID,
            path: "invoice.pdf",
            hash: "invoice-hash",
            type: .invoice,
            analyzedAt: date(10),
            availability: invoiceAvailability
        )
        let payment = includePayment ? try document(
            id: paymentID,
            sourceID: paymentSourceID,
            path: "payment.pdf",
            hash: "payment-hash",
            type: .paymentConfirmation,
            analyzedAt: date(20)
        ) : nil
        return Documents(invoice: invoice, payment: payment)
    }

    private static func candidate(
        invoice: CurrentDocumentDNA,
        payment: CurrentDocumentDNA
    ) throws -> InvoicePaymentCandidate {
        guard let candidate = InvoicePaymentCandidateResolver().candidates(
            matching: "INV42", in: [invoice, payment]
        ).first else {
            throw FixtureError.missingCandidate
        }
        return candidate
    }

    private static func support(
        candidate: InvoicePaymentCandidate,
        key: InvoicePaymentDecisionKey
    ) -> DossierMembershipSupportIdentity {
        DossierMembershipSupportIdentity(
            decisionKey: key,
            decisionUpdatedAt: date(50),
            invoiceDNAAnalyzedAt: candidate.invoice.snapshot.analyzedAt,
            paymentDNAAnalyzedAt: candidate.payment.snapshot.analyzedAt,
            resolverVersion: "invoice-payment-v1"
        )
    }

    private static func decisionKey(
        _ candidate: InvoicePaymentCandidate
    ) throws -> InvoicePaymentDecisionKey {
        try InvoicePaymentDecisionKey(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: candidate.invoice.document.id,
            paymentDocumentID: candidate.payment.document.id,
            invoiceContentHash: candidate.invoice.document.contentHash,
            paymentContentHash: candidate.payment.document.contentHash
        )
    }

    private static func document(
        id: UUID,
        sourceID: UUID,
        path: String,
        hash: String,
        type: DocumentType,
        analyzedAt: Date,
        availability: DocumentAvailability = .available
    ) throws -> CurrentDocumentDNA {
        let record = DocumentRecord(
            id: id,
            sourceRootID: sourceID,
            relativePath: path,
            contentHash: hash,
            byteCount: 1,
            modifiedAt: date(1),
            mediaType: .pdf,
            status: .ready,
            availability: availability,
            pageCount: 1,
            lastSeenAt: date(2),
            lastFingerprintAt: date(3)
        )
        let referenceQualifier: DocumentDNAReferenceNumberKind = type == .invoice
            ? .invoiceNumber : .paymentReference
        let organizationQualifier = type == .invoice ? "issuer" : "payee"
        return try CurrentDocumentDNA(
            document: record,
            snapshot: DocumentDNA(
                documentID: id,
                schemaVersion: 1,
                analyzerIdentifier: "local-rules",
                analyzerVersion: "2",
                inputContentHash: hash,
                inputExtractionVersion: "text-v1",
                findings: [
                    try finding(.documentType, nil, type.rawValue, type.rawValue),
                    try finding(.referenceNumber, referenceQualifier.rawValue, "INV-42", "INV42"),
                    try finding(.monetaryAmount, "CHF", "CHF 1250", "1250"),
                    try finding(.organization, organizationQualifier, "Alpha AG", "alpha ag"),
                ],
                analyzedAt: analyzedAt
            )
        )
    }

    private static func finding(
        _ kind: DocumentDNAFindingKind,
        _ qualifier: String?,
        _ displayValue: String,
        _ normalizedValue: String
    ) throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: kind,
            qualifier: qualifier,
            displayValue: displayValue,
            normalizedValue: normalizedValue,
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: [try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: 1,
                exactText: "x",
                ocrRegionIndexes: []
            )]
        )
    }

    private struct Documents {
        let invoice: CurrentDocumentDNA
        let payment: CurrentDocumentDNA?
    }

    private enum FixtureError: Error {
        case missingCandidate
    }

    private static let sourceID = uuid("00000000-0000-0000-0000-000000000001")
    private static let paymentSourceID = uuid("00000000-0000-0000-0000-000000000011")
    private static let invoiceID = uuid("00000000-0000-0000-0000-000000000001")
    private static let paymentID = uuid("00000000-0000-0000-0000-000000000002")
    private static let dossierID = uuid("00000000-0000-0000-0000-000000000030")
    private static let exclusionID = uuid("00000000-0000-0000-0000-000000000031")
    private static let dossier = try! DossierRecord(
        id: dossierID,
        kind: .costsAndPayments,
        displayName: "Kosten und Zahlungen",
        anchorDocumentID: invoiceID,
        createdAt: date(4),
        updatedAt: date(5)
    )

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + seconds)
    }

    private static func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
