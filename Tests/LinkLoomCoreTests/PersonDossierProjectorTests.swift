import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Person dossier projector")
struct PersonDossierProjectorTests {
    @Test func projectsCurrentOriginOnlyForExactPersistedInputAndFindingIdentity() throws {
        let fixture = try PersonProjectorFixture.make()

        let snapshot = try PersonDossierProjector().project(fixture.input())

        #expect(snapshot.origin.validity == .current)
        #expect(snapshot.origin.document == fixture.origin.document)
        #expect(snapshot.origin.sourceDisplayName == "Archive")
    }

    @Test func projectsStaleOriginSeparatelyFromDocumentAvailability() throws {
        let base = try PersonProjectorFixture.make()
        let mutations: [(String, String, Int, String, String, Date, PersonDossierRole, String, String, [DocumentDNAEvidence])] = [
            ("changed", "text-v1", 7, "rules", "9", base.origin.snapshot.analyzedAt, .resident, "Elise Muster", "elise muster", base.anchor.personEvidence),
            (base.origin.document.contentHash, "text-v2", 7, "rules", "9", base.origin.snapshot.analyzedAt, .resident, "Elise Muster", "elise muster", base.anchor.personEvidence),
            (base.origin.document.contentHash, "text-v1", 8, "rules", "9", base.origin.snapshot.analyzedAt, .resident, "Elise Muster", "elise muster", base.anchor.personEvidence),
            (base.origin.document.contentHash, "text-v1", 7, "other", "9", base.origin.snapshot.analyzedAt, .resident, "Elise Muster", "elise muster", base.anchor.personEvidence),
            (base.origin.document.contentHash, "text-v1", 7, "rules", "10", base.origin.snapshot.analyzedAt, .resident, "Elise Muster", "elise muster", base.anchor.personEvidence),
            (base.origin.document.contentHash, "text-v1", 7, "rules", "9", base.origin.snapshot.analyzedAt.addingTimeInterval(1), .resident, "Elise Muster", "elise muster", base.anchor.personEvidence),
            (base.origin.document.contentHash, "text-v1", 7, "rules", "9", base.origin.snapshot.analyzedAt, .insuredPerson, "Elise Muster", "elise muster", base.anchor.personEvidence),
            (base.origin.document.contentHash, "text-v1", 7, "rules", "9", base.origin.snapshot.analyzedAt, .resident, "Elise M.", "elise muster", base.anchor.personEvidence),
            (base.origin.document.contentHash, "text-v1", 7, "rules", "9", base.origin.snapshot.analyzedAt, .resident, "Elise Muster", "elise changed", base.anchor.personEvidence),
            (base.origin.document.contentHash, "text-v1", 7, "rules", "9", base.origin.snapshot.analyzedAt, .resident, "Elise Muster", "elise muster", [try PersonDossierFixture.evidence(displayText: "Elise Muster", pageIndex: 2)]),
        ]

        for availability in DocumentAvailability.allCasesForProjectionTest {
            for mutation in mutations {
                let finding = try PersonDossierFixture.personFinding(
                    displayName: mutation.7,
                    normalizedName: mutation.8,
                    role: mutation.6,
                    evidence: mutation.9
                )
                let current = try PersonDossierFixture.currentDocument(
                    id: base.origin.document.id,
                    sourceRootID: base.origin.document.sourceRootID,
                    path: base.origin.document.relativePath,
                    availability: availability,
                    contentHash: mutation.0,
                    extractionVersion: mutation.1,
                    schemaVersion: mutation.2,
                    analyzerIdentifier: mutation.3,
                    analyzerVersion: mutation.4,
                    analyzedAt: mutation.5,
                    personFindings: [finding]
                )
                let snapshot = try PersonDossierProjector().project(base.input(
                    originDocument: current.document,
                    currentOrigin: current,
                    documentsByID: [current.document.id: current.document],
                    currentDocumentsByID: [current.document.id: current]
                ))

                #expect(snapshot.origin.validity == .stale)
                #expect(snapshot.origin.document?.availability == availability)
            }
        }
    }

    @Test func projectsUnavailableOriginOnlyWhenDocumentRowIsGone() throws {
        let fixture = try PersonProjectorFixture.make()

        let snapshot = try PersonDossierProjector().project(fixture.input(
            originDocument: .some(nil),
            currentOrigin: .some(nil),
            documentsByID: [:],
            currentDocumentsByID: [:]
        ))

        #expect(snapshot.origin.validity == .unavailable)
        #expect(snapshot.origin.document == nil)
        #expect(snapshot.origin.sourceDisplayName == nil)
    }

