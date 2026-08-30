import Foundation
import Testing
@testable import LinkLoomAppFeature
@testable import LinkLoomCore

@Suite("Document DNA dashboard presentation")
struct ScanDashboardTests {
    @Test func documentDNAStatusLabelsDistinguishEveryCurrentPhase() {
        let cases: [(DocumentDNAAnalysisPhase?, String)] = [
            (nil, "—"), (.pending, "Ausstehend"), (.analyzing, "Läuft"),
            (.ready, "Bereit"), (.failed(.analysisFailure), "Analyse fehlgeschlagen"),
            (.failed(.invalidFinding), "Ungültiger Befund"),
            (.failed(.invalidProvenance), "Ungültiger Nachweis"),
        ]
        for (phase, title) in cases {
            #expect(DocumentDNAAnalysisPresentation.title(for: phase) == title)
        }
    }

    @Test func documentDNASummaryCountsOnlyPublishedEligiblePhases() {
        let phases: [UUID: DocumentDNAAnalysisPhase] = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!: .pending,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!: .analyzing,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!: .ready,
            UUID(uuidString: "00000000-0000-0000-0000-000000000004")!: .ready,
            UUID(uuidString: "00000000-0000-0000-0000-000000000005")!:
                .failed(.invalidProvenance),
        ]

        let summary = DocumentDNAAnalysisSummary(phases: phases)
        #expect(summary.pending == 1)
        #expect(summary.analyzing == 1)
        #expect(summary.ready == 2)
        #expect(summary.failed == 1)
    }

    @Test func documentDNAFailureLabelsExposeOnlySafeBoundedReasons() {
        let cases: [(DocumentDNAAnalysisFailureCode, String)] = [
            (.analysisFailure, "Lokale Analyse fehlgeschlagen"),
            (.invalidFinding, "Ungültiger Befund"),
            (.invalidProvenance, "Ungültiger Nachweis"),
        ]

        for (code, title) in cases {
            #expect(DocumentDNAFailurePresentation.title(for: code) == title)
        }
    }

    @Test func documentDNADetailProjectsFactsAndOneBasedEvidenceInStoredOrder() throws {
        let personEvidence = try DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 22,
            lengthUTF16: 12,
            exactText: "Elise Muster",
            ocrRegionIndexes: []
        )
        let amountEvidence = try DocumentDNAEvidence(
            pageIndex: 1,
            startUTF16: 10,
            lengthUTF16: 12,
            exactText: "CHF 1'250.00",
            ocrRegionIndexes: []
        )
        let snapshot = try DocumentDNA(
            documentID: UUID(),
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: "invoice-hash",
            inputExtractionVersion: "text-v1",
            findings: [
                try DocumentDNAFinding(
                    kind: .documentType,
                    qualifier: nil,
                    displayValue: "Rechnung",
                    normalizedValue: DocumentType.invoice.rawValue,
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [try DocumentDNAEvidence(
                        pageIndex: 0,
                        startUTF16: 0,
                        lengthUTF16: 8,
                        exactText: "Rechnung",
                        ocrRegionIndexes: []
                    )]
                ),
                try DocumentDNAFinding(
                    kind: .person,
                    qualifier: "invoiceRecipient",
                    displayValue: "Elise Muster",
                    normalizedValue: "elise muster",
                    secondaryNormalizedValue: nil,
                    confidence: 0.95,
                    evidence: [personEvidence]
                ),
                try DocumentDNAFinding(
                    kind: .monetaryAmount,
                    qualifier: "CHF",
                    displayValue: "CHF 1'250.00",
                    normalizedValue: "1250",
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [amountEvidence]
                ),
            ],
            analyzedAt: Date(timeIntervalSince1970: 300)
        )

        let presentation = DocumentDNADetailPresentation(snapshot: snapshot)

        #expect(presentation.documentTypeTitle == "Rechnung")
        #expect(presentation.documentTypeEvidence == [
            DocumentDNAEvidencePresentation(pageNumber: 1, exactText: "Rechnung"),
        ])
        #expect(presentation.facts.map(\.title) == [
            "Person · Rechnungsempfänger:in", "Betrag · CHF",
        ])
        #expect(presentation.facts.map(\.displayValue) == [
            "Elise Muster", "CHF 1'250.00",
        ])
        #expect(presentation.facts.map(\.confidence) == [0.95, 1])
        #expect(presentation.facts.map(\.evidence) == [
            [DocumentDNAEvidencePresentation(pageNumber: 1, exactText: "Elise Muster")],
            [DocumentDNAEvidencePresentation(pageNumber: 2, exactText: "CHF 1'250.00")],
        ])
    }

    @Test func documentDNADetailLabelsEveryCurrentDocumentType() {
        let cases: [(DocumentType, String)] = [
            (.contract, "Vertrag"),
            (.invoice, "Rechnung"),
            (.paymentConfirmation, "Zahlungsbestätigung"),
            (.insuranceStatement, "Versicherungsabrechnung"),
            (.medicalOrCareDocument, "Medizin- oder Pflegedokument"),
            (.powerOfAttorney, "Vollmacht"),
            (.correspondence, "Korrespondenz"),
            (.unknown, "Unbekannt"),
        ]

        for (documentType, title) in cases {
            #expect(DocumentDNADetailPresentation.title(for: documentType) == title)
        }
    }

    @Test func invoicePaymentCandidatePresentationUsesNeutralLabelsAndBothSources() throws {
        let invoiceSourceID = UUID(
            uuidString: "71000000-0000-0000-0000-000000000010"
        )!
        let paymentSourceID = UUID(
            uuidString: "71000000-0000-0000-0000-000000000020"
        )!
        let invoice = try candidateDocument(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
            sourceRootID: invoiceSourceID,
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            referencePageIndex: 0,
            amountPageIndex: 1
        )
        let payment = try candidateDocument(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!,
            sourceRootID: paymentSourceID,
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            referencePageIndex: 2,
            amountPageIndex: 3
        )
        let candidate = InvoicePaymentCandidate(
            invoice: invoice.current,
            payment: payment.current,
            disposition: .automatic,
            resolverVersion: "invoice-payment-v1",
            signals: [
                InvoicePaymentCandidateSignal(
                    kind: .referenceNumber,
                    invoiceFinding: invoice.reference,
                    paymentFinding: payment.reference
                ),
                InvoicePaymentCandidateSignal(
                    kind: .monetaryAmount,
                    invoiceFinding: invoice.amount,
                    paymentFinding: payment.amount
                ),
            ]
        )

        let presentation = InvoicePaymentCandidatePresentation(
            candidate: candidate,
            selectedDocumentID: invoice.current.document.id,
            sourceDisplayNames: [paymentSourceID: "Zahlungen"]
        )

        #expect(presentation.counterpartLocation == "Zahlungen · payment.pdf")
        #expect(presentation.dispositionTitle == "Hohe Übereinstimmung")
        #expect(presentation.signals.map(\.title) == ["Referenz", "Betrag und Währung"])
        #expect(presentation.signals.map(\.comparison) == [
            "INV-42 ↔ INV 42", "CHF 1250 ↔ CHF 1250",
        ])
        #expect(presentation.signals[0].invoiceEvidence == [
            InvoicePaymentEvidencePresentation(pageNumber: 1, exactText: "INV-42"),
        ])
        #expect(presentation.signals[0].paymentEvidence == [
            InvoicePaymentEvidencePresentation(pageNumber: 3, exactText: "INV 42"),
        ])
        #expect(presentation.signals[1].invoiceEvidence == [
            InvoicePaymentEvidencePresentation(pageNumber: 2, exactText: "CHF 1250"),
        ])
        #expect(presentation.signals[1].paymentEvidence == [
            InvoicePaymentEvidencePresentation(pageNumber: 4, exactText: "CHF 1250"),
        ])
    }
}

