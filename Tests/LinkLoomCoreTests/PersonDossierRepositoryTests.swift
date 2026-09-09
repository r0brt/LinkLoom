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
        let beforeFailure = try await fixture.databaseSnapshot()
        do {
            _ = try await repository.createOrOpenPersonDossier(from: selection)
            Issue.record("Expected SQLite trigger failure")
        } catch is DatabaseError {
            // The unexpected storage error must cross the repository boundary unchanged.
        } catch {
            Issue.record("Expected DatabaseError, got \(error)")
        }
        #expect(try await fixture.personPersistenceCounts() == (0, 0))
        #expect(try await fixture.databaseSnapshot() == beforeFailure)
    }

    @Test func acceptsCurrentSecondaryAndBirthConflictSuggestionsExactly() async throws {
        for (index, variant) in PersonSuggestionCommandScenario.Variant.allCases.enumerated() {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: variant,
                sequence: 600 + index * 100
            )
            let revisionID = PersonDossierFixture.repositoryUUID(800 + index)
            let confirmedAt = PersonDossierFixture.repositoryDate(TimeInterval(800 + index))
            let repository = values.fixture.makeDossierRepository(
                sequence: 800 + index,
                timestamp: confirmedAt
            )
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let suggestion = try #require(before.suggestions.first {
                $0.document.id == values.candidate.document.id
            })

            let accepted = try await repository.acceptPersonSuggestion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: before.token
            )

            let person = suggestion.commandSupport.person
            let confirmations = try await values.fixture.database.read { db in
                try DossierStore.confirmations(in: db, dossierID: values.dossier.id)
            }
            #expect(confirmations.count == 1)
            let confirmation = try #require(confirmations.first)
            #expect(confirmation.dossierID == values.dossier.id)
            #expect(confirmation.documentID == values.candidate.document.id)
            #expect(confirmation.revisionID == revisionID)
            #expect(confirmation.confirmedAt == confirmedAt)
            #expect(confirmation.candidateKind == suggestion.commandSupport.kind)
            #expect(confirmation.acceptedContentHash == person.contentHash)
            #expect(confirmation.acceptedExtractionVersion == person.extractionVersion)
            #expect(confirmation.acceptedDNASchemaVersion == person.dnaSchemaVersion)
            #expect(confirmation.acceptedDNAAnalyzerIdentifier == person.dnaAnalyzerIdentifier)
            #expect(confirmation.acceptedDNAAnalyzerVersion == person.dnaAnalyzerVersion)
            #expect(confirmation.acceptedDNAAnalyzedAt == person.dnaAnalyzedAt)
            #expect(confirmation.acceptedRole == person.role)
            #expect(confirmation.acceptedNormalizedName == person.normalizedName)
            #expect(!accepted.suggestions.contains { $0.document.id == values.candidate.document.id })
            let member = try #require(
                (accepted.directMembers + accepted.costsAndPayments).first {
                    $0.document.id == values.candidate.document.id
                }
            )
            #expect(member.isConfirmationAuthoritative)
            #expect(member.supports == [.manualConfirmation(
                confirmation: confirmation,
                currentCandidate: suggestion.commandSupport
            )])
            #expect(accepted.corrections.contains {
                $0.document.id == values.candidate.document.id
                    && $0.decision == .confirmation(confirmation)
            })
            #expect(accepted.token != before.token)
            #expect(try await repository.personDossierSnapshot(id: values.dossier.id) == accepted)
            #expect(try await values.fixture.database.read { db in
                try DossierStore.exclusions(in: db, dossierID: values.dossier.id)
            }.isEmpty)
        }
    }

    @Test func acceptingSuggestionIsDossierLocalAndPreservesOtherPersistence() async throws {
        let values = try await PersistedPersonDossierScenario.make()
        let foreignFinding = try values.fixture.personFinding(
            qualifier: PersonDossierRole.resident.rawValue
        )
        let foreignOrigin = try await values.fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(590),
            path: "people/foreign-origin.pdf",
            findings: [foreignFinding],
            documentType: .correspondence
        )
        let (_, foreignDossier) = try await values.fixture.insertPersonDossier(
            sequence: 591,
            origin: foreignOrigin,
            finding: foreignFinding
        )
        let repository = values.fixture.makeDossierRepository(
            sequence: 594,
            timestamp: PersonDossierFixture.repositoryDate(594)
        )
        let before = try await repository.personDossierSnapshot(id: values.dossier.id)
        let suggestion = try #require(before.suggestions.first {
            $0.document.id == values.suggestion.document.id
        })
        let foreignBefore = try await repository.personDossierSnapshot(id: foreignDossier.id)
        #expect(foreignBefore.suggestions.contains {
            $0.document.id == values.suggestion.document.id
        })
        let costsBefore = try await repository.snapshot(id: values.costsDossier.id)
        let exclusionsBefore = try await values.fixture.database.read { db in
            try DossierStore.exclusions(in: db, dossierID: values.dossier.id)
        }
        let decisionsBefore = try await values.fixture.database.read { db in
            try InvoicePaymentDecisionRepository.currentRecords(
                in: db,
                keys: [values.relationshipDecision.key, values.unrelatedDecision.key]
            )
        }

        _ = try await repository.acceptPersonSuggestion(
            dossierID: values.dossier.id,
            documentID: values.suggestion.document.id,
            expectedSupport: suggestion.commandSupport,
            expectedToken: before.token
        )

        #expect(try await values.fixture.database.read { db in
            try DocumentDNARepository.currentSnapshot(
                in: db,
                documentID: values.suggestion.document.id,
                target: values.fixture.target
            )
        } == values.suggestion)
        #expect(try await values.fixture.database.read { db in
            try DossierStore.exclusions(in: db, dossierID: values.dossier.id)
        } == exclusionsBefore)
        #expect(try await values.fixture.database.read { db in
            try InvoicePaymentDecisionRepository.currentRecords(
                in: db,
                keys: [values.relationshipDecision.key, values.unrelatedDecision.key]
            )
        } == decisionsBefore)
        #expect(try await repository.snapshot(id: values.costsDossier.id) == costsBefore)
        #expect(try await repository.personDossierSnapshot(id: foreignDossier.id) == foreignBefore)
        #expect(try await values.fixture.database.read { db in
            try DossierStore.confirmations(in: db, dossierID: foreignDossier.id)
        }.isEmpty)
    }

    @Test func acceptanceRejectsStaleTokenForeignSupportChangedAnalysisAndWrongDocument() async throws {
        do {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: .secondaryRole,
                sequence: 900
            )
            let repository = values.fixture.makeDossierRepository(sequence: 920)
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let suggestion = try #require(before.suggestions.first)
            try await values.fixture.database.write { db in
                try db.execute(
                    sql: "UPDATE dossier SET updatedAt = ? WHERE id = ?",
                    arguments: [PersonDossierFixture.repositoryDate(999), values.dossier.id]
                )
            }
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.acceptPersonSuggestion(
                    dossierID: values.dossier.id,
                    documentID: values.candidate.document.id,
                    expectedSupport: suggestion.commandSupport,
                    expectedToken: before.token
                )
            }
            #expect(try await values.confirmations().isEmpty)
        }

        do {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: .secondaryRole,
                sequence: 1_000,
                additionalSuggestion: true
            )
            let repository = values.fixture.makeDossierRepository(sequence: 1_020)
            let snapshot = try await repository.personDossierSnapshot(id: values.dossier.id)
            #expect(snapshot.suggestions.count == 2)
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.acceptPersonSuggestion(
                    dossierID: values.dossier.id,
                    documentID: snapshot.suggestions[0].document.id,
                    expectedSupport: snapshot.suggestions[1].commandSupport,
                    expectedToken: snapshot.token
                )
            }
            #expect(try await values.confirmations().isEmpty)
        }

        do {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: .secondaryRole,
                sequence: 1_100
            )
            let repository = values.fixture.makeDossierRepository(sequence: 1_120)
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let staleSupport = try #require(before.suggestions.first).commandSupport
            try await values.fixture.database.write { db in
                try db.execute(
                    sql: "UPDATE documentDNA SET analyzedAt = ? WHERE documentID = ?",
                    arguments: [
                        PersonDossierFixture.repositoryDate(1_199),
                        values.candidate.document.id,
                    ]
                )
            }
            let current = try await repository.personDossierSnapshot(id: values.dossier.id)
            #expect(current.suggestions.first?.commandSupport != staleSupport)
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.acceptPersonSuggestion(
                    dossierID: values.dossier.id,
                    documentID: values.candidate.document.id,
                    expectedSupport: staleSupport,
                    expectedToken: current.token
                )
            }
            #expect(try await values.confirmations().isEmpty)
        }

        do {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: .birthDateConflict,
                sequence: 1_200
            )
            let repository = values.fixture.makeDossierRepository(sequence: 1_220)
            let snapshot = try await repository.personDossierSnapshot(id: values.dossier.id)
            let suggestion = try #require(snapshot.suggestions.first)
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.acceptPersonSuggestion(
                    dossierID: values.dossier.id,
                    documentID: PersonDossierFixture.repositoryUUID(9_999),
                    expectedSupport: suggestion.commandSupport,
                    expectedToken: snapshot.token
                )
            }
            #expect(try await values.confirmations().isEmpty)
        }
    }

    @Test func acceptanceRejectsAlreadyAcceptedMissingAndCostsDossiersWithoutExtraWrites() async throws {
        let values = try await PersonSuggestionCommandScenario.make(
            variant: .secondaryRole,
            sequence: 1_300
        )
        let repository = values.fixture.makeDossierRepository(sequence: 1_320)
        let initial = try await repository.personDossierSnapshot(id: values.dossier.id)
        let suggestion = try #require(initial.suggestions.first)

        let accepted = try await repository.acceptPersonSuggestion(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            expectedSupport: suggestion.commandSupport,
            expectedToken: initial.token
        )
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.acceptPersonSuggestion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: accepted.token
            )
        }
        #expect(try await values.confirmations().count == 1)

        let missingID = PersonDossierFixture.repositoryUUID(9_998)
        await #expect(throws: DossierRepositoryError.dossierNotFound) {
            try await repository.acceptPersonSuggestion(
                dossierID: missingID,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: initial.token
            )
        }
        let costsDossier = try DossierRecord(
            id: PersonDossierFixture.repositoryUUID(1_330),
            kind: .costsAndPayments,
            displayName: "Costs",
            anchor: .document(values.candidate.document.id),
            createdAt: PersonDossierFixture.repositoryDate(1_330),
            updatedAt: PersonDossierFixture.repositoryDate(1_330)
        )
        try await values.fixture.database.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: costsDossier)
        }
        await #expect(throws: DossierRepositoryError.invalidStoredState) {
            try await repository.acceptPersonSuggestion(
                dossierID: costsDossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: initial.token
            )
        }
        #expect(try await values.confirmations().count == 1)
        #expect(try await values.fixture.database.read { db in
            try DossierStore.confirmations(in: db, dossierID: costsDossier.id)
        }.isEmpty)
    }

    @Test func rejectsCurrentSecondaryAndBirthConflictSuggestionsExactly() async throws {
        for (index, variant) in PersonSuggestionCommandScenario.Variant.allCases.enumerated() {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: variant,
                sequence: 1_400 + index * 100
            )
            let revisionID = PersonDossierFixture.repositoryUUID(1_600 + index)
            let excludedAt = PersonDossierFixture.repositoryDate(TimeInterval(1_600 + index))
            let repository = values.fixture.makeDossierRepository(
                sequence: 1_600 + index,
                timestamp: excludedAt
            )
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let suggestion = try #require(before.suggestions.first {
                $0.document.id == values.candidate.document.id
            })

            let rejected = try await repository.rejectPersonSuggestion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: before.token
            )

            let exclusions = try await values.fixture.database.read { db in
                try DossierStore.exclusions(in: db, dossierID: values.dossier.id)
            }
            #expect(exclusions.count == 1)
            let exclusion = try #require(exclusions.first)
            #expect(exclusion == DossierMembershipExclusion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                revisionID: revisionID,
                excludedAt: excludedAt
            ))
            #expect(!rejected.suggestions.contains { $0.document.id == values.candidate.document.id })
            #expect(!(rejected.directMembers + rejected.costsAndPayments).contains {
                $0.document.id == values.candidate.document.id
            })
            #expect(rejected.corrections.contains {
                $0.document.id == values.candidate.document.id
                    && $0.decision == .exclusion(exclusion)
            })
            #expect(rejected.token != before.token)
            #expect(try await repository.personDossierSnapshot(id: values.dossier.id) == rejected)
            #expect(try await values.confirmations().isEmpty)
        }
    }

    @Test func rejectingSuggestionIsIsolatedToTheSelectedDossier() async throws {
        let values = try await PersonSuggestionCommandScenario.make(
            variant: .secondaryRole,
            sequence: 1_700
        )
        let foreignPerson = try values.fixture.personFinding(
            qualifier: PersonDossierRole.resident.rawValue
        )
        let foreignOrigin = try await values.fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(1_710),
            path: "commands/foreign-reject-origin.pdf",
            findings: [foreignPerson],
            documentType: .correspondence
        )
        let (_, foreignDossier) = try await values.fixture.insertPersonDossier(
            sequence: 1_711,
            origin: foreignOrigin,
            finding: foreignPerson
        )
        let repository = values.fixture.makeDossierRepository(sequence: 1_720)
        let before = try await repository.personDossierSnapshot(id: values.dossier.id)
        let suggestion = try #require(before.suggestions.first)
        let foreignBefore = try await repository.personDossierSnapshot(id: foreignDossier.id)

        _ = try await repository.rejectPersonSuggestion(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            expectedSupport: suggestion.commandSupport,
            expectedToken: before.token
        )

        #expect(try await repository.personDossierSnapshot(id: foreignDossier.id) == foreignBefore)
        #expect(try await values.fixture.database.read { db in
            try DossierStore.exclusions(in: db, dossierID: foreignDossier.id)
        }.isEmpty)
        #expect(try await values.confirmations().isEmpty)
    }

    @Test func rejectionRejectsStaleTokenForeignSupportAndWrongDocumentWithoutWrites() async throws {
        do {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: .secondaryRole,
                sequence: 1_800
            )
            let repository = values.fixture.makeDossierRepository(sequence: 1_820)
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let suggestion = try #require(before.suggestions.first)
            try await values.fixture.database.write { db in
                try db.execute(
                    sql: "UPDATE dossier SET updatedAt = ? WHERE id = ?",
                    arguments: [PersonDossierFixture.repositoryDate(1_899), values.dossier.id]
                )
            }
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.rejectPersonSuggestion(
                    dossierID: values.dossier.id,
                    documentID: values.candidate.document.id,
                    expectedSupport: suggestion.commandSupport,
                    expectedToken: before.token
                )
            }
            #expect(try await values.exclusions().isEmpty)
        }

        do {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: .secondaryRole,
                sequence: 1_900,
                additionalSuggestion: true
            )
            let repository = values.fixture.makeDossierRepository(sequence: 1_920)
            let snapshot = try await repository.personDossierSnapshot(id: values.dossier.id)
            #expect(snapshot.suggestions.count == 2)
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.rejectPersonSuggestion(
                    dossierID: values.dossier.id,
                    documentID: snapshot.suggestions[0].document.id,
                    expectedSupport: snapshot.suggestions[1].commandSupport,
                    expectedToken: snapshot.token
                )
            }
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.rejectPersonSuggestion(
                    dossierID: values.dossier.id,
                    documentID: PersonDossierFixture.repositoryUUID(9_997),
                    expectedSupport: snapshot.suggestions[0].commandSupport,
                    expectedToken: snapshot.token
                )
            }
            #expect(try await values.exclusions().isEmpty)
            #expect(try await values.confirmations().isEmpty)
        }
    }

    @Test func rejectionRejectsAlreadyCorrectedMissingAndCostsDossiersWithoutExtraWrites() async throws {
        let values = try await PersonSuggestionCommandScenario.make(
            variant: .birthDateConflict,
            sequence: 2_000
        )
        let repository = values.fixture.makeDossierRepository(sequence: 2_020)
        let initial = try await repository.personDossierSnapshot(id: values.dossier.id)
        let suggestion = try #require(initial.suggestions.first)

        let rejected = try await repository.rejectPersonSuggestion(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            expectedSupport: suggestion.commandSupport,
            expectedToken: initial.token
        )
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.rejectPersonSuggestion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: rejected.token
            )
        }
        #expect(try await values.exclusions().count == 1)

        await #expect(throws: DossierRepositoryError.dossierNotFound) {
            try await repository.rejectPersonSuggestion(
                dossierID: PersonDossierFixture.repositoryUUID(9_996),
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: initial.token
            )
        }
        let costsDossier = try DossierRecord(
            id: PersonDossierFixture.repositoryUUID(2_030),
            kind: .costsAndPayments,
            displayName: "Costs",
            anchor: .document(values.candidate.document.id),
            createdAt: PersonDossierFixture.repositoryDate(2_030),
            updatedAt: PersonDossierFixture.repositoryDate(2_030)
        )
        try await values.fixture.database.write { db in
            _ = try DossierStore.insertOrFetchAnchored(in: db, proposed: costsDossier)
        }
        await #expect(throws: DossierRepositoryError.invalidStoredState) {
            try await repository.rejectPersonSuggestion(
                dossierID: costsDossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: initial.token
            )
        }
        #expect(try await values.exclusions().count == 1)
        #expect(try await values.fixture.database.read { db in
            try DossierStore.exclusions(in: db, dossierID: costsDossier.id)
        }.isEmpty)
        #expect(try await values.confirmations().isEmpty)
    }

    @Test func removesExactPrimaryAndRelationshipMembersWithExactDisplayedIdentity() async throws {
        for index in 0..<2 {
            let values = try await PersistedPersonDossierScenario.make()
            let selectedDocument = index == 0 ? values.direct : values.payment
            let revisionID = PersonDossierFixture.repositoryUUID(2_100 + index)
            let excludedAt = PersonDossierFixture.repositoryDate(TimeInterval(2_100 + index))
            let repository = values.fixture.makeDossierRepository(
                sequence: 2_100 + index,
                timestamp: excludedAt
            )
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let member = try #require(
                (before.directMembers + before.costsAndPayments).first {
                    $0.document.id == selectedDocument.document.id
                }
            )
            let support = try member.commandSupport

            if index == 0 {
                guard case .exactPrimary = support else {
                    Issue.record("Expected exact-primary command support")
                    continue
                }
            } else {
                guard case .confirmedPayment = support else {
                    Issue.record("Expected confirmed-payment command support")
                    continue
                }
            }

            let removed = try await repository.removePersonMember(
                dossierID: values.dossier.id,
                documentID: selectedDocument.document.id,
                expectedSupport: support,
                expectedToken: before.token
            )

            let exclusion = DossierMembershipExclusion(
                dossierID: values.dossier.id,
                documentID: selectedDocument.document.id,
                revisionID: revisionID,
                excludedAt: excludedAt
            )
            #expect(try await values.fixture.database.read { db in
                try DossierStore.exclusions(in: db, dossierID: values.dossier.id)
            }.contains(exclusion))
            #expect(!(removed.directMembers + removed.costsAndPayments).contains {
                $0.document.id == selectedDocument.document.id
            })
            #expect(!removed.suggestions.contains {
                $0.document.id == selectedDocument.document.id
            })
            #expect(removed.corrections.contains {
                $0.document.id == selectedDocument.document.id
                    && $0.decision == .exclusion(exclusion)
            })
            #expect(removed.token != before.token)
            #expect(try await repository.personDossierSnapshot(id: values.dossier.id) == removed)
        }
    }

    @Test func removalAcceptsOnlyCanonicalPreferredSupportForMultiplySupportedPayment() async throws {
        let values = try await PersistedPersonDossierScenario.make()
        let secondInvoice = try await values.fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(2_200),
            path: "billing/second-invoice.pdf",
            findings: [
                try values.fixture.personFinding(
                    qualifier: PersonDossierRole.invoiceRecipient.rawValue
                ),
                try values.fixture.finding(
                    kind: .referenceNumber,
                    qualifier: DocumentDNAReferenceNumberKind.invoiceNumber.rawValue,
                    displayValue: values.includedReference,
                    normalizedValue: values.includedReference
                ),
                try values.fixture.finding(
                    kind: .monetaryAmount,
                    qualifier: "CHF",
                    displayValue: "1250",
                    normalizedValue: "1250"
                ),
                try values.fixture.finding(
                    kind: .organization,
                    qualifier: "issuer",
                    displayValue: "Alpha AG",
                    normalizedValue: "alpha ag"
                ),
            ],
            documentType: .invoice,
            analyzedAt: PersonDossierFixture.repositoryDate(2_200)
        )
        let candidate = try #require(InvoicePaymentCandidateProjector().candidates(
            from: InvoicePaymentCandidateProjectionInput(
                selected: secondInvoice,
                matchesByNormalizedReference: [
                    values.includedReference: [secondInvoice, values.payment],
                ]
            )
        ).first)
        let (_, decision) = try PersonDossierFixture.relationshipDecision(
            for: candidate,
            updatedAt: PersonDossierFixture.repositoryDate(2_201)
        )
        try await values.fixture.insertDecision(decision)
        let repository = values.fixture.makeDossierRepository(sequence: 2_202)
        let before = try await repository.personDossierSnapshot(id: values.dossier.id)
        let payment = try #require(before.costsAndPayments.first {
            $0.document.id == values.payment.document.id
        })
        let paymentSupports = payment.supports.filter {
            if case .confirmedPayment = $0 { return true }
            return false
        }
        #expect(paymentSupports.count == 2)
        let commandSupport = try payment.commandSupport
        let nonCommandSupport = try #require(paymentSupports.first { $0 != commandSupport })
        let rowsBefore = try await correctionRows(values.fixture.database, values.dossier.id)

        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.removePersonMember(
                dossierID: values.dossier.id,
                documentID: values.payment.document.id,
                expectedSupport: nonCommandSupport,
                expectedToken: before.token
            )
        }
        #expect(try await correctionRows(values.fixture.database, values.dossier.id) == rowsBefore)

        let removed = try await repository.removePersonMember(
            dossierID: values.dossier.id,
            documentID: values.payment.document.id,
            expectedSupport: commandSupport,
            expectedToken: before.token
        )
        #expect(!removed.costsAndPayments.contains {
            $0.document.id == values.payment.document.id
        })
    }

    @Test func removalRejectsStaleForeignWrongAlreadyRemovedMissingCostsAndAnchorInputsWithoutWrites() async throws {
        do {
            let values = try await PersistedPersonDossierScenario.make()
            let repository = values.fixture.makeDossierRepository(sequence: 2_300)
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let member = try #require(before.directMembers.first {
                $0.document.id == values.direct.document.id
            })
            let rowsBefore = try await correctionRows(values.fixture.database, values.dossier.id)
            try await values.fixture.database.write { db in
                try db.execute(
                    sql: "UPDATE dossier SET updatedAt = ? WHERE id = ?",
                    arguments: [PersonDossierFixture.repositoryDate(2_399), values.dossier.id]
                )
            }
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.removePersonMember(
                    dossierID: values.dossier.id,
                    documentID: values.direct.document.id,
                    expectedSupport: try member.commandSupport,
                    expectedToken: before.token
                )
            }
            #expect(try await correctionRows(values.fixture.database, values.dossier.id) == rowsBefore)
        }

        do {
            let values = try await PersistedPersonDossierScenario.make()
            let repository = values.fixture.makeDossierRepository(sequence: 2_400)
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let direct = try #require(before.directMembers.first {
                $0.document.id == values.direct.document.id
            })
            let invoice = try #require(before.costsAndPayments.first {
                $0.document.id == values.invoice.document.id
            })
            let origin = try #require(before.directMembers.first {
                $0.document.id == values.origin.document.id
            })
            let rowsBefore = try await correctionRows(values.fixture.database, values.dossier.id)

            for (documentID, support) in [
                (values.direct.document.id, try invoice.commandSupport),
                (PersonDossierFixture.repositoryUUID(9_995), try direct.commandSupport),
                (values.origin.document.id, try origin.commandSupport),
            ] {
                await #expect(throws: DossierRepositoryError.staleInput) {
                    try await repository.removePersonMember(
                        dossierID: values.dossier.id,
                        documentID: documentID,
                        expectedSupport: support,
                        expectedToken: before.token
                    )
                }
                #expect(
                    try await correctionRows(values.fixture.database, values.dossier.id)
                        == rowsBefore
                )
            }

            await #expect(throws: DossierRepositoryError.dossierNotFound) {
                try await repository.removePersonMember(
                    dossierID: PersonDossierFixture.repositoryUUID(9_994),
                    documentID: values.direct.document.id,
                    expectedSupport: try direct.commandSupport,
                    expectedToken: before.token
                )
            }
            await #expect(throws: DossierRepositoryError.invalidStoredState) {
                try await repository.removePersonMember(
                    dossierID: values.costsDossier.id,
                    documentID: values.direct.document.id,
                    expectedSupport: try direct.commandSupport,
                    expectedToken: before.token
                )
            }
            #expect(try await correctionRows(values.fixture.database, values.dossier.id) == rowsBefore)
            #expect(try await correctionRows(values.fixture.database, values.costsDossier.id)
                == PersonCorrectionRows(confirmations: [], exclusions: []))

            let removed = try await repository.removePersonMember(
                dossierID: values.dossier.id,
                documentID: values.direct.document.id,
                expectedSupport: try direct.commandSupport,
                expectedToken: before.token
            )
            let rowsAfterRemoval = try await correctionRows(
                values.fixture.database,
                values.dossier.id
            )
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.removePersonMember(
                    dossierID: values.dossier.id,
                    documentID: values.direct.document.id,
                    expectedSupport: try direct.commandSupport,
                    expectedToken: removed.token
                )
            }
            #expect(try await correctionRows(values.fixture.database, values.dossier.id)
                == rowsAfterRemoval)
        }
    }

    @Test func removingManualMemberAtomicallyReplacesExactConfirmationWithExclusion() async throws {
        let values = try await PersonSuggestionCommandScenario.make(
            variant: .secondaryRole,
            sequence: 2_500
        )
        let confirmedAt = PersonDossierFixture.repositoryDate(2_510)
        let removedAt = PersonDossierFixture.repositoryDate(2_511)
        let repository = values.fixture.makeDossierRepository(
            sequence: 2_510,
            timestamp: confirmedAt
        )
        let initial = try await repository.personDossierSnapshot(id: values.dossier.id)
        let suggestion = try #require(initial.suggestions.first)
        let accepted = try await repository.acceptPersonSuggestion(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            expectedSupport: suggestion.commandSupport,
            expectedToken: initial.token
        )
        let member = try #require(accepted.directMembers.first {
            $0.document.id == values.candidate.document.id
        })
        let confirmation = try #require(try await values.confirmations().first)
        let removalRepository = values.fixture.makeDossierRepository(
            sequence: 2_511,
            timestamp: removedAt
        )

        let removed = try await removalRepository.removePersonMember(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            expectedSupport: try member.commandSupport,
            expectedToken: accepted.token
        )

        let exclusion = DossierMembershipExclusion(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            revisionID: PersonDossierFixture.repositoryUUID(2_511),
            excludedAt: removedAt
        )
        #expect(confirmation.revisionID == PersonDossierFixture.repositoryUUID(2_510))
        #expect(try await values.confirmations().isEmpty)
        #expect(try await values.exclusions() == [exclusion])
        #expect(removed.corrections.filter {
            $0.document.id == values.candidate.document.id
        }.map(\.decision) == [.exclusion(exclusion)])
        #expect(!(removed.directMembers + removed.costsAndPayments).contains {
            $0.document.id == values.candidate.document.id
        })
    }

    @Test func manualRemovalRollsBackConfirmationDeletionWhenFinalProjectionFails() async throws {
        let values = try await PersonSuggestionCommandScenario.make(
            variant: .secondaryRole,
            sequence: 2_600
        )
        let repository = values.fixture.makeDossierRepository(sequence: 2_610)
        let initial = try await repository.personDossierSnapshot(id: values.dossier.id)
        let suggestion = try #require(initial.suggestions.first)
        let accepted = try await repository.acceptPersonSuggestion(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            expectedSupport: suggestion.commandSupport,
            expectedToken: initial.token
        )
        let member = try #require(accepted.directMembers.first {
            $0.document.id == values.candidate.document.id
        })
        let confirmation = try #require(try await values.confirmations().first)
        try await values.fixture.database.write { db in
            try db.execute(sql: """
                CREATE TABLE person_confirmation_backup AS
                SELECT * FROM dossierMembershipConfirmation
                WHERE dossierID = x'\(values.dossier.id.sqliteBytes)'
                  AND documentID = x'\(values.candidate.document.id.sqliteBytes)'
                """)
            try db.execute(sql: """
                CREATE TRIGGER restore_conflicting_person_confirmation
                AFTER INSERT ON dossierMembershipExclusion
                WHEN NEW.dossierID = x'\(values.dossier.id.sqliteBytes)'
                  AND NEW.documentID = x'\(values.candidate.document.id.sqliteBytes)'
                BEGIN
                    INSERT INTO dossierMembershipConfirmation
                    SELECT * FROM person_confirmation_backup;
                END
                """)
        }
        let beforeFailure = try await values.fixture.databaseSnapshot()

        await #expect(throws: DossierRepositoryError.invalidStoredState) {
            try await repository.removePersonMember(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: try member.commandSupport,
                expectedToken: accepted.token
            )
        }

        #expect(try await values.confirmations() == [confirmation])
        #expect(try await values.exclusions().isEmpty)
        #expect(try await repository.personDossierSnapshot(id: values.dossier.id) == accepted)
        #expect(try await values.fixture.databaseSnapshot() == beforeFailure)
    }

    @Test func resettingConfirmationReturnsOnlyCurrentEvidenceToSuggestion() async throws {
        do {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: .secondaryRole,
                sequence: 2_700
            )
            let repository = values.fixture.makeDossierRepository(sequence: 2_710)
            let initial = try await repository.personDossierSnapshot(id: values.dossier.id)
            let suggestion = try #require(initial.suggestions.first)
            let accepted = try await repository.acceptPersonSuggestion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: initial.token
            )
            let correction = try #require(accepted.corrections.first {
                $0.document.id == values.candidate.document.id
            })

            let reset = try await repository.resetPersonCorrection(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedDecision: correction.decision,
                expectedToken: accepted.token
            )

            #expect(try await values.confirmations().isEmpty)
            #expect(reset.suggestions.contains {
                $0.document.id == values.candidate.document.id
                    && $0.commandSupport == suggestion.commandSupport
            })
            #expect(!(reset.directMembers + reset.costsAndPayments).contains {
                $0.document.id == values.candidate.document.id
            })
            #expect(!reset.corrections.contains {
                $0.document.id == values.candidate.document.id
            })
            #expect(reset.token != accepted.token)
        }

        do {
            let values = try await PersistedPersonDossierScenario.make()
            let repository = values.fixture.makeDossierRepository(sequence: 2_720)
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let correction = try #require(before.corrections.first {
                $0.document.id == values.manualDocument.id
            })
            guard case .confirmation = correction.decision else {
                Issue.record("Expected confirmation correction")
                return
            }

            let reset = try await repository.resetPersonCorrection(
                dossierID: values.dossier.id,
                documentID: values.manualDocument.id,
                expectedDecision: correction.decision,
                expectedToken: before.token
            )

            #expect(try await correctionRows(values.fixture.database, values.dossier.id)
                == PersonCorrectionRows(confirmations: [], exclusions: [values.exclusion]))
            #expect(!(reset.directMembers + reset.costsAndPayments).contains {
                $0.document.id == values.manualDocument.id
            })
            #expect(!reset.suggestions.contains {
                $0.document.id == values.manualDocument.id
            })
            #expect(!reset.corrections.contains {
                $0.document.id == values.manualDocument.id
            })
        }
    }

    @Test func resettingExclusionReprojectsMemberSuggestionOrHiddenFromCurrentEvidence() async throws {
        do {
            let values = try await PersistedPersonDossierScenario.make()
            let repository = values.fixture.makeDossierRepository(sequence: 2_800)
            let initial = try await repository.personDossierSnapshot(id: values.dossier.id)
            let member = try #require(initial.directMembers.first {
                $0.document.id == values.direct.document.id
            })
            let expectedSupport = try member.commandSupport
            let removed = try await repository.removePersonMember(
                dossierID: values.dossier.id,
                documentID: values.direct.document.id,
                expectedSupport: expectedSupport,
                expectedToken: initial.token
            )
            let correction = try #require(removed.corrections.first {
                $0.document.id == values.direct.document.id
            })

            let reset = try await repository.resetPersonCorrection(
                dossierID: values.dossier.id,
                documentID: values.direct.document.id,
                expectedDecision: correction.decision,
                expectedToken: removed.token
            )

            let resetMember = try #require(reset.directMembers.first {
                $0.document.id == values.direct.document.id
            })
            #expect(try resetMember.commandSupport == expectedSupport)
            #expect(!reset.corrections.contains {
                $0.document.id == values.direct.document.id
            })
        }

        do {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: .birthDateConflict,
                sequence: 2_900
            )
            let repository = values.fixture.makeDossierRepository(sequence: 2_910)
            let initial = try await repository.personDossierSnapshot(id: values.dossier.id)
            let suggestion = try #require(initial.suggestions.first)
            let rejected = try await repository.rejectPersonSuggestion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: initial.token
            )
            let correction = try #require(rejected.corrections.first)

            let reset = try await repository.resetPersonCorrection(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedDecision: correction.decision,
                expectedToken: rejected.token
            )

            #expect(reset.suggestions.contains {
                $0.document.id == values.candidate.document.id
                    && $0.commandSupport == suggestion.commandSupport
            })
            #expect(try await values.exclusions().isEmpty)
        }

        do {
            let values = try await PersistedPersonDossierScenario.make()
            let repository = values.fixture.makeDossierRepository(sequence: 2_920)
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let correction = try #require(before.corrections.first {
                $0.document.id == values.excludedInvoice.document.id
            })

            let reset = try await repository.resetPersonCorrection(
                dossierID: values.dossier.id,
                documentID: values.excludedInvoice.document.id,
                expectedDecision: correction.decision,
                expectedToken: before.token
            )

            #expect(!(reset.directMembers + reset.costsAndPayments).contains {
                $0.document.id == values.excludedInvoice.document.id
            })
            #expect(!reset.suggestions.contains {
                $0.document.id == values.excludedInvoice.document.id
            })
            #expect(!reset.corrections.contains {
                $0.document.id == values.excludedInvoice.document.id
            })
        }
    }

    @Test func resettingManualReplacementExclusionNeverRestoresDeletedConfirmation() async throws {
        let values = try await PersonSuggestionCommandScenario.make(
            variant: .secondaryRole,
            sequence: 3_000
        )
        let repository = values.fixture.makeDossierRepository(sequence: 3_010)
        let initial = try await repository.personDossierSnapshot(id: values.dossier.id)
        let suggestion = try #require(initial.suggestions.first)
        let accepted = try await repository.acceptPersonSuggestion(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            expectedSupport: suggestion.commandSupport,
            expectedToken: initial.token
        )
        let member = try #require(accepted.directMembers.first {
            $0.document.id == values.candidate.document.id
        })
        let removed = try await repository.removePersonMember(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            expectedSupport: try member.commandSupport,
            expectedToken: accepted.token
        )
        let correction = try #require(removed.corrections.first)

        let reset = try await repository.resetPersonCorrection(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            expectedDecision: correction.decision,
            expectedToken: removed.token
        )

        #expect(try await values.confirmations().isEmpty)
        #expect(try await values.exclusions().isEmpty)
        #expect(reset.suggestions.contains {
            $0.document.id == values.candidate.document.id
                && $0.commandSupport == suggestion.commandSupport
        })
        #expect(!(reset.directMembers + reset.costsAndPayments).contains {
            $0.document.id == values.candidate.document.id
        })
    }

    @Test func resetRejectsStaleReplacedMismatchedAndWrongInputsWithoutDeletion() async throws {
        do {
            let values = try await PersistedPersonDossierScenario.make()
            let repository = values.fixture.makeDossierRepository(sequence: 3_100)
            let before = try await repository.personDossierSnapshot(id: values.dossier.id)
            let correction = try #require(before.corrections.first {
                $0.document.id == values.excludedInvoice.document.id
            })
            let rowsBefore = try await correctionRows(values.fixture.database, values.dossier.id)
            try await values.fixture.database.write { db in
                try db.execute(
                    sql: "UPDATE dossier SET updatedAt = ? WHERE id = ?",
                    arguments: [PersonDossierFixture.repositoryDate(3_199), values.dossier.id]
                )
            }

            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.resetPersonCorrection(
                    dossierID: values.dossier.id,
                    documentID: values.excludedInvoice.document.id,
                    expectedDecision: correction.decision,
                    expectedToken: before.token
                )
            }
            #expect(try await correctionRows(values.fixture.database, values.dossier.id) == rowsBefore)
        }

        do {
            let values = try await PersistedPersonDossierScenario.make()
            let repository = values.fixture.makeDossierRepository(sequence: 3_200)
            let original = values.exclusion
            let replacement = DossierMembershipExclusion(
                dossierID: original.dossierID,
                documentID: original.documentID,
                revisionID: PersonDossierFixture.repositoryUUID(3_201),
                excludedAt: PersonDossierFixture.repositoryDate(3_201)
            )
            try await values.fixture.database.write { db in
                #expect(try DossierStore.deleteExclusion(
                    in: db,
                    dossierID: original.dossierID,
                    documentID: original.documentID,
                    expectedRevisionID: original.revisionID
                ))
                try DossierStore.insertExclusion(in: db, exclusion: replacement)
            }
            let current = try await repository.personDossierSnapshot(id: values.dossier.id)
            let rowsBefore = try await correctionRows(values.fixture.database, values.dossier.id)

            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.resetPersonCorrection(
                    dossierID: values.dossier.id,
                    documentID: original.documentID,
                    expectedDecision: .exclusion(original),
                    expectedToken: current.token
                )
            }
            #expect(try await correctionRows(values.fixture.database, values.dossier.id) == rowsBefore)

            let mismatched = DossierMembershipExclusion(
                dossierID: replacement.dossierID,
                documentID: replacement.documentID,
                revisionID: replacement.revisionID,
                excludedAt: replacement.excludedAt.addingTimeInterval(1)
            )
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.resetPersonCorrection(
                    dossierID: values.dossier.id,
                    documentID: replacement.documentID,
                    expectedDecision: .exclusion(mismatched),
                    expectedToken: current.token
                )
            }
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.resetPersonCorrection(
                    dossierID: values.dossier.id,
                    documentID: values.direct.document.id,
                    expectedDecision: .exclusion(replacement),
                    expectedToken: current.token
                )
            }
            #expect(try await correctionRows(values.fixture.database, values.dossier.id) == rowsBefore)

            let foreignFinding = try values.fixture.personFinding(
                qualifier: PersonDossierRole.resident.rawValue
            )
            let foreignOrigin = try await values.fixture.insertSnapshot(
                id: PersonDossierFixture.repositoryUUID(3_210),
                path: "people/reset-wrong-dossier-origin.pdf",
                findings: [foreignFinding],
                documentType: .correspondence
            )
            let (_, foreignDossier) = try await values.fixture.insertPersonDossier(
                sequence: 3_211,
                origin: foreignOrigin,
                finding: foreignFinding
            )
            let foreign = try await repository.personDossierSnapshot(id: foreignDossier.id)
            await #expect(throws: DossierRepositoryError.staleInput) {
                try await repository.resetPersonCorrection(
                    dossierID: foreignDossier.id,
                    documentID: replacement.documentID,
                    expectedDecision: .exclusion(replacement),
                    expectedToken: foreign.token
                )
            }
            await #expect(throws: DossierRepositoryError.dossierNotFound) {
                try await repository.resetPersonCorrection(
                    dossierID: PersonDossierFixture.repositoryUUID(9_993),
                    documentID: replacement.documentID,
                    expectedDecision: .exclusion(replacement),
                    expectedToken: current.token
                )
            }
            await #expect(throws: DossierRepositoryError.invalidStoredState) {
                try await repository.resetPersonCorrection(
                    dossierID: values.costsDossier.id,
                    documentID: replacement.documentID,
                    expectedDecision: .exclusion(replacement),
                    expectedToken: current.token
                )
            }
            #expect(try await correctionRows(values.fixture.database, values.dossier.id) == rowsBefore)
            #expect(try await correctionRows(values.fixture.database, foreignDossier.id)
                == PersonCorrectionRows(confirmations: [], exclusions: []))
            #expect(try await correctionRows(values.fixture.database, values.costsDossier.id)
                == PersonCorrectionRows(confirmations: [], exclusions: []))
        }
    }

    @Test func resetDeletesOnlyTheSelectedDossiersCorrectionForSharedDocument() async throws {
        let values = try await PersistedPersonDossierScenario.make()
        let repository = values.fixture.makeDossierRepository(sequence: 3_300)
        let foreignFinding = try values.fixture.personFinding(
            qualifier: PersonDossierRole.resident.rawValue
        )
        let foreignOrigin = try await values.fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(3_301),
            path: "people/reset-isolation-origin.pdf",
            findings: [foreignFinding],
            documentType: .correspondence
        )
        let (_, foreignDossier) = try await values.fixture.insertPersonDossier(
            sequence: 3_302,
            origin: foreignOrigin,
            finding: foreignFinding
        )
        let initial = try await repository.personDossierSnapshot(id: values.dossier.id)
        let member = try #require(initial.directMembers.first {
            $0.document.id == values.direct.document.id
        })
        let removed = try await repository.removePersonMember(
            dossierID: values.dossier.id,
            documentID: values.direct.document.id,
            expectedSupport: try member.commandSupport,
            expectedToken: initial.token
        )
        let primaryCorrection = try #require(removed.corrections.first {
            $0.document.id == values.direct.document.id
        })
        let foreignExclusion = DossierMembershipExclusion(
            dossierID: foreignDossier.id,
            documentID: values.direct.document.id,
            revisionID: PersonDossierFixture.repositoryUUID(3_304),
            excludedAt: PersonDossierFixture.repositoryDate(3_304)
        )
        try await values.fixture.insertExclusion(foreignExclusion)
        let foreignBefore = try await repository.personDossierSnapshot(id: foreignDossier.id)

        let reset = try await repository.resetPersonCorrection(
            dossierID: values.dossier.id,
            documentID: values.direct.document.id,
            expectedDecision: primaryCorrection.decision,
            expectedToken: removed.token
        )

        #expect(reset.directMembers.contains { $0.document.id == values.direct.document.id })
        #expect(try await repository.personDossierSnapshot(id: foreignDossier.id) == foreignBefore)
        #expect(try await correctionRows(values.fixture.database, foreignDossier.id)
            == PersonCorrectionRows(confirmations: [], exclusions: [foreignExclusion]))
    }

    @Test func reanalysisReevaluatesAutomaticSupportButPreservesManualDecisions() async throws {
        let values = try await PersistedPersonDossierScenario.make()
        let initial = try await values.repository.personDossierSnapshot(id: values.dossier.id)
        let rows = try await correctionRows(values.fixture.database, values.dossier.id)
        #expect(initial.directMembers.contains { $0.document.id == values.direct.document.id })
        #expect(initial.directMembers.contains { $0.document.id == values.manualDocument.id })

        let otherPerson = try values.fixture.personFinding(
            normalizedName: "other person",
            qualifier: PersonDossierRole.insuredPerson.rawValue
        )
        let changedDirect = try await values.fixture.reanalyze(
            values.direct,
            contentHash: "changed-direct-content",
            findings: values.direct.snapshot.findings.filter { $0.kind != .person } + [otherPerson],
            analyzedAt: PersonDossierFixture.repositoryDate(4_001)
        )
        let changed = try await values.repository.personDossierSnapshot(id: values.dossier.id)

        #expect(!changed.directMembers.contains { $0.document.id == values.direct.document.id })
        let manual = try #require(changed.directMembers.first {
            $0.document.id == values.manualDocument.id
        })
        #expect(manual.supports == [.manualConfirmation(
            confirmation: values.confirmation,
            currentCandidate: nil
        )])
        #expect(!(changed.directMembers + changed.costsAndPayments).contains {
            $0.document.id == values.excludedInvoice.document.id
        })
        #expect(try await correctionRows(values.fixture.database, values.dossier.id) == rows)

        _ = try await values.fixture.reanalyze(
            changedDirect,
            contentHash: values.direct.document.contentHash,
            findings: values.direct.snapshot.findings,
            analyzedAt: PersonDossierFixture.repositoryDate(4_002)
        )
        let matchingExcludedFindings = try values.excludedInvoice.snapshot.findings.map { finding in
            guard finding.kind == .person else { return finding }
            return try values.fixture.personFinding(
                qualifier: PersonDossierRole.accountHolder.rawValue
            )
        }
        _ = try await values.fixture.reanalyze(
            values.excludedInvoice,
            contentHash: "matching-excluded-content",
            findings: matchingExcludedFindings,
            analyzedAt: PersonDossierFixture.repositoryDate(4_003)
        )
        let restored = try await values.repository.personDossierSnapshot(id: values.dossier.id)

        #expect(restored.directMembers.contains { $0.document.id == values.direct.document.id })
        #expect(!(restored.directMembers + restored.costsAndPayments).contains {
            $0.document.id == values.excludedInvoice.document.id
        })
        #expect(restored.corrections.contains {
            $0.document.id == values.excludedInvoice.document.id
                && $0.decision == .exclusion(values.exclusion)
        })
        #expect(try await correctionRows(values.fixture.database, values.dossier.id) == rows)
        #expect(restored.token != changed.token)
    }

    @Test func relationshipDecisionRequiresCurrentInvoiceAndPaymentContent() async throws {
        for changeInvoice in [true, false] {
            let values = try await PersistedPersonDossierScenario.make()
            let initial = try await values.repository.personDossierSnapshot(id: values.dossier.id)
            #expect(initial.costsAndPayments.contains {
                $0.document.id == values.payment.document.id
            })
            let decisionRows = try await values.fixture.databaseSnapshot(
                tables: ["invoicePaymentUserDecision"]
            )
            let changedEndpoint = try await values.fixture.reanalyze(
                changeInvoice ? values.invoice : values.payment,
                contentHash: changeInvoice ? "changed-invoice-content" : "changed-payment-content",
                analyzedAt: PersonDossierFixture.repositoryDate(changeInvoice ? 4_101 : 4_102)
            )
            let stale = try await values.repository.personDossierSnapshot(id: values.dossier.id)
            #expect(!stale.costsAndPayments.contains {
                $0.document.id == values.payment.document.id
            })
            #expect(try await values.fixture.databaseSnapshot(
                tables: ["invoicePaymentUserDecision"]
            ) == decisionRows)

            let currentInvoice = changeInvoice ? changedEndpoint : values.invoice
            let currentPayment = changeInvoice ? values.payment : changedEndpoint
            let candidate = try #require(InvoicePaymentCandidateProjector().candidates(
                from: InvoicePaymentCandidateProjectionInput(
                    selected: currentInvoice,
                    matchesByNormalizedReference: [
                        values.includedReference: [
                            currentInvoice, currentPayment, values.rejectedPayment,
                        ],
                    ]
                )
            ).first { $0.payment.document.id == currentPayment.document.id })
            let (_, currentDecision) = try PersonDossierFixture.relationshipDecision(
                for: candidate,
                updatedAt: PersonDossierFixture.repositoryDate(changeInvoice ? 4_111 : 4_112)
            )
            try await values.fixture.insertDecision(currentDecision)

            let restored = try await values.repository.personDossierSnapshot(id: values.dossier.id)
            #expect(restored.costsAndPayments.contains {
                $0.document.id == values.payment.document.id
            })
            #expect(restored.token != stale.token)
        }
    }

    @Test func acceptedStaleCandidateStaysManualAndOldProjectionInputsWriteNothing() async throws {
        let values = try await PersonSuggestionCommandScenario.make(
            variant: .secondaryRole,
            sequence: 4_200
        )
        let repository = values.fixture.makeDossierRepository(sequence: 4_210)
        let initial = try await repository.personDossierSnapshot(id: values.dossier.id)
        let suggestion = try #require(initial.suggestions.first)
        let accepted = try await repository.acceptPersonSuggestion(
            dossierID: values.dossier.id,
            documentID: values.candidate.document.id,
            expectedSupport: suggestion.commandSupport,
            expectedToken: initial.token
        )
        let oldMember = try #require(accepted.directMembers.first {
            $0.document.id == values.candidate.document.id
        })
        let oldCorrection = try #require(accepted.corrections.first)
        _ = try await values.fixture.reanalyze(
            values.candidate,
            contentHash: "changed-accepted-candidate",
            findings: values.candidate.snapshot.findings.filter { $0.kind != .person } + [
                try values.fixture.personFinding(
                    normalizedName: "another person",
                    qualifier: PersonDossierRole.authorizedPerson.rawValue
                ),
            ],
            analyzedAt: PersonDossierFixture.repositoryDate(4_220)
        )
        let current = try await repository.personDossierSnapshot(id: values.dossier.id)
        let currentMember = try #require(current.directMembers.first {
            $0.document.id == values.candidate.document.id
        })
        let confirmation = try #require(try await values.confirmations().first)
        #expect(currentMember.supports == [.manualConfirmation(
            confirmation: confirmation,
            currentCandidate: nil
        )])
        #expect(current.suggestions.isEmpty)

        let beforeInvalidCommands = try await values.fixture.databaseSnapshot()
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.acceptPersonSuggestion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: initial.token
            )
        }
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.rejectPersonSuggestion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: initial.token
            )
        }
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.removePersonMember(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: try oldMember.commandSupport,
                expectedToken: accepted.token
            )
        }
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.acceptPersonSuggestion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: current.token
            )
        }
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.rejectPersonSuggestion(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: current.token
            )
        }
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.removePersonMember(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedSupport: try oldMember.commandSupport,
                expectedToken: current.token
            )
        }
        await #expect(throws: DossierRepositoryError.staleInput) {
            try await repository.resetPersonCorrection(
                dossierID: values.dossier.id,
                documentID: values.candidate.document.id,
                expectedDecision: oldCorrection.decision,
                expectedToken: accepted.token
            )
        }
        #expect(try await values.fixture.databaseSnapshot() == beforeInvalidCommands)
    }

    @Test func stableDocumentMovesAvailabilityAndSourceRemovalPreservePersonLifecycle() async throws {
        let values = try await PersistedPersonDossierScenario.make()
        let movedSource = try await values.fixture.insertSource(
            sequence: 4_300,
            displayName: "Moved Archive"
        )
        let initial = try await values.repository.personDossierSnapshot(id: values.dossier.id)
        let rows = try await correctionRows(values.fixture.database, values.dossier.id)

        try await values.fixture.moveDocument(
            values.origin.document.id,
            to: movedSource,
            path: "moved/origin-renamed.pdf"
        )
        try await values.fixture.moveDocument(
            values.direct.document.id,
            to: movedSource,
            path: "moved/direct-renamed.pdf"
        )
        let south = try #require(values.sourceDisplayNames.first {
            $0.value == "South Archive"
        })
        let southSource = try await values.fixture.database.read { db in
            let source = try SourceRootRecord.fetchOne(db, key: south.key)
            return try #require(source)
        }
        try await values.fixture.moveDocument(
            values.manualDocument.id,
            to: southSource,
            path: "moved/manual-renamed.pdf"
        )

        let moved = try await values.repository.personDossierSnapshot(id: values.dossier.id)
        #expect(moved.origin.document?.relativePath == "moved/origin-renamed.pdf")
        #expect(moved.origin.sourceDisplayName == movedSource.displayName)
        let movedDirect = try #require(moved.directMembers.first {
            $0.document.id == values.direct.document.id
        })
        #expect(movedDirect.document.relativePath == "moved/direct-renamed.pdf")
        #expect(movedDirect.sourceDisplayName == movedSource.displayName)
        let movedManual = try #require(moved.directMembers.first {
            $0.document.id == values.manualDocument.id
        })
        #expect(movedManual.document.relativePath == "moved/manual-renamed.pdf")
        #expect(movedManual.sourceDisplayName == southSource.displayName)
        #expect(moved.token != initial.token)
        #expect(try await correctionRows(values.fixture.database, values.dossier.id) == rows)
        #expect(try await values.repository.personDossierSummaries() == [
            PersonDossierSummary(dossier: values.dossier, anchor: values.anchor),
        ])

        for availability in [DocumentAvailability.unavailable, .missing] {
            try await values.fixture.setAvailability(
                availability,
                for: values.direct.document.id
            )
            try await values.fixture.setAvailability(
                availability,
                for: values.origin.document.id
            )
            let unavailable = try await values.repository.personDossierSnapshot(
                id: values.dossier.id
            )
            #expect(unavailable.origin.validity == .current)
            #expect(unavailable.origin.document?.availability == availability)
            #expect(unavailable.directMembers.first {
                $0.document.id == values.direct.document.id
            }?.document.availability == availability)
        }

        try await values.fixture.database.write { db in
            try db.execute(
                sql: "UPDATE document SET contentHash = 'stale-origin-content' WHERE id = ?",
                arguments: [values.origin.document.id]
            )
        }
        let staleOrigin = try await values.repository.personDossierSnapshot(id: values.dossier.id)
        #expect(staleOrigin.origin.validity == .stale)
        #expect(staleOrigin.origin.document?.availability == .missing)
        let directBeforeRemoval = try #require(staleOrigin.directMembers.first {
            $0.document.id == values.direct.document.id
        })
        let withOriginSourceCorrection = try await values.repository.removePersonMember(
            dossierID: values.dossier.id,
            documentID: values.direct.document.id,
            expectedSupport: try directBeforeRemoval.commandSupport,
            expectedToken: staleOrigin.token
        )
        let originSourceCorrection = try #require(withOriginSourceCorrection.corrections.first {
            $0.document.id == values.direct.document.id
        })
        guard case let .exclusion(originSourceExclusion) = originSourceCorrection.decision else {
            Issue.record("Expected an exclusion on the moved origin source")
            return
        }

        try await SourceRootRepository(dbWriter: values.fixture.database).remove(id: southSource.id)
        let withoutNonOriginSource = try await values.repository.personDossierSnapshot(
            id: values.dossier.id
        )
        #expect((withoutNonOriginSource.directMembers + withoutNonOriginSource.costsAndPayments)
            .allSatisfy { $0.document.sourceRootID != southSource.id })
        #expect(!withoutNonOriginSource.corrections.contains {
            $0.document.sourceRootID == southSource.id
        })
        #expect(try await correctionRows(values.fixture.database, values.dossier.id)
            == PersonCorrectionRows(confirmations: [], exclusions: [originSourceExclusion]))
        await #expect(throws: DossierRepositoryError.dossierNotFound) {
            try await values.repository.snapshot(id: values.costsDossier.id)
        }

        try await SourceRootRepository(dbWriter: values.fixture.database).remove(id: movedSource.id)
        let withoutOriginSource = try await values.repository.personDossierSnapshot(
            id: values.dossier.id
        )
        #expect(withoutOriginSource.origin.validity == .unavailable)
        #expect(withoutOriginSource.origin.document == nil)
        #expect((withoutOriginSource.directMembers + withoutOriginSource.costsAndPayments)
            .allSatisfy { $0.document.sourceRootID != movedSource.id })
        #expect(try await correctionRows(values.fixture.database, values.dossier.id)
            == PersonCorrectionRows(confirmations: [], exclusions: []))
        #expect(try await values.fixture.personPersistenceCounts() == (1, 1))
        #expect(try await values.repository.personDossierSummaries() == [
            PersonDossierSummary(dossier: values.dossier, anchor: values.anchor),
        ])
    }

    @Test func preCancelledPersonCommandsPreserveCancellationAndEveryPersistedTable() async throws {
        do {
            let fixture = try await PersonDossierFixture.make()
            let finding = try fixture.personFinding(
                qualifier: PersonDossierRole.resident.rawValue
            )
            let current = try await fixture.insertSnapshot(
                id: PersonDossierFixture.repositoryUUID(4_400),
                path: "cancel/create.pdf",
                findings: [finding],
                documentType: .correspondence
            )
            let repository = fixture.makeDossierRepository(sequence: 4_401)
            let selection = try fixture.selection(current: current, finding: finding)
            let before = try await fixture.databaseSnapshot()
            await expectPreCancelled {
                try await repository.createOrOpenPersonDossier(from: selection)
            }
            #expect(try await fixture.databaseSnapshot() == before)
        }

        do {
            let values = try await PersonSuggestionCommandScenario.make(
                variant: .secondaryRole,
                sequence: 4_500
            )
            let repository = values.fixture.makeDossierRepository(sequence: 4_510)
            let snapshot = try await repository.personDossierSnapshot(id: values.dossier.id)
            let suggestion = try #require(snapshot.suggestions.first)
            var before = try await values.fixture.databaseSnapshot()
            await expectPreCancelled {
                try await repository.acceptPersonSuggestion(
                    dossierID: values.dossier.id,
                    documentID: values.candidate.document.id,
                    expectedSupport: suggestion.commandSupport,
                    expectedToken: snapshot.token
                )
            }
            #expect(try await values.fixture.databaseSnapshot() == before)
            before = try await values.fixture.databaseSnapshot()
            await expectPreCancelled {
                try await repository.rejectPersonSuggestion(
                    dossierID: values.dossier.id,
                    documentID: values.candidate.document.id,
                    expectedSupport: suggestion.commandSupport,
                    expectedToken: snapshot.token
                )
            }
            #expect(try await values.fixture.databaseSnapshot() == before)
        }

        do {
            let values = try await PersistedPersonDossierScenario.make()
            let snapshot = try await values.repository.personDossierSnapshot(id: values.dossier.id)
            let member = try #require(snapshot.directMembers.first {
                $0.document.id == values.direct.document.id
            })
            let correction = try #require(snapshot.corrections.first {
                $0.document.id == values.excludedInvoice.document.id
            })
            var before = try await values.fixture.databaseSnapshot()
            await expectPreCancelled {
                try await values.repository.removePersonMember(
                    dossierID: values.dossier.id,
                    documentID: values.direct.document.id,
                    expectedSupport: try member.commandSupport,
                    expectedToken: snapshot.token
                )
            }
            #expect(try await values.fixture.databaseSnapshot() == before)
            before = try await values.fixture.databaseSnapshot()
            await expectPreCancelled {
                try await values.repository.resetPersonCorrection(
                    dossierID: values.dossier.id,
                    documentID: values.excludedInvoice.document.id,
                    expectedDecision: correction.decision,
                    expectedToken: snapshot.token
                )
            }
            #expect(try await values.fixture.databaseSnapshot() == before)
        }
    }

    @Test func successfulPersonCommandsNeverMutateAnalysisOrRelationshipTables() async throws {
        let fixture = try await PersonDossierFixture.make()
        let originFinding = try fixture.personFinding(
            qualifier: PersonDossierRole.resident.rawValue
        )
        let origin = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(4_600),
            path: "protected/origin.pdf",
            findings: [originFinding],
            documentType: .correspondence
        )
        _ = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(4_601),
            path: "protected/suggestion.pdf",
            findings: [try fixture.personFinding(
                qualifier: PersonDossierRole.authorizedPerson.rawValue
            )],
            documentType: .powerOfAttorney
        )
        let repository = fixture.makeDossierRepository(sequence: 4_610)
        let selection = try fixture.selection(current: origin, finding: originFinding)

        var protectedBefore = try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        )
        let createdResult = try await repository.createOrOpenPersonDossier(from: selection)
        guard case let .opened(created) = createdResult else {
            Issue.record("Expected a newly opened person dossier")
            return
        }
        #expect(try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        ) == protectedBefore)

        let suggestion = try #require(created.suggestions.first)
        protectedBefore = try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        )
        let accepted = try await repository.acceptPersonSuggestion(
            dossierID: created.dossier.id,
            documentID: suggestion.document.id,
            expectedSupport: suggestion.commandSupport,
            expectedToken: created.token
        )
        #expect(try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        ) == protectedBefore)

        let member = try #require(accepted.directMembers.first {
            $0.document.id == suggestion.document.id
        })
        protectedBefore = try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        )
        let removed = try await repository.removePersonMember(
            dossierID: created.dossier.id,
            documentID: suggestion.document.id,
            expectedSupport: try member.commandSupport,
            expectedToken: accepted.token
        )
        #expect(try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        ) == protectedBefore)

        let removalCorrection = try #require(removed.corrections.first)
        protectedBefore = try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        )
        let reset = try await repository.resetPersonCorrection(
            dossierID: created.dossier.id,
            documentID: suggestion.document.id,
            expectedDecision: removalCorrection.decision,
            expectedToken: removed.token
        )
        #expect(try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        ) == protectedBefore)

        let currentSuggestion = try #require(reset.suggestions.first)
        protectedBefore = try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        )
        let rejected = try await repository.rejectPersonSuggestion(
            dossierID: created.dossier.id,
            documentID: currentSuggestion.document.id,
            expectedSupport: currentSuggestion.commandSupport,
            expectedToken: reset.token
        )
        #expect(try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        ) == protectedBefore)

        let rejectionCorrection = try #require(rejected.corrections.first)
        protectedBefore = try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        )
        _ = try await repository.resetPersonCorrection(
            dossierID: created.dossier.id,
            documentID: currentSuggestion.document.id,
            expectedDecision: rejectionCorrection.decision,
            expectedToken: rejected.token
        )
        #expect(try await fixture.databaseSnapshot(
            tables: PersonDossierDatabaseSnapshot.protectedTables
        ) == protectedBefore)
    }
}

