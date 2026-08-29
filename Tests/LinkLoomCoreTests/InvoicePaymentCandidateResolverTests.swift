import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Invoice payment candidate resolver")
struct InvoicePaymentCandidateResolverTests {
    @Test func currentDocumentDNARejectsMismatchedDocumentIdentity() throws {
        let current = try currentDocument(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            referenceValue: "INV42",
            amount: nil,
            currency: nil,
            organizationQualifier: nil,
            organization: nil
        )
        var wrongID = current.document
        wrongID.id = UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
        var wrongHash = current.document
        wrongHash.contentHash = "different-hash"

        #expect(throws: CurrentDocumentDNAError.invalidDocumentIdentity) {
            try CurrentDocumentDNA(document: wrongID, snapshot: current.snapshot)
        }
        #expect(throws: CurrentDocumentDNAError.invalidDocumentIdentity) {
            try CurrentDocumentDNA(document: wrongHash, snapshot: current.snapshot)
        }
    }

    @Test func completeIndependentSignalsProduceOneAutomaticCandidate() throws {
        let invoice = try currentDocument(
            id: UUID(uuidString: "61000000-0000-0000-0000-000000000001")!,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-2026-0042",
            referenceValue: "INV20260042",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "pflegezentrum sonnenrain ag"
        )
        let payment = try currentDocument(
            id: UUID(uuidString: "61000000-0000-0000-0000-000000000002")!,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 2026 0042",
            referenceValue: "INV20260042",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "pflegezentrum sonnenrain ag"
        )

        let candidates = InvoicePaymentCandidateResolver().candidates(
            matching: "INV20260042",
            in: [payment, invoice]
        )

        let candidate = try #require(candidates.only)
        #expect(candidate.invoice.document.id == invoice.document.id)
        #expect(candidate.payment.document.id == payment.document.id)
        #expect(candidate.disposition == .automatic)
        #expect(candidate.resolverVersion == "invoice-payment-v1")
        #expect(candidate.signals.map(\.kind) == [
            .referenceNumber,
            .monetaryAmount,
            .organization,
        ])
        #expect(candidate.signals[0].invoiceFinding.displayValue == "INV-2026-0042")
        #expect(candidate.signals[0].paymentFinding.displayValue == "INV 2026 0042")
        #expect(candidate.signals.allSatisfy {
            !$0.invoiceFinding.evidence.isEmpty && !$0.paymentFinding.evidence.isEmpty
        })
    }

    @Test func oneIndependentSignalProducesSuggestion() throws {
        let invoice = try currentDocument(
            id: UUID(uuidString: "62000000-0000-0000-0000-000000000001")!,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: nil,
            organization: nil
        )
        let payment = try currentDocument(
            id: UUID(uuidString: "62000000-0000-0000-0000-000000000002")!,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: nil,
            organization: nil
        )

        let candidate = try #require(InvoicePaymentCandidateResolver().candidates(
            matching: "INV42",
            in: [invoice, payment]
        ).only)

        #expect(candidate.disposition == .suggestion)
        #expect(candidate.signals.map(\.kind) == [.referenceNumber, .monetaryAmount])
    }

    @Test func explicitOrganizationConflictRejectsSeparatorCollision() throws {
        let invoice = try currentDocument(
            id: UUID(uuidString: "63000000-0000-0000-0000-000000000001")!,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "AB-12",
            referenceValue: "AB12",
            amount: "100",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag"
        )
        let payment = try currentDocument(
            id: UUID(uuidString: "63000000-0000-0000-0000-000000000002")!,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "A-B12",
            referenceValue: "AB12",
            amount: "100",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "beta ag"
        )

        #expect(InvoicePaymentCandidateResolver().candidates(
            matching: "AB12",
            in: [invoice, payment]
        ).isEmpty)
    }

    @Test func explicitAmountOrCurrencyConflictRejectsCandidate() throws {
        let invoice = try currentDocument(
            id: UUID(uuidString: "64000000-0000-0000-0000-000000000001")!,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag"
        )
        let payment = try currentDocument(
            id: UUID(uuidString: "64000000-0000-0000-0000-000000000002")!,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "EUR",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )

        #expect(InvoicePaymentCandidateResolver().candidates(
            matching: "INV42",
            in: [invoice, payment]
        ).isEmpty)
    }

    @Test func multipleStrongCounterpartsAreDeterministicSuggestions() throws {
        let firstInvoice = try currentDocument(
            id: UUID(uuidString: "65000000-0000-0000-0000-000000000001")!,
            path: "a-invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag"
        )
        let secondInvoice = try currentDocument(
            id: UUID(uuidString: "65000000-0000-0000-0000-000000000002")!,
            path: "b-invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV/42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag"
        )
        let payment = try currentDocument(
            id: UUID(uuidString: "65000000-0000-0000-0000-000000000003")!,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )

        let candidates = InvoicePaymentCandidateResolver().candidates(
            matching: "INV42",
            in: [secondInvoice, payment, firstInvoice]
        )

        #expect(candidates.map(\.invoice.document.relativePath) == [
            "a-invoice.pdf",
            "b-invoice.pdf",
        ])
        #expect(candidates.allSatisfy { $0.disposition == .suggestion })
    }

    @Test func referenceAloneProducesNoCandidate() throws {
        let invoice = try currentDocument(
            id: UUID(uuidString: "66000000-0000-0000-0000-000000000001")!,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            referenceValue: "INV42",
            amount: nil,
            currency: nil,
            organizationQualifier: nil,
            organization: nil
        )
        let payment = try currentDocument(
            id: UUID(uuidString: "66000000-0000-0000-0000-000000000002")!,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            referenceValue: "INV42",
            amount: nil,
            currency: nil,
            organizationQualifier: nil,
            organization: nil
        )

        #expect(InvoicePaymentCandidateResolver().candidates(
            matching: "INV42",
            in: [invoice, payment]
        ).isEmpty)
    }

    @Test func incompatibleReferenceQualifierProducesNoCandidate() throws {
        let invoice = try currentDocument(
            id: UUID(uuidString: "67000000-0000-0000-0000-000000000001")!,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag"
        )
        let payment = try currentDocument(
            id: UUID(uuidString: "67000000-0000-0000-0000-000000000002")!,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV 42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )

        #expect(InvoicePaymentCandidateResolver().candidates(
            matching: "INV42",
            in: [invoice, payment]
        ).isEmpty)
    }

    @Test func referenceIdentityPreservesLeadingZerosAndCheckDigits() throws {
        let invoice = try currentDocument(
            id: UUID(uuidString: "68000000-0000-0000-0000-000000000001")!,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-00-42",
            referenceValue: "INV0042",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag"
        )
        let payment = try currentDocument(
            id: UUID(uuidString: "68000000-0000-0000-0000-000000000002")!,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV-0-42",
            referenceValue: "INV042",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )

        #expect(InvoicePaymentCandidateResolver().candidates(
            matching: "INV0042",
            in: [invoice, payment]
        ).isEmpty)
    }

    @Test func mixedAnalyzerTargetsProduceNoCandidate() throws {
        let invoice = try currentDocument(
            id: UUID(uuidString: "69000000-0000-0000-0000-000000000001")!,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag",
            analyzerVersion: "2"
        )
        let payment = try currentDocument(
            id: UUID(uuidString: "69000000-0000-0000-0000-000000000002")!,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag",
            analyzerVersion: "1"
        )

        #expect(InvoicePaymentCandidateResolver().candidates(
            matching: "INV42",
            in: [invoice, payment]
        ).isEmpty)
    }

    @Test func resolverDoesNotFoldUnicodeConfusables() throws {
        let invoice = try currentDocument(
            id: UUID(uuidString: "6a000000-0000-0000-0000-000000000001")!,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            referenceValue: "INV42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag"
        )
        let payment = try currentDocument(
            id: UUID(uuidString: "6a000000-0000-0000-0000-000000000002")!,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "ＩＮＶ 42",
            referenceValue: "ＩＮＶ42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )

        #expect(InvoicePaymentCandidateResolver().candidates(
            matching: "INV42",
            in: [invoice, payment]
        ).isEmpty)
    }
}

