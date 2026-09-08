import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Person dossier acceptance")
struct PersonDossierAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINKLOOM_PERF_TEST"] == "1"))
    func indexedLookupAndProjectionStayBoundedAtTenThousandDocuments() async throws {
        let fixture = try await PersonDossierFixture.make()
        let corpus = try await fixture.makeAcceptanceCorpus(documentCount: 10_000)
        let trace = PersonDossierAcceptanceSQLTrace()
        try await fixture.database.write { db in
            db.trace(options: .statement) { event in trace.record(event) }
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        trace.beginPersonLookup()
        let matches = try await PersonDossierCandidateLookup(
            repository: fixture.repository,
            target: fixture.target
        ).currentDocuments(matchingNormalizedName: corpus.anchor.normalizedName)
        let personTrace = trace.personCounts

        trace.beginRelationshipLookup()
        let relationshipCandidates = try await InvoicePaymentCandidateLookup(
            repository: fixture.repository,
            target: fixture.target
        ).candidates(involving: corpus.invoiceDocumentID)
        let relationshipTrace = trace.relationshipCounts
        try await fixture.database.write { db in db.trace(options: []) }

        let catalogCount = try await fixture.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document") ?? 0
        }
        let matchIDs = matches.map(\.document.id)
        #expect(catalogCount == 10_000)
        #expect(matchIDs == corpus.expectedPersonMatchIDs)
        #expect(personTrace.indexedCohortReadCount == 1)
        #expect(personTrace.completeSnapshotHeaderReadCount == 3)
        #expect(relationshipTrace.indexedCohortReadCount == 1)

        try #require(relationshipCandidates.count == 1)
        let relationship = relationshipCandidates[0]
        #expect(relationship.invoice.document.id == corpus.invoiceDocumentID)
        #expect(relationship.payment.document.id == corpus.paymentDocumentID)
        let (decisionKey, decision) = try PersonDossierFixture.relationshipDecision(
            for: relationship
        )
        var currentDocumentsByID: [UUID: CurrentDocumentDNA] = [:]
        for current in matches + [relationship.invoice, relationship.payment] {
            currentDocumentsByID[current.document.id] = current
        }
        let documentsByID = currentDocumentsByID.mapValues(\.document)
        let origin = try #require(currentDocumentsByID[corpus.directDocumentID])
        let input = PersonDossierProjectionInput(
            dossier: corpus.dossier,
            originDocument: origin.document,
            currentOrigin: origin,
            documentsByID: documentsByID,
            currentDocumentsByID: currentDocumentsByID,
            personCandidates: matches,
            relationshipCandidates: relationshipCandidates,
            relationshipDecisionsByKey: [decisionKey: decision],
            sourceDisplayNames: [fixture.source.id: fixture.source.displayName],
            confirmations: [],
            exclusions: []
        )

        let snapshot = try PersonDossierProjector().project(input)
        let directMemberIDs = snapshot.directMembers.map { $0.id }
        let costsAndPaymentsIDs = snapshot.costsAndPayments.map { $0.id }
        let suggestionIDs = snapshot.suggestions.map { $0.id }
        #expect(directMemberIDs == [corpus.directDocumentID])
        #expect(costsAndPaymentsIDs == [
            corpus.invoiceDocumentID,
            corpus.paymentDocumentID,
        ])
        #expect(suggestionIDs == [corpus.secondaryDocumentID])
        #expect(snapshot.corrections.isEmpty)
        let payment = try #require(snapshot.costsAndPayments.first {
            $0.id == corpus.paymentDocumentID
        })
        let confirmedPaymentSupportCount = payment.supports.count { support in
            if case .confirmedPayment = support { return true }
            return false
        }
        #expect(confirmedPaymentSupportCount == 1)

        let visibleDocumentIDs = documentIDsReferenced(by: snapshot)
        let expectedVisibleDocumentIDs: Set<UUID> = [
            corpus.directDocumentID,
            corpus.invoiceDocumentID,
            corpus.paymentDocumentID,
            corpus.secondaryDocumentID,
        ]
        #expect(visibleDocumentIDs == expectedVisibleDocumentIDs)
        #expect(visibleDocumentIDs.isDisjoint(with: corpus.unrelatedDocumentIDs))

        let reversedInput = PersonDossierProjectionInput(
            dossier: corpus.dossier,
            originDocument: origin.document,
            currentOrigin: origin,
            documentsByID: documentsByID,
            currentDocumentsByID: currentDocumentsByID,
            personCandidates: matches.reversed(),
            relationshipCandidates: relationshipCandidates.reversed(),
            relationshipDecisionsByKey: [decisionKey: decision],
            sourceDisplayNames: [fixture.source.id: fixture.source.displayName],
            confirmations: [],
            exclusions: []
        )
        let reversedSnapshot = try PersonDossierProjector().project(reversedInput)
        #expect(reversedSnapshot == snapshot)
        #expect(reversedSnapshot.token == snapshot.token)

        let elapsed = startedAt.duration(to: clock.now).components
        let elapsedMilliseconds = elapsed.seconds * 1_000
            + elapsed.attoseconds / 1_000_000_000_000_000
        let diagnostic = "Person dossier scale: catalog=\(catalogCount) "
            + "matches=\(matches.count) "
            + "personCohorts=\(personTrace.indexedCohortReadCount) "
            + "snapshots=\(personTrace.completeSnapshotHeaderReadCount) "
            + "relationshipCohorts=\(relationshipTrace.indexedCohortReadCount) "
            + "elapsedMs=\(elapsedMilliseconds)"
        print(diagnostic)
    }
}

