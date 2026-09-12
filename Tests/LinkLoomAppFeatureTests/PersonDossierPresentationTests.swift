import Foundation
import Testing
@testable import LinkLoomAppFeature
@testable import LinkLoomCore

@Suite("Person dossier entry presentation")
struct PersonDossierPresentationTests {
    @Test func projectsPrimaryPersonFindingsInSnapshotOrderWithStableActions() throws {
        let document = document(
            id: uuid("71000000-0000-0000-0000-000000000001"),
            contentHash: "current-content"
        )
        let dna = try snapshot(
            documentID: document.id,
            contentHash: document.contentHash,
            findings: [
                try finding(kind: .documentType, qualifier: nil, display: "Pflegebericht", normalized: DocumentType.medicalOrCareDocument.rawValue),
                try person(.resident, name: "Elise Muster"),
                try finding(kind: .organization, qualifier: "issuer", display: "Pflegeheim Sonnengarten", normalized: "pflegeheim sonnengarten"),
                try person(.insuredPerson, name: "Irma Beispiel"),
                try person(.authorizedPerson, name: "Karin Vertretung"),
                try person(.accountHolder, name: "Berta Konto"),
                try person(.invoiceRecipient, name: "Rita Rechnung"),
                try finding(kind: .date, qualifier: DocumentDNADateRole.birthDate.rawValue, display: "14.03.1942", normalized: "1942-03-14"),
                try person(.grantor, name: "Gerta Vollmacht"),
            ]
        )
        let existing = try personSummary(
            originDocumentID: document.id,
            role: .resident,
            displayName: "Elise Muster",
            normalizedName: "elise muster",
            contentHash: document.contentHash
        )

        let entries = PersonDossierEntryPresentation.entries(
            document: document,
            snapshot: dna,
            summaries: [existing]
        )

        #expect(entries.map(\.ordinal) == [0, 1, 2, 3, 4])
        #expect(entries.map(\.findingIndex) == [1, 3, 5, 6, 8])
        #expect(entries.map(\.actionTitle) == [
            "Hauptdossier öffnen",
            "Hauptdossier erstellen",
            "Hauptdossier erstellen",
            "Hauptdossier erstellen",
            "Hauptdossier erstellen",
        ])
        #expect(entries.map(\.accessibilityIdentifier) == [
            "document-dna.person-dossier.0",
            "document-dna.person-dossier.1",
            "document-dna.person-dossier.2",
            "document-dna.person-dossier.3",
            "document-dna.person-dossier.4",
        ])
        #expect(entries.map(\.roleTitle) == [
            "Bewohnerin",
            "Versicherte Person",
            "Kontoinhaberin",
            "Rechnungsempfängerin",
            "Vollmachtgeberin",
        ])
        #expect(entries[0].accessibilityLabel == "Hauptdossier öffnen für Elise Muster Rolle Bewohnerin")
        #expect(entries.allSatisfy { $0.selection.support.documentID == document.id })
    }

    @Test func onlyExactOriginTripleOpensAnExistingDossier() throws {
        let document = document(
            id: uuid("71000000-0000-0000-0000-000000000002"),
            contentHash: "current-content"
        )
        let dna = try snapshot(
            documentID: document.id,
            contentHash: document.contentHash,
            findings: [
                try finding(kind: .documentType, qualifier: nil, display: "Rechnung", normalized: DocumentType.invoice.rawValue),
                try person(.invoiceRecipient, name: "Elise Muster"),
            ]
        )
        let sameNameOtherOrigin = try personSummary(
            originDocumentID: uuid("71000000-0000-0000-0000-000000000003"),
            role: .invoiceRecipient,
            displayName: "Elise Muster",
            normalizedName: "elise muster",
            contentHash: "other-content"
        )

        let entries = PersonDossierEntryPresentation.entries(
            document: document,
            snapshot: dna,
            summaries: [sameNameOtherOrigin]
        )

        #expect(entries.map(\.actionTitle) == ["Hauptdossier erstellen"])
    }

    @Test func excludesSecondaryUnsupportedAndInvalidCurrentInputs() throws {
        let document = document(
            id: uuid("71000000-0000-0000-0000-000000000004"),
            contentHash: "current-content"
        )
        let noEntryDNA = try snapshot(
            documentID: document.id,
            contentHash: document.contentHash,
            findings: [
                try finding(kind: .documentType, qualifier: nil, display: "Vollmacht", normalized: DocumentType.powerOfAttorney.rawValue),
                try person(.authorizedPerson, name: "Karin Vertretung"),
                try finding(kind: .person, qualifier: nil, display: "Ohne Rolle", normalized: "ohne rolle"),
                try finding(kind: .person, qualifier: "unsupported", display: "Nicht unterstützt", normalized: "nicht unterstützt"),
            ]
        )
        #expect(PersonDossierEntryPresentation.entries(document: document, snapshot: noEntryDNA, summaries: []).isEmpty)

        let staleContentDNA = try snapshot(
            documentID: document.id,
            contentHash: "stale-content",
            findings: [
                try finding(kind: .documentType, qualifier: nil, display: "Pflegebericht", normalized: DocumentType.medicalOrCareDocument.rawValue),
                try person(.resident, name: "Elise Muster"),
            ]
        )
        #expect(PersonDossierEntryPresentation.entries(document: document, snapshot: staleContentDNA, summaries: []).isEmpty)

        let otherDocumentDNA = try snapshot(
            documentID: uuid("71000000-0000-0000-0000-000000000005"),
            contentHash: document.contentHash,
            findings: [
                try finding(kind: .documentType, qualifier: nil, display: "Pflegebericht", normalized: DocumentType.medicalOrCareDocument.rawValue),
                try person(.resident, name: "Elise Muster"),
            ]
        )
        #expect(PersonDossierEntryPresentation.entries(document: document, snapshot: otherDocumentDNA, summaries: []).isEmpty)

        #expect(throws: DocumentDNAValidationError.invalidFinding) {
            try DocumentDNAFinding(
                kind: .person,
                qualifier: PersonDossierRole.resident.rawValue,
                displayValue: "Leere Evidenz",
                normalizedValue: "leere evidenz",
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: []
            )
        }
    }

    @Test func entryActionsStayDisabledWhileAChoiceIsUnresolved() {
        let documentID = uuid("71000000-0000-0000-0000-000000000006")

        #expect(
            PersonDossierEntryInteractionPresentation.actionIsDisabled(
                mutationState: .idle,
                hasUnresolvedChoice: true
            )
        )
        #expect(
            PersonDossierEntryInteractionPresentation.actionIsDisabled(
                mutationState: .openingPerson(documentID: documentID),
                hasUnresolvedChoice: false
            )
        )
        #expect(
            !PersonDossierEntryInteractionPresentation.actionIsDisabled(
                mutationState: .idle,
                hasUnresolvedChoice: false
            )
        )
    }
}