    @Test func rejectsMissingOriginInputWhenDocumentRowStillExists() throws {
        let fixture = try PersonProjectorFixture.make()

        #expect(throws: PersonDossierProjectionError.invalidStoredState) {
            try PersonDossierProjector().project(fixture.input(
                originDocument: .some(nil),
                currentOrigin: .some(nil),
                documentsByID: [fixture.origin.document.id: fixture.origin.document],
                currentDocumentsByID: [:]
            ))
        }
    }

    @Test func rejectsWrongDossierKindOrAnchor() throws {
        let fixture = try PersonProjectorFixture.make()
        let costs = try DossierRecord(
            id: fixture.dossier.id,
            kind: .costsAndPayments,
            displayName: "Costs",
            anchor: .document(fixture.origin.document.id),
            createdAt: fixture.dossier.createdAt,
            updatedAt: fixture.dossier.updatedAt
        )
        #expect(throws: PersonDossierProjectionError.invalidStoredState) {
            try PersonDossierProjector().project(fixture.input(dossier: costs))
        }

        let foreign = PersonDossierFixture.document(
            id: UUID(uuidString: "74000000-0000-0000-0000-000000000099")!,
            sourceRootID: fixture.origin.document.sourceRootID,
            path: "foreign.pdf",
            contentHash: "foreign"
        )
        #expect(throws: PersonDossierProjectionError.invalidStoredState) {
            try PersonDossierProjector().project(fixture.input(originDocument: foreign))
        }
    }

    @Test func rejectsForeignDuplicateAndContradictoryCorrections() throws {
        let fixture = try PersonProjectorFixture.make()
        let member = try fixture.candidate(idSuffix: 2, role: .authorizedPerson)
        let confirmation = try fixture.confirmation(for: member)
        let exclusion = fixture.exclusion(for: member)
        let foreignConfirmation = try fixture.confirmation(
            for: member,
            dossierID: UUID(uuidString: "74000000-0000-0000-0000-000000000098")!
        )
        let foreignExclusion = fixture.exclusion(
            for: member,
            dossierID: UUID(uuidString: "74000000-0000-0000-0000-000000000098")!
        )
        let inputs = [
            fixture.input(documents: [member], confirmations: [foreignConfirmation]),
            fixture.input(documents: [member], exclusions: [foreignExclusion]),
            fixture.input(documents: [member], confirmations: [confirmation, confirmation]),
            fixture.input(documents: [member], exclusions: [exclusion, exclusion]),
            fixture.input(documents: [member], confirmations: [confirmation], exclusions: [exclusion]),
        ]

        for input in inputs {
            #expect(throws: PersonDossierProjectionError.invalidStoredState) {
                try PersonDossierProjector().project(input)
            }
        }
    }

    @Test func rejectsConfirmationOrExclusionWithoutItsDocumentRow() throws {
        let fixture = try PersonProjectorFixture.make()
        let member = try fixture.candidate(idSuffix: 2, role: .authorizedPerson)

        for input in [
            fixture.input(confirmations: [try fixture.confirmation(for: member)]),
            fixture.input(exclusions: [fixture.exclusion(for: member)]),
        ] {
            #expect(throws: PersonDossierProjectionError.invalidStoredState) {
                try PersonDossierProjector().project(input)
            }
        }
    }

    @Test func projectsEachAutomaticDocumentOnceWithAllOrderedExactSupports() throws {
        let fixture = try PersonProjectorFixture.make()
        let resident = try PersonDossierFixture.personFinding(role: .resident)
        let insured = try PersonDossierFixture.personFinding(role: .insuredPerson)
        let candidate = try fixture.candidate(
            idSuffix: 2,
            roles: [insured, resident, resident]
        )

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [candidate],
            personCandidates: [candidate, candidate]
        ))

        #expect(snapshot.directMembers.count == 1)
        #expect(snapshot.directMembers[0].id == candidate.document.id)
        #expect(snapshot.directMembers[0].supports.compactMap(\.exactPrimaryRole) == [
            .resident, .insuredPerson,
        ])
        #expect(!snapshot.directMembers[0].isConfirmationAuthoritative)
    }

    @Test func placesInvoicesAndPaymentsInCostsAndPaymentsAndEverythingElseDirect() throws {
        let fixture = try PersonProjectorFixture.make()
        let candidates = try DocumentType.allCases.enumerated().map { index, type in
            try fixture.candidate(idSuffix: index + 2, role: .resident, type: type)
        }

        let snapshot = try PersonDossierProjector().project(fixture.input(documents: candidates))

        #expect(snapshot.costsAndPayments.map(\.documentType) == [
            .invoice, .paymentConfirmation,
        ])
        #expect(snapshot.directMembers.compactMap(\.documentType) == [
            .contract, .insuranceStatement, .medicalOrCareDocument,
            .powerOfAttorney, .correspondence, .unknown,
        ])
        #expect(snapshot.directMembers.allSatisfy { $0.section == .directDocuments })
        #expect(snapshot.costsAndPayments.allSatisfy { $0.section == .costsAndPayments })
    }

    @Test func projectsSecondaryAndConflictCandidatesAsSuggestions() throws {
        let birthDate = try PersonDossierBirthDate(
            displayValue: "01.02.1940",
            normalizedValue: "1940-02-01",
            evidence: [try PersonDossierFixture.evidence(displayText: "01.02.1940")]
        )
        let fixture = try PersonProjectorFixture.make(birthDate: birthDate)
        let secondary = try fixture.candidate(
            idSuffix: 2,
            role: .authorizedPerson,
            type: .invoice
        )
        let conflictingDate = try PersonDossierFixture.finding(
            kind: .date,
            qualifier: DocumentDNADateRole.birthDate.rawValue,
            displayValue: "02.03.1941",
            normalizedValue: "1941-03-02"
        )
        let conflict = try fixture.candidate(
            idSuffix: 3,
            type: .correspondence,
            roles: [try PersonDossierFixture.personFinding(role: .resident), conflictingDate]
        )

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [secondary, conflict]
        ))

        #expect(snapshot.suggestions.map(\.kind) == [.secondaryRole, .birthDateConflict])
        #expect(snapshot.suggestions.map(\.section) == [.costsAndPayments, .directDocuments])
        #expect(snapshot.suggestions[0].document == secondary.document)
        #expect(snapshot.suggestions[0].sourceDisplayName == "Archive")
        #expect(snapshot.suggestions[0].documentType == .invoice)
        #expect(snapshot.suggestions[0].currentSupports == [snapshot.suggestions[0].commandSupport])
        #expect(snapshot.suggestions[0].commandSupport.person.finding.evidence
            == secondary.snapshot.findings.last?.evidence)
        guard case let .hardBirthDateConflict(anchor, candidate) = snapshot.suggestions[1].conflict else {
            Issue.record("Expected a hard birth-date conflict")
            return
        }
        #expect(anchor == birthDate)
        #expect(candidate == conflictingDate)
    }

    @Test func exclusionSuppressesAutomaticSuggestionConfirmationAndRelationshipSupport() throws {
        let fixture = try PersonProjectorFixture.make()
        let automatic = try fixture.candidate(idSuffix: 2, role: .resident)
        let suggestion = try fixture.candidate(idSuffix: 3, role: .authorizedPerson)
        let confirmed = try fixture.candidate(idSuffix: 4, role: .authorizedPerson)
        let inputs = [
            fixture.input(documents: [automatic], exclusions: [fixture.exclusion(for: automatic)]),
            fixture.input(documents: [suggestion], exclusions: [fixture.exclusion(for: suggestion)]),
            fixture.input(documents: [confirmed], exclusions: [fixture.exclusion(for: confirmed)]),
        ]

        for input in inputs {
            let snapshot = try PersonDossierProjector().project(input)
            #expect(snapshot.directMembers.isEmpty)
            #expect(snapshot.costsAndPayments.isEmpty)
            #expect(snapshot.suggestions.isEmpty)
            #expect(snapshot.corrections.count == 1)
            guard case .exclusion = snapshot.corrections[0].decision else {
                Issue.record("Expected only an exclusion correction")
                continue
            }
        }
    }

    @Test func confirmationCreatesAnAuthoritativeMemberAndCorrection() throws {
        let fixture = try PersonProjectorFixture.make()
        let candidate = try fixture.candidate(idSuffix: 2, role: .authorizedPerson)
        let confirmation = try fixture.confirmation(for: candidate)

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [candidate],
            confirmations: [confirmation]
        ))

        #expect(snapshot.directMembers.count == 1)
        #expect(snapshot.directMembers[0].isConfirmationAuthoritative)
        #expect(snapshot.directMembers[0].supports.count == 1)
        #expect(snapshot.corrections.count == 1)
        #expect(snapshot.corrections[0].document == candidate.document)
        guard case let .confirmation(projected) = snapshot.corrections[0].decision else {
            Issue.record("Expected a confirmation correction")
            return
        }
        #expect(projected == confirmation)
    }

    @Test func currentAcceptedCandidateAddsCurrentEvidenceToManualSupport() throws {
        let fixture = try PersonProjectorFixture.make()
        let candidate = try fixture.candidate(idSuffix: 2, role: .authorizedPerson)
        let confirmation = try fixture.confirmation(for: candidate)

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [candidate],
            confirmations: [confirmation]
        ))

        guard case let .manualConfirmation(projected, current?) = snapshot.directMembers[0].supports[0] else {
            Issue.record("Expected current accepted evidence on manual support")
            return
        }
        #expect(projected == confirmation)
        #expect(current.kind == .secondaryRole)
        #expect(current.person.finding.evidence == candidate.snapshot.findings.last?.evidence)
        #expect(current.person.documentID == candidate.document.id)
    }

    @Test func staleAcceptedCandidateKeepsOnlyManualSupport() throws {
        let fixture = try PersonProjectorFixture.make()
        let accepted = try fixture.candidate(idSuffix: 2, role: .authorizedPerson)
        let confirmation = try fixture.confirmation(for: accepted)
        let mutations: [(String, String, Int, String, String, Date, PersonDossierRole, String)] = [
            ("changed", "text-v1", 1, "local-rules", "1", PersonDossierFixture.date, .authorizedPerson, "elise muster"),
            (accepted.document.contentHash, "text-v2", 1, "local-rules", "1", PersonDossierFixture.date, .authorizedPerson, "elise muster"),
            (accepted.document.contentHash, "text-v1", 2, "local-rules", "1", PersonDossierFixture.date, .authorizedPerson, "elise muster"),
            (accepted.document.contentHash, "text-v1", 1, "other", "1", PersonDossierFixture.date, .authorizedPerson, "elise muster"),
            (accepted.document.contentHash, "text-v1", 1, "local-rules", "2", PersonDossierFixture.date, .authorizedPerson, "elise muster"),
            (accepted.document.contentHash, "text-v1", 1, "local-rules", "1", PersonDossierFixture.date.addingTimeInterval(1), .authorizedPerson, "elise muster"),
            (accepted.document.contentHash, "text-v1", 1, "local-rules", "1", PersonDossierFixture.date, .resident, "elise muster"),
            (accepted.document.contentHash, "text-v1", 1, "local-rules", "1", PersonDossierFixture.date, .authorizedPerson, "elise changed"),
        ]

        for mutation in mutations {
            let current = try PersonDossierFixture.currentDocument(
                id: accepted.document.id,
                sourceRootID: accepted.document.sourceRootID,
                path: accepted.document.relativePath,
                contentHash: mutation.0,
                extractionVersion: mutation.1,
                schemaVersion: mutation.2,
                analyzerIdentifier: mutation.3,
                analyzerVersion: mutation.4,
                analyzedAt: mutation.5,
                personFindings: [try PersonDossierFixture.personFinding(
                    normalizedName: mutation.7,
                    role: mutation.6
                )]
            )
            let snapshot = try PersonDossierProjector().project(fixture.input(
                documents: [current],
                confirmations: [confirmation]
            ))
            guard case let .manualConfirmation(projected, currentCandidate) = snapshot.directMembers[0].supports[0] else {
                Issue.record("Expected retained manual support")
                continue
            }
            #expect(projected == confirmation)
            #expect(currentCandidate == nil)
        }
    }

    @Test func reanalysisAndPathOrSourceMoveKeepConfirmationAndExclusionAuthoritative() throws {
        let fixture = try PersonProjectorFixture.make()
        let accepted = try fixture.candidate(idSuffix: 2, role: .authorizedPerson)
        let movedSource = UUID(uuidString: "74000000-0000-0000-0000-000000000011")!
        let moved = try PersonDossierFixture.currentDocument(
            id: accepted.document.id,
            sourceRootID: movedSource,
            path: "moved/reanalyzed.pdf",
            contentHash: "reanalyzed",
            analyzedAt: PersonDossierFixture.date.addingTimeInterval(10),
            personFindings: []
        )
        let confirmed = try PersonDossierProjector().project(fixture.input(
            documents: [moved],
            confirmations: [try fixture.confirmation(for: accepted)],
            sourceDisplayNames: [movedSource: "Moved"]
        ))
        #expect(confirmed.directMembers[0].document == moved.document)
        #expect(confirmed.directMembers[0].sourceDisplayName == "Moved")
        #expect(confirmed.directMembers[0].isConfirmationAuthoritative)

        let excluded = try PersonDossierProjector().project(fixture.input(
            documents: [moved],
            exclusions: [fixture.exclusion(for: accepted)],
            sourceDisplayNames: [movedSource: "Moved"]
        ))
        #expect(excluded.directMembers.isEmpty)
        #expect(excluded.corrections[0].document == moved.document)
        #expect(excluded.corrections[0].sourceDisplayName == "Moved")
    }

    @Test func ordersEachSectionAndSuggestionsBySourceNamePathUUID() throws {
        let fixture = try PersonProjectorFixture.make()
        let alpha = UUID(uuidString: "74000000-0000-0000-0000-000000000011")!
        let beta = UUID(uuidString: "74000000-0000-0000-0000-000000000012")!
        let directZ = try fixture.candidate(idSuffix: 5, role: .resident, path: "z.pdf", sourceRootID: alpha)
        let directAHigh = try fixture.candidate(idSuffix: 4, role: .resident, path: "a.pdf", sourceRootID: alpha)
        let directALow = try fixture.candidate(idSuffix: 3, role: .resident, path: "a.pdf", sourceRootID: alpha)
        let costs = try fixture.candidate(idSuffix: 2, role: .resident, type: .invoice, path: "a.pdf", sourceRootID: beta)
        let suggestion = try fixture.candidate(idSuffix: 6, role: .authorizedPerson, path: "b.pdf", sourceRootID: alpha)

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [suggestion, directZ, directAHigh, costs, directALow],
            sourceDisplayNames: [beta: "Beta", alpha: "Alpha"]
        ))

        #expect(snapshot.directMembers.map(\.id) == [
            directALow.document.id, directAHigh.document.id, directZ.document.id,
        ])
        #expect(snapshot.costsAndPayments.map(\.id) == [costs.document.id])
        #expect(snapshot.suggestions.map(\.id) == [suggestion.document.id])
    }

    @Test func projectionIsInputOrderIndependent() throws {
        let fixture = try PersonProjectorFixture.make()
        let automatic = try fixture.candidate(idSuffix: 2, role: .resident)
        let suggested = try fixture.candidate(idSuffix: 3, role: .authorizedPerson)
        let confirmed = try fixture.candidate(idSuffix: 4, role: .authorizedPerson)
        let excluded = try fixture.candidate(idSuffix: 5, role: .resident)
        let secondSource = UUID(uuidString: "74000000-0000-0000-0000-000000000012")!
        let confirmedSecond = try fixture.candidate(
            idSuffix: 6,
            role: .authorizedPerson,
            sourceRootID: secondSource
        )
        let excludedSecond = try fixture.candidate(
            idSuffix: 7,
            role: .resident,
            sourceRootID: secondSource
        )
        let documents = [automatic, suggested, confirmed, excluded, confirmedSecond, excludedSecond]
        let confirmations = [
            try fixture.confirmation(for: confirmed),
            try fixture.confirmation(
                for: confirmedSecond,
                revisionID: UUID(uuidString: "74000000-0000-0000-0000-000000000041")!
            ),
        ]
        let exclusions = [
            fixture.exclusion(for: excluded),
            fixture.exclusion(
                for: excludedSecond,
                revisionID: UUID(uuidString: "74000000-0000-0000-0000-000000000051")!
            ),
        ]
        let sourceNames = [(fixture.sourceID, "Archive"), (secondSource, "Backup")]
        let forward = try PersonDossierProjector().project(fixture.input(
            documents: documents,
            personCandidates: documents,
            confirmations: confirmations,
            exclusions: exclusions,
            sourceDisplayNames: Dictionary(uniqueKeysWithValues: sourceNames)
        ))
        let reverse = try PersonDossierProjector().project(fixture.input(
            documents: Array(documents.reversed()),
            personCandidates: Array(documents.reversed()),
            confirmations: Array(confirmations.reversed()),
            exclusions: Array(exclusions.reversed()),
            sourceDisplayNames: Dictionary(uniqueKeysWithValues: sourceNames.reversed())
        ))

        #expect(reverse == forward)
    }

    @Test(arguments: OriginTokenMutation.allCases)
    func staleOriginMutationsChangeProjectionToken(
        _ mutation: OriginTokenMutation
    ) throws {
        let fixture = try PersonProjectorFixture.make()
        let baselineOrigin = try fixture.staleOrigin()
        let baseline = try PersonDossierProjector().project(fixture.input(
            originDocument: baselineOrigin.document,
            currentOrigin: baselineOrigin,
            documentsByID: [baselineOrigin.document.id: baselineOrigin.document],
            currentDocumentsByID: [baselineOrigin.document.id: baselineOrigin]
        ))
        let changedOrigin = try fixture.staleOrigin(mutation: mutation)
        let changed = try PersonDossierProjector().project(fixture.input(
            originDocument: changedOrigin.document,
            currentOrigin: changedOrigin,
            documentsByID: [changedOrigin.document.id: changedOrigin.document],
            currentDocumentsByID: [changedOrigin.document.id: changedOrigin],
            sourceDisplayNames: [changedOrigin.document.sourceRootID: "Archive"]
        ))

        #expect(baseline.origin.validity == .stale)
        #expect(changed.origin.validity == .stale)
        #expect(changed.token != baseline.token)
    }

    @Test func confirmedCurrentCandidateAddsPaymentFromDirectInvoice() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let candidate = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoice, payment: payment)
        let decision = try PersonDossierFixture.relationshipDecision(for: candidate)

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [invoice, payment],
            personCandidates: [invoice],
            relationshipCandidates: [candidate],
            relationshipDecisionsByKey: [decision.0: decision.1]
        ))

        #expect(snapshot.costsAndPayments.map(\.id) == [invoice.document.id, payment.document.id])
        guard let projectedPayment = snapshot.costsAndPayments.first(where: { $0.id == payment.document.id }),
              case let .confirmedPayment(support) = projectedPayment.supports[0] else {
            Issue.record("Expected a confirmed relationship support")
            return
        }
        #expect(support.relationship.decisionKey == decision.0)
        #expect(support.relationship.decisionUpdatedAt == decision.1.updatedAt)
        #expect(support.relationship.invoiceDNAAnalyzedAt == invoice.snapshot.analyzedAt)
        #expect(support.relationship.paymentDNAAnalyzedAt == payment.snapshot.analyzedAt)
        #expect(support.relationship.resolverVersion == candidate.resolverVersion)
        #expect(support.signals.map(\.kind) == [.referenceNumber, .monetaryAmount, .organization])
        guard case let .exactPerson(invoiceSupports) = support.invoiceMembershipBasis else {
            Issue.record("Expected exact person invoice basis")
            return
        }
        #expect(invoiceSupports.map(\.documentID) == [invoice.document.id])
        #expect(projectedPayment.preferredPaymentSupport == support)
    }

    @Test func confirmedCurrentCandidateAddsPaymentFromManuallyConfirmedInvoice() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .authorizedPerson)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let confirmation = try fixture.confirmation(for: invoice)
        let candidate = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoice, payment: payment)
        let decision = try PersonDossierFixture.relationshipDecision(for: candidate)

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [invoice, payment],
            personCandidates: [invoice],
            relationshipCandidates: [candidate],
            relationshipDecisionsByKey: [decision.0: decision.1],
            confirmations: [confirmation]
        ))

        guard let projectedPayment = snapshot.costsAndPayments.first(where: { $0.id == payment.document.id }),
              case let .confirmedPayment(support) = projectedPayment.supports[0],
              case let .manualConfirmation(revisionID) = support.invoiceMembershipBasis else {
            Issue.record("Expected manual invoice basis")
            return
        }
        #expect(revisionID == confirmation.revisionID)
    }

    @Test func relationshipCandidateEndpointsMustMatchCompleteCurrentSnapshots() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let currentCandidate = try PersonDossierFixture.invoicePaymentCandidate(
            invoice: invoice,
            payment: payment
        )
        let staleInvoice = try PersonDossierFixture.currentDocument(
            id: invoice.document.id,
            sourceRootID: invoice.document.sourceRootID,
            path: invoice.document.relativePath,
            documentType: .invoice,
            contentHash: invoice.document.contentHash,
            analyzedAt: invoice.snapshot.analyzedAt.addingTimeInterval(1),
            personFindings: Array(invoice.snapshot.findings.dropFirst())
        )
        let wrongPaymentType = try PersonDossierFixture.currentDocument(
            id: payment.document.id,
            sourceRootID: payment.document.sourceRootID,
            path: payment.document.relativePath,
            documentType: .correspondence,
            contentHash: payment.document.contentHash,
            analyzedAt: payment.snapshot.analyzedAt,
            personFindings: Array(payment.snapshot.findings.dropFirst())
        )
        let candidates = [
            InvoicePaymentCandidate(
                invoice: staleInvoice,
                payment: payment,
                disposition: currentCandidate.disposition,
                resolverVersion: currentCandidate.resolverVersion,
                signals: currentCandidate.signals
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: wrongPaymentType,
                disposition: currentCandidate.disposition,
                resolverVersion: currentCandidate.resolverVersion,
                signals: currentCandidate.signals
            ),
        ]
        let decision = try PersonDossierFixture.relationshipDecision(for: currentCandidate)

        for candidate in candidates {
            let snapshot = try PersonDossierProjector().project(fixture.input(
                documents: [invoice, payment],
                personCandidates: [invoice],
                relationshipCandidates: [candidate],
                relationshipDecisionsByKey: [decision.0: decision.1]
            ))

            #expect(snapshot.costsAndPayments.map(\.id) == [invoice.document.id])
        }
    }

    @Test func relationshipCandidatesRequirePaymentEndpointAndSharedAnalysisTarget() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let valid = try PersonDossierFixture.invoicePaymentCandidate(
            invoice: invoice,
            payment: payment
        )
        let invoiceTypedPayment = try fixture.relationshipVariant(
            payment,
            documentType: .invoice
        )
        let differentTargetPayment = try fixture.relationshipVariant(
            payment,
            analyzerVersion: "different"
        )

        for currentPayment in [invoiceTypedPayment, differentTargetPayment] {
            let candidate = InvoicePaymentCandidate(
                invoice: invoice,
                payment: currentPayment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: valid.signals
            )
            let decision = try PersonDossierFixture.relationshipDecision(for: candidate)
            let snapshot = try PersonDossierProjector().project(fixture.input(
                documents: [invoice, currentPayment],
                personCandidates: [invoice],
                relationshipCandidates: [candidate],
                relationshipDecisionsByKey: [decision.0: decision.1]
            ))

            #expect(snapshot.costsAndPayments.map(\.id) == [invoice.document.id])
        }
    }

    @Test func relationshipSignalsMustMatchResolverSemantics() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let valid = try PersonDossierFixture.invoicePaymentCandidate(
            invoice: invoice,
            payment: payment
        )
        let reference = try #require(valid.signals.first { $0.kind == .referenceNumber })
        let amount = try #require(valid.signals.first { $0.kind == .monetaryAmount })
        let organization = try #require(valid.signals.first { $0.kind == .organization })

        let wrongInvoiceReferenceQualifier = try PersonDossierFixture.finding(
            kind: .referenceNumber,
            qualifier: DocumentDNAReferenceNumberKind.paymentReference.rawValue,
            displayValue: "INV-42",
            normalizedValue: "INV42"
        )
        let wrongPaymentReferenceValue = try PersonDossierFixture.finding(
            kind: .referenceNumber,
            qualifier: DocumentDNAReferenceNumberKind.paymentReference.rawValue,
            displayValue: "OTHER-42",
            normalizedValue: "OTHER42"
        )
        let wrongPaymentAmountQualifier = try PersonDossierFixture.finding(
            kind: .monetaryAmount,
            qualifier: "EUR",
            displayValue: "EUR 1250",
            normalizedValue: "1250"
        )
        let wrongPaymentAmountValue = try PersonDossierFixture.finding(
            kind: .monetaryAmount,
            qualifier: "CHF",
            displayValue: "CHF 999",
            normalizedValue: "999"
        )
        let wrongInvoiceOrganizationQualifier = try PersonDossierFixture.finding(
            kind: .organization,
            qualifier: "payee",
            displayValue: "Alpha AG",
            normalizedValue: "alpha ag"
        )
        let wrongPaymentOrganizationValue = try PersonDossierFixture.finding(
            kind: .organization,
            qualifier: "payee",
            displayValue: "Beta AG",
            normalizedValue: "beta ag"
        )

        let referenceQualifierInvoice = try fixture.relationshipVariant(
            invoice,
            additionalFindings: [wrongInvoiceReferenceQualifier]
        )
        let referenceValuePayment = try fixture.relationshipVariant(
            payment,
            additionalFindings: [wrongPaymentReferenceValue]
        )
        let amountQualifierPayment = try fixture.relationshipVariant(
            payment,
            additionalFindings: [wrongPaymentAmountQualifier]
        )
        let amountValuePayment = try fixture.relationshipVariant(
            payment,
            additionalFindings: [wrongPaymentAmountValue]
        )
        let organizationQualifierInvoice = try fixture.relationshipVariant(
            invoice,
            additionalFindings: [wrongInvoiceOrganizationQualifier]
        )
        let organizationValuePayment = try fixture.relationshipVariant(
            payment,
            additionalFindings: [wrongPaymentOrganizationValue]
        )

        let invalidCandidates = [
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: payment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [amount, organization]
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: payment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [reference]
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: payment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [reference, reference, amount]
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: payment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [
                    InvoicePaymentCandidateSignal(
                        kind: .referenceNumber,
                        invoiceFinding: amount.invoiceFinding,
                        paymentFinding: amount.paymentFinding
                    ),
                    amount,
                    organization,
                ]
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: payment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [
                    reference,
                    InvoicePaymentCandidateSignal(
                        kind: .monetaryAmount,
                        invoiceFinding: organization.invoiceFinding,
                        paymentFinding: organization.paymentFinding
                    ),
                    organization,
                ]
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: payment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [
                    reference,
                    amount,
                    InvoicePaymentCandidateSignal(
                        kind: .organization,
                        invoiceFinding: reference.invoiceFinding,
                        paymentFinding: reference.paymentFinding
                    ),
                ]
            ),
            InvoicePaymentCandidate(
                invoice: referenceQualifierInvoice,
                payment: payment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [
                    InvoicePaymentCandidateSignal(
                        kind: .referenceNumber,
                        invoiceFinding: wrongInvoiceReferenceQualifier,
                        paymentFinding: reference.paymentFinding
                    ),
                    amount,
                    organization,
                ]
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: referenceValuePayment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [
                    InvoicePaymentCandidateSignal(
                        kind: .referenceNumber,
                        invoiceFinding: reference.invoiceFinding,
                        paymentFinding: wrongPaymentReferenceValue
                    ),
                    amount,
                    organization,
                ]
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: amountQualifierPayment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [
                    reference,
                    InvoicePaymentCandidateSignal(
                        kind: .monetaryAmount,
                        invoiceFinding: amount.invoiceFinding,
                        paymentFinding: wrongPaymentAmountQualifier
                    ),
                    organization,
                ]
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: amountValuePayment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [
                    reference,
                    InvoicePaymentCandidateSignal(
                        kind: .monetaryAmount,
                        invoiceFinding: amount.invoiceFinding,
                        paymentFinding: wrongPaymentAmountValue
                    ),
                    organization,
                ]
            ),
            InvoicePaymentCandidate(
                invoice: organizationQualifierInvoice,
                payment: payment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [
                    reference,
                    amount,
                    InvoicePaymentCandidateSignal(
                        kind: .organization,
                        invoiceFinding: wrongInvoiceOrganizationQualifier,
                        paymentFinding: organization.paymentFinding
                    ),
                ]
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: organizationValuePayment,
                disposition: valid.disposition,
                resolverVersion: valid.resolverVersion,
                signals: [
                    reference,
                    amount,
                    InvoicePaymentCandidateSignal(
                        kind: .organization,
                        invoiceFinding: organization.invoiceFinding,
                        paymentFinding: wrongPaymentOrganizationValue
                    ),
                ]
            ),
        ]

        for candidate in invalidCandidates {
            let decision = try PersonDossierFixture.relationshipDecision(for: candidate)
            let snapshot = try PersonDossierProjector().project(fixture.input(
                documents: [candidate.invoice, candidate.payment],
                personCandidates: [candidate.invoice],
                relationshipCandidates: [candidate],
                relationshipDecisionsByKey: [decision.0: decision.1]
            ))

            #expect(snapshot.costsAndPayments.map(\.id) == [candidate.invoice.document.id])
        }
    }

    @Test func relationshipSignalFindingsMustExistInCurrentEndpointSnapshots() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let currentCandidate = try PersonDossierFixture.invoicePaymentCandidate(
            invoice: invoice,
            payment: payment
        )
        let fabricatedInvoiceFinding = try PersonDossierFixture.finding(
            kind: .referenceNumber,
            qualifier: DocumentDNAReferenceNumberKind.invoiceNumber.rawValue,
            displayValue: "FABRICATED-42",
            normalizedValue: "INV42"
        )
        let fabricatedPaymentFinding = try PersonDossierFixture.finding(
            kind: .referenceNumber,
            qualifier: DocumentDNAReferenceNumberKind.paymentReference.rawValue,
            displayValue: "FABRICATED-42",
            normalizedValue: "INV42"
        )
        let candidates = [
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: payment,
                disposition: currentCandidate.disposition,
                resolverVersion: currentCandidate.resolverVersion,
                signals: [InvoicePaymentCandidateSignal(
                    kind: .referenceNumber,
                    invoiceFinding: fabricatedInvoiceFinding,
                    paymentFinding: currentCandidate.signals[0].paymentFinding
                )]
            ),
            InvoicePaymentCandidate(
                invoice: invoice,
                payment: payment,
                disposition: currentCandidate.disposition,
                resolverVersion: currentCandidate.resolverVersion,
                signals: [InvoicePaymentCandidateSignal(
                    kind: .referenceNumber,
                    invoiceFinding: currentCandidate.signals[0].invoiceFinding,
                    paymentFinding: fabricatedPaymentFinding
                )]
            ),
        ]
        let decision = try PersonDossierFixture.relationshipDecision(for: currentCandidate)

        for candidate in candidates {
            let snapshot = try PersonDossierProjector().project(fixture.input(
                documents: [invoice, payment],
                personCandidates: [invoice],
                relationshipCandidates: [candidate],
                relationshipDecisionsByKey: [decision.0: decision.1]
            ))

            #expect(snapshot.costsAndPayments.map(\.id) == [invoice.document.id])
        }
    }

    @Test func undecidedExcludedAndContentStaleRelationshipsAddNothing() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let candidate = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoice, payment: payment)
        let excluded = try PersonDossierFixture.relationshipDecision(for: candidate, decision: .excluded)
        let staleInvoice = try PersonDossierFixture.relationshipDecision(for: candidate, invoiceContentHash: "old-invoice")
        let stalePayment = try PersonDossierFixture.relationshipDecision(for: candidate, paymentContentHash: "old-payment")
        let decisions: [[InvoicePaymentDecisionKey: InvoicePaymentDecisionRecord]] = [
            [:], [excluded.0: excluded.1], [staleInvoice.0: staleInvoice.1], [stalePayment.0: stalePayment.1],
        ]

        for records in decisions {
            let snapshot = try PersonDossierProjector().project(fixture.input(
                documents: [invoice, payment],
                personCandidates: [invoice],
                relationshipCandidates: [candidate],
                relationshipDecisionsByKey: records
            ))
            #expect(snapshot.costsAndPayments.map(\.id) == [invoice.document.id])
        }
    }

    @Test func personExclusionSuppressesOtherwiseConfirmedPayment() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let candidate = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoice, payment: payment)
        let decision = try PersonDossierFixture.relationshipDecision(for: candidate)
        let exclusion = fixture.exclusion(for: payment)

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [invoice, payment], personCandidates: [invoice],
            relationshipCandidates: [candidate], relationshipDecisionsByKey: [decision.0: decision.1],
            exclusions: [exclusion]
        ))

        #expect(snapshot.costsAndPayments.map(\.id) == [invoice.document.id])
        #expect(snapshot.corrections.map(\.id) == [payment.document.id])
        guard case .exclusion = snapshot.corrections[0].decision else {
            Issue.record("Expected exclusion correction")
            return
        }
    }

    @Test func doesNotExpandFromSuggestionExcludedInvoiceOrInferredPayment() throws {
        let fixture = try PersonProjectorFixture.make()
        let suggestedInvoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .authorizedPerson)
        let excludedInvoice = try fixture.relationshipDocument(idSuffix: 3, type: .invoice, role: .resident)
        let inferredInvoice = try fixture.relationshipDocument(idSuffix: 4, type: .invoice)
        let payment = try fixture.relationshipDocument(idSuffix: 5, type: .paymentConfirmation)
        let candidates = try [suggestedInvoice, excludedInvoice, inferredInvoice].map {
            try PersonDossierFixture.invoicePaymentCandidate(invoice: $0, payment: payment)
        }
        let decisions = try Dictionary(uniqueKeysWithValues: candidates.map {
            try PersonDossierFixture.relationshipDecision(for: $0)
        })

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [suggestedInvoice, excludedInvoice, inferredInvoice, payment],
            personCandidates: [suggestedInvoice, excludedInvoice],
            relationshipCandidates: candidates,
            relationshipDecisionsByKey: decisions,
            exclusions: [fixture.exclusion(for: excludedInvoice)]
        ))

        #expect(snapshot.costsAndPayments.isEmpty)
        #expect(snapshot.suggestions.map(\.id) == [suggestedInvoice.document.id])
    }

    @Test func stopsAfterPaymentAndNeverAddsSecondInvoice() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let secondInvoice = try fixture.relationshipDocument(idSuffix: 4, type: .invoice)
        let first = try PersonDossierFixture.invoicePaymentCandidate(
            invoice: invoice,
            payment: payment
        )
        let second = try PersonDossierFixture.invoicePaymentCandidate(
            invoice: secondInvoice,
            payment: payment
        )
        let firstDecision = try PersonDossierFixture.relationshipDecision(for: first)
        let secondDecision = try PersonDossierFixture.relationshipDecision(for: second)

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [invoice, payment, secondInvoice], personCandidates: [invoice],
            relationshipCandidates: [first, second],
            relationshipDecisionsByKey: [firstDecision.0: firstDecision.1, secondDecision.0: secondDecision.1]
        ))

        #expect(snapshot.costsAndPayments.map(\.id) == [invoice.document.id, payment.document.id])
    }

    @Test func removingSoleInvoiceRemovesDerivedPayment() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let candidate = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoice, payment: payment)
        let decision = try PersonDossierFixture.relationshipDecision(for: candidate)

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [invoice, payment], personCandidates: [invoice],
            relationshipCandidates: [candidate], relationshipDecisionsByKey: [decision.0: decision.1],
            exclusions: [fixture.exclusion(for: invoice)]
        ))

        #expect(snapshot.costsAndPayments.isEmpty)
        #expect(snapshot.corrections.map(\.id) == [invoice.document.id])
    }

    @Test func keepsPaymentWithIndependentDirectManualOrSecondInvoiceSupport() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoiceA = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let invoiceB = try fixture.relationshipDocument(idSuffix: 3, type: .invoice, role: .resident)
        let directPayment = try fixture.relationshipDocument(idSuffix: 4, type: .paymentConfirmation, role: .resident)
        let manualPayment = try fixture.relationshipDocument(idSuffix: 5, type: .paymentConfirmation, role: .authorizedPerson)
        let sharedPayment = try fixture.relationshipDocument(idSuffix: 6, type: .paymentConfirmation)
        let directCandidate = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoiceA, payment: directPayment)
        let manualCandidate = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoiceA, payment: manualPayment)
        let sharedA = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoiceA, payment: sharedPayment)
        let sharedB = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoiceB, payment: sharedPayment)
        let allCandidates = [directCandidate, manualCandidate, sharedA, sharedB]
        let decisions = try Dictionary(uniqueKeysWithValues: allCandidates.map {
            try PersonDossierFixture.relationshipDecision(for: $0)
        })
        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [invoiceA, invoiceB, directPayment, manualPayment, sharedPayment],
            personCandidates: [invoiceA, invoiceB, directPayment, manualPayment],
            relationshipCandidates: allCandidates,
            relationshipDecisionsByKey: decisions,
            confirmations: [try fixture.confirmation(for: manualPayment)],
            exclusions: [fixture.exclusion(for: invoiceA)]
        ))

        #expect(snapshot.costsAndPayments.map(\.id) == [
            invoiceB.document.id, directPayment.document.id, manualPayment.document.id, sharedPayment.document.id,
        ])
        #expect(snapshot.costsAndPayments.first { $0.id == directPayment.document.id }?.supports.count == 1)
        #expect(snapshot.costsAndPayments.first { $0.id == manualPayment.document.id }?.supports.count == 1)
        #expect(snapshot.costsAndPayments.first { $0.id == sharedPayment.document.id }?.supports.count == 1)
    }

    @Test func deduplicatesPaymentAndRetainsAllConfirmedPaths() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoiceA = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident, path: "a.pdf")
        let invoiceB = try fixture.relationshipDocument(idSuffix: 3, type: .invoice, role: .resident, path: "b.pdf")
        let payment = try fixture.relationshipDocument(idSuffix: 4, type: .paymentConfirmation)
        let candidates = try [invoiceA, invoiceB].map {
            try PersonDossierFixture.invoicePaymentCandidate(invoice: $0, payment: payment)
        }
        let decisions = try Dictionary(uniqueKeysWithValues: candidates.map {
            try PersonDossierFixture.relationshipDecision(for: $0)
        })

        let snapshot = try PersonDossierProjector().project(fixture.input(
            documents: [invoiceA, invoiceB, payment], personCandidates: [invoiceA, invoiceB],
            relationshipCandidates: candidates + [candidates[0]], relationshipDecisionsByKey: decisions
        ))

        let projectedPayment = snapshot.costsAndPayments.first { $0.id == payment.document.id }
        #expect(projectedPayment?.supports.count == 2)
        #expect(projectedPayment?.supports.compactMap(\.confirmedPaymentValue).map(\.invoiceDocumentID)
            == [invoiceA.document.id, invoiceB.document.id])
    }

    @Test func selectsPreferredPaymentCommandSupportByExistingRanking() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let base = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoice, payment: payment)
        let invalidReferenceOnly = try PersonDossierFixture.invoicePaymentCandidate(
            invoice: invoice, payment: payment, disposition: .suggestion,
            resolverVersion: "z", signals: [base.signals[0]]
        )
        let strongLater = try PersonDossierFixture.invoicePaymentCandidate(
            invoice: invoice, payment: payment, disposition: .automatic,
            resolverVersion: "z", signals: Array(base.signals.reversed())
        )
        let strongPreferred = try PersonDossierFixture.invoicePaymentCandidate(
            invoice: invoice, payment: payment, disposition: .automatic,
            resolverVersion: "a", signals: base.signals
        )
        let laterInvoice = try PersonDossierFixture.currentDocument(
            id: invoice.document.id,
            sourceRootID: invoice.document.sourceRootID,
            path: invoice.document.relativePath,
            documentType: .invoice,
            contentHash: invoice.document.contentHash,
            analyzedAt: invoice.snapshot.analyzedAt.addingTimeInterval(100),
            personFindings: []
        )
        let laterPayment = try PersonDossierFixture.currentDocument(
            id: payment.document.id,
            sourceRootID: payment.document.sourceRootID,
            path: payment.document.relativePath,
            documentType: .paymentConfirmation,
            contentHash: payment.document.contentHash,
            analyzedAt: payment.snapshot.analyzedAt.addingTimeInterval(100),
            personFindings: []
        )
        let laterAnalysis = InvoicePaymentCandidate(
            invoice: laterInvoice,
            payment: laterPayment,
            disposition: .automatic,
            resolverVersion: "a",
            signals: base.signals
        )
        let alternateInvoiceType = try PersonDossierFixture.currentDocument(
            id: invoice.document.id,
            sourceRootID: invoice.document.sourceRootID,
            path: invoice.document.relativePath,
            documentType: .correspondence,
            contentHash: invoice.document.contentHash,
            analyzedAt: invoice.snapshot.analyzedAt,
            personFindings: []
        )
        let alternateReference = InvoicePaymentCandidateSignal(
            kind: .referenceNumber,
            invoiceFinding: try PersonDossierFixture.finding(
                kind: .referenceNumber,
                qualifier: DocumentDNAReferenceNumberKind.invoiceNumber.rawValue,
                displayValue: "ALT-42",
                normalizedValue: "INV42"
            ),
            paymentFinding: base.signals[0].paymentFinding
        )
        let wrongType = InvoicePaymentCandidate(
            invoice: alternateInvoiceType,
            payment: payment,
            disposition: .automatic,
            resolverVersion: "a",
            signals: base.signals
        )
        let fabricated = InvoicePaymentCandidate(
            invoice: invoice,
            payment: payment,
            disposition: .automatic,
            resolverVersion: "a",
            signals: [base.signals[2], base.signals[1], alternateReference]
        )
        let candidates = [
            invalidReferenceOnly, strongLater, strongPreferred,
            laterAnalysis, wrongType, fabricated,
        ]
        let decision = try PersonDossierFixture.relationshipDecision(for: base)
        let input = fixture.input(
            documents: [invoice, payment], personCandidates: [invoice],
            relationshipCandidates: candidates, relationshipDecisionsByKey: [decision.0: decision.1]
        )
        let forward = try PersonDossierProjector().project(input)
        let reverse = try PersonDossierProjector().project(fixture.input(
            documents: [payment, invoice], personCandidates: [invoice],
            relationshipCandidates: Array(candidates.reversed()), relationshipDecisionsByKey: [decision.0: decision.1]
        ))
        let preferred = forward.costsAndPayments.first { $0.id == payment.document.id }?.preferredPaymentSupport
        let projectedSupports = forward.costsAndPayments
            .first { $0.id == payment.document.id }?.supports.compactMap(\.confirmedPaymentValue)

        #expect(preferred?.relationship.resolverVersion == "a")
        #expect(preferred?.signals.map(\.kind) == [.referenceNumber, .monetaryAmount, .organization])
        #expect(preferred?.signals[0].invoiceFinding.displayValue == "INV-42")
        #expect(projectedSupports?.count == 2)
        #expect(projectedSupports?.contains { $0.signals.count == 1 } == false)
        #expect(projectedSupports?.contains { support in
            support.signals.contains { $0.invoiceFinding.displayValue == "ALT-42" }
        } == false)
        #expect(reverse == forward)
    }

    @Test func ordersRelationshipSignalsAndSupportsDeterministically() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoiceB = try fixture.relationshipDocument(idSuffix: 3, type: .invoice, role: .resident, path: "b.pdf")
        let invoiceA = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident, path: "a.pdf")
        let payment = try fixture.relationshipDocument(idSuffix: 4, type: .paymentConfirmation)
        let a = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoiceA, payment: payment)
        let bBase = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoiceB, payment: payment)
        let b = try PersonDossierFixture.invoicePaymentCandidate(
            invoice: invoiceB, payment: payment, signals: Array(bBase.signals.reversed())
        )
        let decisions = try Dictionary(uniqueKeysWithValues: [a, b].map {
            try PersonDossierFixture.relationshipDecision(for: $0)
        })
        let forward = try PersonDossierProjector().project(fixture.input(
            documents: [invoiceB, payment, invoiceA], personCandidates: [invoiceB, invoiceA],
            relationshipCandidates: [b, a], relationshipDecisionsByKey: decisions
        ))
        let reverse = try PersonDossierProjector().project(fixture.input(
            documents: [invoiceA, payment, invoiceB], personCandidates: [invoiceA, invoiceB],
            relationshipCandidates: [a, b], relationshipDecisionsByKey: decisions
        ))
        let supports = forward.costsAndPayments.first { $0.id == payment.document.id }?.supports
            .compactMap(\.confirmedPaymentValue)

        #expect(supports?.map(\.invoiceDocumentID) == [invoiceA.document.id, invoiceB.document.id])
        #expect(supports?.allSatisfy { $0.signals.map(\.kind) == [
            .referenceNumber, .monetaryAmount, .organization,
        ] } == true)
        #expect(reverse == forward)
    }

    @Test func relationshipOnlyPaymentNeverBecomesPersonSuggestion() throws {
        let fixture = try PersonProjectorFixture.make()
        let invoice = try fixture.relationshipDocument(idSuffix: 2, type: .invoice, role: .resident)
        let payment = try fixture.relationshipDocument(idSuffix: 3, type: .paymentConfirmation)
        let candidate = try PersonDossierFixture.invoicePaymentCandidate(invoice: invoice, payment: payment)
        let excluded = try PersonDossierFixture.relationshipDecision(for: candidate, decision: .excluded)

        for decisions in [[:], [excluded.0: excluded.1]] {
            let snapshot = try PersonDossierProjector().project(fixture.input(
                documents: [invoice, payment], personCandidates: [invoice],
                relationshipCandidates: [candidate], relationshipDecisionsByKey: decisions
            ))
            #expect(snapshot.suggestions.isEmpty)
            #expect(snapshot.costsAndPayments.map(\.id) == [invoice.document.id])
        }
    }
}

