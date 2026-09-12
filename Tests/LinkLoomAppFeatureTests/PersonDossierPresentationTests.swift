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

    @Test func sidebarItemsMixCostsAndPeopleByCreationTimeThenPersistedIdentifier() throws {
        let costsFirst = try costsSummary(
            dossierID: uuid("71000000-0000-0000-0000-000000000010"),
            createdAt: 100,
            path: "kosten/anker.pdf"
        )
        let personEarlierID = uuid("71000000-0000-0000-0000-000000000011")
        let personLaterID = uuid("71000000-0000-0000-0000-000000000012")
        let people = [
            try personSummary(
                dossierID: personLaterID,
                originDocumentID: uuid("71000000-0000-0000-0000-000000000013"),
                role: .resident,
                displayName: "Beate Muster",
                normalizedName: "beate muster",
                contentHash: "later",
                createdAt: 200
            ),
            try personSummary(
                dossierID: personEarlierID,
                originDocumentID: uuid("71000000-0000-0000-0000-000000000014"),
                role: .resident,
                displayName: "Anna Muster",
                normalizedName: "anna muster",
                contentHash: "earlier",
                createdAt: 200
            ),
        ]

        let items = WorkspaceDossierSidebarItem.items(
            costs: [costsFirst],
            people: people
        )

        #expect(items.map(\.id) == [costsFirst.id, personEarlierID, personLaterID])
        #expect(items.map(\.subtitle) == ["kosten/anker.pdf", "Anna Muster", "Beate Muster"])
    }

    @Test func workspaceRoutingKeepsKnownPersonSelectionDuringLoadingAndFailure() throws {
        let person = try PersonDossierAppModelValues.make().snapshot
        let costs = try CostsAndPaymentsDossierAppModelValues.make().snapshot
        let personSummary = PersonDossierSummary(dossier: person.dossier, anchor: person.anchor)

        #expect(DossierWorkspaceViewKind(
            selection: .dossier(person.dossier.id),
            detail: .available(.personMatter(person)),
            personSummaries: [personSummary]
        ) == .personMatter)
        #expect(DossierWorkspaceViewKind(
            selection: .dossier(person.dossier.id),
            detail: .loading(dossierID: person.dossier.id, previous: nil),
            personSummaries: [personSummary]
        ) == .personMatter)
        #expect(DossierWorkspaceViewKind(
            selection: .dossier(person.dossier.id),
            detail: .loading(
                dossierID: person.dossier.id,
                previous: .costsAndPayments(costs)
            ),
            personSummaries: [personSummary]
        ) == .personMatter)
        #expect(DossierWorkspaceViewKind(
            selection: .dossier(person.dossier.id),
            detail: .failed(dossierID: person.dossier.id, previous: nil),
            personSummaries: [personSummary]
        ) == .personMatter)
        #expect(DossierWorkspaceViewKind(
            selection: .dossier(costs.dossier.id),
            detail: .available(.costsAndPayments(costs)),
            personSummaries: [personSummary]
        ) == .costsAndPayments)
    }

    @Test func anchorPresentationNamesCurrentStaleAndUnavailableOriginStates() throws {
        let values = try PersonDossierAppModelValues.make()
        let current = PersonDossierAnchorPresentation(
            snapshot: values.snapshot
        )
        let staleSnapshot = values.snapshot.replacingOrigin(
            try PersonDossierOriginState(
                validity: .stale,
                document: values.document,
                sourceDisplayName: "Archive"
            )
        )
        let unavailableSnapshot = values.snapshot.replacingOrigin(
            try PersonDossierOriginState(
                validity: .unavailable,
                document: nil,
                sourceDisplayName: nil
            )
        )

        #expect(current.evidenceValidityTitle == "Ursprungsnachweis aktuell")
        #expect(current.sourceAvailabilityTitle == "Verfügbar")
        #expect(PersonDossierAnchorPresentation(
            snapshot: staleSnapshot
        ).evidenceValidityTitle == "Ursprungsnachweis veraltet")
        #expect(PersonDossierAnchorPresentation(
            snapshot: unavailableSnapshot
        ).evidenceValidityTitle == "Ursprungsnachweis nicht verfügbar")
        #expect(PersonDossierAnchorPresentation(
            snapshot: unavailableSnapshot
        ).sourceAvailabilityTitle == nil)
    }

    @Test func anchorPresentationMapsUnavailableAndMissingOriginDocumentsWithoutLeakingMetadata() throws {
        let values = try PersonDossierAppModelValues.make()
        var unavailableDocument = values.document
        unavailableDocument.availability = .unavailable
        var missingDocument = values.document
        missingDocument.availability = .missing

        let unavailable = PersonDossierAnchorPresentation(
            snapshot: values.snapshot.replacingOrigin(try PersonDossierOriginState(
                validity: .current,
                document: unavailableDocument,
                sourceDisplayName: "Archive"
            ))
        )
        let missing = PersonDossierAnchorPresentation(
            snapshot: values.snapshot.replacingOrigin(try PersonDossierOriginState(
                validity: .current,
                document: missingDocument,
                sourceDisplayName: "Archive"
            ))
        )

        #expect(unavailable.sourceAvailabilityTitle == "Vorübergehend nicht verfügbar")
        #expect(missing.sourceAvailabilityTitle == "Fehlt")
        #expect(!unavailable.accessibilityLabel.contains(values.document.contentHash))
        #expect(!missing.accessibilityLabel.contains("1970"))
    }

    @Test func memberPresentationShowsLocationsAvailabilityAndOrderedReasons() throws {
        let originSourceID = uuid("71000000-0000-0000-0000-000000000020")
        let otherSourceID = uuid("71000000-0000-0000-0000-000000000021")
        let values = try PersonDossierNavigationValues.make(
            originSourceID: originSourceID,
            otherSourceID: otherSourceID
        )
        let direct = try #require(values.snapshot.directMembers.first)
        let crossSource = try #require(values.snapshot.directMembers.last)
        let directPresentation = PersonDossierMemberPresentation(
            member: direct,
            selectedSourceID: originSourceID,
            documents: values.snapshot.allDocuments
        )
        let crossSourcePresentation = PersonDossierMemberPresentation(
            member: crossSource,
            selectedSourceID: originSourceID,
            documents: values.snapshot.allDocuments
        )

        #expect(directPresentation.location == "direct.pdf")
        #expect(crossSourcePresentation.location == "Archive · cross-source-direct.pdf")
        #expect(directPresentation.availabilityTitle == "Verfügbar")
        #expect(directPresentation.membershipRoleTitle == "Direktes Dokument")
        #expect(directPresentation.reasons == [
            "Der Name ‹Elise Muster› stimmt exakt mit dem Personenanker überein. Rolle: Bewohnerin.",
        ])
        #expect(!directPresentation.reasons.joined().contains(direct.id.uuidString))
        #expect(!directPresentation.documentSummaryAccessibilityLabel.contains(direct.id.uuidString))
    }

    @Test func memberPresentationRetainsManualAndPaymentReasonsInSupportOrderWithoutMetadataLeaks() throws {
        let sourceID = uuid("71000000-0000-0000-0000-000000000040")
        let values = try PersonDossierNavigationValues.make(
            originSourceID: sourceID,
            otherSourceID: uuid("71000000-0000-0000-0000-000000000041")
        )
        let suggestion = try #require(values.snapshot.suggestions.first)
        let candidate = try #require(suggestion.currentSupports.first)
        let confirmation = try DossierMembershipConfirmation(
            dossierID: values.snapshot.dossier.id,
            documentID: suggestion.document.id,
            revisionID: uuid("71000000-0000-0000-0000-000000000042"),
            confirmedAt: Date(timeIntervalSince1970: 900),
            candidateKind: candidate.kind,
            acceptedContentHash: candidate.person.contentHash,
            acceptedExtractionVersion: candidate.person.extractionVersion,
            acceptedDNASchemaVersion: candidate.person.dnaSchemaVersion,
            acceptedDNAAnalyzerIdentifier: candidate.person.dnaAnalyzerIdentifier,
            acceptedDNAAnalyzerVersion: candidate.person.dnaAnalyzerVersion,
            acceptedDNAAnalyzedAt: candidate.person.dnaAnalyzedAt,
            acceptedRole: candidate.person.role,
            acceptedNormalizedName: candidate.person.normalizedName
        )
        let manual = try PersonDossierMember(
            document: suggestion.document,
            sourceDisplayName: suggestion.sourceDisplayName,
            documentType: suggestion.documentType,
            section: suggestion.section,
            supports: [.manualConfirmation(
                confirmation: confirmation,
                currentCandidate: candidate
            )],
            isConfirmationAuthoritative: true,
            preferredPaymentSupport: nil
        )
        let staleManual = try PersonDossierMember(
            document: suggestion.document,
            sourceDisplayName: suggestion.sourceDisplayName,
            documentType: suggestion.documentType,
            section: suggestion.section,
            supports: [.manualConfirmation(
                confirmation: confirmation,
                currentCandidate: nil
            )],
            isConfirmationAuthoritative: true,
            preferredPaymentSupport: nil
        )
        let invoice = try #require(values.snapshot.costsAndPayments.first {
            $0.document.relativePath == "invoice.pdf"
        })
        let invoiceSupport = try #require(invoice.supports.first)
        let payment = try paymentMember(
            values: values,
            invoice: invoice,
            invoiceSupport: invoiceSupport
        )
        let documents = values.snapshot.allDocuments.merging([
            payment.id: payment.document,
        ]) { _, replacement in replacement }

        let manualPresentation = PersonDossierMemberPresentation(
            member: manual,
            selectedSourceID: sourceID,
            documents: documents
        )
        let staleManualPresentation = PersonDossierMemberPresentation(
            member: staleManual,
            selectedSourceID: sourceID,
            documents: documents
        )
        let paymentPresentation = PersonDossierMemberPresentation(
            member: payment,
            selectedSourceID: sourceID,
            documents: documents
        )

        #expect(manualPresentation.reasons == ["Von dir aus einem Vorschlag aufgenommen."])
        #expect(staleManualPresentation.reasons == [
            "Von dir aus einem Vorschlag aufgenommen.",
            "Der ursprüngliche Vorschlagsnachweis ist nicht mehr aktuell.",
        ])
        #expect(paymentPresentation.reasons == [
            "Zahlung über die Rechnung ‹invoice.pdf›. Der Name der Rechnung stimmt exakt mit dem Personenanker überein.",
            "Referenz: RE-42 ↔ RE-42",
            "Betrag und Währung: CHF 12.50 ↔ CHF 12.50",
            "Organisation: Pflegeheim ↔ Pflegeheim",
        ])
        #expect(paymentPresentation.reasonAccessibilityIdentifiers == [
            "dossier.person.member.71000000-0000-0000-0000-000000000043.reason.0",
            "dossier.person.member.71000000-0000-0000-0000-000000000043.reason.1",
            "dossier.person.member.71000000-0000-0000-0000-000000000043.reason.2",
            "dossier.person.member.71000000-0000-0000-0000-000000000043.reason.3",
        ])
        #expect(paymentPresentation.documentSummaryAccessibilityLabel == [
            paymentPresentation.location,
            "Dokumenttyp: \(paymentPresentation.documentTypeTitle)",
            paymentPresentation.availabilityTitle,
            paymentPresentation.membershipRoleTitle,
            paymentPresentation.reasons.joined(separator: " "),
        ].joined(separator: ". "))
        for presentation in [manualPresentation, staleManualPresentation, paymentPresentation] {
            #expect(!presentation.documentSummaryAccessibilityLabel.contains("hash"))
            #expect(!presentation.documentSummaryAccessibilityLabel.contains("1970"))
            #expect(!presentation.documentSummaryAccessibilityLabel.contains(presentation.documentID.uuidString))
        }
    }

    @Test func memberIdentifiersUseLowercasePersistedUUIDs() {
        let id = uuid("71000000-0000-0000-0000-0000000000AB")

        #expect(PersonDossierAccessibilityIdentifier.workspace == "dossier.person.workspace")
        #expect(PersonDossierAccessibilityIdentifier.anchor == "dossier.person.anchor")
        #expect(PersonDossierAccessibilityIdentifier.directMembers == "dossier.person.direct-members")
        #expect(PersonDossierAccessibilityIdentifier.costs == "dossier.person.costs")
        #expect(PersonDossierAccessibilityIdentifier.member(id) == "dossier.person.member.71000000-0000-0000-0000-0000000000ab")
        #expect(PersonDossierAccessibilityIdentifier.removeMember(id) == "dossier.person.member.remove.71000000-0000-0000-0000-0000000000ab")
        #expect(PersonDossierAccessibilityIdentifier.counterpart(id) == "dossier.person.member.71000000-0000-0000-0000-0000000000ab.counterpart")
        #expect(PersonDossierAccessibilityIdentifier.reason(id, ordinal: 2) == "dossier.person.member.71000000-0000-0000-0000-0000000000ab.reason.2")
    }
}

