import Foundation
import GRDB
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

    @Test func excludeMemberCreatesCorrectionWithoutChangingDecision() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        let decisions = InvoicePaymentDecisionRepository(dbWriter: values.fixture.db)
        let decisionBefore = try #require(try await decisions.currentDecision(
            for: support.decisionKey
        ))
        let decisionCountBefore = try await values.fixture.decisionCount()

        let corrected = try await values.fixture.repository.excludeMember(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedSupport: support
        )

        #expect(corrected.members.map(\.id) == [values.invoice.id])
        #expect(corrected.corrections.map(\.document.id) == [values.payment.id])
        #expect(corrected.corrections[0].exclusion.revisionID
            == DossierFixture.proposedDossierID)
        #expect(try await decisions.currentDecision(for: support.decisionKey)
            == decisionBefore)
        #expect(try await values.fixture.decisionCount() == decisionCountBefore)
    }

    @Test func anchorCannotBeExcluded() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let memberSupport = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)

        await #expect(throws: DossierRepositoryError.staleInput) {
            try await values.fixture.repository.excludeMember(
                dossierID: values.dossier.id,
                documentID: values.invoice.id,
                expectedSupport: memberSupport
            )
        }
        #expect(try await values.fixture.exclusionCount() == 0)
    }

    @Test func staleSupportCannotExcludeMember() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let oldSupport = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        try await values.fixture.confirm(
            invoice: values.invoice,
            payment: values.payment,
            updatedAt: DossierFixture.baseDate.addingTimeInterval(60)
        )
        let current = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let currentSupport = try #require(current.members.first {
            $0.id == values.payment.id
        }?.support)
        #expect(currentSupport != oldSupport)

        await #expect(throws: DossierRepositoryError.staleInput) {
            try await values.fixture.repository.excludeMember(
                dossierID: values.dossier.id,
                documentID: values.payment.id,
                expectedSupport: oldSupport
            )
        }
        #expect(try await values.fixture.exclusionCount() == 0)
    }

    @Test func duplicateExclusionIsStaleAndPreservesRevision() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        let first = try await values.fixture.repository.excludeMember(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedSupport: support
        )
        let firstRevision = try #require(first.corrections.first?.exclusion.revisionID)

        await #expect(throws: DossierRepositoryError.staleInput) {
            try await values.fixture.repository.excludeMember(
                dossierID: values.dossier.id,
                documentID: values.payment.id,
                expectedSupport: support
            )
        }

        let stored = try #require(try await values.fixture.exclusions(
            dossierID: values.dossier.id
        ).first)
        #expect(stored.revisionID == firstRevision)
        #expect(try await values.fixture.exclusionCount() == 1)
    }

    @Test func exclusionUniquenessConflictIsStaleAndPreservesStoredRevision() async throws {
        let fixture = try await DossierFixture.multipleMatchingDossiers()
        let firstDossierID = fixture.expectedChoiceIDs[0]
        let secondDossierID = fixture.expectedChoiceIDs[1]
        let firstOpened = try await fixture.repository.snapshot(id: firstDossierID)
        let firstSupport = try #require(firstOpened.members.first {
            $0.id == fixture.sharedPayment.id
        }?.support)
        let first = try await fixture.repository.excludeMember(
            dossierID: firstDossierID,
            documentID: fixture.sharedPayment.id,
            expectedSupport: firstSupport
        )
        let storedRevision = try #require(first.corrections.first?.exclusion.revisionID)
        let secondOpened = try await fixture.repository.snapshot(id: secondDossierID)
        let secondSupport = try #require(secondOpened.members.first {
            $0.id == fixture.sharedPayment.id
        }?.support)

        await #expect(throws: DossierRepositoryError.staleInput) {
            try await fixture.repository.excludeMember(
                dossierID: secondDossierID,
                documentID: fixture.sharedPayment.id,
                expectedSupport: secondSupport
            )
        }

        #expect(try await fixture.exclusions(dossierID: firstDossierID)
            .map(\.revisionID) == [storedRevision])
        #expect(try await fixture.exclusions(dossierID: secondDossierID).isEmpty)
    }

    @Test func resetExclusionRequiresExactRevisionAndRestoresMember() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        let corrected = try await values.fixture.repository.excludeMember(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedSupport: support
        )
        let exclusion = try #require(corrected.corrections.first?.exclusion)
        let decisions = InvoicePaymentDecisionRepository(dbWriter: values.fixture.db)
        let decisionBefore = try await decisions.currentDecision(for: support.decisionKey)

        await #expect(throws: DossierRepositoryError.staleInput) {
            try await values.fixture.repository.resetExclusion(
                dossierID: values.dossier.id,
                documentID: values.payment.id,
                expectedRevisionID: DossierFixture.secondExclusionRevisionID
            )
        }
        #expect(try await values.fixture.exclusions(dossierID: values.dossier.id)
            == [exclusion])

        let restored = try await values.fixture.repository.resetExclusion(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedRevisionID: exclusion.revisionID
        )
        #expect(restored.members.map(\.id) == [values.invoice.id, values.payment.id])
        #expect(restored.corrections.isEmpty)
        #expect(try await decisions.currentDecision(for: support.decisionKey)
            == decisionBefore)
    }

    @Test func oldResetCannotDeleteReplacementExclusionABA() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        let first = try await values.fixture.repository.excludeMember(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedSupport: support
        )
        let firstRevision = try #require(first.corrections.first?.exclusion.revisionID)
        let restored = try await values.fixture.repository.resetExclusion(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedRevisionID: firstRevision
        )
        let restoredSupport = try #require(restored.members.first {
            $0.id == values.payment.id
        }?.support)
        let replacementRepository = values.fixture.makeRepository(
            now: DossierFixture.baseDate.addingTimeInterval(100),
            revisionID: DossierFixture.secondExclusionRevisionID
        )
        let replaced = try await replacementRepository.excludeMember(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedSupport: restoredSupport
        )
        #expect(replaced.corrections.first?.exclusion.revisionID
            == DossierFixture.secondExclusionRevisionID)

        await #expect(throws: DossierRepositoryError.staleInput) {
            try await values.fixture.repository.resetExclusion(
                dossierID: values.dossier.id,
                documentID: values.payment.id,
                expectedRevisionID: firstRevision
            )
        }
        #expect(try await values.fixture.exclusions(dossierID: values.dossier.id)
            .map(\.revisionID) == [DossierFixture.secondExclusionRevisionID])
    }

    @Test func exclusionSurvivesPathAndSourceMoveWithStableDocumentIdentity() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        let corrected = try await values.fixture.repository.excludeMember(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedSupport: support
        )
        let revision = try #require(corrected.corrections.first?.exclusion.revisionID)

        let moved = try await values.fixture.moveDocumentToNewSource(
            id: values.payment.id,
            relativePath: "moved/payment.pdf"
        )
        let afterMove = try await values.fixture.repository.snapshot(id: values.dossier.id)

        #expect(afterMove.corrections.first?.document.id == values.payment.id)
        #expect(afterMove.corrections.first?.document == moved)
        #expect(afterMove.corrections.first?.sourceDisplayName == "Moved dossier documents")
        #expect(afterMove.corrections.first?.exclusion.revisionID == revision)

        let restored = try await values.fixture.repository.resetExclusion(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedRevisionID: revision
        )
        #expect(restored.members.first { $0.id == values.payment.id }?.document == moved)
        #expect(restored.members.first { $0.id == values.payment.id }?.sourceDisplayName
            == "Moved dossier documents")
    }

    @Test func contentChangeRemovesUnsupportedMemberWithoutDeletingDecision() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        let decisions = InvoicePaymentDecisionRepository(dbWriter: values.fixture.db)

        _ = try await values.fixture.reanalyze(
            documentID: values.payment.id,
            contentHash: "hash-payment-v2",
            type: .paymentConfirmation,
            reference: "INV42",
            analyzedAt: DossierFixture.baseDate.addingTimeInterval(100)
        )
        let changed = try await values.fixture.repository.snapshot(id: values.dossier.id)

        #expect(changed.dossier == values.dossier)
        #expect(changed.members.map(\.id) == [values.invoice.id])
        #expect(changed.corrections.isEmpty)
        #expect(try await decisions.currentDecision(for: support.decisionKey) == nil)
        #expect(try await values.fixture.decisionCount() == 1)
    }

    @Test func exactContentReturnReactivatesDecisionAndRetainsExclusion() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        let corrected = try await values.fixture.repository.excludeMember(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedSupport: support
        )
        let revision = try #require(corrected.corrections.first?.exclusion.revisionID)

        _ = try await values.fixture.reanalyze(
            documentID: values.payment.id,
            contentHash: "hash-payment-v2",
            type: .paymentConfirmation,
            reference: "INV42",
            analyzedAt: DossierFixture.baseDate.addingTimeInterval(100)
        )
        _ = try await values.fixture.reanalyze(
            documentID: values.payment.id,
            contentHash: values.payment.contentHash,
            type: .paymentConfirmation,
            reference: "INV42",
            analyzedAt: DossierFixture.laterDate
        )
        let returned = try await values.fixture.repository.snapshot(id: values.dossier.id)

        #expect(returned.members.map(\.id) == [values.invoice.id])
        #expect(returned.corrections.map(\.exclusion.revisionID) == [revision])
        #expect(try await values.fixture.decisionCount() == 1)

        let restored = try await values.fixture.repository.resetExclusion(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedRevisionID: revision
        )
        let returnedSupport = try #require(restored.members.first {
            $0.id == values.payment.id
        }?.support)
        #expect(returnedSupport.decisionKey == support.decisionKey)
        #expect(returnedSupport.paymentDNAAnalyzedAt == DossierFixture.laterDate)
    }

    @Test func oldSupportCannotExcludeAfterExactContentReturns() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let oldSupport = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)

        _ = try await values.fixture.reanalyze(
            documentID: values.payment.id,
            contentHash: "hash-payment-v2",
            type: .paymentConfirmation,
            reference: "INV42",
            analyzedAt: DossierFixture.baseDate.addingTimeInterval(100)
        )
        _ = try await values.fixture.reanalyze(
            documentID: values.payment.id,
            contentHash: values.payment.contentHash,
            type: .paymentConfirmation,
            reference: "INV42",
            analyzedAt: DossierFixture.laterDate
        )
        let returned = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let currentSupport = try #require(returned.members.first {
            $0.id == values.payment.id
        }?.support)
        #expect(currentSupport.decisionKey == oldSupport.decisionKey)
        #expect(currentSupport.decisionUpdatedAt == oldSupport.decisionUpdatedAt)
        #expect(currentSupport.paymentDNAAnalyzedAt == DossierFixture.laterDate)
        #expect(currentSupport != oldSupport)

        await #expect(throws: DossierRepositoryError.staleInput) {
            try await values.fixture.repository.excludeMember(
                dossierID: values.dossier.id,
                documentID: values.payment.id,
                expectedSupport: oldSupport
            )
        }
        #expect(try await values.fixture.exclusionCount() == 0)
    }

    @Test func missingAndUnavailableOriginalsRemainVisibleWithAvailability() async throws {
        let values = try await DossierFixture.confirmedPair()
        try await values.fixture.setAvailability(
            documentID: values.invoice.id,
            availability: .unavailable
        )
        try await values.fixture.setAvailability(
            documentID: values.payment.id,
            availability: .missing
        )

        let snapshot = try await values.fixture.repository.snapshot(id: values.dossier.id)

        #expect(snapshot.members.map(\.id) == [values.invoice.id, values.payment.id])
        #expect(snapshot.members.first { $0.id == values.invoice.id }?.document.availability
            == .unavailable)
        #expect(snapshot.members.first { $0.id == values.payment.id }?.document.availability
            == .missing)
    }

    @Test func anchorSourceRemovalCascadesDossierAndExclusion() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        _ = try await values.fixture.repository.excludeMember(
            dossierID: values.dossier.id,
            documentID: values.payment.id,
            expectedSupport: support
        )
        _ = try await values.fixture.moveDocumentToNewSource(
            id: values.payment.id,
            relativePath: "retained/payment.pdf"
        )

        try await SourceRootRepository(dbWriter: values.fixture.db).remove(
            id: values.fixture.source.id
        )

        await #expect(throws: DossierRepositoryError.dossierNotFound) {
            try await values.fixture.repository.snapshot(id: values.dossier.id)
        }
        #expect(try await values.fixture.dossierCount() == 0)
        #expect(try await values.fixture.exclusionCount() == 0)
        #expect(try await values.fixture.document(id: values.payment.id) != nil)
    }

    @Test func correctionsRejectMissingDossier() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        let missingDossierID = UUID(uuidString: "82000000-0000-0000-0000-000000000098")!

        await #expect(throws: DossierRepositoryError.dossierNotFound) {
            try await values.fixture.repository.excludeMember(
                dossierID: missingDossierID,
                documentID: values.payment.id,
                expectedSupport: support
            )
        }
        await #expect(throws: DossierRepositoryError.dossierNotFound) {
            try await values.fixture.repository.resetExclusion(
                dossierID: missingDossierID,
                documentID: values.payment.id,
                expectedRevisionID: UUID()
            )
        }
        #expect(try await values.fixture.exclusionCount() == 0)
    }

    @Test func correctionCancellationIsNotMappedOrPersisted() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await values.fixture.repository.excludeMember(
                dossierID: values.dossier.id,
                documentID: values.payment.id,
                expectedSupport: support
            )
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try await values.fixture.exclusionCount() == 0)
    }

    @Test func unexpectedDatabaseErrorIsNotMapped() async throws {
        let values = try await DossierFixture.confirmedPair()
        let opened = try await values.fixture.repository.snapshot(id: values.dossier.id)
        let support = try #require(opened.members.first {
            $0.id == values.payment.id
        }?.support)
        try values.fixture.db.close()

        await #expect(throws: DatabaseError.self) {
            try await values.fixture.repository.excludeMember(
                dossierID: values.dossier.id,
                documentID: values.payment.id,
                expectedSupport: support
            )
        }
    }

    @Test func malformedDNAIsMappedToInvalidStoredState() async throws {
        let values = try await DossierFixture.confirmedPair()
        try await values.fixture.corruptDocumentTypeFinding(for: values.invoice.id)

        await #expect(throws: DossierRepositoryError.invalidStoredState) {
            try await values.fixture.repository.snapshot(id: values.dossier.id)
        }
    }
}