private struct PersonProjectorFixture {
    let sourceID = UUID(uuidString: "74000000-0000-0000-0000-000000000010")!
    let origin: CurrentDocumentDNA
    let anchor: PersonDossierAnchor
    let dossier: DossierRecord

    static func make(birthDate: PersonDossierBirthDate? = nil) throws -> Self {
        let sourceID = UUID(uuidString: "74000000-0000-0000-0000-000000000010")!
        let finding = try PersonDossierFixture.personFinding(role: .resident)
        let origin = try PersonDossierFixture.currentDocument(
            id: UUID(uuidString: "74000000-0000-0000-0000-000000000001")!,
            sourceRootID: sourceID,
            path: "origin.pdf",
            contentHash: "origin-hash",
            extractionVersion: "text-v1",
            schemaVersion: 7,
            analyzerIdentifier: "rules",
            analyzerVersion: "9",
            personFindings: [finding]
        )
        let anchor = try PersonDossierAnchor(
            id: UUID(uuidString: "74000000-0000-0000-0000-000000000020")!,
            displayName: finding.displayValue,
            normalizedName: finding.normalizedValue,
            primaryRole: .resident,
            originDocumentID: origin.document.id,
            originContentHash: origin.snapshot.inputContentHash,
            originExtractionVersion: origin.snapshot.inputExtractionVersion,
            originDNASchemaVersion: origin.snapshot.schemaVersion,
            originDNAAnalyzerIdentifier: origin.snapshot.analyzerIdentifier,
            originDNAAnalyzerVersion: origin.snapshot.analyzerVersion,
            originDNAAnalyzedAt: origin.snapshot.analyzedAt,
            personEvidence: finding.evidence,
            birthDate: birthDate,
            createdAt: PersonDossierFixture.date,
            updatedAt: PersonDossierFixture.date
        )
        let dossier = try DossierRecord(
            id: UUID(uuidString: "74000000-0000-0000-0000-000000000030")!,
            kind: .personMatter,
            displayName: "Person matter",
            anchor: .person(anchor),
            createdAt: PersonDossierFixture.date,
            updatedAt: PersonDossierFixture.date
        )
        return Self(origin: origin, anchor: anchor, dossier: dossier)
    }

