import Foundation
import Testing
@testable import LinkLoomAppFeature
@testable import LinkLoomCore

@Suite("Person dossier AppModel", .serialized)
struct PersonDossierAppModelTests {
    @Test @MainActor func reloadPublishesPersonSummariesAtomicallyWithSourcesAndCosts() async throws {
        let fixture = try PersonDossierAppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let costs = try CostsAndPaymentsDossierAppModelValues.make().snapshot
        let person = try PersonDossierAppModelValues.make().snapshot
        let costsLoader = ScriptedPersonDossierCostsLoader(summaries: [costSummary(costs)])
        let people = ScriptedPersonDossierLoader(summarySteps: [.result([personSummary(person)])])
        let model = makeModel(fixture, costsLoader: costsLoader, people: people)

        try await model.reload()

        #expect(model.sources == [source])
        #expect(model.dossiers == [costSummary(costs)])
        #expect(model.personDossiers == [personSummary(person)])
        #expect(model.workspaceSelection == .source(source.id))
    }

    @Test @MainActor func failedPersonSummaryLoadPublishesNoPartialReloadState() async throws {
        let fixture = try PersonDossierAppModelFixture()
        _ = try await fixture.addSource(named: "Archive")
        let costs = try CostsAndPaymentsDossierAppModelValues.make().snapshot
        let model = makeModel(
            fixture,
            costsLoader: ScriptedPersonDossierCostsLoader(summaries: [costSummary(costs)]),
            people: ScriptedPersonDossierLoader(summarySteps: [.failure])
        )

        await #expect(throws: PersonDossierAppModelTestError.self) {
            try await model.reload()
        }

