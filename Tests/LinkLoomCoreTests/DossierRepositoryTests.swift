import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Dossier repository")
struct DossierRepositoryTests {
    @Test func nonDNAAnchorIsRejectedWithoutCreating() async throws {
        let fixture = try await DossierFixture.empty()
        let document = try await fixture.insertPlainDocument(path: "unanalyzed.pdf")

        await #expect(throws: DossierRepositoryError.invalidAnchor) {
            try await fixture.repository.createOrOpen(anchorDocumentID: document.id)
        }
        #expect(try await fixture.dossierCount() == 0)
    }

    @Test func anchoredCreateOrOpenIsIdempotent() async throws {
        var fixture = try await DossierFixture.empty()
        let anchor = try await fixture.insertAnalyzedDocument(
            id: UUID(uuidString: "82000000-0000-0000-0000-000000000030")!,
            path: "anchor.pdf",
            type: .invoice,
            reference: "IDEMPOTENT42"
        )

        let first = try await fixture.repository.createOrOpen(anchorDocumentID: anchor.id)
        let second = try await fixture.repository.createOrOpen(anchorDocumentID: anchor.id)
        guard case .opened(let firstSnapshot) = first,
              case .opened(let secondSnapshot) = second else {
            Issue.record("Expected the anchored dossier to open")
            return
        }
        #expect(firstSnapshot.dossier.id == DossierFixture.proposedDossierID)
        #expect(secondSnapshot.dossier.id == firstSnapshot.dossier.id)
        #expect(try await fixture.dossierCount() == 1)
        #expect(try await fixture.repository.entryDisposition(for: anchor.id)
            == .open(DossierSummary(dossier: firstSnapshot.dossier, anchor: anchor)))
    }

    @Test func confirmedMemberReusesExistingDossier() async throws {
        let values = try await DossierFixture.confirmedPair()
        let before = try await values.fixture.dossierCount()

        let disposition = try await values.fixture.repository.entryDisposition(
            for: values.payment.id
        )
        let result = try await values.fixture.repository.createOrOpen(
            anchorDocumentID: values.payment.id
        )

        guard case .open(let summary) = disposition,
              case .opened(let snapshot) = result else {
            Issue.record("Expected the existing member dossier to open")
            return
        }
        #expect(summary.id == values.dossier.id)
        #expect(snapshot.dossier.id == values.dossier.id)
        #expect(snapshot.members.map(\.id) == [values.invoice.id, values.payment.id])
        #expect(try await values.fixture.dossierCount() == before)
    }

    @Test func multipleMembershipMatchesRequireChoiceWithoutCreating() async throws {
        let fixture = try await DossierFixture.multipleMatchingDossiers()
        let before = try await fixture.dossierCount()

        let disposition = try await fixture.repository.entryDisposition(
            for: fixture.sharedPayment.id
        )
        let result = try await fixture.repository.createOrOpen(
            anchorDocumentID: fixture.sharedPayment.id
        )

        guard case .choose(let advisoryChoices) = disposition,
              case .choose(let choices) = result else {
            Issue.record("Expected ambiguous dossier choice")
            return
        }
        #expect(advisoryChoices.map(\.id) == fixture.expectedChoiceIDs)
        #expect(choices.map(\.id) == fixture.expectedChoiceIDs)
        #expect(try await fixture.dossierCount() == before)
    }

    @Test func distinctAnchorsMayCreateSameNamedDossiers() async throws {
        var fixture = try await DossierFixture.empty()
        let first = try await fixture.insertAnalyzedDocument(
            id: UUID(uuidString: "82000000-0000-0000-0000-000000000040")!,
            path: "first.pdf",
            type: .invoice,
            reference: "FIRST42"
        )
        let second = try await fixture.insertAnalyzedDocument(
            id: UUID(uuidString: "82000000-0000-0000-0000-000000000041")!,
            path: "second.pdf",
            type: .invoice,
            reference: "SECOND42"
        )
        #expect(try await fixture.repository.entryDisposition(for: first.id) == .create)

        _ = try await fixture.repository.createOrOpen(anchorDocumentID: first.id)
        let secondRepository = DossierRepository(
            dbWriter: fixture.db,
            target: fixture.target,
            now: { DossierFixture.baseDate.addingTimeInterval(1) },
            makeUUID: {
                UUID(uuidString: "82000000-0000-0000-0000-000000000091")!
            }
        )
        _ = try await secondRepository.createOrOpen(anchorDocumentID: second.id)

        let summaries = try await fixture.repository.summaries()
        #expect(summaries.count == 2)
        #expect(Set(summaries.map(\.dossier.displayName)) == ["Kosten und Zahlungen"])
        #expect(Set(summaries.map(\.anchor.id)) == [first.id, second.id])
    }

    @Test func summariesAreOrderedByCreationDateThenUUID() async throws {
        var fixture = try await DossierFixture.empty()
        let anchors = try await [
            ("82000000-0000-0000-0000-000000000050", "late-low.pdf", "LATELOW"),
            ("82000000-0000-0000-0000-000000000051", "early.pdf", "EARLY"),
            ("82000000-0000-0000-0000-000000000052", "late-high.pdf", "LATEHIGH"),
        ].asyncMap { id, path, reference in
            try await fixture.insertAnalyzedDocument(
                id: UUID(uuidString: id)!,
                path: path,
                type: .invoice,
                reference: reference
            )
        }
        let lowID = UUID(uuidString: "82000000-0000-0000-0000-000000000060")!
        let earlyID = UUID(uuidString: "82000000-0000-0000-0000-000000000061")!
        let highID = UUID(uuidString: "82000000-0000-0000-0000-000000000062")!
        try await fixture.insert(try fixture.makeDossier(
            id: highID,
            anchor: anchors[2],
            createdAt: DossierFixture.baseDate.addingTimeInterval(20)
        ))
        try await fixture.insert(try fixture.makeDossier(
            id: earlyID,
            anchor: anchors[1],
            createdAt: DossierFixture.baseDate.addingTimeInterval(10)
        ))
        try await fixture.insert(try fixture.makeDossier(
            id: lowID,
            anchor: anchors[0],
            createdAt: DossierFixture.baseDate.addingTimeInterval(20)
        ))

        #expect(try await fixture.repository.summaries().map(\.id)
            == [earlyID, lowID, highID])
    }

    @Test func snapshotKeepsAnchorAfterItsDNABecomesStale() async throws {
        let values = try await DossierFixture.confirmedPair()
        try await values.fixture.makeDNAStale(for: values.invoice.id)

        let snapshot = try await values.fixture.repository.snapshot(id: values.dossier.id)

        #expect(snapshot.members.map(\.id) == [values.invoice.id])
        #expect(snapshot.members[0].documentType == nil)
        #expect(snapshot.members[0].sourceDisplayName == "Dossier documents")
        #expect(snapshot.token.anchorContentHash == "changed-content-hash")
    }

    @Test func malformedDNAIsMappedToInvalidStoredState() async throws {
        let values = try await DossierFixture.confirmedPair()
        try await values.fixture.corruptDocumentTypeFinding(for: values.invoice.id)

        await #expect(throws: DossierRepositoryError.invalidStoredState) {
            try await values.fixture.repository.snapshot(id: values.dossier.id)
        }
    }
}

private extension Array {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var values: [T] = []
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