    func candidate(
        idSuffix: Int,
        role: PersonDossierRole,
        type: DocumentType = .correspondence,
        path: String? = nil,
        sourceRootID: UUID? = nil
    ) throws -> CurrentDocumentDNA {
        let id = UUID(uuidString: String(format: "74000000-0000-0000-0000-%012d", idSuffix))!
        return try PersonDossierFixture.currentDocument(
            id: id,
            sourceRootID: sourceRootID ?? sourceID,
            path: path ?? "candidate-\(idSuffix).pdf",
            documentType: type,
            personFindings: [try PersonDossierFixture.personFinding(role: role)]
        )
    }

    func relationshipDocument(
        idSuffix: Int,
        type: DocumentType,
        role: PersonDossierRole? = nil,
        path: String? = nil
    ) throws -> CurrentDocumentDNA {
        let id = UUID(uuidString: String(format: "74000000-0000-0000-0000-%012d", idSuffix))!
        return try PersonDossierFixture.invoicePaymentDocument(
            id: id,
            sourceRootID: sourceID,
            path: path ?? "relationship-\(idSuffix).pdf",
            documentType: type,
            analyzedAt: PersonDossierFixture.date.addingTimeInterval(TimeInterval(idSuffix)),
            personFindings: try role.map { [try PersonDossierFixture.personFinding(role: $0)] } ?? []
        )
    }

