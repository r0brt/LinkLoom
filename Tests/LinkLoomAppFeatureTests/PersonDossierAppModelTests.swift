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

    @Test @MainActor func currentSelectedSupportPublishesOpenedPersonWorkspaceAndFreshSummariesAtomically() async throws {
        let initial = try PersonDossierAppModelValues.make(dossierID: UUID())
        let opened = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let refreshed = [personSummary(opened)]
        let context = try await makeOpenContext(
            summarySteps: [
                .result([personSummary(initial.snapshot)]),
                .blocked(refreshed),
            ],
            openSteps: [.result(.opened(opened))]
        )
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState

        let open = Task {
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
        }
        await context.service.waitUntilBlockedSummaryStarts()

        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.personDossiers == [personSummary(initial.snapshot)])
        #expect(context.model.dossierMutationState == .openingPerson(
            documentID: context.values.document.id
        ))

        await context.service.releaseBlockedSummaries()
        await open.value

        #expect(context.model.workspaceSelection == .dossier(opened.dossier.id))
        #expect(context.model.dossierDetailState.personSnapshot == opened)
        #expect(context.model.personDossiers == refreshed)
        #expect(context.model.personDossierChoices.isEmpty)
        #expect(await context.service.openSelections == [context.values.selection])
    }

    @Test @MainActor func noNameMatchCreationPublishesReturnedPersonSnapshot() async throws {
        let opened = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            summarySteps: [.result([]), .result([])],
            openSteps: [.result(.opened(opened))]
        )

        await context.model.openOrCreatePersonDossier(from: context.values.selection)

        #expect(context.model.workspaceSelection == .dossier(opened.dossier.id))
        #expect(context.model.dossierDetailState == .available(.personMatter(opened)))
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func sameNameOpenPublishesOnlyPersonChoices() async throws {
        let choice = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            openSteps: [.result(.choose([personSummary(choice)]))]
        )
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState

        await context.model.openOrCreatePersonDossier(from: context.values.selection)

        #expect(context.model.personDossierChoices == [personSummary(choice)])
        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
    }

    @Test @MainActor func choosingOfferedPersonForwardsExactSelectionAndExistingID() async throws {
        let selected = try PersonDossierAppModelValues.make(
            dossierID: UUID(),
            documentID: UUID()
        ).snapshot
        let context = try await makeOpenContext(
            summarySteps: [.result([]), .result([personSummary(selected)])],
            openSteps: [.result(.choose([personSummary(selected)]))],
            choiceSteps: [.result(selected)]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)

        await context.model.choosePersonDossier(id: selected.dossier.id)

        #expect(await context.service.choiceSelections == [context.values.selection])
        #expect(await context.service.creationChoices == [
            .existing(dossierID: selected.dossier.id),
        ])
        #expect(context.model.dossierDetailState == .available(.personMatter(selected)))
        #expect(context.model.personDossiers == [personSummary(selected)])
    }

    @Test @MainActor func explicitNewPersonForwardsExactSelectionAndNewChoice() async throws {
        let created = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            summarySteps: [.result([]), .result([])],
            openSteps: [.result(.choose([]))],
            choiceSteps: [.result(created)]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)

        await context.model.createNewPersonDossier()

        #expect(await context.service.choiceSelections == [context.values.selection])
        #expect(await context.service.creationChoices == [.new])
        #expect(context.model.dossierDetailState.personSnapshot == created)
    }

    @Test @MainActor func absentPersonChoiceIDPerformsNoCommand() async throws {
        let offered = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            openSteps: [.result(.choose([personSummary(offered)]))]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)

        await context.model.choosePersonDossier(id: UUID())

        #expect(await context.service.choiceSelections.isEmpty)
        #expect(context.model.personDossierChoices == [personSummary(offered)])
    }

    @Test @MainActor func duplicatePersonOpenIsSuppressedWhileFirstIsInFlight() async throws {
        let context = try await makeOpenContext(
            openSteps: [.blocked(.success(.opened(try PersonDossierAppModelValues.make().snapshot)))]
        )
        let first = Task {
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
        }
        await context.service.waitUntilBlockedMutationStarts()

        await context.model.openOrCreatePersonDossier(from: context.values.selection)

        #expect(await context.service.openSelections == [context.values.selection])
        await context.service.releaseBlockedMutations()
        await first.value
    }

    @Test @MainActor func duplicatePersonChoiceIsSuppressedWhileFirstIsInFlight() async throws {
        let selected = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            openSteps: [.result(.choose([personSummary(selected)]))],
            choiceSteps: [.blocked(.success(selected))]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)
        let first = Task { await context.model.choosePersonDossier(id: selected.dossier.id) }
        await context.service.waitUntilBlockedMutationStarts()

        await context.model.createNewPersonDossier()

        #expect(await context.service.creationChoices == [
            .existing(dossierID: selected.dossier.id),
        ])
        await context.service.releaseBlockedMutations()
        await first.value
    }

    @Test(arguments: PersonDossierRaceScenario.allCases)
    @MainActor func personChoiceFirstAwaitRejectsEveryStaleContext(
        scenario: PersonDossierRaceScenario
    ) async throws {
        let selected = try PersonDossierAppModelValues.make(
            dossierID: UUID(),
            documentID: UUID()
        ).snapshot
        let other = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            summarySteps: [.result([personSummary(other)]), .result([personSummary(selected)])],
            snapshotSteps: [.result(other)],
            openSteps: [.result(.choose([personSummary(selected)]))],
            choiceSteps: [.blocked(.success(selected))]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)
        let choice = Task { await context.model.choosePersonDossier(id: selected.dossier.id) }
        await context.service.waitUntilBlockedMutationStarts()

        try await apply(scenario, to: context, dossier: other)
        let workspaceAfterRace = context.model.workspaceSelection
        let detailAfterRace = context.model.dossierDetailState
        let choicesAfterRace = context.model.personDossierChoices
        let summariesAfterRace = context.model.personDossiers
        await context.service.releaseBlockedMutations()
        await choice.value

        #expect(await context.service.summaryInvocationCount == 1)
        #expect(context.model.workspaceSelection == workspaceAfterRace)
        #expect(context.model.dossierDetailState == detailAfterRace)
        #expect(context.model.personDossierChoices == choicesAfterRace)
        #expect(context.model.personDossiers == summariesAfterRace)
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test(
        arguments: PersonDossierSummaryBoundary.allCases,
        PersonDossierRaceScenario.allCases
    )
    @MainActor func latePersonSummaryReloadRejectsEveryStaleContext(
        boundary: PersonDossierSummaryBoundary,
        scenario: PersonDossierRaceScenario
    ) async throws {
        let published = try PersonDossierAppModelValues.make(
            dossierID: UUID(),
            documentID: boundary == .choice ? UUID() : PersonDossierAppModelValues.defaultDocumentID
        ).snapshot
        let other = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let openSteps: [ScriptedPersonDossierLoader.OpenStep] = switch boundary {
        case .open:
            [.result(.opened(published))]
        case .choice:
            [.result(.choose([personSummary(published)]))]
        }
        let choiceSteps: [ScriptedPersonDossierLoader.ChoiceStep] = switch boundary {
        case .open: []
        case .choice: [.result(published)]
        }
        let context = try await makeOpenContext(
            summarySteps: [
                .result([personSummary(other)]),
                .blocked([personSummary(published)]),
            ],
            snapshotSteps: [.result(other)],
            openSteps: openSteps,
            choiceSteps: choiceSteps
        )

        let operation: Task<Void, Never>
        switch boundary {
        case .open:
            operation = Task {
                await context.model.openOrCreatePersonDossier(from: context.values.selection)
            }
        case .choice:
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
            operation = Task {
                await context.model.choosePersonDossier(id: published.dossier.id)
            }
        }
        await context.service.waitUntilBlockedSummaryStarts()

        try await apply(scenario, to: context, dossier: other)
        let workspaceAfterRace = context.model.workspaceSelection
        let detailAfterRace = context.model.dossierDetailState
        let choicesAfterRace = context.model.personDossierChoices
        let summariesAfterRace = context.model.personDossiers
        await context.service.releaseBlockedSummaries()
        await operation.value

        #expect(await context.service.summaryInvocationCount == 2)
        #expect(context.model.workspaceSelection == workspaceAfterRace)
        #expect(context.model.dossierDetailState == detailAfterRace)
        #expect(context.model.personDossierChoices == choicesAfterRace)
        #expect(context.model.personDossiers == summariesAfterRace)
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func cancelledCancellationInsensitivePersonOpenPreservesState() async throws {
        let opened = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            summarySteps: [.result([]), .result([personSummary(opened)])],
            openSteps: [.blocked(.success(.opened(opened)))]
        )
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState
        let open = Task {
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
        }
        await context.service.waitUntilBlockedMutationStarts()

        open.cancel()
        await context.service.releaseBlockedMutations()
        await open.value

        #expect(await context.service.summaryInvocationCount == 1)
        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.personDossiers.isEmpty)
        #expect(context.model.personDossierChoices.isEmpty)
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func cancelledCancellationInsensitivePersonChoicePreservesState() async throws {
        let selected = try PersonDossierAppModelValues.make(
            dossierID: UUID(),
            documentID: UUID()
        ).snapshot
        let context = try await makeOpenContext(
            summarySteps: [.result([]), .result([personSummary(selected)])],
            openSteps: [.result(.choose([personSummary(selected)]))],
            choiceSteps: [.blocked(.success(selected))]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState
        let choice = Task { await context.model.choosePersonDossier(id: selected.dossier.id) }
        await context.service.waitUntilBlockedMutationStarts()

        choice.cancel()
        await context.service.releaseBlockedMutations()
        await choice.value

        #expect(await context.service.summaryInvocationCount == 1)
        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.personDossiers.isEmpty)
        #expect(context.model.personDossierChoices == [personSummary(selected)])
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func cancelledCancellationInsensitivePersonSummaryReloadPreservesState() async throws {
        let opened = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            summarySteps: [.result([]), .blocked([personSummary(opened)])],
            openSteps: [.result(.opened(opened))]
        )
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState
        let open = Task {
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
        }
        await context.service.waitUntilBlockedSummaryStarts()

        open.cancel()
        await context.service.releaseBlockedSummaries()
        await open.value

        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.personDossiers.isEmpty)
        #expect(context.model.personDossierChoices.isEmpty)
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func cancelledPersonOpenIgnoresLateNonCancellationFailure() async throws {
        let context = try await makeOpenContext(
            openSteps: [.blocked(.failure(.loadFailed))]
        )
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState
        let open = Task {
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
        }
        await context.service.waitUntilBlockedMutationStarts()

        open.cancel()
        await context.service.releaseBlockedMutations()
        await open.value

        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test func summaryCountGateKeepsHigherTargetWaiting() async throws {
        let service = ScriptedPersonDossierLoader(summarySteps: [.blocked([]), .blocked([])])
        let targetTwo = Task { await service.waitUntilBlockedSummaryStarts(count: 2) }
        #expect(await waitUntilPersonDossierCondition {
            await service.pendingSummaryStartWaiterCount == 1
        })

        let first = Task { try await service.personDossierSummaries() }
        await service.waitUntilBlockedSummaryStarts(count: 1)
        #expect(await service.pendingSummaryStartWaiterCount == 1)
        let second = Task { try await service.personDossierSummaries() }
        await targetTwo.value
        await service.waitUntilBlockedSummaryStarts(count: 2)
        await service.releaseBlockedSummaries()
        _ = try await first.value
        _ = try await second.value
    }

    @Test func snapshotCountGateKeepsHigherTargetWaiting() async throws {
        let snapshot = try PersonDossierAppModelValues.make().snapshot
        let service = ScriptedPersonDossierLoader(snapshotSteps: [
            .blocked(.success(snapshot)),
            .blocked(.success(snapshot)),
        ])
        let targetTwo = Task { await service.waitUntilBlockedSnapshotStarts(count: 2) }
        #expect(await waitUntilPersonDossierCondition {
            await service.pendingSnapshotStartWaiterCount == 1
        })

        let first = Task { try await service.personDossierSnapshot(id: snapshot.dossier.id) }
        await service.waitUntilBlockedSnapshotStarts(count: 1)
        #expect(await service.pendingSnapshotStartWaiterCount == 1)
        let second = Task { try await service.personDossierSnapshot(id: snapshot.dossier.id) }
        await targetTwo.value
        await service.waitUntilBlockedSnapshotStarts(count: 2)
        await service.releaseBlockedSnapshots()
        _ = try await first.value
        _ = try await second.value
    }

    @Test func mutationCountGateKeepsHigherTargetWaiting() async throws {
        let values = try PersonDossierAppModelValues.make()
        let service = ScriptedPersonDossierLoader(openSteps: [
            .blocked(.success(.choose([]))),
            .blocked(.success(.choose([]))),
        ])
        let targetTwo = Task { await service.waitUntilBlockedMutationStarts(count: 2) }
        #expect(await waitUntilPersonDossierCondition {
            await service.pendingMutationStartWaiterCount == 1
        })

        let first = Task {
            try await service.createOrOpenPersonDossier(from: values.selection)
        }
        await service.waitUntilBlockedMutationStarts(count: 1)
        #expect(await service.pendingMutationStartWaiterCount == 1)
        let second = Task {
            try await service.createOrOpenPersonDossier(from: values.selection)
        }
        await targetTwo.value
        await service.waitUntilBlockedMutationStarts(count: 2)
        await service.releaseBlockedMutations()
        _ = try await first.value
        _ = try await second.value
    }

    @Test @MainActor func changedSourceRejectsLatePersonOpen() async throws {
        let context = try await makeOpenContext(
            openSteps: [.blocked(.success(.opened(try PersonDossierAppModelValues.make().snapshot)))]
        )
        let otherSource = try await context.fixture.addSource(named: "Other")
        let open = Task {
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
        }
        await context.service.waitUntilBlockedMutationStarts()

        await context.model.selectSource(id: otherSource.id)
        await context.service.releaseBlockedMutations()
        await open.value

        #expect(context.model.selectedSourceID == otherSource.id)
        #expect(context.model.workspaceSelection == .source(otherSource.id))
        #expect(context.model.dossierDetailState == .none)
    }

    @Test @MainActor func changedDocumentRejectsLatePersonOpen() async throws {
        let context = try await makeOpenContext(
            openSteps: [.blocked(.success(.opened(try PersonDossierAppModelValues.make().snapshot)))]
        )
        let open = Task {
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
        }
        await context.service.waitUntilBlockedMutationStarts()

        await context.model.selectDocument(id: context.otherValues.document.id)
        await context.service.releaseBlockedMutations()
        await open.value

        #expect(context.model.selectedDocumentID == context.otherValues.document.id)
        #expect(context.model.workspaceSelection == .source(context.source.id))
        #expect(context.model.dossierDetailState == .none)
    }

    @Test @MainActor func changedDNAGenerationRejectsLatePersonOpen() async throws {
        let context = try await makeOpenContext(
            openSteps: [.blocked(.success(.opened(try PersonDossierAppModelValues.make().snapshot)))]
        )
        let open = Task {
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
        }
        await context.service.waitUntilBlockedMutationStarts()

        await context.model.selectDocument(id: context.values.document.id)
        await context.service.releaseBlockedMutations()
        await open.value

        #expect(context.model.selectedDocumentID == context.values.document.id)
        #expect(context.model.workspaceSelection == .source(context.source.id))
        #expect(context.model.dossierDetailState == .none)
    }

    @Test @MainActor func changedDossierRejectsLatePersonOpen() async throws {
        let other = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            summarySteps: [.result([personSummary(other)])],
            snapshotSteps: [.result(other)],
            openSteps: [.blocked(.success(.opened(try PersonDossierAppModelValues.make().snapshot)))]
        )
        let open = Task {
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
        }
        await context.service.waitUntilBlockedMutationStarts()

        await context.model.selectDossier(id: other.dossier.id)
        await context.service.releaseBlockedMutations()
        await open.value

        #expect(context.model.workspaceSelection == .dossier(other.dossier.id))
        #expect(context.model.dossierDetailState == .available(.personMatter(other)))
    }

    @Test @MainActor func documentABARejectsLatePersonOpen() async throws {
        let context = try await makeOpenContext(
            openSteps: [.blocked(.success(.opened(try PersonDossierAppModelValues.make().snapshot)))]
        )
        let open = Task {
            await context.model.openOrCreatePersonDossier(from: context.values.selection)
        }
        await context.service.waitUntilBlockedMutationStarts()

        await context.model.selectDocument(id: context.otherValues.document.id)
        await context.model.selectDocument(id: context.values.document.id)
        await context.service.releaseBlockedMutations()
        await open.value

        #expect(context.model.selectedDocumentID == context.values.document.id)
        #expect(context.model.workspaceSelection == .source(context.source.id))
        #expect(context.model.dossierDetailState == .none)
    }

    @Test @MainActor func personOpenFailurePreservesWorkspaceDetailAndChoicesWithSafeDiagnostic() async throws {
        let context = try await makeOpenContext(openSteps: [.failure])
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState

        await context.model.openOrCreatePersonDossier(from: context.values.selection)

        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.personDossierChoices.isEmpty)
        #expect(context.model.lastErrorCode == "dossierOpenFailure")
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func failedPersonChoicePreservesWorkspaceDetailAndOfferedChoices() async throws {
        let offered = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            openSteps: [.result(.choose([personSummary(offered)]))],
            choiceSteps: [.failure]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState

        await context.model.choosePersonDossier(id: offered.dossier.id)

        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.personDossierChoices == [personSummary(offered)])
        #expect(context.model.lastErrorCode == "dossierOpenFailure")
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func cancelledPersonChoiceIsIdleSilentAndPreservesWorkspaceAndChoices() async throws {
        let offered = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            openSteps: [.result(.choose([personSummary(offered)]))],
            choiceSteps: [.cancellation]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)
        let workspace = context.model.workspaceSelection
        let detail = context.model.dossierDetailState

        await context.model.choosePersonDossier(id: offered.dossier.id)

        #expect(context.model.workspaceSelection == workspace)
        #expect(context.model.dossierDetailState == detail)
        #expect(context.model.personDossierChoices == [personSummary(offered)])
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func successfulPersonOpenClearsPendingChoicesAndPriorOpenFailure() async throws {
        let offered = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            summarySteps: [.result([]), .result([])],
            openSteps: [
                .failure,
                .result(.choose([personSummary(offered)])),
                .result(.opened(try PersonDossierAppModelValues.make().snapshot)),
            ]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)
        #expect(context.model.lastErrorCode == "dossierOpenFailure")
        await context.model.openOrCreatePersonDossier(from: context.values.selection)
        #expect(context.model.personDossierChoices == [personSummary(offered)])

        await context.model.openOrCreatePersonDossier(from: context.values.selection)
        await context.model.createNewPersonDossier()

        #expect(context.model.personDossierChoices.isEmpty)
        #expect(context.model.lastErrorCode == nil)
        #expect(await context.service.choiceSelections.isEmpty)
    }

    @Test @MainActor func sourceSelectionChangeClearsPendingPersonChoices() async throws {
        let offered = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            openSteps: [.result(.choose([personSummary(offered)]))]
        )
        let otherSource = try await context.fixture.addSource(named: "Other")
        await context.model.openOrCreatePersonDossier(from: context.values.selection)

        await context.model.selectSource(id: otherSource.id)

        #expect(context.model.personDossierChoices.isEmpty)
        await context.model.createNewPersonDossier()
        #expect(await context.service.choiceSelections.isEmpty)
    }

    @Test @MainActor func documentSelectionChangeClearsPendingPersonChoices() async throws {
        let offered = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            openSteps: [.result(.choose([personSummary(offered)]))]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)

        await context.model.selectDocument(id: context.otherValues.document.id)

        #expect(context.model.personDossierChoices.isEmpty)
        await context.model.createNewPersonDossier()
        #expect(await context.service.choiceSelections.isEmpty)
    }

    @Test @MainActor func dossierSelectionChangeClearsPendingPersonChoices() async throws {
        let offered = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeOpenContext(
            openSteps: [.result(.choose([personSummary(offered)]))]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)

        await context.model.selectDossier(id: UUID())

        #expect(context.model.personDossierChoices.isEmpty)
        await context.model.createNewPersonDossier()
        #expect(await context.service.choiceSelections.isEmpty)
    }

    @Test @MainActor func successfulCostsChoiceClearsPendingPersonChoices() async throws {
        let offeredPerson = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let costsSnapshot = try CostsAndPaymentsDossierAppModelValues.make().snapshot
        let costs = ScriptedPersonDossierCostsLoader(
            snapshots: [costsSnapshot],
            openSteps: [.result(.choose([costSummary(costsSnapshot)]))]
        )
        let context = try await makeOpenContext(
            costsLoader: costs,
            costsMutator: costs,
            documentType: .invoice,
            openSteps: [.result(.choose([personSummary(offeredPerson)]))]
        )
        await context.model.openOrCreatePersonDossier(from: context.values.selection)
        #expect(context.model.personDossierChoices == [personSummary(offeredPerson)])

        await context.model.openOrCreateDossierForSelectedDocument()
        await context.model.chooseDossier(id: costsSnapshot.dossier.id)

        #expect(context.model.workspaceSelection == .dossier(costsSnapshot.dossier.id))
        #expect(context.model.dossierDetailState == .available(.costsAndPayments(costsSnapshot)))
        #expect(context.model.personDossierChoices.isEmpty)
        await context.model.createNewPersonDossier()
        #expect(await context.service.choiceSelections.isEmpty)
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
        costsMutator: (any DossierMutating)? = nil,
        people: (any PersonDossierLoading)? = nil,
        peopleMutator: (any PersonDossierMutating)? = nil,
        dnaStatuses: (any DocumentDNAStatusLoading)? = nil,
        dnaSnapshots: (any DocumentDNASnapshotLoading)? = nil,
        documentLoader: (@Sendable (UUID) async throws -> [DocumentRecord])? = nil
    ) -> AppModel {
        if let documentLoader {
            return AppModel(
                sources: fixture.sources,
                documents: fixture.documents,
                sourceAccess: fixture.sourceAccess,
                catalog: PersonDossierNoopCatalog(),
                ingestion: PersonDossierNoopIngester(),
                dnaStatuses: dnaStatuses,
                dnaSnapshots: dnaSnapshots,
                dossierLoader: costsLoader,
                dossierMutator: costsMutator,
                personDossierLoader: people,
                personDossierMutator: peopleMutator,
                documentLoader: documentLoader
            )
        }
        return AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: PersonDossierNoopCatalog(),
            ingestion: PersonDossierNoopIngester(),
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            dossierLoader: costsLoader,
            dossierMutator: costsMutator,
            personDossierLoader: people,
            personDossierMutator: peopleMutator
        )
    }

    @MainActor
    func makeOpenContext(
        costsLoader: (any DossierLoading)? = nil,
        costsMutator: (any DossierMutating)? = nil,
        documentType: DocumentType = .unknown,
        summarySteps: [ScriptedPersonDossierLoader.SummaryStep] = [.result([])],
        snapshotSteps: [ScriptedPersonDossierLoader.SnapshotStep] = [],
        openSteps: [ScriptedPersonDossierLoader.OpenStep],
        choiceSteps: [ScriptedPersonDossierLoader.ChoiceStep] = []
    ) async throws -> PersonDossierOpenContext {
        let fixture = try PersonDossierAppModelFixture()
        let source = try await fixture.addSource(named: "Archive")
        let values = try PersonDossierAppModelValues.make(
            sourceID: source.id,
            documentType: documentType
        )
        let otherValues = try PersonDossierAppModelValues.make(
            dossierID: UUID(),
            sourceID: source.id,
            documentID: UUID(),
            name: "Mara Beispiel"
        )
        try await fixture.documents.save(values.document)
        try await fixture.documents.save(otherValues.document)
        let service = ScriptedPersonDossierLoader(
            summarySteps: summarySteps,
            snapshotSteps: snapshotSteps,
            openSteps: openSteps,
            choiceSteps: choiceSteps
        )
        let statuses = PersonDossierDNAStatusLoader(statusesBySource: [source.id: [
            DocumentDNAAnalysisStatus(documentID: values.document.id, phase: .ready),
            DocumentDNAAnalysisStatus(documentID: otherValues.document.id, phase: .ready),
        ]])
        let dnaSnapshots = ScriptedPersonDossierDNALoader(snapshotsByDocument: [
            values.document.id: Array(repeating: values.dna, count: 4),
            otherValues.document.id: Array(repeating: otherValues.dna, count: 4),
        ])
        let model = makeModel(
            fixture,
            costsLoader: costsLoader,
            costsMutator: costsMutator,
            people: service,
            peopleMutator: service,
            dnaStatuses: statuses,
            dnaSnapshots: dnaSnapshots
        )
        try await model.reload()
        await model.selectSource(id: source.id)
        await model.selectDocument(id: values.document.id)
        return PersonDossierOpenContext(
            fixture: fixture,
            source: source,
            values: values,
            otherValues: otherValues,
            service: service,
            model: model
        )
    }

    func costSummary(_ snapshot: DossierSnapshot) -> DossierSummary {
        DossierSummary(dossier: snapshot.dossier, anchor: snapshot.members[0].document)
    }

    func personSummary(_ snapshot: PersonDossierSnapshot) -> PersonDossierSummary {
        PersonDossierSummary(dossier: snapshot.dossier, anchor: snapshot.anchor)
    }

    @MainActor
    func apply(
        _ scenario: PersonDossierRaceScenario,
        to context: PersonDossierOpenContext,
        dossier: PersonDossierSnapshot
    ) async throws {
        switch scenario {
        case .source:
            let source = try await context.fixture.addSource(named: "Race source")
            await context.model.selectSource(id: source.id)
        case .document:
            await context.model.selectDocument(id: context.otherValues.document.id)
        case .dnaGeneration:
            await context.model.selectDocument(id: context.values.document.id)
        case .dossier:
            await context.model.selectDossier(id: dossier.dossier.id)
        case .documentABA:
            await context.model.selectDocument(id: context.otherValues.document.id)
            await context.model.selectDocument(id: context.values.document.id)
        }
    }
}

private struct PersonDossierOpenContext {
    let fixture: PersonDossierAppModelFixture
    let source: SourceRootRecord
    let values: PersonDossierAppModelValues
    let otherValues: PersonDossierAppModelValues
    let service: ScriptedPersonDossierLoader
    let model: AppModel
}

enum PersonDossierRaceScenario: CaseIterable, Sendable {
    case source
    case document
    case dnaGeneration
    case dossier
    case documentABA
}

enum PersonDossierSummaryBoundary: CaseIterable, Sendable {
    case open
    case choice
}

private func waitUntilPersonDossierCondition(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return false
}