private struct PersonCorrectionRows: Equatable {
    let confirmations: [DossierMembershipConfirmation]
    let exclusions: [DossierMembershipExclusion]
}

private func correctionRows(
    _ database: DatabaseQueue,
    _ dossierID: UUID
) async throws -> PersonCorrectionRows {
    try await database.read { db in
        try PersonCorrectionRows(
            confirmations: DossierStore.confirmations(in: db, dossierID: dossierID),
            exclusions: DossierStore.exclusions(in: db, dossierID: dossierID)
        )
    }
}

private func expectPreCancelled<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) async {
    let task = Task<T, any Error> {
        withUnsafeCurrentTask { task in task?.cancel() }
        return try await operation()
    }
    do {
        _ = try await task.value
        Issue.record("Expected CancellationError")
    } catch is CancellationError {
        // Cancellation must cross the repository boundary unchanged.
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
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
    let unrelatedDecision: InvoicePaymentDecisionRecord
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
            unrelatedDecision: unrelatedDecision,
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

private struct PersonSuggestionCommandScenario: Sendable {
    enum Variant: CaseIterable {
        case secondaryRole
        case birthDateConflict
    }

    let fixture: PersonDossierFixture
    let dossier: DossierRecord
    let candidate: CurrentDocumentDNA

    static func make(
        variant: Variant,
        sequence: Int,
        additionalSuggestion: Bool = false
    ) async throws -> Self {
        let fixture = try await PersonDossierFixture.make()
        let originPerson = try fixture.personFinding(
            qualifier: PersonDossierRole.resident.rawValue
        )
        let originBirthFinding = try fixture.birthDateFinding(
            normalizedValue: "1940-02-01"
        )
        let origin = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(sequence),
            path: "commands/\(sequence)-origin.pdf",
            findings: [originPerson, originBirthFinding],
            documentType: .correspondence,
            analyzedAt: PersonDossierFixture.repositoryDate(TimeInterval(sequence))
        )
        let birthDate = try PersonDossierBirthDate(
            displayValue: originBirthFinding.displayValue,
            normalizedValue: originBirthFinding.normalizedValue,
            evidence: originBirthFinding.evidence
        )
        let anchor = try fixture.makePersonAnchor(
            sequence: sequence + 1,
            origin: origin,
            finding: originPerson,
            birthDate: birthDate
        )
        let dossier = try DossierRecord(
            id: PersonDossierFixture.repositoryUUID(sequence + 2),
            kind: .personMatter,
            displayName: "Suggestion commands",
            anchor: .person(anchor),
            createdAt: PersonDossierFixture.repositoryDate(TimeInterval(sequence + 2)),
            updatedAt: PersonDossierFixture.repositoryDate(TimeInterval(sequence + 2))
        )
        try await fixture.database.write { db in
            let storedAnchor = try PersonDossierAnchorStore.insertOrFetch(
                in: db,
                proposed: anchor
            )
            _ = try DossierStore.insertOrFetchAnchored(
                in: db,
                proposed: try DossierRecord(
                    id: dossier.id,
                    kind: dossier.kind,
                    displayName: dossier.displayName,
                    anchor: .person(storedAnchor),
                    createdAt: dossier.createdAt,
                    updatedAt: dossier.updatedAt
                )
            )
        }

        let candidateFindings: [DocumentDNAFinding]
        let candidateType: DocumentType
        switch variant {
        case .secondaryRole:
            candidateFindings = [try fixture.personFinding(
                qualifier: PersonDossierRole.authorizedPerson.rawValue
            )]
            candidateType = .powerOfAttorney
        case .birthDateConflict:
            candidateFindings = [
                try fixture.personFinding(qualifier: PersonDossierRole.insuredPerson.rawValue),
                try fixture.birthDateFinding(
                    displayValue: "02.03.1941",
                    normalizedValue: "1941-03-02"
                ),
            ]
            candidateType = .correspondence
        }
        let candidate = try await fixture.insertSnapshot(
            id: PersonDossierFixture.repositoryUUID(sequence + 3),
            path: "commands/\(sequence)-candidate.pdf",
            findings: candidateFindings,
            documentType: candidateType,
            analyzedAt: PersonDossierFixture.repositoryDate(TimeInterval(sequence + 3))
        )
        if additionalSuggestion {
            _ = try await fixture.insertSnapshot(
                id: PersonDossierFixture.repositoryUUID(sequence + 4),
                path: "commands/\(sequence)-second-candidate.pdf",
                findings: [try fixture.personFinding(
                    qualifier: PersonDossierRole.authorizedPerson.rawValue
                )],
                documentType: .contract,
                analyzedAt: PersonDossierFixture.repositoryDate(TimeInterval(sequence + 4))
            )
        }
        return Self(fixture: fixture, dossier: dossier, candidate: candidate)
    }

    func confirmations() async throws -> [DossierMembershipConfirmation] {
        try await fixture.database.read { db in
            try DossierStore.confirmations(in: db, dossierID: dossier.id)
        }
    }

    func exclusions() async throws -> [DossierMembershipExclusion] {
        try await fixture.database.read { db in
            try DossierStore.exclusions(in: db, dossierID: dossier.id)
        }
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
    var sqliteBytes: String {
        uuidString.replacingOccurrences(of: "-", with: "")
    }

    var sqliteHexLiteral: String {
        "x'\(sqliteBytes)'"
    }
}
