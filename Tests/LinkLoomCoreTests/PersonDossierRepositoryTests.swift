import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Person dossier repository")
struct PersonDossierRepositoryTests {
    @Test func loadsCompleteSnapshotWithBoundedIndexedReads() async throws {
        let values = try await PersistedPersonDossierScenario.make()
        let trace = PersonDossierRepositorySQLTrace()
        try await values.fixture.database.write { db in
            db.trace(options: .statement) { event in trace.record(event) }
        }
        trace.reset()

        let actual = try await values.repository.personDossierSnapshot(
            id: values.dossier.id
        )
        let statements = trace.statements
        try await values.fixture.database.write { db in db.trace(options: []) }

        let candidateProjector = InvoicePaymentCandidateProjector()
        let relationshipCandidates = candidateProjector.candidates(
            from: InvoicePaymentCandidateProjectionInput(
                selected: values.invoice,
                matchesByNormalizedReference: [
                    values.includedReference: [
                        values.invoice, values.payment, values.rejectedPayment,
                    ],
                ]
            )
        )
        var expectedDocumentsByID = Dictionary(uniqueKeysWithValues: [
            values.origin, values.direct, values.suggestion, values.invoice,
            values.payment, values.excludedInvoice,
        ].map { ($0.document.id, $0.document) })
        expectedDocumentsByID[values.manualDocument.id] = values.manualDocument
        let expected = try PersonDossierProjector().project(
            PersonDossierProjectionInput(
                dossier: values.dossier,
                originDocument: values.origin.document,
                currentOrigin: values.origin,
                documentsByID: expectedDocumentsByID,
                currentDocumentsByID: Dictionary(uniqueKeysWithValues: [
                    values.origin, values.direct, values.suggestion, values.invoice,
                    values.payment, values.excludedInvoice,
                ].map { ($0.document.id, $0) }),
                personCandidates: [
                    values.origin, values.direct, values.suggestion, values.invoice,
                ],
                relationshipCandidates: relationshipCandidates,
                relationshipDecisionsByKey: [
                    values.relationshipDecision.key: values.relationshipDecision,
                ],
                sourceDisplayNames: values.sourceDisplayNames,
                confirmations: [values.confirmation],
                exclusions: [values.exclusion]
            )
        )

        #expect(actual == expected)
        #expect(actual.origin.validity == .current)
        #expect(Set(actual.directMembers.map(\.document.id)) == Set([
            values.origin.document.id,
            values.direct.document.id,
            values.manualDocument.id,
        ]))
        #expect(Set(actual.costsAndPayments.map(\.document.id)) == Set([
            values.invoice.document.id,
            values.payment.document.id,
        ]))
        #expect(actual.suggestions.map(\.document.id) == [values.suggestion.document.id])
        #expect(actual.corrections.map(\.document.id) == [
            values.manualDocument.id,
            values.excludedInvoice.document.id,
        ])

        let personReads = statements.filter {
            $0.contains("INDEXED BY document_dna_finding_kind_value")
                && $0.contains("finding.kind = 'person'")
        }
        let referenceReads = statements.filter {
            $0.contains("INDEXED BY document_dna_finding_kind_value")
                && $0.contains("referenceNumber")
        }
        #expect(personReads.count == 1)
        #expect(
            referenceReads.count == 1,
            "Indexed finding statements: \(statements.filter { $0.contains("INDEXED BY document_dna_finding_kind_value") })"
        )
        if let referenceRead = referenceReads.first {
            #expect(referenceRead.contains(values.includedReference))
        }
        #expect(!statements.contains { $0.contains(values.excludedReference) })
        #expect(!statements.contains { $0.contains(values.unrelatedReference) })

        let reconstructedIDs = statements.compactMap(
            PersonDossierRepositorySQLTrace.reconstructedDocumentID
        )
        let permittedReconstructionIDs = Set([
            values.origin.document.id,
            values.direct.document.id,
            values.suggestion.document.id,
            values.invoice.document.id,
            values.payment.document.id,
            values.rejectedPayment.document.id,
            values.excludedInvoice.document.id,
        ])
        #expect(!reconstructedIDs.isEmpty)
        #expect(reconstructedIDs.allSatisfy(permittedReconstructionIDs.contains))
        #expect(Dictionary(grouping: reconstructedIDs, by: { $0 }).mapValues(\.count) == [
            values.origin.document.id: 1,
            values.direct.document.id: 1,
            values.suggestion.document.id: 1,
            values.invoice.document.id: 2,
            values.payment.document.id: 1,
            values.rejectedPayment.document.id: 1,
            values.excludedInvoice.document.id: 1,
        ])
        #expect(!reconstructedIDs.contains(values.unrelatedInvoice.document.id))
        #expect(!reconstructedIDs.contains(values.unrelatedPayment.document.id))

        for sourceID in values.sourceDisplayNames.keys {
            #expect(statements.count {
                $0.contains("SELECT displayName FROM sourceRoot WHERE id")
                    && $0.contains(sourceID.sqliteHexLiteral)
            } == 1)
        }

        let decisionReads = statements.filter {
            $0.contains("WITH requested")
                && $0.contains("invoicePaymentUserDecision AS userDecision")
        }
        #expect(decisionReads.count == 1)
        #expect(decisionReads[0].contains(values.invoice.document.id.sqliteHexLiteral))
        #expect(decisionReads[0].contains(values.payment.document.id.sqliteHexLiteral))
        #expect(!decisionReads[0].contains(values.unrelatedInvoice.document.id.sqliteHexLiteral))
        #expect(!decisionReads[0].contains(values.unrelatedPayment.document.id.sqliteHexLiteral))
    }

    @Test func typedSummariesSurviveOriginDeletionAndExcludeCostsDossiers() async throws {
        let values = try await PersistedPersonDossierScenario.make()
        try await values.fixture.database.write { db in
            try db.execute(
                sql: "DELETE FROM document WHERE id = ?",
                arguments: [values.origin.document.id]
            )
        }

        let summaries = try await values.repository.personDossierSummaries()
        let snapshot = try await values.repository.personDossierSnapshot(id: values.dossier.id)

        #expect(summaries == [PersonDossierSummary(
            dossier: values.dossier,
            anchor: values.anchor
        )])
        #expect(snapshot.origin.validity == .unavailable)
        #expect(snapshot.origin.document == nil)
    }

    @Test func personSnapshotRejectsMissingAndCostsDossierIDs() async throws {
        let values = try await PersistedPersonDossierScenario.make()

        await #expect(throws: DossierRepositoryError.dossierNotFound) {
            try await values.repository.personDossierSnapshot(
                id: PersonDossierFixture.repositoryUUID(999)
            )
        }
        await #expect(throws: DossierRepositoryError.invalidStoredState) {
            try await values.repository.personDossierSnapshot(id: values.costsDossier.id)
        }
    }

    @Test func currentSelectionValidationRejectsMissingAndChangedSupportWithoutWrites() async throws {
        let fixture = try await PersonDossierFixture.make()
        let repository = fixture.makeDossierRepository()
        let missingFinding = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
        let missing = try PersonDossierFixture.currentDocument(
            id: PersonDossierFixture.repositoryUUID(200),
            sourceRootID: fixture.source.id,
            path: "missing.pdf",
            personFindings: [missingFinding]
        )
        let missingSelection = try fixture.selection(current: missing, finding: missingFinding)

        for operation in PersonRepositoryOperation.allCases {
            await #expect(throws: DossierRepositoryError.invalidAnchor) {
                try await operation.run(repository: repository, selection: missingSelection)
            }
        }

        let currentFinding = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
        let current = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(201),
            path: "current.pdf",
            findings: [currentFinding],
            documentType: .correspondence,
            analyzedAt: PersonDossierFixture.repositoryDate(201)
        )
        let changedFinding = try fixture.finding(
            kind: .person,
            qualifier: PersonDossierRole.insuredPerson.rawValue,
            displayValue: "Elise Muster",
            normalizedValue: "elise muster"
        )
        let changedName = try fixture.personFinding(
            normalizedName: "elise other",
            qualifier: PersonDossierRole.resident.rawValue
        )
        let changedDisplay = try fixture.finding(
            kind: .person,
            qualifier: PersonDossierRole.resident.rawValue,
            displayValue: "Elise M.",
            normalizedValue: "elise muster"
        )
        let changedEvidence = try PersonDossierFixture.personFinding(
            role: .resident,
            evidence: [try PersonDossierFixture.evidence(
                displayText: "Elise Muster",
                pageIndex: 1
            )]
        )
        let variants: [(DocumentDNAFinding, String?, String, Int, String, String, Date)] = [
            (changedFinding, nil, "text-v1", 1, "local-rules", "1", current.snapshot.analyzedAt),
            (changedName, nil, "text-v1", 1, "local-rules", "1", current.snapshot.analyzedAt),
            (changedDisplay, nil, "text-v1", 1, "local-rules", "1", current.snapshot.analyzedAt),
            (changedEvidence, nil, "text-v1", 1, "local-rules", "1", current.snapshot.analyzedAt),
            (currentFinding, "changed-hash", "text-v1", 1, "local-rules", "1", current.snapshot.analyzedAt),
            (currentFinding, nil, "text-v2", 1, "local-rules", "1", current.snapshot.analyzedAt),
            (currentFinding, nil, "text-v1", 2, "local-rules", "1", current.snapshot.analyzedAt),
            (currentFinding, nil, "text-v1", 1, "other-rules", "1", current.snapshot.analyzedAt),
            (currentFinding, nil, "text-v1", 1, "local-rules", "2", current.snapshot.analyzedAt),
            (currentFinding, nil, "text-v1", 1, "local-rules", "1", current.snapshot.analyzedAt.addingTimeInterval(1)),
        ]
        for (finding, contentHash, extraction, schema, identifier, version, analyzedAt) in variants {
            let alternate = try PersonDossierFixture.currentDocument(
                id: current.document.id,
                sourceRootID: current.document.sourceRootID,
                path: current.document.relativePath,
                contentHash: contentHash ?? current.document.contentHash,
                extractionVersion: extraction,
                schemaVersion: schema,
                analyzerIdentifier: identifier,
                analyzerVersion: version,
                analyzedAt: analyzedAt,
                personFindings: [finding]
            )
            let selection = try fixture.selection(current: alternate, finding: finding)
            for operation in PersonRepositoryOperation.allCases {
                await #expect(throws: DossierRepositoryError.staleInput) {
                    try await operation.run(repository: repository, selection: selection)
                }
            }
        }
        try await fixture.database.write { db in
            try db.execute(
                sql: "UPDATE documentDNA SET analyzerVersion = 'not-target' WHERE documentID = ?",
                arguments: [current.document.id]
            )
        }
        let currentSelection = try fixture.selection(current: current, finding: currentFinding)
        for operation in PersonRepositoryOperation.allCases {
            await #expect(throws: DossierRepositoryError.invalidAnchor) {
                try await operation.run(repository: repository, selection: currentSelection)
            }
        }
        #expect(try await fixture.personPersistenceCounts() == (0, 0))
    }

    @Test func removedFindingIsStaleButAvailabilityDoesNotInvalidateStoredSupport() async throws {
        let fixture = try await PersonDossierFixture.make()
        let repository = fixture.makeDossierRepository()
        let finding = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
        let current = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(210),
            path: "availability.pdf",
            findings: [finding],
            documentType: .correspondence
        )
        let selection = try fixture.selection(current: current, finding: finding)

        for availability in [DocumentAvailability.unavailable, .missing] {
            try await fixture.setAvailability(availability, for: current.document.id)
            #expect(try await repository.personDossierEntryDisposition(for: selection) == .create)
        }

        try await fixture.setAvailability(.available, for: current.document.id)
        try await fixture.repository.replace(try DocumentDNA(
            documentID: current.document.id,
            schemaVersion: current.snapshot.schemaVersion,
            analyzerIdentifier: current.snapshot.analyzerIdentifier,
            analyzerVersion: current.snapshot.analyzerVersion,
            inputContentHash: current.snapshot.inputContentHash,
            inputExtractionVersion: current.snapshot.inputExtractionVersion,
            findings: current.snapshot.findings.filter { $0.kind != .person },
            analyzedAt: current.snapshot.analyzedAt
        ))
        for operation in PersonRepositoryOperation.allCases {
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await operation.run(repository: repository, selection: selection)
            }
        }
        #expect(try await fixture.personPersistenceCounts() == (0, 0))
    }

    @Test func createsCompletePersonDossierWithExactSupportAndConservativeBirthDate() async throws {
        let fixture = try await PersonDossierFixture.make()
        let repository = fixture.makeDossierRepository(sequence: 300)
        let person = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
        let birthDate = try fixture.birthDateFinding(normalizedValue: "1940-02-01")
        let current = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(301),
            path: "create.pdf",
            findings: [person, birthDate],
            documentType: .correspondence,
            analyzedAt: PersonDossierFixture.repositoryDate(301)
        )
        let selection = try fixture.selection(current: current, finding: person)

        #expect(try await repository.personDossierEntryDisposition(for: selection) == .create)
        let result = try await repository.createOrOpenPersonDossier(from: selection)
        guard case .opened(let snapshot) = result else {
            Issue.record("Expected a newly opened person dossier")
            return
        }

        #expect(snapshot.dossier.displayName == "Meine Mutter im Pflegeheim")
        #expect(snapshot.anchor.displayName == person.displayValue)
        #expect(snapshot.anchor.normalizedName == selection.support.normalizedName)
        #expect(snapshot.anchor.primaryRole == selection.support.role)
        #expect(snapshot.anchor.originDocumentID == selection.support.documentID)
        #expect(snapshot.anchor.originContentHash == selection.support.contentHash)
        #expect(snapshot.anchor.originExtractionVersion == selection.support.extractionVersion)
        #expect(snapshot.anchor.originDNASchemaVersion == selection.support.dnaSchemaVersion)
        #expect(snapshot.anchor.originDNAAnalyzerIdentifier == selection.support.dnaAnalyzerIdentifier)
        #expect(snapshot.anchor.originDNAAnalyzerVersion == selection.support.dnaAnalyzerVersion)
        #expect(snapshot.anchor.originDNAAnalyzedAt == selection.support.dnaAnalyzedAt)
        #expect(snapshot.anchor.personEvidence == selection.support.finding.evidence)
        let expectedBirthDate = try PersonDossierBirthDate(
            displayValue: birthDate.displayValue,
            normalizedValue: birthDate.normalizedValue,
            evidence: birthDate.evidence
        )
        #expect(snapshot.anchor.birthDate == expectedBirthDate)
        #expect(snapshot.origin.validity == .current)
        #expect(snapshot.directMembers.map(\.document.id).contains(current.document.id))
        #expect(try await fixture.personPersistenceCounts() == (1, 1))
    }

    @Test func ambiguousOrAbsentBirthDateIsNotCaptured() async throws {
        for variant in 0..<3 {
            let fixture = try await PersonDossierFixture.make()
            let repository = fixture.makeDossierRepository(sequence: 320 + variant * 10)
            let person = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
            var findings = [person]
            if variant == 0 {
                findings.append(try fixture.personFinding(
                    normalizedName: "other person",
                    qualifier: PersonDossierRole.insuredPerson.rawValue
                ))
                findings.append(try fixture.birthDateFinding(normalizedValue: "1940-02-01"))
            } else if variant == 2 {
                findings.append(try fixture.birthDateFinding(normalizedValue: "1940-02-01"))
                findings.append(try fixture.birthDateFinding(
                    displayValue: "02.03.1941",
                    normalizedValue: "1941-03-02"
                ))
            }
            let current = try await fixture.insertSnapshot(
                id: PersonDossierFixture.repositoryUUID(321 + variant * 10),
                path: "birth-\(variant).pdf",
                findings: findings,
                documentType: .correspondence
            )
            let result = try await repository.createOrOpenPersonDossier(
                from: fixture.selection(current: current, finding: person)
            )
            guard case .opened(let snapshot) = result else {
                Issue.record("Expected creation for birth-date variant \(variant)")
                continue
            }
            #expect(snapshot.anchor.birthDate == nil)
        }
    }

    @Test func repeatedAndConcurrentCreationConvergeOnOneStableOrigin() async throws {
        let fixture = try await PersonDossierFixture.make()
        let finding = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
        let current = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(360),
            path: "converge.pdf",
            findings: [finding],
            documentType: .correspondence
        )
        let selection = try fixture.selection(current: current, finding: finding)
        let firstRepository = fixture.makeDossierRepository(sequence: 361)
        let secondRepository = fixture.makeDossierRepository(sequence: 371)

        async let first = firstRepository.createOrOpenPersonDossier(from: selection)
        async let second = secondRepository.createOrOpenPersonDossier(from: selection)
        let results = try await [first, second]
        let ids = results.compactMap { result -> UUID? in
            guard case .opened(let snapshot) = result else { return nil }
            return snapshot.dossier.id
        }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 1)
        guard case .opened(let repeated) = try await firstRepository
            .createOrOpenPersonDossier(from: selection) else {
            Issue.record("Expected repeated open")
            return
        }
        #expect(repeated.dossier.id == ids[0])
        #expect(try await fixture.personPersistenceCounts() == (1, 1))
    }

    @Test func stableOriginWinsWhileSameNameRequiresExplicitChoice() async throws {
        let fixture = try await PersonDossierFixture.make()
        let finding = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
        let first = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(400),
            path: "first-homonym.pdf",
            findings: [finding],
            documentType: .correspondence
        )
        let second = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(401),
            path: "second-homonym.pdf",
            findings: [finding],
            documentType: .correspondence
        )
        let repository = fixture.makeDossierRepository(sequence: 410)
        guard case .opened(let existing) = try await repository.createOrOpenPersonDossier(
            from: fixture.selection(current: first, finding: finding)
        ) else {
            Issue.record("Expected first dossier creation")
            return
        }
        let secondSelection = try fixture.selection(current: second, finding: finding)
        let before = try await fixture.personPersistenceCounts()
        guard case .choose(let oneChoice) = try await repository
            .personDossierEntryDisposition(for: secondSelection),
              case .choose(let writeChoices) = try await repository
            .createOrOpenPersonDossier(from: secondSelection) else {
            Issue.record("Expected even one same-name match to require choice")
            return
        }
        #expect(oneChoice.map(\.id) == [existing.dossier.id])
        #expect(writeChoices.map(\.id) == [existing.dossier.id])
        #expect(try await fixture.personPersistenceCounts() == before)

        let explicit = try await repository.chooseOrCreatePersonDossier(
            from: secondSelection,
            choice: .new
        )
        #expect(explicit.dossier.id != existing.dossier.id)
        #expect(try await fixture.personPersistenceCounts() == (2, 2))
        let stable = try await repository.personDossierEntryDisposition(
            for: fixture.selection(current: first, finding: finding)
        )
        #expect(stable == .open(PersonDossierSummary(
            dossier: existing.dossier,
            anchor: existing.anchor
        )))
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.chooseOrCreatePersonDossier(
                from: secondSelection,
                choice: .existing(dossierID: existing.dossier.id)
            )
        }
    }

    @Test func sameNameChoicesReturnEverySummaryInDeterministicAnchorOrder() async throws {
        let fixture = try await PersonDossierFixture.make()
        let finding = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
        let first = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(430),
            path: "choice-first.pdf",
            findings: [finding],
            documentType: .correspondence
        )
        let second = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(431),
            path: "choice-second.pdf",
            findings: [finding],
            documentType: .correspondence
        )
        let selected = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(432),
            path: "choice-selected.pdf",
            findings: [finding],
            documentType: .correspondence
        )
        let (_, late) = try await fixture.insertPersonDossier(
            sequence: 440,
            origin: first,
            finding: finding
        )
        let (_, early) = try await fixture.insertPersonDossier(
            sequence: 420,
            origin: second,
            finding: finding
        )
        let repository = fixture.makeDossierRepository()
        let selection = try fixture.selection(current: selected, finding: finding)
        guard case .choose(let choices) = try await repository
            .personDossierEntryDisposition(for: selection) else {
            Issue.record("Expected deterministic homonym choices")
            return
        }
        #expect(choices.map(\.id) == [early.id, late.id])
        #expect(try await fixture.personPersistenceCounts() == (2, 2))
    }

    @Test func explicitExistingMustRemainInCurrentChoiceSet() async throws {
        let fixture = try await PersonDossierFixture.make()
        let finding = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
        let existingOrigin = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(450),
            path: "existing.pdf",
            findings: [finding],
            documentType: .correspondence
        )
        let repository = fixture.makeDossierRepository(sequence: 451)
        guard case .opened(let existing) = try await repository.createOrOpenPersonDossier(
            from: fixture.selection(current: existingOrigin, finding: finding)
        ) else {
            Issue.record("Expected setup dossier")
            return
        }
        let newOrigin = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(460),
            path: "choice.pdf",
            findings: [finding],
            documentType: .correspondence
        )
        let selection = try fixture.selection(current: newOrigin, finding: finding)
        let opened = try await repository.chooseOrCreatePersonDossier(
            from: selection,
            choice: .existing(dossierID: existing.dossier.id)
        )
        #expect(opened.dossier.id == existing.dossier.id)

        for dossierID in [
            PersonDossierFixture.repositoryUUID(999),
            existing.dossier.id,
        ] {
            let foreignFinding = try fixture.personFinding(
                normalizedName: dossierID == existing.dossier.id ? "other person" : "elise muster",
                qualifier: PersonDossierRole.resident.rawValue
            )
            let foreign = try await fixture.insertSnapshot(
                id: UUID(),
                path: "foreign-\(UUID().uuidString).pdf",
                findings: [foreignFinding],
                documentType: .correspondence
            )
            let foreignSelection = try fixture.selection(current: foreign, finding: foreignFinding)
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.chooseOrCreatePersonDossier(
                    from: foreignSelection,
                    choice: .existing(dossierID: dossierID)
                )
            }
        }
        #expect(try await fixture.personPersistenceCounts() == (1, 1))
    }

    @Test func orphanedOrWrongKindStableAnchorIsInvalidStoredState() async throws {
        for wrongKind in [false, true] {
            let fixture = try await PersonDossierFixture.make()
            let finding = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
            let current = try await fixture.insertSnapshot(
                id: UUID(),
                path: "invalid-stored-\(wrongKind).pdf",
                findings: [finding],
                documentType: .correspondence
            )
            let anchor = try fixture.makePersonAnchor(
                sequence: wrongKind ? 501 : 500,
                origin: current,
                finding: finding
            )
            try await fixture.database.write { db in
                _ = try PersonDossierAnchorStore.insertOrFetch(in: db, proposed: anchor)
                if wrongKind {
                    try db.execute(sql: "PRAGMA ignore_check_constraints = TRUE")
                    try db.execute(
                        sql: """
                            INSERT INTO dossier (
                                id, kind, displayName, anchorDocumentID, personAnchorID,
                                createdAt, updatedAt
                            ) VALUES (?, ?, 'wrong kind', NULL, ?, ?, ?)
                            """,
                        arguments: [
                            UUID(), DossierKind.costsAndPayments.rawValue, anchor.id,
                            PersonDossierFixture.date, PersonDossierFixture.date,
                        ]
                    )
                    try db.execute(sql: "PRAGMA ignore_check_constraints = FALSE")
                }
            }
            let repository = fixture.makeDossierRepository()
            let selection = try fixture.selection(current: current, finding: finding)
            await #expect(throws: DossierRepositoryError.invalidStoredState) {
                try await repository.personDossierEntryDisposition(for: selection)
            }
        }
    }

    @Test func costsDossierIsInvisibleToPersonChoiceAndCreationRollbackIsAtomic() async throws {
        let fixture = try await PersonDossierFixture.make()
        let person = try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)
        let current = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(550),
            path: "costs-invisible.pdf",
            findings: [person],
            documentType: .invoice
        )
        let costs = try DossierRecord(
            id: PersonDossierFixture.repositoryUUID(551),
            kind: .costsAndPayments,
            displayName: "Costs",
            anchor: .document(current.document.id),
            createdAt: PersonDossierFixture.date,
            updatedAt: PersonDossierFixture.date
        )
        try await fixture.database.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: costs)
        }
        let repository = fixture.makeDossierRepository(sequence: 552)
        let selection = try fixture.selection(current: current, finding: person)
        #expect(try await repository.personDossierEntryDisposition(for: selection) == .create)
        #expect(try await repository.personDossierSummaries().isEmpty)
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.chooseOrCreatePersonDossier(
                from: selection,
                choice: .existing(dossierID: costs.id)
            )
        }

        try await fixture.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER abort_person_dossier_insert
                BEFORE INSERT ON dossier
                WHEN NEW.kind = 'personMatter'
                BEGIN
                    SELECT RAISE(ABORT, 'test person dossier insertion failure');
                END
                """)
        }
        do {
            _ = try await repository.createOrOpenPersonDossier(from: selection)
            Issue.record("Expected SQLite trigger failure")
        } catch is DatabaseError {
            // The unexpected storage error must cross the repository boundary unchanged.
        } catch {
            Issue.record("Expected DatabaseError, got \(error)")
        }
        #expect(try await fixture.personPersistenceCounts() == (0, 0))
    }
}

private enum PersonRepositoryOperation: CaseIterable {
    case disposition
    case createOrOpen
    case chooseNew

    func run(
        repository: DossierRepository,
        selection: PersonDossierAnchorSelection
    ) async throws {
        switch self {
        case .disposition:
            _ = try await repository.personDossierEntryDisposition(for: selection)
        case .createOrOpen:
            _ = try await repository.createOrOpenPersonDossier(from: selection)
        case .chooseNew:
            _ = try await repository.chooseOrCreatePersonDossier(
                from: selection,
                choice: .new
            )
        }
    }
}

private struct PersistedPersonDossierScenario: Sendable {
    let fixture: PersonDossierFixture
    let repository: DossierRepository
    let anchor: PersonDossierAnchor
    let dossier: DossierRecord
    let costsDossier: DossierRecord
    let origin: CurrentDocumentDNA
    let direct: CurrentDocumentDNA
    let suggestion: CurrentDocumentDNA
    let invoice: CurrentDocumentDNA
    let payment: CurrentDocumentDNA
    let rejectedPayment: CurrentDocumentDNA
    let manualDocument: DocumentRecord
    let excludedInvoice: CurrentDocumentDNA
    let unrelatedInvoice: CurrentDocumentDNA
    let unrelatedPayment: CurrentDocumentDNA
    let confirmation: DossierMembershipConfirmation
    let exclusion: DossierMembershipExclusion
    let relationshipDecision: InvoicePaymentDecisionRecord
    let sourceDisplayNames: [UUID: String]
    let includedReference: String
    let excludedReference: String
    let unrelatedReference: String

    static func make() async throws -> Self {
        let fixture = try await PersonDossierFixture.make()
        let south = try await fixture.insertSource(sequence: 2, displayName: "South Archive")
        let bank = try await fixture.insertSource(sequence: 3, displayName: "Bank Feed")
        let includedReference = "INV100"
        let excludedReference = "EXC200"
        let unrelatedReference = "UNR400"

        func person(_ role: PersonDossierRole, name: String = "elise muster") throws
            -> DocumentDNAFinding
        {
            try fixture.finding(
                kind: .person,
                qualifier: role.rawValue,
                displayValue: name == "elise muster" ? "Elise Muster" : "Other Person",
                normalizedValue: name
            )
        }

        func relationshipFindings(
            reference: String,
            referenceKind: DocumentDNAReferenceNumberKind,
            amount: String = "1250",
            organizationQualifier: String,
            organization: String = "alpha ag"
        ) throws -> [DocumentDNAFinding] {
            [
                try fixture.finding(
                    kind: .referenceNumber,
                    qualifier: referenceKind.rawValue,
                    displayValue: reference,
                    normalizedValue: reference
                ),
                try fixture.finding(
                    kind: .monetaryAmount,
                    qualifier: "CHF",
                    displayValue: amount,
                    normalizedValue: amount
                ),
                try fixture.finding(
                    kind: .organization,
                    qualifier: organizationQualifier,
                    displayValue: organization,
                    normalizedValue: organization
                ),
            ]
        }

        let originFinding = try person(.resident)
        let origin = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(10),
            path: "people/origin.pdf",
            findings: [originFinding],
            documentType: .correspondence,
            analyzedAt: PersonDossierFixture.repositoryDate(10)
        )
        let direct = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(11),
            path: "people/direct.pdf",
            findings: [try person(.insuredPerson)],
            documentType: .insuranceStatement,
            sourceRoot: south,
            analyzedAt: PersonDossierFixture.repositoryDate(11)
        )
        let suggestion = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(12),
            path: "people/suggestion-invoice.pdf",
            findings: [try person(.authorizedPerson)] + relationshipFindings(
                reference: "SUG300",
                referenceKind: .invoiceNumber,
                organizationQualifier: "issuer"
            ),
            sourceRoot: south,
            analyzedAt: PersonDossierFixture.repositoryDate(12)
        )
        let invoice = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(13),
            path: "billing/invoice.pdf",
            findings: [try person(.invoiceRecipient)] + relationshipFindings(
                reference: includedReference,
                referenceKind: .invoiceNumber,
                organizationQualifier: "issuer"
            ) + [try fixture.finding(
                kind: .referenceNumber,
                qualifier: DocumentDNAReferenceNumberKind.invoiceNumber.rawValue,
                displayValue: "INV-100",
                normalizedValue: includedReference
            )],
            sourceRoot: south,
            analyzedAt: PersonDossierFixture.repositoryDate(13)
        )
        let payment = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(14),
            path: "bank/payment.pdf",
            findings: relationshipFindings(
                reference: includedReference,
                referenceKind: .paymentReference,
                organizationQualifier: "payee"
            ),
            documentType: .paymentConfirmation,
            sourceRoot: bank,
            analyzedAt: PersonDossierFixture.repositoryDate(14)
        )
        let rejectedPayment = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(15),
            path: "bank/rejected-payment.pdf",
            findings: relationshipFindings(
                reference: includedReference,
                referenceKind: .paymentReference,
                amount: "9999",
                organizationQualifier: "payee"
            ),
            documentType: .paymentConfirmation,
            sourceRoot: bank,
            analyzedAt: PersonDossierFixture.repositoryDate(15)
        )
        let manual = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(16),
            path: "people/manual.pdf",
            findings: [try person(.authorizedPerson)],
            documentType: .powerOfAttorney,
            analyzedAt: PersonDossierFixture.repositoryDate(16)
        )
        let excludedInvoice = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(17),
            path: "billing/excluded.pdf",
            findings: [try person(.accountHolder, name: "other person")]
                + relationshipFindings(
                reference: excludedReference,
                referenceKind: .invoiceNumber,
                organizationQualifier: "issuer"
            ),
            sourceRoot: south,
            analyzedAt: PersonDossierFixture.repositoryDate(17)
        )
        let unrelatedInvoice = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(18),
            path: "unrelated/invoice.pdf",
            findings: [try person(.invoiceRecipient, name: "other person")]
                + relationshipFindings(
                    reference: unrelatedReference,
                    referenceKind: .invoiceNumber,
                    organizationQualifier: "issuer"
                ),
            sourceRoot: south,
            analyzedAt: PersonDossierFixture.repositoryDate(18)
        )
        let unrelatedPayment = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(19),
            path: "unrelated/payment.pdf",
            findings: relationshipFindings(
                reference: unrelatedReference,
                referenceKind: .paymentReference,
                organizationQualifier: "payee"
            ),
            documentType: .paymentConfirmation,
            sourceRoot: bank,
            analyzedAt: PersonDossierFixture.repositoryDate(19)
        )

        let (anchor, dossier) = try await fixture.insertPersonDossier(
            sequence: 100,
            origin: origin,
            finding: originFinding
        )
        let confirmation = try DossierMembershipConfirmation(
            dossierID: dossier.id,
            documentID: manual.document.id,
            revisionID: PersonDossierFixture.repositoryUUID(110),
            confirmedAt: PersonDossierFixture.repositoryDate(110),
            candidateKind: .secondaryRole,
            acceptedContentHash: manual.snapshot.inputContentHash,
            acceptedExtractionVersion: manual.snapshot.inputExtractionVersion,
            acceptedDNASchemaVersion: manual.snapshot.schemaVersion,
            acceptedDNAAnalyzerIdentifier: manual.snapshot.analyzerIdentifier,
            acceptedDNAAnalyzerVersion: manual.snapshot.analyzerVersion,
            acceptedDNAAnalyzedAt: manual.snapshot.analyzedAt,
            acceptedRole: .authorizedPerson,
            acceptedNormalizedName: anchor.normalizedName
        )
        try await fixture.insertConfirmation(confirmation)
        try await fixture.makeStale(manual.document.id, by: .contentHash)
        let manualDocument = try await fixture.database.read { db in
            guard let document = try DocumentRecord.fetchOne(
                db,
                key: manual.document.id
            ) else {
                throw DossierStoreError.invalidStoredState
            }
            return document
        }
        let exclusion = DossierMembershipExclusion(
            dossierID: dossier.id,
            documentID: excludedInvoice.document.id,
            revisionID: PersonDossierFixture.repositoryUUID(111),
            excludedAt: PersonDossierFixture.repositoryDate(111)
        )
        try await fixture.insertExclusion(exclusion)

        let candidates = InvoicePaymentCandidateProjector().candidates(
            from: InvoicePaymentCandidateProjectionInput(
                selected: invoice,
                matchesByNormalizedReference: [
                    includedReference: [invoice, payment, rejectedPayment],
                ]
            )
        )
        let relationshipCandidate = try #require(candidates.first)
        let (_, relationshipDecision) = try PersonDossierFixture.relationshipDecision(
            for: relationshipCandidate,
            updatedAt: PersonDossierFixture.repositoryDate(120)
        )
        try await fixture.insertDecision(relationshipDecision)

        let unrelatedCandidate = try #require(
            InvoicePaymentCandidateProjector().candidates(
                from: InvoicePaymentCandidateProjectionInput(
                    selected: unrelatedInvoice,
                    matchesByNormalizedReference: [
                        unrelatedReference: [unrelatedInvoice, unrelatedPayment],
                    ]
                )
            ).first
        )
        let (_, unrelatedDecision) = try PersonDossierFixture.relationshipDecision(
            for: unrelatedCandidate,
            updatedAt: PersonDossierFixture.repositoryDate(121)
        )
        try await fixture.insertDecision(unrelatedDecision)

        let costsDossier = try DossierRecord(
            id: PersonDossierFixture.repositoryUUID(130),
            kind: .costsAndPayments,
            displayName: "Costs",
            anchor: .document(unrelatedInvoice.document.id),
            createdAt: PersonDossierFixture.repositoryDate(130),
            updatedAt: PersonDossierFixture.repositoryDate(130)
        )
        try await fixture.database.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: costsDossier)
        }

        return Self(
            fixture: fixture,
            repository: DossierRepository(dbWriter: fixture.database, target: fixture.target),
            anchor: anchor,
            dossier: dossier,
            costsDossier: costsDossier,
            origin: origin,
            direct: direct,
            suggestion: suggestion,
            invoice: invoice,
            payment: payment,
            rejectedPayment: rejectedPayment,
            manualDocument: manualDocument,
            excludedInvoice: excludedInvoice,
            unrelatedInvoice: unrelatedInvoice,
            unrelatedPayment: unrelatedPayment,
            confirmation: confirmation,
            exclusion: exclusion,
            relationshipDecision: relationshipDecision,
            sourceDisplayNames: [
                fixture.source.id: fixture.source.displayName,
                south.id: south.displayName,
                bank.id: bank.displayName,
            ],
            includedReference: includedReference,
            excludedReference: excludedReference,
            unrelatedReference: unrelatedReference
        )
    }
}

private final class PersonDossierRepositorySQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStatements: [String] = []

    var statements: [String] { lock.withLock { recordedStatements } }

    func reset() {
        lock.withLock { recordedStatements = [] }
    }

    func record(_ event: Database.TraceEvent) {
        guard case let .statement(statement) = event else { return }
        lock.withLock { recordedStatements.append(statement.expandedSQL) }
    }

    static func reconstructedDocumentID(from statement: String) -> UUID? {
        guard statement.contains("SELECT schemaVersion, analyzerIdentifier"),
              statement.contains("FROM documentDNA"),
              let whereRange = statement.range(of: "WHERE documentID = x'")
        else {
            return nil
        }
        let suffix = statement[whereRange.upperBound...]
        guard let end = suffix.firstIndex(of: "'") else { return nil }
        let hex = String(suffix[..<end])
        guard hex.count == 32 else { return nil }
        let boundaries = [8, 12, 16, 20]
        var uuid = ""
        for (index, character) in hex.enumerated() {
            if boundaries.contains(index) { uuid.append("-") }
            uuid.append(character)
        }
        return UUID(uuidString: uuid)
    }
}

private extension UUID {
    var sqliteHexLiteral: String {
        "x'\(uuidString.replacingOccurrences(of: "-", with: ""))'"
    }
}