        #expect(model.sources.isEmpty)
        #expect(model.dossiers.isEmpty)
        #expect(model.personDossiers.isEmpty)
        #expect(model.workspaceSelection == nil)
    }

    @Test @MainActor func cancelledPersonSummaryLoadPublishesNothingAndRethrowsCancellation() async throws {
        let fixture = try PersonDossierAppModelFixture()
        _ = try await fixture.addSource(named: "Archive")
        let model = makeModel(
            fixture,
            people: ScriptedPersonDossierLoader(summarySteps: [.cancellation])
        )

        await #expect(throws: CancellationError.self) {
            try await model.reload()
        }

        #expect(model.sources.isEmpty)
        #expect(model.dossiers.isEmpty)
        #expect(model.personDossiers.isEmpty)
        #expect(model.workspaceSelection == nil)
    }

    @Test @MainActor func cancellationInsensitivePersonSummaryReloadRethrowsAndPreservesPublishedState() async throws {
        let fixture = try PersonDossierAppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = DocumentRecord(
            sourceRootID: source.id,
            relativePath: "existing.pdf",
            contentHash: "existing-document-hash",
            byteCount: 10,
            modifiedAt: Date(timeIntervalSince1970: 100),
            mediaType: .pdf,
            status: .ready,
            pageCount: 1,
            lastSeenAt: Date(timeIntervalSince1970: 100)
        )
        try await fixture.documents.save(document)
        let costs = try CostsAndPaymentsDossierAppModelValues.make().snapshot
        let firstPerson = try PersonDossierAppModelValues.make().snapshot
        let secondPerson = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let people = ScriptedPersonDossierLoader(summarySteps: [
            .result([personSummary(firstPerson)]),
            .blocked([personSummary(secondPerson)]),
        ])
        let model = makeModel(
            fixture,
            costsLoader: ScriptedPersonDossierCostsLoader(summaries: [costSummary(costs)]),
            people: people,
            documentLoader: { _ in [document] }
        )
        try await model.reload()
        let previousSources = model.sources
        let previousDossiers = model.dossiers
        let previousPersonDossiers = model.personDossiers
        let previousDocuments = model.documents
        let previousPhases = model.documentDNAAnalysisPhases
        let previousSelectedSourceID = model.selectedSourceID
        let previousWorkspaceSelection = model.workspaceSelection

        let reload = Task { @MainActor in
            do {
                try await model.reload()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await people.waitUntilBlockedSummaryStarts()
        reload.cancel()
        await people.releaseBlockedSummaries()

        #expect(await reload.value)
        #expect(model.sources == previousSources)
        #expect(model.dossiers == previousDossiers)
        #expect(model.personDossiers == previousPersonDossiers)
        #expect(model.documents == previousDocuments)
        #expect(model.documentDNAAnalysisPhases == previousPhases)
        #expect(model.selectedSourceID == previousSelectedSourceID)
        #expect(model.workspaceSelection == previousWorkspaceSelection)
    }

    @Test @MainActor func selectingPersonSummaryLoadsOneCompleteTypedSnapshot() async throws {
        let fixture = try PersonDossierAppModelFixture()
        let person = try PersonDossierAppModelValues.make().snapshot
        let people = ScriptedPersonDossierLoader(
            summarySteps: [.result([personSummary(person)])],
            snapshotSteps: [.result(person)]
        )
        let model = makeModel(fixture, people: people)
        try await model.reload()

        await model.selectDossier(id: person.dossier.id)

        #expect(await people.snapshotIDs == [person.dossier.id])
        #expect(model.dossierDetailState == .available(.personMatter(person)))
        #expect(model.workspaceSelection == .dossier(person.dossier.id))
    }

    @Test @MainActor func personLoadFailureRetainsThePreviousCompleteWorkspace() async throws {
        let fixture = try PersonDossierAppModelFixture()
        let person = try PersonDossierAppModelValues.make().snapshot
        let people = ScriptedPersonDossierLoader(
            summarySteps: [.result([personSummary(person)])],
            snapshotSteps: [.result(person), .failure]
        )
        let model = makeModel(fixture, people: people)
        try await model.reload()
        await model.selectDossier(id: person.dossier.id)

        await model.selectDossier(id: person.dossier.id)

        #expect(model.dossierDetailState == .failed(
            dossierID: person.dossier.id,
            previous: .personMatter(person)
        ))
        #expect(model.dossierDetailState.personSnapshot == person)
        #expect(model.lastErrorCode == "dossierLoadFailure")
    }

    @Test @MainActor func personLoadCancellationRestoresThePreviousCompleteWorkspaceWithoutDiagnostic() async throws {
        let fixture = try PersonDossierAppModelFixture()
        let person = try PersonDossierAppModelValues.make().snapshot
        let people = ScriptedPersonDossierLoader(
            summarySteps: [.result([personSummary(person)])],
            snapshotSteps: [.result(person), .cancellation]
        )
        let model = makeModel(fixture, people: people)
        try await model.reload()
        await model.selectDossier(id: person.dossier.id)

        await model.selectDossier(id: person.dossier.id)

        #expect(model.dossierDetailState == .available(.personMatter(person)))
        #expect(model.lastErrorCode == nil)
    }

    @Test @MainActor func mismatchedPersonSnapshotIDIsRejectedWithoutPublication() async throws {
        let fixture = try PersonDossierAppModelFixture()
        let person = try PersonDossierAppModelValues.make().snapshot
        let mismatched = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let people = ScriptedPersonDossierLoader(
            summarySteps: [.result([personSummary(person)])],
            snapshotSteps: [.result(mismatched)]
        )
        let model = makeModel(fixture, people: people)
        try await model.reload()

        await model.selectDossier(id: person.dossier.id)

        #expect(model.dossierDetailState == .failed(dossierID: person.dossier.id, previous: nil))
        #expect(model.dossierDetailState.personSnapshot == nil)
        #expect(model.workspaceSelection == nil)
    }

    @Test @MainActor func latePersonLoadCannotReplaceSelectedSource() async throws {
        let fixture = try PersonDossierAppModelFixture()
        _ = try await fixture.addSource(named: "Archive")
        let selectedSource = try await fixture.addSource(named: "Selected archive")
        let person = try PersonDossierAppModelValues.make().snapshot
        let people = ScriptedPersonDossierLoader(
            summarySteps: [.result([personSummary(person)])],
            snapshotSteps: [.blocked(.success(person))]
        )
        let model = makeModel(fixture, people: people)
        try await model.reload()

        let staleSelection = Task { await model.selectDossier(id: person.dossier.id) }
        await people.waitUntilBlockedSnapshotStarts()
        await model.selectSource(id: selectedSource.id)
        await people.releaseBlockedSnapshots()
        await staleSelection.value

        #expect(model.selectedSourceID == selectedSource.id)
        #expect(model.workspaceSelection == .source(selectedSource.id))
        #expect(model.dossierDetailState == .none)
    }

    @Test @MainActor func latePersonLoadCannotReplaceSelectedDocument() async throws {
        let fixture = try PersonDossierAppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let document = DocumentRecord(
            sourceRootID: source.id,
            relativePath: "selected.pdf",
            contentHash: "selected-document-hash",
            byteCount: 10,
            modifiedAt: Date(timeIntervalSince1970: 100),
            mediaType: .pdf,
            status: .ready,
            pageCount: 1,
            lastSeenAt: Date(timeIntervalSince1970: 100)
        )
        try await fixture.documents.save(document)
        let person = try PersonDossierAppModelValues.make().snapshot
        let people = ScriptedPersonDossierLoader(
            summarySteps: [.result([personSummary(person)])],
            snapshotSteps: [.blocked(.success(person))]
        )
        let model = makeModel(fixture, people: people)
        try await model.reload()

        let staleSelection = Task { await model.selectDossier(id: person.dossier.id) }
        await people.waitUntilBlockedSnapshotStarts()
        await model.selectDocument(id: document.id)
        await people.releaseBlockedSnapshots()
        await staleSelection.value

        #expect(model.selectedDocumentID == document.id)
        #expect(model.documentDNADetailState == .unavailable(documentID: document.id))
        #expect(model.workspaceSelection == .source(source.id))
        #expect(model.dossierDetailState == .none)
    }

    @Test @MainActor func latePersonLoadCannotReplaceDifferentDossier() async throws {
        let fixture = try PersonDossierAppModelFixture()
        let first = try PersonDossierAppModelValues.make().snapshot
        let second = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let people = ScriptedPersonDossierLoader(
            summarySteps: [.result([personSummary(first), personSummary(second)])],
            snapshotSteps: [.blocked(.success(first)), .result(second)]
        )
        let model = makeModel(fixture, people: people)
        try await model.reload()

        let staleSelection = Task { await model.selectDossier(id: first.dossier.id) }
        await people.waitUntilBlockedSnapshotStarts()
        await model.selectDossier(id: second.dossier.id)
        await people.releaseBlockedSnapshots()
        await staleSelection.value

        #expect(model.workspaceSelection == .dossier(second.dossier.id))
        #expect(model.dossierDetailState == .available(.personMatter(second)))
    }

    @Test @MainActor func personDossierLoadCannotCrossDossierABA() async throws {
        let fixture = try PersonDossierAppModelFixture()
        let first = try PersonDossierAppModelValues.make().snapshot
        let second = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let people = ScriptedPersonDossierLoader(
            summarySteps: [.result([personSummary(first), personSummary(second)])],
            snapshotSteps: [.blocked(.success(first)), .result(second), .blocked(.success(first))]
        )
        let model = makeModel(fixture, people: people)
        try await model.reload()

        let staleFirst = Task { await model.selectDossier(id: first.dossier.id) }
        await people.waitUntilBlockedSnapshotStarts()
        await model.selectDossier(id: second.dossier.id)
        let currentFirst = Task { await model.selectDossier(id: first.dossier.id) }
        await people.waitUntilBlockedSnapshotStarts(count: 2)
        await people.releaseBlockedSnapshots()
        await staleFirst.value
        await currentFirst.value

        #expect(model.workspaceSelection == .dossier(first.dossier.id))
        #expect(model.dossierDetailState == .available(.personMatter(first)))
    }

    @Test @MainActor func existingCostsSelectDossierStillCallsOnlyTheCostsLoader() async throws {
        let fixture = try PersonDossierAppModelFixture()
        let costs = try CostsAndPaymentsDossierAppModelValues.make().snapshot
        let person = try PersonDossierAppModelValues.make().snapshot
        let costsLoader = ScriptedPersonDossierCostsLoader(
            summaries: [costSummary(costs)],
            snapshots: [costs]
        )
        let people = ScriptedPersonDossierLoader(summarySteps: [.result([personSummary(person)])])
        let model = makeModel(fixture, costsLoader: costsLoader, people: people)
        try await model.reload()

        await model.selectDossier(id: costs.dossier.id)

        #expect(await costsLoader.snapshotIDs == [costs.dossier.id])
        #expect(await people.snapshotIDs.isEmpty)
        #expect(model.dossierDetailState == .available(.costsAndPayments(costs)))
    }
}