extension PersonDossierPresentationTests {
    @Test func suggestionsExplainSecondaryRoleAndBirthDateConflictWithoutTechnicalMetadata() throws {
        let values = try PersonDossierNavigationValues.make(originSourceID: UUID(), otherSourceID: UUID())
        let suggestion = try #require(values.snapshot.suggestions.first)
        let secondary = PersonDossierSuggestionPresentation(suggestion: suggestion, selectedSourceID: nil)
        #expect(secondary.reason == "Der Name stimmt exakt, erscheint aber nur in der Rolle Bevollmächtigte.")
        #expect(secondary.roleTitle == "Bevollmächtigte")
        #expect(secondary.location == "Other archive · suggestion.pdf")
        #expect(secondary.accessibilityLabel == "Other archive · suggestion.pdf. Dokumenttyp: Unbekannt. Verfügbar. Elise Muster, Rolle: Bevollmächtigte. Der Name stimmt exakt, erscheint aber nur in der Rolle Bevollmächtigte. Aufnehmen oder ablehnen.")

        let birth = try finding(kind: .date, qualifier: "birthDate", display: "01.01.1940", normalized: "1940-01-01")
        let anchorBirth = try PersonDossierBirthDate(displayValue: "02.02.1941", normalizedValue: "1941-02-02", evidence: birth.evidence)
        let direct = try #require(values.snapshot.directMembers.first)
        let person = try exactSupport(#require(direct.supports.first))
        let support = try PersonDossierCandidateSupportIdentity(kind: .birthDateConflict, person: person, conflict: .hardBirthDateConflict(anchor: anchorBirth, candidate: birth))
        let conflictRow = try PersonDossierSuggestion(document: direct.document, sourceDisplayName: direct.sourceDisplayName, documentType: direct.documentType, section: direct.section, kind: .birthDateConflict, conflict: support.conflict, currentSupports: [support], commandSupport: support)
        let conflict = PersonDossierSuggestionPresentation(suggestion: conflictRow, selectedSourceID: direct.document.sourceRootID)
        #expect(conflict.reason == "Der Name stimmt, aber dieses Dokument nennt ein anderes Geburtsdatum.")
        #expect(conflict.location == "direct.pdf")
        for label in [secondary.accessibilityLabel, conflict.accessibilityLabel] {
            #expect(!label.contains("hash"))
            #expect(!label.contains("1940"))
            #expect(!label.contains(suggestion.id.uuidString))
        }
    }

    @Test func correctionLabelsDistinguishConfirmationAndExclusion() throws {
        let values = try PersonDossierNavigationValues.make(originSourceID: UUID(), otherSourceID: UUID())
        let correction = try #require(values.snapshot.corrections.first)
        let exclusion = PersonDossierCorrectionPresentation(correction: correction, selectedSourceID: correction.document.sourceRootID)
        let confirmation = try DossierMembershipConfirmation(dossierID: values.snapshot.dossier.id, documentID: correction.id, revisionID: UUID(), confirmedAt: Date(), candidateKind: .secondaryRole, acceptedContentHash: correction.document.contentHash, acceptedExtractionVersion: "text-v1", acceptedDNASchemaVersion: 1, acceptedDNAAnalyzerIdentifier: "local-rules", acceptedDNAAnalyzerVersion: "1", acceptedDNAAnalyzedAt: Date(), acceptedRole: .authorizedPerson, acceptedNormalizedName: "elise muster")
        let confirmed = PersonDossierCorrectionPresentation(correction: try PersonDossierCorrection(document: correction.document, sourceDisplayName: correction.sourceDisplayName, documentType: correction.documentType, decision: .confirmation(confirmation)), selectedSourceID: nil)
        #expect(exclusion.resetTitle == "Ausschluss zurücksetzen")
        #expect(exclusion.decisionTitle == "Von dir ausgeschlossen")
        #expect(exclusion.accessibilityLabel == "correction.pdf. Dokumenttyp: Unbekannt. Verfügbar. Von dir ausgeschlossen. Ausschluss zurücksetzen.")
        #expect(confirmed.resetTitle == "Aufnahme zurücksetzen")
        #expect(confirmed.decisionTitle == "Von dir aufgenommen")
        #expect(confirmed.accessibilityLabel == "Archive · correction.pdf. Dokumenttyp: Unbekannt. Verfügbar. Von dir aufgenommen. Aufnahme zurücksetzen.")
    }

    @Test func mutationOutcomesResolvePublishedRowsAndPrivacySafeAnnouncements() throws {
        let values = try PersonDossierNavigationValues.make(originSourceID: UUID(), otherSourceID: UUID())
        let snapshot = values.snapshot
        #expect(PersonDossierMutationOutcome.accepted(values.direct.id, in: snapshot) == .init(focus: .member(values.direct.id), announcement: "Dokument aufgenommen."))
        #expect(PersonDossierMutationOutcome.rejected(values.correction.id, in: snapshot) == .init(focus: .correction(values.correction.id), announcement: "Vorschlag abgelehnt."))
        #expect(PersonDossierMutationOutcome.removed(values.correction.id, in: snapshot) == .init(focus: .correction(values.correction.id), announcement: "Dokument aus dem Dossier entfernt."))
        #expect(PersonDossierMutationOutcome.reset(values.direct.id, in: snapshot) == .init(focus: .member(values.direct.id), announcement: "Korrektur zurückgesetzt."))
        #expect(PersonDossierMutationOutcome.reset(values.payment.id, in: snapshot).focus == .member(values.payment.id))
        #expect(PersonDossierMutationOutcome.reset(values.suggestion.id, in: snapshot).focus == .suggestion(values.suggestion.id))
        let hidden = values.replacingSnapshot(directMembers: [], costsAndPayments: [], suggestions: [], corrections: [])
        #expect(PersonDossierMutationOutcome.reset(values.correction.id, in: hidden).focus == .section(.corrections))
        #expect(PersonDossierMutationOutcome.accepted(values.direct.id, in: hidden).focus == .section(.suggestions))
        #expect(PersonDossierMutationOutcome.rejected(values.correction.id, in: hidden).focus == .section(.corrections))
    }

    @Test func mutationFeedbackRequiresSuccessfulChangedSnapshotInTheSameDossier() throws {
        let values = try PersonDossierNavigationValues.make(originSourceID: UUID(), otherSourceID: UUID())
        let previous = values.snapshot
        let changed = values.replacingSnapshot(token: PersonDossierProjectionToken(dossierUpdatedAt: Date(), anchorUpdatedAt: previous.token.anchorUpdatedAt, originValidity: .current, documents: previous.token.documents, memberSupports: previous.token.memberSupports, suggestionSupports: previous.token.suggestionSupports, confirmationRevisionIDs: [UUID()], exclusionRevisionIDs: previous.token.exclusionRevisionIDs))
        #expect(PersonDossierMutationOutcome.canPublish(after: previous, detail: .available(.personMatter(changed)), errorCode: nil, isCancelled: false))
        #expect(!PersonDossierMutationOutcome.canPublish(after: previous, detail: .available(.personMatter(previous)), errorCode: nil, isCancelled: false))
        #expect(!PersonDossierMutationOutcome.canPublish(after: previous, detail: .failed(dossierID: previous.dossier.id, previous: .personMatter(changed)), errorCode: nil, isCancelled: false))
        #expect(!PersonDossierMutationOutcome.canPublish(after: previous, detail: .available(.personMatter(changed)), errorCode: "dossierMutationStale", isCancelled: false))
        #expect(!PersonDossierMutationOutcome.canPublish(after: previous, detail: .available(.personMatter(changed)), errorCode: nil, isCancelled: true))
        let other = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        #expect(!PersonDossierMutationOutcome.canPublish(after: previous, detail: .available(.personMatter(other)), errorCode: nil, isCancelled: false))
    }

    @Test func mutationProgressMatchesBothDossierAndDocumentAndIdentifiersStayStable() {
        let id = uuid("71000000-0000-0000-0000-0000000000AB")
        let dossier = UUID()
        for state: DossierMutationState in [.acceptingPerson(dossierID: dossier, documentID: id), .rejectingPerson(dossierID: dossier, documentID: id), .removingPerson(dossierID: dossier, documentID: id), .resettingPerson(dossierID: dossier, documentID: id)] {
            #expect(PersonDossierMutationOutcome.isActive(state, dossierID: dossier, documentID: id))
            #expect(!PersonDossierMutationOutcome.isActive(state, dossierID: UUID(), documentID: id))
            #expect(!PersonDossierMutationOutcome.isActive(state, dossierID: dossier, documentID: UUID()))
        }
        #expect(!PersonDossierMutationOutcome.isActive(.idle, dossierID: dossier, documentID: id))
        #expect(PersonDossierMutationOutcome.progressTarget(.acceptingPerson(dossierID: dossier, documentID: id), dossierID: dossier) == .suggestion(id))
        #expect(PersonDossierMutationOutcome.progressTarget(.rejectingPerson(dossierID: dossier, documentID: id), dossierID: dossier) == .suggestion(id))
        #expect(PersonDossierMutationOutcome.progressTarget(.removingPerson(dossierID: dossier, documentID: id), dossierID: dossier) == .member(id))
        #expect(PersonDossierMutationOutcome.progressTarget(.resettingPerson(dossierID: dossier, documentID: id), dossierID: dossier) == .correction(id))
        #expect(PersonDossierMutationOutcome.progressTarget(.resettingPerson(dossierID: dossier, documentID: id), dossierID: UUID()) == nil)
        #expect(PersonDossierAccessibilityIdentifier.suggestions == "dossier.person.suggestions")
        #expect(PersonDossierAccessibilityIdentifier.corrections == "dossier.person.corrections")
        #expect(PersonDossierAccessibilityIdentifier.error == "dossier.person.error")
        #expect(PersonDossierAccessibilityIdentifier.suggestion(id) == "dossier.person.suggestion.71000000-0000-0000-0000-0000000000ab")
        #expect(PersonDossierAccessibilityIdentifier.acceptSuggestion(id) == "dossier.person.suggestion.accept.71000000-0000-0000-0000-0000000000ab")
        #expect(PersonDossierAccessibilityIdentifier.rejectSuggestion(id) == "dossier.person.suggestion.reject.71000000-0000-0000-0000-0000000000ab")
        #expect(PersonDossierAccessibilityIdentifier.correction(id) == "dossier.person.correction.71000000-0000-0000-0000-0000000000ab")
        #expect(PersonDossierAccessibilityIdentifier.resetCorrection(id) == "dossier.person.correction.reset.71000000-0000-0000-0000-0000000000ab")
    }

    @Test func failedAndStaleMutationsExposeSafeFeedbackWhileKeepingTheCompleteSnapshot() throws {
        let snapshot = try PersonDossierAppModelValues.make().snapshot
        let detail = DossierDetailState.available(.personMatter(snapshot))
        #expect(PersonDossierMutationOutcome.errorMessage(detail: detail, errorCode: "dossierMutationFailure") == "Die Dossier-Korrektur konnte nicht gespeichert werden. Bitte aktualisiere das Hauptdossier und versuche es erneut.")
        #expect(PersonDossierMutationOutcome.errorMessage(detail: .failed(dossierID: snapshot.dossier.id, previous: .personMatter(snapshot)), errorCode: "dossierLoadFailure") == "Das Hauptdossier konnte nicht geladen werden. Bitte versuche es erneut.")
        #expect(PersonDossierMutationOutcome.errorMessage(detail: detail, errorCode: nil) == nil)
        #expect(PersonDossierMutationOutcome.errorMessage(detail: detail, errorCode: "/private/user-document-hash") == nil)
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
        dossierID: UUID? = nil,
        originDocumentID: UUID,
        role: PersonDossierRole,
        displayName: String,
        normalizedName: String,
        contentHash: String,
        createdAt: TimeInterval = 100
    ) throws -> PersonDossierSummary {
        let timestamp = Date(timeIntervalSince1970: createdAt)
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
            id: dossierID ?? uuid("71000000-0000-0000-0000-0000000000CC"),
            kind: .personMatter,
            displayName: "Hauptdossier: \(displayName)",
            anchor: .person(anchor),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return PersonDossierSummary(dossier: dossier, anchor: anchor)
    }

    func costsSummary(
        dossierID: UUID,
        createdAt: TimeInterval,
        path: String
    ) throws -> DossierSummary {
        let timestamp = Date(timeIntervalSince1970: createdAt)
        let anchor = DocumentRecord(
            id: uuid("71000000-0000-0000-0000-000000000030"),
            sourceRootID: uuid("71000000-0000-0000-0000-000000000031"),
            relativePath: path,
            contentHash: "costs-anchor",
            byteCount: 1,
            modifiedAt: timestamp,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: timestamp,
            lastFingerprintAt: timestamp
        )
        return DossierSummary(
            dossier: try DossierRecord(
                id: dossierID,
                kind: .costsAndPayments,
                displayName: "Kosten und Zahlungen",
                anchorDocumentID: anchor.id,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            anchor: anchor
        )
    }

    func paymentMember(
        values: PersonDossierNavigationValues,
        invoice: PersonDossierMember,
        invoiceSupport: PersonDossierMembershipSupport
    ) throws -> PersonDossierMember {
        let paymentDocument = DocumentRecord(
            id: uuid("71000000-0000-0000-0000-000000000043"),
            sourceRootID: invoice.document.sourceRootID,
            relativePath: "payment.pdf",
            contentHash: "payment-hash",
            byteCount: 1,
            modifiedAt: Date(timeIntervalSince1970: 900),
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: Date(timeIntervalSince1970: 900),
            lastFingerprintAt: Date(timeIntervalSince1970: 900)
        )
        let relationship = DossierMembershipSupportIdentity(
            decisionKey: try InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: invoice.id,
                paymentDocumentID: paymentDocument.id,
                invoiceContentHash: invoice.document.contentHash,
                paymentContentHash: paymentDocument.contentHash
            ),
            decisionUpdatedAt: Date(timeIntervalSince1970: 900),
            invoiceDNAAnalyzedAt: Date(timeIntervalSince1970: 200),
            paymentDNAAnalyzedAt: Date(timeIntervalSince1970: 900),
            resolverVersion: "invoice-payment-v1"
        )
        let support = try PersonDossierPaymentSupportIdentity(
            invoiceDocumentID: invoice.id,
            invoiceMembershipBasis: .exactPerson([try exactSupport(invoiceSupport)]),
            relationship: relationship,
            signals: [
                try paymentSignal(.referenceNumber, qualifier: "invoiceNumber", value: "RE-42"),
                try paymentSignal(.monetaryAmount, qualifier: "CHF", value: "CHF 12.50"),
                try paymentSignal(.organization, qualifier: "issuer", value: "Pflegeheim"),
            ]
        )
        return try PersonDossierMember(
            document: paymentDocument,
            sourceDisplayName: "Archive",
            documentType: .paymentConfirmation,
            section: .costsAndPayments,
            supports: [.confirmedPayment(support)],
            isConfirmationAuthoritative: false,
            preferredPaymentSupport: support
        )
    }

    func exactSupport(
        _ support: PersonDossierMembershipSupport
    ) throws -> PersonDossierFindingSupportIdentity {
        guard case let .exactPrimary(finding) = support else {
            throw DossierValidationError.invalidRecord
        }
        return finding
    }

    func paymentSignal(
        _ kind: InvoicePaymentCandidateSignalKind,
        qualifier: String,
        value: String
    ) throws -> InvoicePaymentCandidateSignal {
        let findingKind: DocumentDNAFindingKind = switch kind {
        case .referenceNumber: .referenceNumber
        case .monetaryAmount: .monetaryAmount
        case .organization: .organization
        }
        let normalized = switch kind {
        case .referenceNumber, .organization: value.lowercased()
        case .monetaryAmount: "12.5"
        }
        return InvoicePaymentCandidateSignal(
            kind: kind,
            invoiceFinding: try finding(
                kind: findingKind,
                qualifier: qualifier,
                display: value,
                normalized: normalized
            ),
            paymentFinding: try finding(
                kind: findingKind,
                qualifier: qualifier,
                display: value,
                normalized: normalized
            )
        )
    }
}

private extension PersonDossierSnapshot {
    var allDocuments: [UUID: DocumentRecord] {
        Dictionary(uniqueKeysWithValues: (directMembers + costsAndPayments).map {
            ($0.document.id, $0.document)
        })
    }

    func replacingOrigin(_ origin: PersonDossierOriginState) -> Self {
        PersonDossierSnapshot(
            dossier: dossier,
            anchor: anchor,
            origin: origin,
            directMembers: directMembers,
            costsAndPayments: costsAndPayments,
            suggestions: suggestions,
            corrections: corrections,
            token: token
        )
    }
}
