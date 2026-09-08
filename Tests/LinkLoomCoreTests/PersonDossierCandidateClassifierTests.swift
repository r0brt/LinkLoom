import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Person dossier candidate classifier")
struct PersonDossierCandidateClassifierTests {
    @Test func everyExactPrimaryRoleIsAutomaticRegardlessOfDocumentType() async throws {
        let fixture = try await PersonDossierFixture.make()
        let anchor = try makeAnchor()

        for role in PersonDossierRole.allCases where role.isPrimary {
            for type in DocumentType.allCases {
                let current = try await fixture.insertSnapshot(
                    path: "\(role.rawValue)-\(type.rawValue).pdf",
                    findings: [try fixture.personFinding(qualifier: role.rawValue)],
                    documentType: type
                )

                let classification = PersonDossierCandidateClassifier().classify(current, for: anchor)
                guard case let .automatic(supports) = classification else {
                    Issue.record("Expected an automatic classification for \(role) and \(type)")
                    continue
                }
                #expect(supports.count == 1)
                #expect(supports[0].role == role)
                #expect(supports[0].normalizedName == anchor.normalizedName)
            }
        }
    }

    @Test func exactAuthorizedPersonIsASecondaryRoleSuggestion() async throws {
        let fixture = try await PersonDossierFixture.make()
        let current = try await fixture.insertSnapshot(
            path: "authorized.pdf",
            findings: [try fixture.personFinding(qualifier: PersonDossierRole.authorizedPerson.rawValue)]
        )

        let classification = PersonDossierCandidateClassifier().classify(
            current,
            for: try makeAnchor()
        )

        guard case let .suggestion(kind, conflict, supports, commandSupport) = classification else {
            Issue.record("Expected a secondary-role suggestion")
            return
        }
        #expect(kind == .secondaryRole)
        #expect(conflict == .none)
        #expect(supports.count == 1)
        #expect(commandSupport == supports[0])
        assertCompleteCurrentSupport(supports[0].person, for: current)
    }

    @Test func differentNormalizedNameUnsupportedQualifierAndUnlabelledTextAreHidden() async throws {
        let fixture = try await PersonDossierFixture.make()
        let anchor = try makeAnchor()
        let candidates = [
            try await fixture.insertSnapshot(
                path: "accent.pdf",
                findings: [try fixture.personFinding(
                    normalizedName: "elise müster",
                    qualifier: PersonDossierRole.resident.rawValue
                )]
            ),
            try await fixture.insertSnapshot(
                path: "abbreviation.pdf",
                findings: [try fixture.personFinding(
                    normalizedName: "e. muster",
                    qualifier: PersonDossierRole.resident.rawValue
                )]
            ),
            try await fixture.insertSnapshot(
                path: "partial.pdf",
                findings: [try fixture.personFinding(
                    normalizedName: "elise",
                    qualifier: PersonDossierRole.resident.rawValue
                )]
            ),
            try await fixture.insertSnapshot(
                path: "unqualified.pdf",
                findings: [try fixture.personFinding(qualifier: nil)]
            ),
            try await fixture.insertSnapshot(
                path: "unsupported.pdf",
                findings: [try fixture.personFinding(qualifier: "beneficiary")]
            ),
            try await fixture.insertSnapshot(
                path: "plain-extracted-text.pdf",
                findings: [],
                extractedText: "x Elise Muster"
            ),
            try await fixture.insertSnapshot(
                path: "Elise Muster/reference-123.pdf",
                findings: [
                    try fixture.finding(
                        kind: .organization,
                        qualifier: nil,
                        displayValue: "Elise Muster GmbH",
                        normalizedValue: "elise muster"
                    ),
                    try fixture.finding(
                        kind: .referenceNumber,
                        qualifier: DocumentDNAReferenceNumberKind.other.rawValue,
                        displayValue: "Elise Muster",
                        normalizedValue: "elise muster"
                    ),
                ]
            ),
        ]

        for current in candidates {
            #expect(PersonDossierCandidateClassifier().classify(current, for: anchor) == .hidden)
        }
    }

