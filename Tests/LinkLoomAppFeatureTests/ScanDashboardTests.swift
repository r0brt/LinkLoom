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
}