private extension PersonDossierAppModelTests {
    @MainActor
    func makeModel(
        _ fixture: PersonDossierAppModelFixture,
        costsLoader: (any DossierLoading)? = nil,
        people: (any PersonDossierLoading)? = nil,
        documentLoader: (@Sendable (UUID) async throws -> [DocumentRecord])? = nil
    ) -> AppModel {
        if let documentLoader {
            return AppModel(
                sources: fixture.sources,
                documents: fixture.documents,
                sourceAccess: fixture.sourceAccess,
                catalog: PersonDossierNoopCatalog(),
                ingestion: PersonDossierNoopIngester(),
                dossierLoader: costsLoader,
                personDossierLoader: people,
                documentLoader: documentLoader
            )
        }
        return AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: PersonDossierNoopCatalog(),
            ingestion: PersonDossierNoopIngester(),
            dossierLoader: costsLoader,
            personDossierLoader: people
        )
    }

    func costSummary(_ snapshot: DossierSnapshot) -> DossierSummary {
        DossierSummary(dossier: snapshot.dossier, anchor: snapshot.members[0].document)
    }

    func personSummary(_ snapshot: PersonDossierSnapshot) -> PersonDossierSummary {
        PersonDossierSummary(dossier: snapshot.dossier, anchor: snapshot.anchor)
    }
}
