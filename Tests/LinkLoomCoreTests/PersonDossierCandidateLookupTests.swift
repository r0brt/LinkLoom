import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Person dossier candidate lookup")
struct PersonDossierCandidateLookupTests {
    @Test func lookupReturnsCompleteCurrentSnapshotsForAllSixSupportedRoles() async throws {
        let fixture = try await PersonDossierFixture.make()
        var expected: [CurrentDocumentDNA] = []
        for (index, role) in PersonDossierRole.allCases.enumerated() {
            expected.append(try await fixture.insertSnapshot(
                id: UUID(uuidString: String(format: "72000000-0000-0000-0000-%012d", index + 1))!,
                path: "\(role.rawValue).pdf",
                findings: [try fixture.personFinding(qualifier: role.rawValue)]
            ))
        }

        let matches = try await PersonDossierCandidateLookup(
            repository: fixture.repository,
            target: fixture.target
        ).currentDocuments(matchingNormalizedName: "elise muster")

        #expect(matches == expected.sorted(by: documentOrder))
    }

    @Test func lookupExcludesDifferentNormalizedNamesWithoutAccentFolding() async throws {
        let fixture = try await PersonDossierFixture.make()
        let expected = try await fixture.insertSnapshot(
            path: "exact.pdf",
            findings: [try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)]
        )
        for (index, name) in ["elise müster", "e. muster", "elise"].enumerated() {
            _ = try await fixture.insertSnapshot(
                path: "different-\(index).pdf",
                findings: [try fixture.personFinding(
                    normalizedName: name,
                    qualifier: PersonDossierRole.resident.rawValue
                )]
            )
        }

        let matches = try await PersonDossierCandidateLookup(
            repository: fixture.repository,
            target: fixture.target
        ).currentDocuments(matchingNormalizedName: "elise muster")

        #expect(matches == [expected])
    }

    @Test func lookupDoesNotReconstructUnsupportedOrUnqualifiedPersonSnapshots() async throws {
        let fixture = try await PersonDossierFixture.make()
        _ = try await fixture.insertSnapshot(
            path: "unqualified.pdf",
            findings: [try fixture.personFinding(qualifier: nil)]
        )
        _ = try await fixture.insertSnapshot(
            path: "unsupported.pdf",
            findings: [try fixture.personFinding(qualifier: "beneficiary")]
        )

        let matches = try await PersonDossierCandidateLookup(
            repository: fixture.repository,
            target: fixture.target
        ).currentDocuments(matchingNormalizedName: "elise muster")

        #expect(matches.isEmpty)
    }

    @Test func lookupExcludesStaleContentExtractionAndAnalysisTargets() async throws {
        let fixture = try await PersonDossierFixture.make()
        let control = try await fixture.insertSnapshot(
            path: "control.pdf",
            findings: [try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)]
        )
        for staleness in PersonDossierStaleness.allCases {
            let stale = try await fixture.insertSnapshot(
                path: "stale-\(staleness).pdf",
                findings: [try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)]
            )
            try await fixture.makeStale(stale.document.id, by: staleness)
        }

        let matches = try await PersonDossierCandidateLookup(
            repository: fixture.repository,
            target: fixture.target
        ).currentDocuments(matchingNormalizedName: "elise muster")

        #expect(matches == [control])
    }

    @Test func lookupDeduplicatesDocumentsWithRepeatedSupportedExactFindings() async throws {
        let fixture = try await PersonDossierFixture.make()
        let expected = try await fixture.insertSnapshot(
            path: "repeated.pdf",
            findings: [
                try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue),
                try fixture.personFinding(qualifier: PersonDossierRole.insuredPerson.rawValue),
            ]
        )

        let matches = try await PersonDossierCandidateLookup(
            repository: fixture.repository,
            target: fixture.target
        ).currentDocuments(matchingNormalizedName: "elise muster")

        #expect(matches == [expected])
    }

    @Test func lookupUsesOneIndexedCohortReadAndOnlyReconstructsMatches() async throws {
        let fixture = try await PersonDossierFixture.make()
        let expected = try await fixture.insertSnapshot(
            path: "matched.pdf",
            findings: [try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)]
        )
        _ = try await fixture.insertSnapshot(
            path: "unmatched.pdf",
            findings: [try fixture.personFinding(
                normalizedName: "other person",
                qualifier: PersonDossierRole.resident.rawValue
            )]
        )
        let counter = PersonDossierCandidateLookupSQLCounter()
        try await fixture.database.write { db in
            db.trace(options: .statement) { event in counter.record(event) }
        }
        counter.reset()

        let matches = try await PersonDossierCandidateLookup(
            repository: fixture.repository,
            target: fixture.target
        ).currentDocuments(matchingNormalizedName: "elise muster")
        try await fixture.database.write { db in db.trace(options: []) }

        #expect(matches == [expected])
        #expect(counter.indexedCohortReadCount == 1)
        #expect(counter.completeSnapshotHeaderReadCount == matches.count)
    }

    @Test func lookupRejectsBlankNormalizedNameWithoutReadingDNA() async throws {
        let fixture = try await PersonDossierFixture.make()
        _ = try await fixture.insertSnapshot(
            path: "candidate.pdf",
            findings: [try fixture.personFinding(qualifier: PersonDossierRole.resident.rawValue)]
        )
        let counter = PersonDossierCandidateLookupSQLCounter()
        try await fixture.database.write { db in
            db.trace(options: .statement) { event in counter.record(event) }
        }
        counter.reset()

        let empty = try await PersonDossierCandidateLookup(
            repository: fixture.repository,
            target: fixture.target
        ).currentDocuments(matchingNormalizedName: "")
        let whitespace = try await PersonDossierCandidateLookup(
            repository: fixture.repository,
            target: fixture.target
        ).currentDocuments(matchingNormalizedName: " \n\t")
        try await fixture.database.write { db in db.trace(options: []) }

        #expect(empty.isEmpty)
        #expect(whitespace.isEmpty)
        #expect(counter.dnaStatementCount == 0)
    }
}

private final class PersonDossierCandidateLookupSQLCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var indexedCohortReads = 0
    private var completeSnapshotHeaderReads = 0
    private var dnaStatements = 0

    var indexedCohortReadCount: Int { lock.withLock { indexedCohortReads } }
    var completeSnapshotHeaderReadCount: Int { lock.withLock { completeSnapshotHeaderReads } }
    var dnaStatementCount: Int { lock.withLock { dnaStatements } }

    func reset() {
        lock.withLock {
            indexedCohortReads = 0
            completeSnapshotHeaderReads = 0
            dnaStatements = 0
        }
    }

    func record(_ event: Database.TraceEvent) {
        guard case let .statement(statement) = event else { return }
        lock.withLock {
            if statement.sql.contains("documentDNA") { dnaStatements += 1 }
            if statement.sql.contains("INDEXED BY document_dna_finding_kind_value") {
                indexedCohortReads += 1
            }
            if statement.sql.contains("SELECT schemaVersion, analyzerIdentifier, analyzerVersion,")
                && statement.sql.contains("FROM documentDNA") {
                completeSnapshotHeaderReads += 1
            }
        }
    }
}

private func documentOrder(_ lhs: CurrentDocumentDNA, _ rhs: CurrentDocumentDNA) -> Bool {
    (lhs.document.sourceRootID.uuidString, lhs.document.relativePath, lhs.document.id.uuidString)
        < (rhs.document.sourceRootID.uuidString, rhs.document.relativePath, rhs.document.id.uuidString)
}