private extension PersonDossierPresentationTests {
    func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    func document(id: UUID, contentHash: String) -> DocumentRecord {
        DocumentRecord(
            id: id,
            sourceRootID: uuid("71000000-0000-0000-0000-0000000000AA"),
            relativePath: "origin.pdf",
            contentHash: contentHash,
            byteCount: 128,
            modifiedAt: Date(timeIntervalSince1970: 100),
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: Date(timeIntervalSince1970: 100),
            lastFingerprintAt: Date(timeIntervalSince1970: 100)
        )
    }

    func snapshot(
        documentID: UUID,
        contentHash: String,
        findings: [DocumentDNAFinding]
    ) throws -> DocumentDNA {
        try DocumentDNA(
            documentID: documentID,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: contentHash,
            inputExtractionVersion: "text-v1",
            findings: findings,
            analyzedAt: Date(timeIntervalSince1970: 100)
        )
    }

    func person(_ role: PersonDossierRole, name: String) throws -> DocumentDNAFinding {
        try finding(
            kind: .person,
            qualifier: role.rawValue,
            display: name,
            normalized: name.lowercased()
        )
    }

    func finding(
        kind: DocumentDNAFindingKind,
        qualifier: String?,
        display: String,
        normalized: String
    ) throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: kind,
            qualifier: qualifier,
            displayValue: display,
            normalizedValue: normalized,
            secondaryNormalizedValue: nil,
            confidence: kind == .documentType ? 1 : 0.9,
            evidence: [try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: display.utf16.count,
                exactText: display,
                ocrRegionIndexes: []
            )]
        )
    }

    func personSummary(
        originDocumentID: UUID,
        role: PersonDossierRole,
        displayName: String,
        normalizedName: String,
        contentHash: String
    ) throws -> PersonDossierSummary {
        let timestamp = Date(timeIntervalSince1970: 100)
        let anchor = try PersonDossierAnchor(
            id: uuid("71000000-0000-0000-0000-0000000000BB"),
            displayName: displayName,
            normalizedName: normalizedName,
            primaryRole: role,
            originDocumentID: originDocumentID,
            originContentHash: contentHash,
            originExtractionVersion: "text-v1",
            originDNASchemaVersion: 1,
            originDNAAnalyzerIdentifier: "local-rules",
            originDNAAnalyzerVersion: "1",
            originDNAAnalyzedAt: timestamp,
            personEvidence: [try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: displayName.utf16.count,
                exactText: displayName,
                ocrRegionIndexes: []
            )],
            birthDate: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let dossier = try DossierRecord(
            id: uuid("71000000-0000-0000-0000-0000000000CC"),
            kind: .personMatter,
            displayName: "Hauptdossier: \(displayName)",
            anchor: .person(anchor),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return PersonDossierSummary(dossier: dossier, anchor: anchor)
    }
}