    @Test func oneDifferentUnambiguousBirthDateDemotesPrimaryMatch() async throws {
        let fixture = try await PersonDossierFixture.make()
        let candidateDate = try fixture.birthDateFinding(
            displayValue: "02.03.1941",
            normalizedValue: "1941-03-02"
        )
        let current = try await fixture.insertSnapshot(
            path: "birth-date-conflict.pdf",
            findings: [
                try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue),
                candidateDate,
            ]
        )
        let anchor = try makeAnchor(birthDate: try makeBirthDate(
            displayValue: "01.02.1940",
            normalizedValue: "1940-02-01"
        ))

        let classification = PersonDossierCandidateClassifier().classify(current, for: anchor)

        guard case let .suggestion(kind, conflict, supports, commandSupport) = classification else {
            Issue.record("Expected a birth-date-conflict suggestion")
            return
        }
        #expect(kind == .birthDateConflict)
        #expect(supports.count == 1)
        #expect(commandSupport == supports[0])
        guard case let .hardBirthDateConflict(conflictAnchor, conflictCandidate) = conflict else {
            Issue.record("Expected a hard birth-date conflict")
            return
        }
        #expect(conflictAnchor == anchor.birthDate)
        #expect(conflictCandidate == candidateDate)
        assertCompleteCurrentSupport(supports[0].person, for: current)
        #expect(conflictCandidate.evidence == candidateDate.evidence)
    }

    @Test func matchingMissingOrAmbiguousBirthDatesDoNotConflict() async throws {
        let fixture = try await PersonDossierFixture.make()
        let datedAnchor = try makeAnchor(birthDate: try makeBirthDate(
            displayValue: "01.02.1940",
            normalizedValue: "1940-02-01"
        ))
        let controls: [(PersonDossierAnchor, [DocumentDNAFinding])] = [
            (try makeAnchor(), [
                try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue),
                try fixture.birthDateFinding(normalizedValue: "1941-03-02"),
            ]),
            (datedAnchor, [try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)]),
            (datedAnchor, [
                try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue),
                try fixture.birthDateFinding(normalizedValue: "1940-02-01"),
            ]),
            (datedAnchor, [
                try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue),
                try fixture.personFinding(qualifier: PersonDossierRole.insuredPerson.rawValue),
                try fixture.birthDateFinding(normalizedValue: "1941-03-02"),
            ]),
            (datedAnchor, [
                try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue),
                try fixture.birthDateFinding(normalizedValue: "1941-03-02"),
                try fixture.birthDateFinding(
                    displayValue: "03.04.1942",
                    normalizedValue: "1942-04-03"
                ),
            ]),
        ]

        for (index, control) in controls.enumerated() {
            let current = try await fixture.insertSnapshot(
                path: "birth-date-control-\(index).pdf",
                findings: control.1
            )
            guard case .automatic = PersonDossierCandidateClassifier().classify(
                current,
                for: control.0
            ) else {
                Issue.record("Expected non-conflicting control \(index) to stay automatic")
                continue
            }
        }
    }

    @Test func automaticPrimarySupportOutranksAnAdditionalSecondaryFinding() async throws {
        let fixture = try await PersonDossierFixture.make()
        let current = try await fixture.insertSnapshot(
            path: "primary-and-secondary.pdf",
            findings: [
                try fixture.personFinding(qualifier: PersonDossierRole.authorizedPerson.rawValue),
                try fixture.personFinding(qualifier: PersonDossierRole.grantor.rawValue),
                try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue),
                try fixture.personFinding(qualifier: PersonDossierRole.insuredPerson.rawValue),
            ]
        )

        let classification = PersonDossierCandidateClassifier().classify(
            current,
            for: try makeAnchor()
        )

        guard case let .automatic(supports) = classification else {
            Issue.record("Expected one automatic classification")
            return
        }
        #expect(supports.map(\.role) == [.resident, .insuredPerson, .grantor])
    }

    @Test func classifierPreservesExactUnicodeSemantics() async throws {
        let fixture = try await PersonDossierFixture.make()
        let decomposed = "E\u{301}lise Muster".lowercased()
        let composed = "Élise Muster".lowercased()
        #expect(!decomposed.utf8.elementsEqual(composed.utf8))
        let current = try await fixture.insertSnapshot(
            path: "unicode.pdf",
            findings: [try fixture.personFinding(
                normalizedName: decomposed,
                qualifier: PersonDossierRole.resident.rawValue
            )]
        )

        #expect(PersonDossierCandidateClassifier().classify(
            current,
            for: try makeAnchor(normalizedName: composed)
        ) == .hidden)
    }

    @Test func supportIdentityIncludesCompleteInputAndEvidence() async throws {
        let fixture = try await PersonDossierFixture.make()
        let finding = try fixture.personFinding(qualifier: PersonDossierRole.invoiceRecipient.rawValue)
        let current = try await fixture.insertSnapshot(
            path: "complete-provenance.pdf",
            findings: [finding],
            schemaVersion: 7,
            analyzerIdentifier: "test-analyzer",
            analyzerVersion: "9"
        )

        let classification = PersonDossierCandidateClassifier().classify(
            current,
            for: try makeAnchor()
        )

        guard case let .automatic(supports) = classification,
              let support = supports.first
        else {
            Issue.record("Expected automatic support with complete provenance")
            return
        }
        assertCompleteCurrentSupport(support, for: current)
        #expect(support.role == .invoiceRecipient)
        #expect(support.normalizedName == finding.normalizedValue)
        #expect(support.finding == finding)
        #expect(support.finding.evidence[0].pageIndex == 0)
        #expect(support.finding.evidence[0].startUTF16 == 0)
        #expect(support.finding.evidence[0].lengthUTF16 == 1)
        #expect(support.finding.evidence[0].exactText == "x")
        #expect(support.finding.evidence[0].ocrRegionIndexes == [])
    }
}

