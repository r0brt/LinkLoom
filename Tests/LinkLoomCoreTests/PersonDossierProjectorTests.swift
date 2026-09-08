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
            relationshipCandidates: [],
            relationshipDecisionsByKey: [:],
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
}

enum OriginTokenMutation: CaseIterable {
    case content
    case analysis
    case availability
    case path
    case source
}
