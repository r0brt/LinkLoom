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