private func makeAnchor(
    normalizedName: String = "elise muster",
    birthDate: PersonDossierBirthDate? = nil
) throws -> PersonDossierAnchor {
    try PersonDossierAnchor(
        id: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!,
        displayName: "Elise Muster",
        normalizedName: normalizedName,
        primaryRole: .resident,
        originDocumentID: UUID(uuidString: "73000000-0000-0000-0000-000000000002")!,
        originContentHash: "anchor-hash",
        originExtractionVersion: "anchor-text-v1",
        originDNASchemaVersion: 3,
        originDNAAnalyzerIdentifier: "anchor-rules",
        originDNAAnalyzerVersion: "4",
        originDNAAnalyzedAt: Date(timeIntervalSince1970: 1_700_000_000),
        personEvidence: [try evidence(exactText: "Elise Muster")],
        birthDate: birthDate,
        createdAt: Date(timeIntervalSince1970: 1_700_000_001),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
}

private func makeBirthDate(
    displayValue: String,
    normalizedValue: String
) throws -> PersonDossierBirthDate {
    try PersonDossierBirthDate(
        displayValue: displayValue,
        normalizedValue: normalizedValue,
        evidence: [try evidence(exactText: displayValue)]
    )
}

private func evidence(exactText: String) throws -> DocumentDNAEvidence {
    try DocumentDNAEvidence(
        pageIndex: 2,
        startUTF16: 8,
        lengthUTF16: exactText.utf16.count,
        exactText: exactText,
        ocrRegionIndexes: [3, 4]
    )
}

private func assertCompleteCurrentSupport(
    _ support: PersonDossierFindingSupportIdentity,
    for current: CurrentDocumentDNA
) {
    #expect(support.documentID == current.document.id)
    #expect(support.contentHash == current.document.contentHash)
    #expect(support.contentHash == current.snapshot.inputContentHash)
    #expect(support.extractionVersion == current.snapshot.inputExtractionVersion)
    #expect(support.dnaSchemaVersion == current.snapshot.schemaVersion)
    #expect(support.dnaAnalyzerIdentifier == current.snapshot.analyzerIdentifier)
    #expect(support.dnaAnalyzerVersion == current.snapshot.analyzerVersion)
    #expect(support.dnaAnalyzedAt == current.snapshot.analyzedAt)
    #expect(support.finding.evidence == current.snapshot.findings.first {
        $0 == support.finding
    }?.evidence)
}