    func relationshipVariant(
        _ current: CurrentDocumentDNA,
        documentType: DocumentType? = nil,
        analyzerVersion: String? = nil,
        additionalFindings: [DocumentDNAFinding] = []
    ) throws -> CurrentDocumentDNA {
        try PersonDossierFixture.currentDocument(
            id: current.document.id,
            sourceRootID: current.document.sourceRootID,
            path: current.document.relativePath,
            documentType: documentType ?? current.documentType ?? .unknown,
            availability: current.document.availability,
            contentHash: current.document.contentHash,
            extractionVersion: current.snapshot.inputExtractionVersion,
            schemaVersion: current.snapshot.schemaVersion,
            analyzerIdentifier: current.snapshot.analyzerIdentifier,
            analyzerVersion: analyzerVersion ?? current.snapshot.analyzerVersion,
            analyzedAt: current.snapshot.analyzedAt,
            personFindings: Array(current.snapshot.findings.dropFirst()) + additionalFindings
        )
    }

    func staleOrigin(
        mutation: OriginTokenMutation? = nil
    ) throws -> CurrentDocumentDNA {
        let changedSourceID = UUID(
            uuidString: "74000000-0000-0000-0000-000000000013"
        )!
        return try PersonDossierFixture.currentDocument(
            id: origin.document.id,
            sourceRootID: mutation == .source ? changedSourceID : origin.document.sourceRootID,
            path: mutation == .path ? "moved/origin.pdf" : origin.document.relativePath,
            documentType: .correspondence,
            availability: mutation == .availability ? .missing : .available,
            contentHash: mutation == .content ? "changed-origin-hash" : origin.document.contentHash,
            extractionVersion: origin.snapshot.inputExtractionVersion,
            schemaVersion: origin.snapshot.schemaVersion,
            analyzerIdentifier: origin.snapshot.analyzerIdentifier,
            analyzerVersion: "stale-analyzer-version",
            analyzedAt: mutation == .analysis
                ? origin.snapshot.analyzedAt.addingTimeInterval(2)
                : origin.snapshot.analyzedAt.addingTimeInterval(1),
            personFindings: [try PersonDossierFixture.personFinding(role: .resident)]
        )
    }