private extension InvoicePaymentCandidateResolverTests {
    func currentDocument(
        id: UUID,
        path: String,
        type: DocumentType,
        referenceQualifier: DocumentDNAReferenceNumberKind,
        referenceDisplay: String,
        referenceValue: String,
        amount: String?,
        currency: String?,
        organizationQualifier: String?,
        organization: String?,
        analyzerVersion: String = "2"
    ) throws -> CurrentDocumentDNA {
        var findings = [
            try finding(
                kind: .documentType,
                qualifier: nil,
                displayValue: type.rawValue,
                normalizedValue: type.rawValue
            ),
            try finding(
                kind: .referenceNumber,
                qualifier: referenceQualifier.rawValue,
                displayValue: referenceDisplay,
                normalizedValue: referenceValue
            ),
        ]
        if let amount, let currency {
            findings.append(try finding(
                kind: .monetaryAmount,
                qualifier: currency,
                displayValue: "\(currency) \(amount)",
                normalizedValue: amount
            ))
        }
        if let organization, let organizationQualifier {
            findings.append(try finding(
                kind: .organization,
                qualifier: organizationQualifier,
                displayValue: organization,
                normalizedValue: organization
            ))
        }
        let document = DocumentRecord(
            id: id,
            sourceRootID: UUID(uuidString: "61000000-0000-0000-0000-000000000000")!,
            relativePath: path,
            contentHash: "hash-\(path)",
            byteCount: 64,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastFingerprintAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let snapshot = try DocumentDNA(
            documentID: id,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: analyzerVersion,
            inputContentHash: document.contentHash,
            inputExtractionVersion: "text-v1",
            findings: findings,
            analyzedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        return try CurrentDocumentDNA(document: document, snapshot: snapshot)
    }

    func finding(
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
            evidence: [
                try DocumentDNAEvidence(
                    pageIndex: 0,
                    startUTF16: 0,
                    lengthUTF16: 1,
                    exactText: "x",
                    ocrRegionIndexes: []
                ),
            ]
        )
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