private extension ScanDashboardTests {
    struct CandidateDocument {
        let current: CurrentDocumentDNA
        let reference: DocumentDNAFinding
        let amount: DocumentDNAFinding
    }

    func candidateDocument(
        id: UUID,
        sourceRootID: UUID,
        path: String,
        type: DocumentType,
        referenceQualifier: DocumentDNAReferenceNumberKind,
        referenceDisplay: String,
        referencePageIndex: Int,
        amountPageIndex: Int
    ) throws -> CandidateDocument {
        let classification = try finding(
            kind: .documentType,
            qualifier: nil,
            displayValue: type.rawValue,
            normalizedValue: type.rawValue,
            pageIndex: 0
        )
        let reference = try finding(
            kind: .referenceNumber,
            qualifier: referenceQualifier.rawValue,
            displayValue: referenceDisplay,
            normalizedValue: "INV42",
            pageIndex: referencePageIndex
        )
        let amount = try finding(
            kind: .monetaryAmount,
            qualifier: "CHF",
            displayValue: "CHF 1250",
            normalizedValue: "1250",
            pageIndex: amountPageIndex
        )
        let document = DocumentRecord(
            id: id,
            sourceRootID: sourceRootID,
            relativePath: path,
            contentHash: "hash-\(path)",
            byteCount: 64,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 4,
            lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastFingerprintAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let snapshot = try DocumentDNA(
            documentID: id,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "2",
            inputContentHash: document.contentHash,
            inputExtractionVersion: "text-v1",
            findings: [classification, reference, amount],
            analyzedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        return try CandidateDocument(
            current: CurrentDocumentDNA(document: document, snapshot: snapshot),
            reference: reference,
            amount: amount
        )
    }

    func finding(
        kind: DocumentDNAFindingKind,
        qualifier: String?,
        displayValue: String,
        normalizedValue: String,
        pageIndex: Int
    ) throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: kind,
            qualifier: qualifier,
            displayValue: displayValue,
            normalizedValue: normalizedValue,
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: [try DocumentDNAEvidence(
                pageIndex: pageIndex,
                startUTF16: 0,
                lengthUTF16: displayValue.utf16.count,
                exactText: displayValue,
                ocrRegionIndexes: []
            )]
        )
    }
}