private extension DossierFixture {
    static var laterDate: Date { baseDate.addingTimeInterval(200) }

    static var secondExclusionRevisionID: UUID {
        UUID(uuidString: "82000000-0000-0000-0000-000000000092")!
    }

    static var movedSourceID: UUID {
        UUID(uuidString: "82000000-0000-0000-0000-000000000093")!
    }

    func confirm(
        invoice: DocumentRecord,
        payment: DocumentRecord,
        updatedAt: Date
    ) async throws {
        let key = try InvoicePaymentDecisionKey(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: invoice.id,
            paymentDocumentID: payment.id,
            invoiceContentHash: invoice.contentHash,
            paymentContentHash: payment.contentHash
        )
        try await InvoicePaymentDecisionRepository(dbWriter: db).save(
            InvoicePaymentDecisionRecord(
                key: key,
                decision: .confirmed,
                updatedAt: updatedAt
            )
        )
    }

    func makeRepository(now: Date, revisionID: UUID) -> DossierRepository {
        DossierRepository(
            dbWriter: db,
            target: target,
            now: { now },
            makeUUID: { revisionID }
        )
    }

    func exclusionCount() async throws -> Int {
        try await db.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM dossierMembershipExclusion"
            )!
        }
    }

    func exclusions(dossierID: UUID) async throws -> [DossierMembershipExclusion] {
        try await db.read { database in
            try DossierStore.exclusions(in: database, dossierID: dossierID)
        }
    }

    func decisionCount() async throws -> Int {
        try await db.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM invoicePaymentUserDecision"
            )!
        }
    }

    func document(id: UUID) async throws -> DocumentRecord? {
        try await db.read { database in
            try DocumentRecord.fetchOne(database, key: id)
        }
    }

    func reanalyze(
        documentID: UUID,
        contentHash: String,
        type: DocumentType,
        reference: String,
        analyzedAt: Date
    ) async throws -> DocumentRecord {
        try await db.write { database in
            try database.execute(
                sql: "UPDATE document SET contentHash = ? WHERE id = ?",
                arguments: [contentHash, documentID]
            )
        }
        let current = try #require(try await document(id: documentID))
        try await DocumentDNARepository(dbWriter: db).replace(try Self.dna(
            document: current,
            target: target,
            type: type,
            reference: reference,
            analyzedAt: analyzedAt
        ))
        return current
    }

    func moveDocumentToNewSource(
        id: UUID,
        relativePath: String
    ) async throws -> DocumentRecord {
        let movedSource = SourceRootRecord(
            id: Self.movedSourceID,
            displayName: "Moved dossier documents",
            pathHint: "/synthetic/moved-dossiers",
            bookmarkData: Data("moved-dossier-bookmark".utf8),
            createdAt: Self.baseDate.addingTimeInterval(1)
        )
        try await db.write { database in
            try movedSource.insert(database, onConflict: .ignore)
            try database.execute(
                sql: "UPDATE document SET sourceRootID = ?, relativePath = ? WHERE id = ?",
                arguments: [movedSource.id, relativePath, id]
            )
        }
        return try #require(try await document(id: id))
    }

    func setAvailability(
        documentID: UUID,
        availability: DocumentAvailability
    ) async throws {
        try await db.write { database in
            try database.execute(
                sql: "UPDATE document SET availability = ? WHERE id = ?",
                arguments: [availability, documentID]
            )
        }
    }

    static func dna(
        document: DocumentRecord,
        target: DocumentDNAAnalysisTarget,
        type: DocumentType,
        reference: String,
        analyzedAt: Date
    ) throws -> DocumentDNA {
        let referenceKind: DocumentDNAReferenceNumberKind = type == .invoice
            ? .invoiceNumber : .paymentReference
        let organizationQualifier = type == .invoice ? "issuer" : "payee"
        return try DocumentDNA(
            documentID: document.id,
            schemaVersion: target.schemaVersion,
            analyzerIdentifier: target.analyzerIdentifier,
            analyzerVersion: target.analyzerVersion,
            inputContentHash: document.contentHash,
            inputExtractionVersion: "text-v1",
            findings: [
                try finding(
                    kind: .documentType,
                    qualifier: nil,
                    displayValue: type.rawValue,
                    normalizedValue: type.rawValue
                ),
                try finding(
                    kind: .referenceNumber,
                    qualifier: referenceKind.rawValue,
                    displayValue: reference,
                    normalizedValue: reference
                ),
                try finding(
                    kind: .monetaryAmount,
                    qualifier: "CHF",
                    displayValue: "CHF 42",
                    normalizedValue: "42"
                ),
                try finding(
                    kind: .organization,
                    qualifier: organizationQualifier,
                    displayValue: "Example AG",
                    normalizedValue: "example ag"
                ),
            ],
            analyzedAt: analyzedAt
        )
    }

    static func finding(
        kind: DocumentDNAFindingKind,
        qualifier: String?,
        displayValue: String,
        normalizedValue: String
    ) throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: kind,
            qualifier: qualifier,
            displayValue: displayValue,
            normalizedValue: normalizedValue,
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: [try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: 1,
                exactText: "x",
                ocrRegionIndexes: [0]
            )]
        )
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