private final class PersonDossierAcceptanceSQLTrace: @unchecked Sendable {
    struct Counts: Sendable, Equatable {
        var indexedCohortReadCount = 0
        var completeSnapshotHeaderReadCount = 0
    }

    private enum Phase {
        case setup
        case person
        case relationship
    }

    private let lock = NSLock()
    private var phase = Phase.setup
    private var person = Counts()
    private var relationship = Counts()

    var personCounts: Counts { lock.withLock { person } }
    var relationshipCounts: Counts { lock.withLock { relationship } }

    func beginPersonLookup() {
        lock.withLock { phase = .person }
    }

    func beginRelationshipLookup() {
        lock.withLock { phase = .relationship }
    }

    func record(_ event: Database.TraceEvent) {
        guard case let .statement(statement) = event else { return }
        lock.withLock {
            switch phase {
            case .setup:
                break
            case .person:
                record(statement.sql, in: &person)
            case .relationship:
                record(statement.sql, in: &relationship)
            }
        }
    }

    private func record(_ sql: String, in counts: inout Counts) {
        if sql.contains("INDEXED BY document_dna_finding_kind_value") {
            counts.indexedCohortReadCount += 1
        }
        if sql.contains("SELECT schemaVersion, analyzerIdentifier, analyzerVersion,")
            && sql.contains("FROM documentDNA") {
            counts.completeSnapshotHeaderReadCount += 1
        }
    }
}

private func documentIDsReferenced(by snapshot: PersonDossierSnapshot) -> Set<UUID> {
    var result = Set(snapshot.directMembers.map(\.id))
    result.formUnion(snapshot.costsAndPayments.map(\.id))
    result.formUnion(snapshot.suggestions.map(\.id))
    result.formUnion(snapshot.corrections.map(\.id))
    result.formUnion(snapshot.token.documents.map(\.documentID))

    for member in snapshot.directMembers + snapshot.costsAndPayments {
        for support in member.supports {
            switch support {
            case let .exactPrimary(identity):
                result.insert(identity.documentID)
            case let .manualConfirmation(confirmation, currentCandidate):
                result.insert(confirmation.documentID)
                if let currentCandidate {
                    result.insert(currentCandidate.person.documentID)
                }
            case let .confirmedPayment(identity):
                result.insert(identity.invoiceDocumentID)
                result.insert(identity.relationship.decisionKey.invoiceDocumentID)
                result.insert(identity.relationship.decisionKey.paymentDocumentID)
            }
        }
    }
    for suggestion in snapshot.suggestions {
        result.formUnion(suggestion.currentSupports.map(\.person.documentID))
        result.insert(suggestion.commandSupport.person.documentID)
    }
    return result
}
