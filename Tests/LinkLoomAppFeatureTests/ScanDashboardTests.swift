import Foundation
import Testing
@testable import LinkLoomAppFeature
import LinkLoomCore

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
}