    func candidate(
        idSuffix: Int,
        type: DocumentType = .correspondence,
        path: String? = nil,
        sourceRootID: UUID? = nil,
        roles: [DocumentDNAFinding]
    ) throws -> CurrentDocumentDNA {
        let id = UUID(uuidString: String(format: "74000000-0000-0000-0000-%012d", idSuffix))!
        return try PersonDossierFixture.currentDocument(
            id: id,
            sourceRootID: sourceRootID ?? sourceID,
            path: path ?? "candidate-\(idSuffix).pdf",
            documentType: type,
            personFindings: roles
        )
    }

    func confirmation(
        for current: CurrentDocumentDNA,
        dossierID: UUID? = nil,
        kind: PersonDossierCandidateKind = .secondaryRole,
        role: PersonDossierRole = .authorizedPerson,
        revisionID: UUID = UUID(uuidString: "74000000-0000-0000-0000-000000000040")!
    ) throws -> DossierMembershipConfirmation {
        try DossierMembershipConfirmation(
            dossierID: dossierID ?? dossier.id,
            documentID: current.document.id,
            revisionID: revisionID,
            confirmedAt: PersonDossierFixture.date,
            candidateKind: kind,
            acceptedContentHash: current.snapshot.inputContentHash,
            acceptedExtractionVersion: current.snapshot.inputExtractionVersion,
            acceptedDNASchemaVersion: current.snapshot.schemaVersion,
            acceptedDNAAnalyzerIdentifier: current.snapshot.analyzerIdentifier,
            acceptedDNAAnalyzerVersion: current.snapshot.analyzerVersion,
            acceptedDNAAnalyzedAt: current.snapshot.analyzedAt,
            acceptedRole: role,
            acceptedNormalizedName: anchor.normalizedName
        )
    }

