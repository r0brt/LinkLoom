import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Document DNA domain")
struct DocumentDNADomainTests {
    @Test func completeSnapshotRoundTripsWithoutLosingValues() throws {
        let evidence = try sampleEvidence()
        let snapshot = try DocumentDNA(
            documentID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: "hash-contract",
            inputExtractionVersion: "text-v1",
            findings: [
                try DocumentDNAFinding(
                    kind: .documentType,
                    qualifier: nil,
                    displayValue: "Pflegevertrag",
                    normalizedValue: "contract",
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [evidence]
                ),
                try DocumentDNAFinding(
                    kind: .person,
                    qualifier: "resident",
                    displayValue: "Elise Muster",
                    normalizedValue: "elise muster",
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [evidence]
                ),
            ],
            analyzedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let decoded = try JSONDecoder().decode(
            DocumentDNA.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded == snapshot)
    }

    @Test func snapshotRequiresExactlyOneClassification() throws {
        let person = try samplePersonFinding()

        #expect(throws: DocumentDNAValidationError.invalidSnapshot) {
            try sampleSnapshot(findings: [person])
        }
        #expect(throws: DocumentDNAValidationError.invalidSnapshot) {
            try sampleSnapshot(findings: [
                try unknownClassification(),
                try unknownClassification(),
            ])
        }
    }

    @Test func snapshotRejectsInvalidVersionAndInputIdentity() throws {
        let classification = try unknownClassification()

        #expect(throws: DocumentDNAValidationError.invalidSnapshot) {
            try sampleSnapshot(schemaVersion: 0, findings: [classification])
        }
        #expect(throws: DocumentDNAValidationError.invalidSnapshot) {
            try sampleSnapshot(analyzerIdentifier: " ", findings: [classification])
        }
        #expect(throws: DocumentDNAValidationError.invalidSnapshot) {
            try sampleSnapshot(inputContentHash: "", findings: [classification])
        }
    }

    @Test func decodingRunsSnapshotValidation() {
        let invalidJSON = Data(
            """
            {
              "documentID": "10000000-0000-0000-0000-000000000001",
              "schemaVersion": 0,
              "analyzerIdentifier": "local-rules",
              "analyzerVersion": "1",
              "inputContentHash": "hash",
              "inputExtractionVersion": "text-v1",
              "findings": [{
                "kind": "documentType",
                "displayValue": "",
                "normalizedValue": "unknown",
                "confidence": 0,
                "evidence": []
              }],
              "analyzedAt": 0
            }
            """.utf8
        )

        #expect(throws: DocumentDNAValidationError.invalidSnapshot) {
            try JSONDecoder().decode(DocumentDNA.self, from: invalidJSON)
        }
    }

    @Test func unknownClassificationHasNoClaimedEvidence() throws {
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .documentType,
                qualifier: nil,
                displayValue: "Unbekannt",
                normalizedValue: "unknown",
                secondaryNormalizedValue: nil,
                confidence: 0,
                evidence: []
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .documentType,
                qualifier: nil,
                displayValue: "",
                normalizedValue: "unknown",
                secondaryNormalizedValue: nil,
                confidence: 0.1,
                evidence: []
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .documentType,
                qualifier: nil,
                displayValue: "",
                normalizedValue: "unknown",
                secondaryNormalizedValue: nil,
                confidence: 0,
                evidence: [try sampleEvidence()]
            )
        }
        #expect(try unknownClassification().normalizedValue == "unknown")
    }

    @Test func nonUnknownFindingsRequireEvidenceAndBoundedConfidence() throws {
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .person,
                qualifier: nil,
                displayValue: "Elise Muster",
                normalizedValue: "elise muster",
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: []
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .person,
                qualifier: nil,
                displayValue: "Elise Muster",
                normalizedValue: "elise muster",
                secondaryNormalizedValue: nil,
                confidence: 1.01,
                evidence: [try sampleEvidence()]
            )
        }
    }

    @Test func findingQualifiersMatchTheirKind() throws {
        let evidence = try sampleEvidence()

        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .documentType,
                qualifier: "contract",
                displayValue: "Vertrag",
                normalizedValue: "contract",
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: [evidence]
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .date,
                qualifier: "signedYesterday",
                displayValue: "01.08.2026",
                normalizedValue: "2026-08-01",
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: [evidence]
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .monetaryAmount,
                qualifier: "Franken",
                displayValue: "CHF 1'250.00",
                normalizedValue: "1250",
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: [evidence]
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .referenceNumber,
                qualifier: nil,
                displayValue: "INV-2026-0042",
                normalizedValue: "INV-2026-0042",
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: [evidence]
            )
        }
    }

    @Test func findingsRejectMalformedNormalizedValues() throws {
        let evidence = try sampleEvidence()

        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .documentType,
                qualifier: nil,
                displayValue: "Aktennotiz",
                normalizedValue: "memo",
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: [evidence]
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .date,
                qualifier: "issueDate",
                displayValue: "31.02.2026",
                normalizedValue: "2026-02-31",
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: [evidence]
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .monetaryAmount,
                qualifier: "CHF",
                displayValue: "CHF zwölf",
                normalizedValue: "twelve",
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: [evidence]
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .referenceNumber,
                qualifier: "archiveNumber",
                displayValue: "ABC-1",
                normalizedValue: "ABC-1",
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: [evidence]
            )
        }
    }

    @Test func evidenceRequiresValidLiteralSpanAndRegionIndexes() {
        #expect(throws: DocumentDNAValidationError.invalidEvidence) {
            try DocumentDNAEvidence(
                pageIndex: -1,
                startUTF16: 0,
                lengthUTF16: 1,
                exactText: "A",
                ocrRegionIndexes: []
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidEvidence) {
            try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: 0,
                exactText: "",
                ocrRegionIndexes: []
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidEvidence) {
            try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: 1,
                exactText: "A",
                ocrRegionIndexes: [1, 1]
            )
        }
        #expect(throws: DocumentDNAValidationError.invalidEvidence) {
            try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: 1,
                exactText: "A",
                ocrRegionIndexes: [1, 0]
            )
        }
    }

    private func sampleEvidence() throws -> DocumentDNAEvidence {
        try DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 11,
            lengthUTF16: 12,
            exactText: "Elise Muster",
            ocrRegionIndexes: []
        )
    }

    private func samplePersonFinding() throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: .person,
            qualifier: "resident",
            displayValue: "Elise Muster",
            normalizedValue: "elise muster",
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: [try sampleEvidence()]
        )
    }

    private func unknownClassification() throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: .documentType,
            qualifier: nil,
            displayValue: "",
            normalizedValue: "unknown",
            secondaryNormalizedValue: nil,
            confidence: 0,
            evidence: []
        )
    }

    private func sampleSnapshot(
        schemaVersion: Int = 1,
        analyzerIdentifier: String = "local-rules",
        inputContentHash: String = "hash",
        findings: [DocumentDNAFinding]
    ) throws -> DocumentDNA {
        try DocumentDNA(
            documentID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            schemaVersion: schemaVersion,
            analyzerIdentifier: analyzerIdentifier,
            analyzerVersion: "1",
            inputContentHash: inputContentHash,
            inputExtractionVersion: "text-v1",
            findings: findings,
            analyzedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
