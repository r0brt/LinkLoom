import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Invoice payment candidate projector")
struct InvoicePaymentCandidateProjectorTests {
    @Test func projectorDeduplicatesReferencesAndPreservesLookupOrder() throws {
        let fixture = try CandidateProjectionFixture.make()

        let projected = InvoicePaymentCandidateProjector().candidates(
            from: fixture.input
        )

        #expect(projected.map(CandidateProjectionPair.init) == fixture.expectedPairs)
        #expect(projected.allSatisfy { $0.disposition == .suggestion })
    }
}

private struct CandidateProjectionFixture {
    let input: InvoicePaymentCandidateProjectionInput
    let expectedPairs: [CandidateProjectionPair]

    static func make() throws -> Self {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
        let invoice = try document(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!,
            sourceID: sourceID,
            path: "invoice.pdf",
            type: .invoice,
            references: [.invoiceNumber, .invoiceNumber],
            date: date
        )
        let firstPayment = try document(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000003")!,
            sourceID: sourceID,
            path: "a-payment.pdf",
            type: .paymentConfirmation,
            references: [.paymentReference],
            date: date
        )
        let secondPayment = try document(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000004")!,
            sourceID: sourceID,
            path: "b-payment.pdf",
            type: .paymentConfirmation,
            references: [.paymentReference],
            date: date
        )

        return Self(
            input: InvoicePaymentCandidateProjectionInput(
                selected: invoice,
                matchesByNormalizedReference: [
                    "INV42": [secondPayment, invoice, firstPayment],
                ]
            ),
            expectedPairs: [
                CandidateProjectionPair(
                    invoiceID: invoice.document.id,
                    paymentID: firstPayment.document.id
                ),
                CandidateProjectionPair(
                    invoiceID: invoice.document.id,
                    paymentID: secondPayment.document.id
                ),
            ]
        )
    }

    private static func document(
        id: UUID,
        sourceID: UUID,
        path: String,
        type: DocumentType,
        references: [DocumentDNAReferenceNumberKind],
        date: Date
    ) throws -> CurrentDocumentDNA {
        let record = DocumentRecord(
            id: id,
            sourceRootID: sourceID,
            relativePath: path,
            contentHash: "hash-\(path)",
            byteCount: 1,
            modifiedAt: date,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: date,
            lastFingerprintAt: date
        )
        let referenceFindings = try references.map { qualifier in
            try finding(
                kind: .referenceNumber,
                qualifier: qualifier.rawValue,
                displayValue: "INV-42",
                normalizedValue: "INV42"
            )
        }
        let organizationQualifier = type == .invoice ? "issuer" : "payee"
        return try CurrentDocumentDNA(
            document: record,
            snapshot: DocumentDNA(
                documentID: record.id,
                schemaVersion: 1,
                analyzerIdentifier: "local-rules",
                analyzerVersion: "2",
                inputContentHash: record.contentHash,
                inputExtractionVersion: "text-v1",
                findings: [
                    try finding(
                        kind: .documentType,
                        qualifier: nil,
                        displayValue: type.rawValue,
                        normalizedValue: type.rawValue
                    ),
                ] + referenceFindings + [
                    try finding(
                        kind: .monetaryAmount,
                        qualifier: "CHF",
                        displayValue: "CHF 1250",
                        normalizedValue: "1250"
                    ),
                    try finding(
                        kind: .organization,
                        qualifier: organizationQualifier,
                        displayValue: "alpha ag",
                        normalizedValue: "alpha ag"
                    ),
                ],
                analyzedAt: date
            )
        )
    }

    private static func finding(
        kind: DocumentDNAFindingKind,
        qualifier: String?,
        displayValue: String,
        normalizedValue: String
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
}

private struct CandidateProjectionPair: Equatable {
    let invoiceID: UUID
    let paymentID: UUID

    init(_ candidate: InvoicePaymentCandidate) {
        invoiceID = candidate.invoice.document.id
        paymentID = candidate.payment.document.id
    }

    init(invoiceID: UUID, paymentID: UUID) {
        self.invoiceID = invoiceID
        self.paymentID = paymentID
    }
}