    func exclusion(
        for current: CurrentDocumentDNA,
        dossierID: UUID? = nil,
        revisionID: UUID = UUID(uuidString: "74000000-0000-0000-0000-000000000050")!
    ) -> DossierMembershipExclusion {
        DossierMembershipExclusion(
            dossierID: dossierID ?? dossier.id,
            documentID: current.document.id,
            revisionID: revisionID,
            excludedAt: PersonDossierFixture.date
        )
    }

    func input(
        dossier: DossierRecord? = nil,
        originDocument: DocumentRecord?? = nil,
        currentOrigin: CurrentDocumentDNA?? = nil,
        documentsByID: [UUID: DocumentRecord]? = nil,
        currentDocumentsByID: [UUID: CurrentDocumentDNA]? = nil,
        documents: [CurrentDocumentDNA] = [],
        personCandidates: [CurrentDocumentDNA]? = nil,
        relationshipCandidates: [InvoicePaymentCandidate] = [],
        relationshipDecisionsByKey: [InvoicePaymentDecisionKey: InvoicePaymentDecisionRecord] = [:],
        confirmations: [DossierMembershipConfirmation] = [],
        exclusions: [DossierMembershipExclusion] = [],
        sourceDisplayNames: [UUID: String]? = nil
    ) -> PersonDossierProjectionInput {
        let all = [origin] + documents
        return PersonDossierProjectionInput(
            dossier: dossier ?? self.dossier,
            originDocument: originDocument ?? origin.document,
            currentOrigin: currentOrigin ?? origin,
            documentsByID: documentsByID ?? Dictionary(
                uniqueKeysWithValues: all.map { ($0.document.id, $0.document) }
            ),
            currentDocumentsByID: currentDocumentsByID ?? Dictionary(
                uniqueKeysWithValues: all.map { ($0.document.id, $0) }
            ),
            personCandidates: personCandidates ?? documents,
            relationshipCandidates: relationshipCandidates,
            relationshipDecisionsByKey: relationshipDecisionsByKey,
            sourceDisplayNames: sourceDisplayNames ?? [sourceID: "Archive"],
            confirmations: confirmations,
            exclusions: exclusions
        )
    }
}

private extension DocumentAvailability {
    static let allCasesForProjectionTest: [Self] = [.available, .unavailable, .missing]
}

private extension PersonDossierMembershipSupport {
    var exactPrimaryRole: PersonDossierRole? {
        guard case let .exactPrimary(support) = self else { return nil }
        return support.role
    }


    var confirmedPaymentValue: PersonDossierPaymentSupportIdentity? {
        guard case let .confirmedPayment(support) = self else { return nil }
        return support
    }
}

enum OriginTokenMutation: CaseIterable {
    case content
    case analysis
    case availability
    case path
    case source
}
