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

    @Test @MainActor func manualScanRefreshesActivePersonDossierExactlyOnceWithCompleteSnapshot() async throws {
        let context = try await makePersonLifecycleContext()
        let refreshed = try refreshedPersonLifecycleSnapshot(in: context)
        await context.people.setSnapshotSteps([.result(refreshed)])
        let initialInvocationCount = await context.people.snapshotIDs.count

        await context.model.scanSelectedSource()

        #expect(await context.people.snapshotIDs.count == initialInvocationCount + 1)
        #expect(await context.costs.snapshotIDs.isEmpty)
        #expect(context.model.workspaceSelection == .dossier(context.values.snapshot.dossier.id))
        #expect(context.model.dossierDetailState == .available(.personMatter(refreshed)))
    }

    @Test(arguments: [PersonDossierWatcherSource.selected, .other])
    @MainActor func everyWatcherCompletionRefreshesActivePersonDossier(
        completedSource: PersonDossierWatcherSource
    ) async throws {
        let context = try await makePersonLifecycleContext()
        let refreshed = try refreshedPersonLifecycleSnapshot(in: context)
        await context.people.setSnapshotSteps([.result(refreshed)])
        let sourceID = completedSource == .selected
            ? context.originSource.id
            : context.otherSource.id

        context.scheduler.completeRescan(sourceID: sourceID)

        #expect(await waitUntilPersonDossierCondition {
            await MainActor.run {
                context.model.dossierDetailState == .available(.personMatter(refreshed))
            }
        })
        #expect(await context.costs.snapshotIDs.isEmpty)
        await context.model.stopWatching()
    }

    @Test @MainActor func failedPersonRefreshKeepsEveryLastGoodPresentationField() async throws {
        let context = try await makePersonLifecycleContext()
        let previous = personLifecyclePresentation(context.model)
        await context.people.setSnapshotSteps([.failure])

        await context.model.refreshSelectedDossier()

        #expect(personLifecyclePresentation(context.model) == previous.replacing(
            detail: .failed(
                dossierID: context.values.snapshot.dossier.id,
                previous: .personMatter(context.values.snapshot)
            ),
            errorCode: "dossierLoadFailure"
        ))
    }

    @Test(arguments: PersonDossierLateRefreshOutcome.allCases)
    @MainActor func cancelledCancellationInsensitivePersonRefreshCannotPublishSuccessOrFailure(
        outcome: PersonDossierLateRefreshOutcome
    ) async throws {
        let recorder = PersonDossierDiagnosticRecorder()
        let context = try await makePersonLifecycleContext(
            reportRuntimeFailure: { recorder.record($0) }
        )
        let refreshed = try refreshedPersonLifecycleSnapshot(in: context)
        let result: Result<PersonDossierSnapshot, PersonDossierAppModelTestError> = switch outcome {
        case .success: .success(refreshed)
        case .failure: .failure(.loadFailed)
        }
        await context.people.setSnapshotSteps([.blocked(result)])
        let previous = personLifecyclePresentation(context.model)

        let refresh = Task { await context.model.refreshSelectedDossier() }
        await context.people.waitUntilBlockedSnapshotStarts()
        refresh.cancel()
        await context.people.releaseBlockedSnapshots()
        await refresh.value

        #expect(personLifecyclePresentation(context.model) == previous)
        #expect(recorder.diagnostics.isEmpty)
    }

    @Test @MainActor func failedManualScanRefreshPublishesNoStagedPersonLifecycleValues() async throws {
        let recorder = PersonDossierDiagnosticRecorder()
        let context = try await makePersonLifecycleContext(
            reportRuntimeFailure: { recorder.record($0) }
        )
        let previous = personLifecyclePresentation(context.model)
        var stagedDocuments = context.originDocuments
        stagedDocuments[0].relativePath = "refreshed-manual/person.pdf"
        await context.documents.setDocuments(stagedDocuments, sourceID: context.originSource.id)
        try await context.fixture.sources.updateLastScan(
            id: context.originSource.id,
            at: Date(timeIntervalSince1970: 700)
        )
        await context.people.setSnapshotSteps([.failure])

        await context.model.scanSelectedSource()

        #expect(personLifecyclePresentation(context.model) == previous.replacing(
            detail: .failed(
                dossierID: context.values.snapshot.dossier.id,
                previous: .personMatter(context.values.snapshot)
            ),
            errorCode: "dossierLoadFailure"
        ))
        #expect(recorder.diagnostics.map(\.category) == [.dossierLoad])
    }

    @Test @MainActor func failedWatcherRefreshPublishesNoStagedPersonLifecycleValues() async throws {
        let recorder = PersonDossierDiagnosticRecorder()
        let context = try await makePersonLifecycleContext(
            reportRuntimeFailure: { recorder.record($0) }
        )
        let previous = personLifecyclePresentation(context.model)
        var stagedDocuments = context.originDocuments
        stagedDocuments[0].relativePath = "refreshed-watcher/person.pdf"
        await context.documents.setDocuments(stagedDocuments, sourceID: context.originSource.id)
        try await context.fixture.sources.updateLastScan(
            id: context.originSource.id,
            at: Date(timeIntervalSince1970: 800)
        )
        await context.people.setSnapshotSteps([.failure])

        context.scheduler.completeRescan(sourceID: context.originSource.id)

        #expect(await waitUntilPersonDossierCondition {
            await MainActor.run { context.model.lastErrorCode == "dossierLoadFailure" }
        })
        #expect(personLifecyclePresentation(context.model) == previous.replacing(
            detail: .failed(
                dossierID: context.values.snapshot.dossier.id,
                previous: .personMatter(context.values.snapshot)
            ),
            errorCode: "dossierLoadFailure"
        ))
        #expect(recorder.diagnostics.map(\.category) == [.dossierLoad])
        await context.model.stopWatching()
    }

    @Test(arguments: PersonDossierRefreshRace.allCases)
    @MainActor func blockedPersonRefreshRejectsEveryStaleContext(
        race: PersonDossierRefreshRace
    ) async throws {
        let context = try await makePersonLifecycleContext()
        let refreshed = try refreshedPersonLifecycleSnapshot(in: context)
        await context.people.setSnapshotSteps([.blocked(.success(refreshed))])
        let refresh = Task { await context.model.refreshSelectedDossier() }
        await context.people.waitUntilBlockedSnapshotStarts()

        switch race {
        case .sourceSelection:
            await context.model.selectSource(id: context.otherSource.id)
        case .documentSelection:
            await context.model.selectDocument(id: context.values.origin.id)
        case .personMutation:
            await context.people.setAcceptSteps([.result(context.mutatedSnapshot)])
            await context.model.acceptPersonDossierSuggestion(
                context.values.snapshot.suggestions[0]
            )
        case .dossierABA:
            await context.people.setSnapshotSteps([
                .result(context.otherSnapshot),
                .result(context.values.snapshot),
            ])
            await context.model.selectDossier(id: context.otherSnapshot.dossier.id)
            await context.model.selectDossier(id: context.values.snapshot.dossier.id)
        }
        let expectedWorkspace = context.model.workspaceSelection
        let expectedDetail = context.model.dossierDetailState
        await context.people.releaseBlockedSnapshots()
        await refresh.value

        #expect(context.model.workspaceSelection == expectedWorkspace)
        #expect(context.model.dossierDetailState == expectedDetail)
        #expect(context.model.dossierDetailState.personSnapshot != refreshed)
    }

    @Test @MainActor func removingNonOriginSourcePublishesBothSummariesDocumentsAndPersonSnapshotTogether() async throws {
        let context = try await makePersonLifecycleContext(selectedSource: .other)
        let refreshed = context.values.replacingSnapshot(
            directMembers: context.values.snapshot.directMembers.filter {
                $0.document.sourceRootID == context.originSource.id
            },
            costsAndPayments: context.values.snapshot.costsAndPayments.filter {
                $0.document.sourceRootID == context.originSource.id
            },
            suggestions: [],
            corrections: context.values.snapshot.corrections.filter {
                $0.document.sourceRootID == context.originSource.id
            }
        )
        let finalPersonSummaries = [personSummary(refreshed), personSummary(context.otherSnapshot)]
        let finalCostSummaries = [costSummary(context.costSnapshot)]
        await context.people.setSummarySteps([.result(finalPersonSummaries)])
        await context.costs.setSummarySteps([.result(finalCostSummaries)])
        await context.people.setSnapshotSteps([.result(refreshed)])

        await context.model.removeSource(context.otherSource)

        #expect(context.model.sources == [context.originSource])
        #expect(context.model.dossiers == finalCostSummaries)
        #expect(context.model.personDossiers == finalPersonSummaries)
        #expect(context.model.documents == context.originDocuments)
        #expect(context.model.workspaceSelection == .dossier(context.values.snapshot.dossier.id))
        #expect(context.model.dossierDetailState == .available(.personMatter(refreshed)))
        #expect(context.model.lastErrorCode == nil)
    }

    @Test @MainActor func removingPersonOriginKeepsWorkspaceAndPublishesUnavailableOriginWithoutRemovedDiagnostic() async throws {
        let context = try await makePersonLifecycleContext(selectedSource: .origin)
        let refreshed = try unavailablePersonOriginSnapshot(in: context)
        let finalPersonSummaries = [personSummary(refreshed)]
        await context.people.setSummarySteps([.result(finalPersonSummaries)])
        await context.costs.setSummarySteps([.result([])])
        await context.people.setSnapshotSteps([.result(refreshed)])

        await context.model.removeSource(context.originSource)

        #expect(context.model.sources == [context.otherSource])
        #expect(context.model.personDossiers == finalPersonSummaries)
        #expect(context.model.documents == context.otherDocuments)
        #expect(context.model.workspaceSelection == .dossier(context.values.snapshot.dossier.id))
        #expect(context.model.dossierDetailState == .available(.personMatter(refreshed)))
        #expect(context.model.lastErrorCode != "dossierRemoved")
    }

    @Test @MainActor func actualMissingPersonDossierUsesOneAtomicSharedFallback() async throws {
        let recorder = PersonDossierDiagnosticRecorder()
        let context = try await makePersonLifecycleContext(
            reportRuntimeFailure: { recorder.record($0) }
        )
        let remainingPersonSummaries = [personSummary(context.otherSnapshot)]
        let remainingCostSummaries = [costSummary(context.costSnapshot)]
        let invoiceDNA = try #require(context.values.dnaByDocument[context.values.invoice.id])
        let invoicePerson = try #require(invoiceDNA.findings.first { $0.kind == .person })
        let invoiceSelection = try PersonDossierAnchorSelection(
            document: context.values.invoice,
            snapshot: invoiceDNA,
            finding: invoicePerson
        )
        await context.model.selectDocument(id: context.values.invoice.id)
        await context.costs.setOpenSteps([.result(.choose(remainingCostSummaries))])
        await context.model.openOrCreateDossierForSelectedDocument()
        await context.people.setOpenSteps([.result(.choose(remainingPersonSummaries))])
        await context.model.openOrCreatePersonDossier(from: invoiceSelection)
        #expect(context.model.dossierChoices == remainingCostSummaries)
        #expect(context.model.personDossierChoices == remainingPersonSummaries)
        await context.people.setSnapshotSteps([.dossierFailure(.dossierNotFound)])
        await context.people.setSummarySteps([.result(remainingPersonSummaries)])
        await context.costs.setSummarySteps([.result(remainingCostSummaries)])

        await context.model.refreshSelectedDossier()

        #expect(context.model.sources == [context.originSource, context.otherSource])
        #expect(context.model.dossiers == remainingCostSummaries)
        #expect(context.model.personDossiers == remainingPersonSummaries)
        #expect(context.model.documents == context.originDocuments)
        #expect(context.model.workspaceSelection == .source(context.originSource.id))
        #expect(context.model.dossierDetailState == .none)
        #expect(context.model.dossierChoices.isEmpty)
        #expect(context.model.personDossierChoices.isEmpty)
        #expect(context.model.lastErrorCode == "dossierRemoved")
        #expect(recorder.diagnostics.filter { $0.category == .dossierLoad }.count == 1)
    }

    @Test @MainActor func failedPersonSourceRemovalPublishesNoMixedLifecycleState() async throws {
        let context = try await makePersonLifecycleContext(selectedSource: .other)
        let previous = personLifecyclePresentation(context.model)
        await context.people.setSummarySteps([.result([personSummary(context.otherSnapshot)])])
        await context.costs.setSummarySteps([.result([costSummary(context.costSnapshot)])])
        await context.people.setSnapshotSteps([.failure])

        await context.model.removeSource(context.otherSource)

        #expect(personLifecyclePresentation(context.model) == previous.replacing(
            detail: .failed(
                dossierID: context.values.snapshot.dossier.id,
                previous: .personMatter(context.values.snapshot)
            ),
            errorCode: "dossierLoadFailure"
        ))
    }

    @Test @MainActor func sameSourceDirectPersonMemberNavigationKeepsExactWorkspace() async throws {
        let context = try await makeNavigationContext()

        await context.model.selectPersonDossierDocument(documentID: context.values.direct.id)

        #expect(context.model.workspaceSelection == .dossier(context.values.snapshot.dossier.id))
        #expect(context.model.selectedSourceID == context.values.direct.sourceRootID)
        #expect(context.model.selectedDocumentID == context.values.direct.id)
        #expect(context.model.documentDNADetailState == .available(
            context.values.dnaByDocument[context.values.direct.id]!
        ))
        #expect(context.model.dossierDetailState.personSnapshot == context.values.snapshot)
    }

    @Test @MainActor func crossSourceDirectPersonMemberNavigationKeepsExactWorkspace() async throws {
        let context = try await makeNavigationContext()

        await context.model.selectPersonDossierDocument(
            documentID: context.values.crossSourceDirect.id
        )

        #expect(context.model.workspaceSelection == .dossier(context.values.snapshot.dossier.id))
        #expect(context.model.selectedSourceID == context.values.crossSourceDirect.sourceRootID)
        #expect(context.model.selectedDocumentID == context.values.crossSourceDirect.id)
        #expect(context.model.dossierDetailState.personSnapshot == context.values.snapshot)
    }

    @Test @MainActor func personCostsPaymentNavigationUsesStoredCompleteDocument() async throws {
        let context = try await makeNavigationContext()

        await context.model.selectPersonDossierDocument(documentID: context.values.payment.id)

        #expect(context.model.workspaceSelection == .dossier(context.values.snapshot.dossier.id))
        #expect(context.model.selectedSourceID == context.values.payment.sourceRootID)
        #expect(context.model.selectedDocumentID == context.values.payment.id)
        #expect(context.model.documentDNADetailState == .available(
            context.values.dnaByDocument[context.values.payment.id]!
        ))
        #expect(context.model.dossierDetailState.personSnapshot == context.values.snapshot)
    }

    @Test(arguments: [PersonDossierNavigationRow.suggestion, .correction])
    @MainActor func suggestionAndCorrectionRowsAreNavigable(
        row: PersonDossierNavigationRow
    ) async throws {
        let context = try await makeNavigationContext()
        let document = switch row {
        case .suggestion: context.values.suggestion
        case .correction: context.values.correction
        }

        await context.model.selectPersonDossierDocument(documentID: document.id)

        #expect(context.model.selectedSourceID == document.sourceRootID)
        #expect(context.model.selectedDocumentID == document.id)
        #expect(context.model.documentDNADetailState == .available(
            context.values.dnaByDocument[document.id]!
        ))
        #expect(context.model.dossierDetailState.personSnapshot == context.values.snapshot)
    }

    @Test @MainActor func currentPersonOriginDocumentIsNavigable() async throws {
        let context = try await makeNavigationContext()

        await context.model.selectPersonDossierDocument(documentID: context.values.origin.id)

        #expect(context.model.selectedSourceID == context.values.origin.sourceRootID)
        #expect(context.model.selectedDocumentID == context.values.origin.id)
        #expect(context.model.documentDNADetailState == .available(
            context.values.dnaByDocument[context.values.origin.id]!
        ))
        #expect(context.model.dossierDetailState.personSnapshot == context.values.snapshot)
    }

    @Test @MainActor func duplicatePersonDocumentIDUsesEarlierCompleteSnapshotRecord() async throws {
        let context = try await makeNavigationContext(duplicateFirstWins: true)

        await context.model.selectPersonDossierDocument(documentID: context.values.direct.id)

        #expect(context.model.selectedSourceID == context.values.direct.sourceRootID)
        #expect(context.model.selectedDocumentID == context.values.direct.id)
        #expect(context.model.documents == context.originSourceDocuments)
        #expect(context.model.documentDNADetailState == .available(
            context.values.dnaByDocument[context.values.direct.id]!
        ))
        #expect(await context.documents.sourceIDs.last == context.originSource.id)
        #expect(context.model.dossierDetailState.personSnapshot == context.openedSnapshot)
    }

    @Test @MainActor func unavailablePersonOriginPerformsNoDocumentLoad() async throws {
        let context = try await makeNavigationContext(originUnavailable: true)
        let loadsBefore = await context.documents.sourceIDs

        await context.model.selectPersonDossierDocument(documentID: context.values.origin.id)

        #expect(await context.documents.sourceIDs == loadsBefore)
        #expect(context.model.selectedDocumentID == nil)
        #expect(context.model.dossierDetailState.personSnapshot == context.openedSnapshot)
    }

    @Test @MainActor func unknownPersonDocumentIDPerformsNoDocumentLoad() async throws {
        let context = try await makeNavigationContext()
        let loadsBefore = await context.documents.sourceIDs

        await context.model.selectPersonDossierDocument(documentID: UUID())

        #expect(await context.documents.sourceIDs == loadsBefore)
        #expect(context.model.selectedDocumentID == nil)
        #expect(context.model.dossierDetailState.personSnapshot == context.values.snapshot)
    }

    @Test @MainActor func changedSourceRejectsPersonNavigationAndPreservesSnapshot() async throws {
        let context = try await makeNavigationContext(includeCandidates: true)
        let previous = await preselectPersonInvoice(in: context)
        var moved = context.values.direct
        moved.sourceRootID = context.otherSource.id
        await context.documents.setDocuments(
            context.otherSourceDocuments + [moved],
            sourceID: context.otherSource.id
        )
        await context.documents.setDocuments(
            context.originSourceDocuments.filter { $0.id != moved.id },
            sourceID: context.originSource.id
        )

        await context.model.selectPersonDossierDocument(documentID: moved.id)

        assertFailedNavigationPreserved(context, previous: previous)
    }

    @Test @MainActor func changedContentHashRejectsPersonNavigationAndPreservesSnapshot() async throws {
        let context = try await makeNavigationContext(includeCandidates: true)
        let previous = await preselectPersonInvoice(in: context)
        var changed = context.values.direct
        changed.contentHash = "changed-direct-hash"
        await context.documents.setDocuments(
            context.originSourceDocuments.map { $0.id == changed.id ? changed : $0 },
            sourceID: context.originSource.id
        )

        await context.model.selectPersonDossierDocument(documentID: changed.id)

        assertFailedNavigationPreserved(context, previous: previous)
    }

    @Test @MainActor func nonReadyDNARejectsPersonNavigationAndPreservesSnapshot() async throws {
        let context = try await makeNavigationContext(
            nonReadyDocumentID: PersonDossierNavigationValues.paymentID,
            includeCandidates: true
        )
        let previous = await preselectPersonInvoice(in: context)

        await context.model.selectPersonDossierDocument(documentID: context.values.payment.id)

        assertFailedNavigationPreserved(context, previous: previous)
    }

    @Test @MainActor func documentLoaderFailurePreservesPersonWorkspaceAndLastSnapshot() async throws {
        let context = try await makeNavigationContext(includeCandidates: true)
        let previous = await preselectPersonInvoice(in: context)
        await context.documents.setSteps([.failure], sourceID: context.otherSource.id)

        await context.model.selectPersonDossierDocument(documentID: context.values.payment.id)

        assertFailedNavigationPreserved(context, previous: previous)
    }

    @Test @MainActor func cancelledDocumentLoadSilentlyPreservesPersonWorkspaceAndLastSnapshot() async throws {
        let context = try await makeNavigationContext(includeCandidates: true)
        let previous = await preselectPersonInvoice(in: context)
        await context.documents.setSteps([
            .blocked(.success(context.otherSourceDocuments)),
        ], sourceID: context.otherSource.id)
        let navigation = Task {
            await context.model.selectPersonDossierDocument(
                documentID: context.values.payment.id
            )
        }
        await context.documents.waitUntilBlockedLoadStarts()

        navigation.cancel()
        await context.documents.releaseBlockedLoads()
        await navigation.value

        #expect(personDocumentPresentation(of: context.model) == previous)
        #expect(context.model.lastErrorCode == nil)
    }

    @Test @MainActor func secondPersonNavigationInvalidatesEarlierInFlightNavigation() async throws {
        let context = try await makeNavigationContext()
        await context.documents.setSteps([
            .blocked(.success(context.originSourceDocuments)),
        ], sourceID: context.originSource.id)
        let stale = Task {
            await context.model.selectPersonDossierDocument(documentID: context.values.direct.id)
        }
        await context.documents.waitUntilBlockedLoadStarts()

        await context.model.selectPersonDossierDocument(
            documentID: context.values.crossSourceDirect.id
        )
        await context.documents.releaseBlockedLoads()
        await stale.value

        #expect(context.model.selectedDocumentID == context.values.crossSourceDirect.id)
        #expect(context.model.dossierDetailState.personSnapshot == context.values.snapshot)
    }

    @Test @MainActor func personDocumentABARaceRejectsStaleNavigationCompletion() async throws {
        let context = try await makeNavigationContext()
        await context.documents.setSteps([
            .blocked(.success(context.originSourceDocuments)),
        ], sourceID: context.originSource.id)
        let stale = Task {
            await context.model.selectPersonDossierDocument(documentID: context.values.direct.id)
        }
        await context.documents.waitUntilBlockedLoadStarts()

        await context.model.selectPersonDossierDocument(
            documentID: context.values.crossSourceDirect.id
        )
        await context.model.selectPersonDossierDocument(documentID: context.values.direct.id)
        await context.documents.releaseBlockedLoads()
        await stale.value

        #expect(context.model.selectedDocumentID == context.values.direct.id)
        #expect(context.model.documentDNADetailState == .available(
            context.values.dnaByDocument[context.values.direct.id]!
        ))
    }

    @Test @MainActor func personDossierABARaceRejectsStaleNavigationCompletion() async throws {
        let other = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeNavigationContext(dossierABASnapshot: other)
        await context.documents.setSteps([
            .blocked(.success(context.originSourceDocuments)),
        ], sourceID: context.originSource.id)
        let stale = Task {
            await context.model.selectPersonDossierDocument(documentID: context.values.direct.id)
        }
        await context.documents.waitUntilBlockedLoadStarts()

        await context.model.selectDossier(id: other.dossier.id)
        await context.model.selectDossier(id: context.values.snapshot.dossier.id)
        await context.documents.releaseBlockedLoads()
        await stale.value

        #expect(context.model.workspaceSelection == .dossier(context.values.snapshot.dossier.id))
        #expect(context.model.selectedDocumentID == nil)
        #expect(context.model.dossierDetailState.personSnapshot == context.values.snapshot)
    }

    @Test @MainActor func personMutationCompletionRejectsStaleNavigation() async throws {
        let context = try await makeNavigationContext(includeOpenMutation: true)
        await context.model.selectPersonDossierDocument(documentID: context.values.invoice.id)
        await context.documents.setSteps([
            .blocked(.success(context.otherSourceDocuments)),
        ], sourceID: context.otherSource.id)
        let stale = Task {
            await context.model.selectPersonDossierDocument(documentID: context.values.payment.id)
        }
        await context.documents.waitUntilBlockedLoadStarts()
        let invoiceDNA = context.values.dnaByDocument[context.values.invoice.id]!
        let selection = try PersonDossierAnchorSelection(
            document: context.values.invoice,
            snapshot: invoiceDNA,
            finding: try #require(invoiceDNA.findings.first { $0.kind == .person })
        )

        await context.model.openOrCreatePersonDossier(from: selection)
        await context.documents.releaseBlockedLoads()
        await stale.value

        #expect(context.model.selectedDocumentID == context.values.invoice.id)
        #expect(context.model.dossierDetailState.personSnapshot == context.mutatedSnapshot)
    }

    @Test @MainActor func confirmedCounterpartFromPersonPaymentKeepsExactPersonIdentity() async throws {
        let context = try await makeNavigationContext(includeCandidates: true)
        await context.model.selectPersonDossierDocument(documentID: context.values.payment.id)

        await context.model.showInvoicePaymentCounterpart(
            candidate: context.values.candidate.candidate
        )

        #expect(context.model.workspaceSelection == .dossier(context.values.snapshot.dossier.id))
        #expect(context.model.selectedSourceID == context.values.invoice.sourceRootID)
        #expect(context.model.selectedDocumentID == context.values.invoice.id)
        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.values.snapshot)
        ))
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func personCorrectionForwardsExactCurrentInputAndPublishesCompleteSnapshot(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        await configure(
            command,
            service: context.service,
            steps: [.result(context.mutatedSnapshot)]
        )

        await perform(command, in: context)

        try await assertExactInvocation(command, context: context)
        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.mutatedSnapshot)
        ))
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func resetPersonCorrectionForwardsCompleteConfirmationDecision() async throws {
        let context = try await makeNavigationContext()
        let confirmed = try snapshotWithConfirmationCorrection(from: context.values.snapshot)
        await context.service.setSnapshotSteps([.result(confirmed)])
        await context.model.selectDossier(id: confirmed.dossier.id)
        let correction = try #require(confirmed.corrections.first)
        await context.service.setResetSteps([.result(context.mutatedSnapshot)])

        await context.model.resetPersonDossierCorrection(correction)

        #expect(await context.service.resetInvocations == [.init(
            dossierID: confirmed.dossier.id,
            documentID: correction.id,
            expectedDecision: correction.decision,
            expectedToken: confirmed.token
        )])
    }

    @Test @MainActor func removePersonMemberUsesAuthoritativeCommandSupportNotAnotherStoredSupport() async throws {
        let context = try await makeNavigationContext()
        let original = try #require(context.values.snapshot.directMembers.first)
        let revisionID = UUID(uuidString: "74000000-0000-0000-0000-000000000002")!
        let confirmation = try DossierMembershipConfirmation(
            dossierID: context.values.snapshot.dossier.id,
            documentID: original.id,
            revisionID: revisionID,
            confirmedAt: Date(timeIntervalSince1970: 401),
            candidateKind: .birthDateConflict,
            acceptedContentHash: original.document.contentHash,
            acceptedExtractionVersion: "text-v1",
            acceptedDNASchemaVersion: 1,
            acceptedDNAAnalyzerIdentifier: "local-rules",
            acceptedDNAAnalyzerVersion: "1",
            acceptedDNAAnalyzedAt: Date(timeIntervalSince1970: 200),
            acceptedRole: .resident,
            acceptedNormalizedName: "elise muster"
        )
        let authoritative = try PersonDossierMember(
            document: original.document,
            sourceDisplayName: original.sourceDisplayName,
            documentType: original.documentType,
            section: original.section,
            supports: original.supports + [.manualConfirmation(
                confirmation: confirmation,
                currentCandidate: nil
            )],
            isConfirmationAuthoritative: true,
            preferredPaymentSupport: nil
        )
        let current = context.values.replacingSnapshot(
            directMembers: [authoritative] + context.values.snapshot.directMembers.dropFirst(),
            token: PersonDossierProjectionToken(
                dossierUpdatedAt: context.values.snapshot.token.dossierUpdatedAt,
                anchorUpdatedAt: context.values.snapshot.token.anchorUpdatedAt,
                originValidity: context.values.snapshot.token.originValidity,
                documents: context.values.snapshot.token.documents,
                memberSupports: [authoritative.supports]
                    + context.values.snapshot.directMembers.dropFirst().map(\.supports)
                    + context.values.snapshot.costsAndPayments.map(\.supports),
                suggestionSupports: context.values.snapshot.token.suggestionSupports,
                confirmationRevisionIDs: [revisionID],
                exclusionRevisionIDs: context.values.snapshot.token.exclusionRevisionIDs
            )
        )
        await context.service.setSnapshotSteps([.result(current)])
        await context.model.selectDossier(id: current.dossier.id)
        await context.service.setRemoveSteps([.result(context.mutatedSnapshot)])

        await context.model.removePersonDossierMember(authoritative)

        #expect(await context.service.removeInvocations == [.init(
            dossierID: current.dossier.id,
            documentID: authoritative.id,
            expectedSupport: try authoritative.commandSupport,
            expectedToken: current.token
        )])
    }

    @Test(arguments: [PersonDossierCorrectionCommand.accept, .reject])
    @MainActor func suggestionCommandUsesAuthoritativeSupportWhenItIsNotFirst(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        let original = try #require(context.values.snapshot.suggestions.first)
        let authoritative = original.commandSupport
        let originalDNA = try #require(context.values.dnaByDocument[original.id])
        let finding = authoritative.person.finding
        let alternateFinding = try DocumentDNAFinding(
            kind: finding.kind,
            qualifier: finding.qualifier,
            displayValue: finding.displayValue,
            normalizedValue: finding.normalizedValue,
            secondaryNormalizedValue: finding.secondaryNormalizedValue,
            confidence: finding.confidence == 0.8 ? 0.7 : 0.8,
            evidence: finding.evidence
        )
        let alternateDNA = try DocumentDNA(
            documentID: originalDNA.documentID,
            schemaVersion: originalDNA.schemaVersion,
            analyzerIdentifier: originalDNA.analyzerIdentifier,
            analyzerVersion: originalDNA.analyzerVersion,
            inputContentHash: originalDNA.inputContentHash,
            inputExtractionVersion: originalDNA.inputExtractionVersion,
            findings: originalDNA.findings + [alternateFinding],
            analyzedAt: originalDNA.analyzedAt
        )
        let alternatePerson = try PersonDossierFindingSupportIdentity(
            current: CurrentDocumentDNA(document: original.document, snapshot: alternateDNA),
            role: authoritative.person.role,
            finding: alternateFinding
        )
        let alternate = try PersonDossierCandidateSupportIdentity(
            kind: authoritative.kind,
            person: alternatePerson,
            conflict: authoritative.conflict
        )
        let suggestion = try PersonDossierSuggestion(
            document: original.document,
            sourceDisplayName: original.sourceDisplayName,
            documentType: original.documentType,
            section: original.section,
            kind: original.kind,
            conflict: original.conflict,
            currentSupports: [alternate, authoritative],
            commandSupport: authoritative
        )
        let current = context.values.replacingSnapshot(
            suggestions: [suggestion],
            token: PersonDossierProjectionToken(
                dossierUpdatedAt: context.values.snapshot.token.dossierUpdatedAt,
                anchorUpdatedAt: context.values.snapshot.token.anchorUpdatedAt,
                originValidity: context.values.snapshot.token.originValidity,
                documents: context.values.snapshot.token.documents,
                memberSupports: context.values.snapshot.token.memberSupports,
                suggestionSupports: [alternate, authoritative],
                confirmationRevisionIDs: context.values.snapshot.token.confirmationRevisionIDs,
                exclusionRevisionIDs: context.values.snapshot.token.exclusionRevisionIDs
            )
        )
        await context.service.setSnapshotSteps([.result(current)])
        await context.model.selectDossier(id: current.dossier.id)
        await configure(
            command,
            service: context.service,
            steps: [.result(context.mutatedSnapshot)]
        )

        await perform(command, in: context)

        let invocation: ScriptedPersonDossierLoader.SuggestionInvocation? = switch command {
        case .accept: await context.service.acceptInvocations.first
        case .reject: await context.service.rejectInvocations.first
        default: nil
        }
        #expect(invocation == .init(
            dossierID: current.dossier.id,
            documentID: suggestion.id,
            expectedSupport: authoritative,
            expectedToken: current.token
        ))
    }

    @Test @MainActor func removePersonCostsMemberForwardsExactCommandSupportAndPublishesSnapshot() async throws {
        let context = try await makeNavigationContext()
        let member = try #require(context.values.snapshot.costsAndPayments.first)
        await context.service.setRemoveSteps([.result(context.mutatedSnapshot)])

        await context.model.removePersonDossierMember(member)

        #expect(await context.service.removeInvocations == [.init(
            dossierID: context.values.snapshot.dossier.id,
            documentID: member.id,
            expectedSupport: try member.commandSupport,
            expectedToken: context.values.snapshot.token
        )])
        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.mutatedSnapshot)
        ))
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func staleDisplayedPersonCorrectionValueDoesNotStart(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        let stale = try staleInput(for: command, snapshot: context.values.snapshot)

        await perform(command, input: stale, model: context.model)

        #expect(await invocationCount(command, service: context.service) == 0)
        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.values.snapshot)
        ))
        #expect(context.model.lastErrorCode == nil)
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func personCorrectionFailurePreservesLastGoodSnapshotAndPublishesSafeDiagnostic(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        await configure(command, service: context.service, steps: [.failure])

        await perform(command, in: context)

        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.values.snapshot)
        ))
        #expect(context.model.lastErrorCode == "dossierMutationFailure")
        #expect(
            context.model.lastErrorMessage
                == "Die Dossier-Korrektur konnte nicht gespeichert werden. Bitte versuche es erneut."
        )
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func wrongDossierPersonCorrectionResultPreservesSnapshotAndPublishesFailure(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        let wrong = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        await configure(command, service: context.service, steps: [.result(wrong)])

        await perform(command, in: context)

        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.values.snapshot)
        ))
        #expect(context.model.lastErrorCode == "dossierMutationFailure")
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func stalePersonCorrectionInputPreservesSnapshotAndPublishesSafeDiagnostic(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        await configure(command, service: context.service, steps: [.staleInput])

        await perform(command, in: context)

        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.values.snapshot)
        ))
        #expect(context.model.lastErrorCode == "dossierMutationFailure")
        #expect(
            context.model.lastErrorMessage
                == "Die Dossier-Korrektur konnte nicht gespeichert werden. Bitte versuche es erneut."
        )
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func cancelledPersonCorrectionPreservesSnapshotWithoutDiagnostic(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        await configure(command, service: context.service, steps: [.cancellation])

        await perform(command, in: context)

        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.values.snapshot)
        ))
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func cancelledCancellationInsensitivePersonCorrectionIsIdleAndSilent(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        await configure(
            command,
            service: context.service,
            steps: [.blocked(.failure(.loadFailed))]
        )
        let mutation = Task { await perform(command, in: context) }
        await context.service.waitUntilBlockedMutationStarts()

        mutation.cancel()
        await context.service.releaseBlockedMutations()
        await mutation.value

        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.values.snapshot)
        ))
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func cancelledCancellationInsensitivePersonCorrectionSuccessIsIdleAndSilent(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        await configure(
            command,
            service: context.service,
            steps: [.blocked(.success(context.mutatedSnapshot))]
        )
        let mutation = Task { await perform(command, in: context) }
        await context.service.waitUntilBlockedMutationStarts()

        mutation.cancel()
        await context.service.releaseNextBlockedMutation()
        await mutation.value

        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.values.snapshot)
        ))
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func personCorrectionSuppressesEverySecondMutationWhileInFlight(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        await configure(
            command,
            service: context.service,
            steps: [.blocked(.success(context.mutatedSnapshot))]
        )
        let first = Task { await perform(command, in: context) }
        await context.service.waitUntilBlockedMutationStarts()

        #expect(context.model.dossierMutationState == mutationState(
            command,
            snapshot: context.values.snapshot
        ))
        for second in PersonDossierCorrectionCommand.allCases {
            await perform(second, in: context)
        }

        #expect(await totalCorrectionInvocationCount(context.service) == 1)
        await context.service.releaseBlockedMutations()
        await first.value
    }

    @Test(
        arguments: PersonDossierCorrectionCommand.allCases,
        PersonDossierCorrectionSelectionRace.allCases
    )
    @MainActor func personCorrectionRejectsLateCompletionAfterEverySelectionRace(
        command: PersonDossierCorrectionCommand,
        race: PersonDossierCorrectionSelectionRace
    ) async throws {
        let other = try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
        let context = try await makeNavigationContext(dossierABASnapshot: other)
        await configure(
            command,
            service: context.service,
            steps: [.blocked(.success(context.mutatedSnapshot))]
        )
        let mutation = Task { await perform(command, in: context) }
        await context.service.waitUntilBlockedMutationStarts()

        switch race {
        case .source:
            await context.model.selectSource(id: context.otherSource.id)
        case .document:
            await context.model.selectPersonDossierDocument(
                documentID: context.values.crossSourceDirect.id
            )
        case .dossier:
            await context.model.selectDossier(id: other.dossier.id)
        case .dossierABA:
            await context.model.selectDossier(id: other.dossier.id)
            await context.model.selectDossier(id: context.values.snapshot.dossier.id)
        }
        let workspaceAfterRace = context.model.workspaceSelection
        let detailAfterRace = context.model.dossierDetailState
        let sourceAfterRace = context.model.selectedSourceID
        let documentAfterRace = context.model.selectedDocumentID
        await context.service.releaseBlockedMutations()
        await mutation.value

        #expect(context.model.workspaceSelection == workspaceAfterRace)
        #expect(context.model.dossierDetailState == detailAfterRace)
        #expect(context.model.selectedSourceID == sourceAfterRace)
        #expect(context.model.selectedDocumentID == documentAfterRace)
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func concurrentPersonReloadPreventsOlderCorrectionFromPublishing(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        await configure(
            command,
            service: context.service,
            steps: [.blocked(.success(context.mutatedSnapshot))]
        )
        let mutation = Task { await perform(command, in: context) }
        await context.service.waitUntilBlockedMutationStarts()
        await context.service.setSnapshotSteps([.result(context.values.snapshot)])

        await context.model.selectDossier(id: context.values.snapshot.dossier.id)
        await context.service.releaseBlockedMutations()
        await mutation.value

        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.values.snapshot)
        ))
        #expect(context.model.lastErrorCode == nil)
    }

    @Test(
        arguments: PersonDossierRefreshPortOutcome.allCases,
        PersonDossierLateCorrectionOutcome.allCases
    )
    @MainActor func personRefreshLoadGenerationAloneRejectsLatePersonCorrection(
        refreshOutcome: PersonDossierRefreshPortOutcome,
        correctionOutcome: PersonDossierLateCorrectionOutcome
    ) async throws {
        let context = try await makeNavigationContext()
        let correctionStep: ScriptedPersonDossierLoader.CorrectionStep = switch correctionOutcome {
        case .success: .blocked(.success(context.mutatedSnapshot))
        case .failure: .blocked(.failure(.loadFailed))
        }
        await context.service.setAcceptSteps([correctionStep])
        let correction = Task {
            await context.model.acceptPersonDossierSuggestion(
                context.values.snapshot.suggestions[0]
            )
        }
        await context.service.waitUntilBlockedMutationStarts()
        switch refreshOutcome {
        case .returnWrongDossier:
            await context.service.setSnapshotSteps([.result(
                try PersonDossierAppModelValues.make(dossierID: UUID()).snapshot
            )])
        case .failure:
            await context.service.setSnapshotSteps([.failure])
        }

        await context.model.refreshSelectedDossier()
        let detailAfterRefresh = context.model.dossierDetailState
        let failureAfterRefresh = context.model.lastErrorCode
        #expect(detailAfterRefresh == .failed(
            dossierID: context.values.snapshot.dossier.id,
            previous: .personMatter(context.values.snapshot)
        ))
        #expect(failureAfterRefresh == "dossierLoadFailure")
        await context.service.releaseNextBlockedMutation()
        await correction.value

        #expect(context.model.dossierDetailState == detailAfterRefresh)
        #expect(context.model.lastErrorCode == failureAfterRefresh)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test @MainActor func oldMutationDeferCannotClearNewerInFlightMutation() async throws {
        let context = try await makeNavigationContext()
        await context.service.setAcceptSteps([
            .blocked(.success(context.mutatedSnapshot)),
        ])
        let old = Task { await perform(.accept, in: context) }
        await context.service.waitUntilBlockedMutationStarts(count: 1)
        await context.service.setSnapshotSteps([.result(context.values.snapshot)])
        await context.model.selectDossier(id: context.values.snapshot.dossier.id)
        await context.service.setRejectSteps([
            .blocked(.success(context.mutatedSnapshot)),
        ])
        let newer = Task { await perform(.reject, in: context) }
        await context.service.waitUntilBlockedMutationStarts(count: 2)

        await context.service.releaseNextBlockedMutation()
        await old.value
        #expect(context.model.dossierMutationState == .rejectingPerson(
            dossierID: context.values.snapshot.dossier.id,
            documentID: context.values.snapshot.suggestions[0].id
        ))
        await perform(.remove, in: context)
        #expect(await totalCorrectionInvocationCount(context.service) == 2)

        await context.service.releaseNextBlockedMutation()
        await newer.value
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func personCorrectionInvalidatesInFlightPersonDossierLoad(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        let staleLoad = try PersonDossierAppModelValues.make(
            dossierID: context.values.snapshot.dossier.id,
            documentID: UUID()
        ).snapshot
        await context.service.setSnapshotSteps([.blocked(.success(staleLoad))])
        let load = Task {
            await context.model.selectDossier(id: context.values.snapshot.dossier.id)
        }
        await context.service.waitUntilBlockedSnapshotStarts()
        await configure(
            command,
            service: context.service,
            steps: [.result(context.mutatedSnapshot)]
        )

        await perform(command, in: context)
        await context.service.releaseBlockedSnapshots()
        await load.value

        #expect(context.model.dossierDetailState == .available(
            .personMatter(context.mutatedSnapshot)
        ))
        #expect(context.model.lastErrorCode == nil)
        #expect(context.model.dossierMutationState == .idle)
    }

    @Test(arguments: PersonDossierCorrectionCommand.allCases)
    @MainActor func newerCompletedPersonCorrectionPreventsOlderResultFromPublishing(
        command: PersonDossierCorrectionCommand
    ) async throws {
        let context = try await makeNavigationContext()
        let newerCommand = command.next
        let newerSnapshot = try PersonDossierAppModelValues.make(
            dossierID: context.values.snapshot.dossier.id,
            documentID: UUID()
        ).snapshot
        await configure(
            command,
            service: context.service,
            steps: [.blocked(.success(context.mutatedSnapshot))]
        )
        let older = Task { await perform(command, in: context) }
        await context.service.waitUntilBlockedMutationStarts()
        await context.service.setSnapshotSteps([.result(context.values.snapshot)])
        await context.model.selectDossier(id: context.values.snapshot.dossier.id)
        await configure(
            newerCommand,
            service: context.service,
            steps: [.result(newerSnapshot)]
        )

        await perform(newerCommand, in: context)
        await context.service.releaseBlockedMutations()
        await older.value

        #expect(context.model.dossierDetailState == .available(
            .personMatter(newerSnapshot)
        ))
        #expect(context.model.lastErrorCode == nil)
    }
}

private extension PersonDossierAppModelTests {
    @MainActor
    func makePersonLifecycleContext(
        selectedSource: PersonDossierLifecycleSelectedSource = .origin,
        reportRuntimeFailure: @escaping @MainActor @Sendable (AppRuntimeDiagnostic) -> Void = { _ in }
    ) async throws -> PersonDossierLifecycleContext {
        let fixture = try PersonDossierAppModelFixture()
        let originSource = try await fixture.addSource(named: "Archive")
        let otherSource = try await fixture.addSource(named: "Other archive")
        let values = try PersonDossierNavigationValues.make(
            originSourceID: originSource.id,
            otherSourceID: otherSource.id
        )
        let otherSnapshot = try PersonDossierAppModelValues.make(
            dossierID: UUID(),
            sourceID: originSource.id,
            documentID: UUID(),
            name: "Mara Beispiel"
        ).snapshot
        let mutatedSnapshot = values.replacingSnapshot(suggestions: [])
        let costSnapshot = try CostsAndPaymentsDossierAppModelValues.make().snapshot
        let originDocuments = [
            values.origin,
            values.direct,
            values.invoice,
            values.correction,
        ]
        let otherDocuments = [
            values.crossSourceDirect,
            values.payment,
            values.suggestion,
        ]
        let documents = ScriptedPersonDossierDocumentLoader(documentsBySource: [
            originSource.id: originDocuments,
            otherSource.id: otherDocuments,
        ])
        let allDocuments = originDocuments + otherDocuments
        let statuses = PersonDossierDNAStatusLoader(statusesBySource:
            Dictionary(grouping: allDocuments, by: \.sourceRootID).mapValues { records in
                records.map { DocumentDNAAnalysisStatus(documentID: $0.id, phase: .ready) }
            }
        )
        let dnaSnapshots = ScriptedPersonDossierDNALoader(
            snapshotsByDocument: values.dnaByDocument.mapValues {
                Array(repeating: $0, count: 8)
            }
        )
        let people = ScriptedPersonDossierLoader(
            summarySteps: [.result([
                personSummary(values.snapshot),
                personSummary(otherSnapshot),
            ])],
            snapshotSteps: [.result(values.snapshot)]
        )
        let costs = ScriptedPersonDossierCostsLoader()
        let scheduler = PersonDossierWatchScheduler()
        let model = makeModel(
            fixture,
            costsLoader: costs,
            costsMutator: costs,
            people: people,
            peopleMutator: people,
            dnaStatuses: statuses,
            dnaSnapshots: dnaSnapshots,
            watchScheduler: scheduler,
            documentLoader: { sourceID in
                try await documents.load(sourceID: sourceID)
            },
            reportRuntimeFailure: reportRuntimeFailure
        )
        try await model.reload()
        let selectedSourceID = selectedSource == .origin ? originSource.id : otherSource.id
        await model.selectSource(id: selectedSourceID)
        await model.selectDossier(id: values.snapshot.dossier.id)
        return PersonDossierLifecycleContext(
            fixture: fixture,
            originSource: originSource,
            otherSource: otherSource,
            originDocuments: originDocuments,
            otherDocuments: otherDocuments,
            values: values,
            otherSnapshot: otherSnapshot,
            mutatedSnapshot: mutatedSnapshot,
            costSnapshot: costSnapshot,
            people: people,
            costs: costs,
            documents: documents,
            scheduler: scheduler,
            model: model
        )
    }

    func refreshedPersonLifecycleSnapshot(
        in context: PersonDossierLifecycleContext
    ) throws -> PersonDossierSnapshot {
        var movedOrigin = context.values.origin
        movedOrigin.sourceRootID = context.otherSource.id
        movedOrigin.relativePath = "relocated/person.pdf"
        movedOrigin.availability = .unavailable
        let tokenDate = Date(timeIntervalSince1970: 900)
        return context.values.replacingSnapshot(
            origin: try PersonDossierOriginState(
                validity: .stale,
                document: movedOrigin,
                sourceDisplayName: context.otherSource.displayName
            ),
            directMembers: [context.values.snapshot.directMembers[0]],
            costsAndPayments: [context.values.snapshot.costsAndPayments[0]],
            suggestions: [],
            corrections: [],
            token: PersonDossierProjectionToken(
                dossierUpdatedAt: tokenDate,
                anchorUpdatedAt: tokenDate,
                originValidity: .stale,
                documents: [PersonDossierDocumentProjectionIdentity(
                    document: movedOrigin,
                    dnaAnalyzedAt: tokenDate
                )],
                memberSupports: [],
                suggestionSupports: [],
                confirmationRevisionIDs: [],
                exclusionRevisionIDs: []
            )
        )
    }

    func unavailablePersonOriginSnapshot(
        in context: PersonDossierLifecycleContext
    ) throws -> PersonDossierSnapshot {
        context.values.replacingSnapshot(
            origin: try PersonDossierOriginState(
                validity: .unavailable,
                document: nil,
                sourceDisplayName: nil
            ),
            directMembers: context.values.snapshot.directMembers.filter {
                $0.document.sourceRootID != context.originSource.id
            },
            costsAndPayments: context.values.snapshot.costsAndPayments.filter {
                $0.document.sourceRootID != context.originSource.id
            },
            suggestions: context.values.snapshot.suggestions.filter {
                $0.document.sourceRootID != context.originSource.id
            },
            corrections: context.values.snapshot.corrections.filter {
                $0.document.sourceRootID != context.originSource.id
            },
            token: PersonDossierProjectionToken(
                dossierUpdatedAt: Date(timeIntervalSince1970: 900),
                anchorUpdatedAt: Date(timeIntervalSince1970: 900),
                originValidity: .unavailable,
                documents: [],
                memberSupports: [],
                suggestionSupports: [],
                confirmationRevisionIDs: [],
                exclusionRevisionIDs: []
            )
        )
    }

    @MainActor
    func personLifecyclePresentation(_ model: AppModel) -> PersonDossierLifecyclePresentation {
        PersonDossierLifecyclePresentation(
            sources: model.sources,
            dossiers: model.dossiers,
            personDossiers: model.personDossiers,
            selectedSourceID: model.selectedSourceID,
            documents: model.documents,
            phases: model.documentDNAAnalysisPhases,
            unavailableSourceIDs: model.unavailableSourceIDs,
            selectedDocumentID: model.selectedDocumentID,
            documentDetail: model.documentDNADetailState,
            invoiceCandidates: model.invoicePaymentCandidateState,
            updatingCandidate: model.invoicePaymentDecisionUpdatingCandidate,
            navigatingCandidate: model.invoicePaymentCounterpartNavigatingCandidate,
            isDecisionUpdateInFlight: model.isInvoicePaymentDecisionUpdateInFlight,
            retryingDocumentID: model.documentDNARetryingDocumentID,
            scanState: model.scanState,
            workspace: model.workspaceSelection,
            detail: model.dossierDetailState,
            entry: model.dossierEntryState,
            dossierChoices: model.dossierChoices,
            personDossierChoices: model.personDossierChoices,
            mutationState: model.dossierMutationState,
            errorCode: model.lastErrorCode
        )
    }

    @MainActor
    func perform(
        _ command: PersonDossierCorrectionCommand,
        in context: PersonDossierNavigationContext
    ) async {
        let snapshot = context.model.dossierDetailState.personSnapshot
            ?? context.values.snapshot
        switch command {
        case .accept:
            guard let value = snapshot.suggestions.first else { return }
            await context.model.acceptPersonDossierSuggestion(value)
        case .reject:
            guard let value = snapshot.suggestions.first else { return }
            await context.model.rejectPersonDossierSuggestion(value)
        case .remove:
            guard let value = snapshot.directMembers.first else { return }
            await context.model.removePersonDossierMember(value)
        case .reset:
            guard let value = snapshot.corrections.first else { return }
            await context.model.resetPersonDossierCorrection(value)
        }
    }

    @MainActor
    func perform(
        _ command: PersonDossierCorrectionCommand,
        input: PersonDossierCorrectionInput,
        model: AppModel
    ) async {
        switch (command, input) {
        case (.accept, .suggestion(let value)):
            await model.acceptPersonDossierSuggestion(value)
        case (.reject, .suggestion(let value)):
            await model.rejectPersonDossierSuggestion(value)
        case (.remove, .member(let value)):
            await model.removePersonDossierMember(value)
        case (.reset, .correction(let value)):
            await model.resetPersonDossierCorrection(value)
        default:
            Issue.record("Mismatched correction input")
        }
    }

    func configure(
        _ command: PersonDossierCorrectionCommand,
        service: ScriptedPersonDossierLoader,
        steps: [ScriptedPersonDossierLoader.CorrectionStep]
    ) async {
        switch command {
        case .accept: await service.setAcceptSteps(steps)
        case .reject: await service.setRejectSteps(steps)
        case .remove: await service.setRemoveSteps(steps)
        case .reset: await service.setResetSteps(steps)
        }
    }

    func invocationCount(
        _ command: PersonDossierCorrectionCommand,
        service: ScriptedPersonDossierLoader
    ) async -> Int {
        switch command {
        case .accept: await service.acceptInvocations.count
        case .reject: await service.rejectInvocations.count
        case .remove: await service.removeInvocations.count
        case .reset: await service.resetInvocations.count
        }
    }

    func totalCorrectionInvocationCount(
        _ service: ScriptedPersonDossierLoader
    ) async -> Int {
        await service.acceptInvocations.count
            + service.rejectInvocations.count
            + service.removeInvocations.count
            + service.resetInvocations.count
    }

    func assertExactInvocation(
        _ command: PersonDossierCorrectionCommand,
        context: PersonDossierNavigationContext
    ) async throws {
        let snapshot = context.values.snapshot
        switch command {
        case .accept:
            let suggestion = try #require(snapshot.suggestions.first)
            #expect(await context.service.acceptInvocations == [.init(
                dossierID: snapshot.dossier.id,
                documentID: suggestion.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: snapshot.token
            )])
        case .reject:
            let suggestion = try #require(snapshot.suggestions.first)
            #expect(await context.service.rejectInvocations == [.init(
                dossierID: snapshot.dossier.id,
                documentID: suggestion.id,
                expectedSupport: suggestion.commandSupport,
                expectedToken: snapshot.token
            )])
        case .remove:
            let member = try #require(snapshot.directMembers.first)
            #expect(await context.service.removeInvocations == [.init(
                dossierID: snapshot.dossier.id,
                documentID: member.id,
                expectedSupport: try member.commandSupport,
                expectedToken: snapshot.token
            )])
        case .reset:
            let correction = try #require(snapshot.corrections.first)
            #expect(await context.service.resetInvocations == [.init(
                dossierID: snapshot.dossier.id,
                documentID: correction.id,
                expectedDecision: correction.decision,
                expectedToken: snapshot.token
            )])
        }
    }

    func staleInput(
        for command: PersonDossierCorrectionCommand,
        snapshot: PersonDossierSnapshot
    ) throws -> PersonDossierCorrectionInput {
        switch command {
        case .accept, .reject:
            let value = try #require(snapshot.suggestions.first)
            return .suggestion(try PersonDossierSuggestion(
                document: value.document,
                sourceDisplayName: "Stale archive",
                documentType: value.documentType,
                section: value.section,
                kind: value.kind,
                conflict: value.conflict,
                currentSupports: value.currentSupports,
                commandSupport: value.commandSupport
            ))
        case .remove:
            let value = try #require(snapshot.directMembers.first)
            return .member(try PersonDossierMember(
                document: value.document,
                sourceDisplayName: "Stale archive",
                documentType: value.documentType,
                section: value.section,
                supports: value.supports,
                isConfirmationAuthoritative: value.isConfirmationAuthoritative,
                preferredPaymentSupport: value.preferredPaymentSupport
            ))
        case .reset:
            let value = try #require(snapshot.corrections.first)
            return .correction(try PersonDossierCorrection(
                document: value.document,
                sourceDisplayName: "Stale archive",
                documentType: value.documentType,
                decision: value.decision
            ))
        }
    }

    func mutationState(
        _ command: PersonDossierCorrectionCommand,
        snapshot: PersonDossierSnapshot
    ) -> DossierMutationState {
        switch command {
        case .accept:
            .acceptingPerson(
                dossierID: snapshot.dossier.id,
                documentID: snapshot.suggestions[0].id
            )
        case .reject:
            .rejectingPerson(
                dossierID: snapshot.dossier.id,
                documentID: snapshot.suggestions[0].id
            )
        case .remove:
            .removingPerson(
                dossierID: snapshot.dossier.id,
                documentID: snapshot.directMembers[0].id
            )
        case .reset:
            .resettingPerson(
                dossierID: snapshot.dossier.id,
                documentID: snapshot.corrections[0].id
            )
        }
    }

    func snapshotWithConfirmationCorrection(
        from snapshot: PersonDossierSnapshot
    ) throws -> PersonDossierSnapshot {
        let previous = try #require(snapshot.corrections.first)
        let revisionID = UUID(uuidString: "74000000-0000-0000-0000-000000000001")!
        let confirmation = try DossierMembershipConfirmation(
            dossierID: snapshot.dossier.id,
            documentID: previous.id,
            revisionID: revisionID,
            confirmedAt: Date(timeIntervalSince1970: 400),
            candidateKind: .secondaryRole,
            acceptedContentHash: previous.document.contentHash,
            acceptedExtractionVersion: "text-v1",
            acceptedDNASchemaVersion: 1,
            acceptedDNAAnalyzerIdentifier: "local-rules",
            acceptedDNAAnalyzerVersion: "1",
            acceptedDNAAnalyzedAt: Date(timeIntervalSince1970: 200),
            acceptedRole: .authorizedPerson,
            acceptedNormalizedName: "elise muster"
        )
        let correction = try PersonDossierCorrection(
            document: previous.document,
            sourceDisplayName: previous.sourceDisplayName,
            documentType: previous.documentType,
            decision: .confirmation(confirmation)
        )
        let token = PersonDossierProjectionToken(
            dossierUpdatedAt: snapshot.token.dossierUpdatedAt,
            anchorUpdatedAt: snapshot.token.anchorUpdatedAt,
            originValidity: snapshot.token.originValidity,
            documents: snapshot.token.documents,
            memberSupports: snapshot.token.memberSupports,
            suggestionSupports: snapshot.token.suggestionSupports,
            confirmationRevisionIDs: [revisionID],
            exclusionRevisionIDs: []
        )
        return PersonDossierSnapshot(
            dossier: snapshot.dossier,
            anchor: snapshot.anchor,
            origin: snapshot.origin,
            directMembers: snapshot.directMembers,
            costsAndPayments: snapshot.costsAndPayments,
            suggestions: snapshot.suggestions,
            corrections: [correction],
            token: token
        )
    }

    @MainActor
    func makeModel(
        _ fixture: PersonDossierAppModelFixture,
        catalog: any CatalogScanning = PersonDossierNoopCatalog(),
        ingestion: any PendingIngesting = PersonDossierNoopIngester(),
        costsLoader: (any DossierLoading)? = nil,
        costsMutator: (any DossierMutating)? = nil,
        people: (any PersonDossierLoading)? = nil,
        peopleMutator: (any PersonDossierMutating)? = nil,
        dnaStatuses: (any DocumentDNAStatusLoading)? = nil,
        dnaSnapshots: (any DocumentDNASnapshotLoading)? = nil,
        invoicePaymentCandidates: (any InvoicePaymentCandidateLoading)? = nil,
        watchScheduler: (any SourceWatchScheduling)? = nil,
        documentLoader: (@Sendable (UUID) async throws -> [DocumentRecord])? = nil,
        reportRuntimeFailure: @escaping @MainActor @Sendable (AppRuntimeDiagnostic) -> Void = { _ in }
    ) -> AppModel {
        if let watchScheduler {
            return AppModel(
                sources: fixture.sources,
                documents: fixture.documents,
                sourceAccess: fixture.sourceAccess,
                catalog: catalog,
                ingestion: ingestion,
                dnaStatuses: dnaStatuses,
                dnaSnapshots: dnaSnapshots,
                invoicePaymentCandidates: invoicePaymentCandidates,
                dossierLoader: costsLoader,
                dossierMutator: costsMutator,
                personDossierLoader: people,
                personDossierMutator: peopleMutator,
                watchScheduler: watchScheduler,
                sourceResolver: { _ in fixture.directory },
                documentLoader: documentLoader,
                reportRuntimeFailure: reportRuntimeFailure
            )
        }
        if let documentLoader {
            return AppModel(
                sources: fixture.sources,
                documents: fixture.documents,
                sourceAccess: fixture.sourceAccess,
                catalog: catalog,
                ingestion: ingestion,
                dnaStatuses: dnaStatuses,
                dnaSnapshots: dnaSnapshots,
                invoicePaymentCandidates: invoicePaymentCandidates,
                dossierLoader: costsLoader,
                dossierMutator: costsMutator,
                personDossierLoader: people,
                personDossierMutator: peopleMutator,
                documentLoader: documentLoader,
                reportRuntimeFailure: reportRuntimeFailure
            )
        }
        return AppModel(
            sources: fixture.sources,
            documents: fixture.documents,
            sourceAccess: fixture.sourceAccess,
            catalog: catalog,
            ingestion: ingestion,
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: invoicePaymentCandidates,
            dossierLoader: costsLoader,
            dossierMutator: costsMutator,
            personDossierLoader: people,
            personDossierMutator: peopleMutator,
            reportRuntimeFailure: reportRuntimeFailure
        )
    }

    @MainActor
    func makeNavigationContext(
        originUnavailable: Bool = false,
        nonReadyDocumentID: UUID? = nil,
        dossierABASnapshot: PersonDossierSnapshot? = nil,
        includeOpenMutation: Bool = false,
        includeCandidates: Bool = false,
        duplicateFirstWins: Bool = false
    ) async throws -> PersonDossierNavigationContext {
        let fixture = try PersonDossierAppModelFixture()
        let originSource = try await fixture.addSource(named: "Archive")
        let otherSource = try await fixture.addSource(named: "Other archive")
        let values = try PersonDossierNavigationValues.make(
            originSourceID: originSource.id,
            otherSourceID: otherSource.id
        )
        var openedSnapshot: PersonDossierSnapshot
        if originUnavailable {
            let token = PersonDossierProjectionToken(
                dossierUpdatedAt: values.snapshot.token.dossierUpdatedAt,
                anchorUpdatedAt: values.snapshot.token.anchorUpdatedAt,
                originValidity: .unavailable,
                documents: values.snapshot.token.documents.filter {
                    $0.documentID != values.origin.id
                },
                memberSupports: values.snapshot.token.memberSupports,
                suggestionSupports: values.snapshot.token.suggestionSupports,
                confirmationRevisionIDs: values.snapshot.token.confirmationRevisionIDs,
                exclusionRevisionIDs: values.snapshot.token.exclusionRevisionIDs
            )
            openedSnapshot = values.replacingSnapshot(
                origin: try PersonDossierOriginState(
                    validity: .unavailable,
                    document: nil,
                    sourceDisplayName: nil
                ),
                token: token
            )
        } else {
            openedSnapshot = values.snapshot
        }
        let mutatedSnapshot = try PersonDossierAppModelValues.make(
            dossierID: values.snapshot.dossier.id,
            sourceID: originSource.id,
            documentID: values.invoice.id
        ).snapshot
        let originSourceDocuments = [
            values.origin,
            values.direct,
            values.invoice,
            values.correction,
        ]
        var otherSourceDocuments = [
            values.crossSourceDirect,
            values.payment,
            values.suggestion,
        ]
        if duplicateFirstWins {
            let duplicate = try values.duplicateFirstWinsSnapshot(
                laterSourceID: otherSource.id
            )
            openedSnapshot = duplicate.snapshot
            otherSourceDocuments.append(duplicate.laterDocument)
        }
        let documents = ScriptedPersonDossierDocumentLoader(documentsBySource: [
            originSource.id: originSourceDocuments,
            otherSource.id: otherSourceDocuments,
        ])
        let allDocuments = originSourceDocuments + otherSourceDocuments
        let statusesBySource = Dictionary(grouping: allDocuments, by: \.sourceRootID)
            .mapValues { records in
                records.map {
                    DocumentDNAAnalysisStatus(
                        documentID: $0.id,
                        phase: $0.id == nonReadyDocumentID ? .pending : .ready
                    )
                }
            }
        let dnaSnapshots = ScriptedPersonDossierDNALoader(
            snapshotsByDocument: values.dnaByDocument.mapValues {
                Array(repeating: $0, count: 8)
            }
        )
        let candidateLoader: PersonDossierCandidateLoader? = includeCandidates
            ? PersonDossierCandidateLoader(candidatesByDocument: [
                values.invoice.id: [values.candidate],
                values.payment.id: [values.candidate],
            ])
            : nil
        var snapshotSteps: [ScriptedPersonDossierLoader.SnapshotStep] = [
            .result(openedSnapshot),
        ]
        if let dossierABASnapshot {
            snapshotSteps += [.result(dossierABASnapshot), .result(openedSnapshot)]
        }
        let summaries = [personSummary(openedSnapshot)]
            + (dossierABASnapshot.map { [personSummary($0)] } ?? [])
        let people = ScriptedPersonDossierLoader(
            summarySteps: includeOpenMutation
                ? [.result(summaries), .result([personSummary(mutatedSnapshot)])]
                : [.result(summaries)],
            snapshotSteps: snapshotSteps,
            openSteps: includeOpenMutation ? [.result(.opened(mutatedSnapshot))] : []
        )
        let dossierLoader = ScriptedPersonDossierCostsLoader()
        let model = makeModel(
            fixture,
            costsLoader: dossierLoader,
            people: people,
            peopleMutator: people,
            dnaStatuses: PersonDossierDNAStatusLoader(statusesBySource: statusesBySource),
            dnaSnapshots: dnaSnapshots,
            invoicePaymentCandidates: candidateLoader,
            documentLoader: { sourceID in
                try await documents.load(sourceID: sourceID)
            }
        )
        try await model.reload()
        await model.selectDossier(id: openedSnapshot.dossier.id)
        return PersonDossierNavigationContext(
            fixture: fixture,
            originSource: originSource,
            otherSource: otherSource,
            originSourceDocuments: originSourceDocuments,
            otherSourceDocuments: otherSourceDocuments,
            values: values,
            openedSnapshot: openedSnapshot,
            mutatedSnapshot: mutatedSnapshot,
            documents: documents,
            service: people,
            costsService: dossierLoader,
            model: model
        )
    }

    @MainActor
    func assertFailedNavigationPreserved(
        _ context: PersonDossierNavigationContext,
        previous: PersonDossierDocumentPresentation
    ) {
        #expect(personDocumentPresentation(of: context.model) == previous)
        #expect(context.model.lastErrorCode == "documentLoadFailure")
    }

    @MainActor
    func preselectPersonInvoice(
        in context: PersonDossierNavigationContext
    ) async -> PersonDossierDocumentPresentation {
        await context.model.selectPersonDossierDocument(documentID: context.values.invoice.id)
        #expect(context.model.dossierEntryState == .available(
            documentID: context.values.invoice.id,
            disposition: .create
        ))
        return personDocumentPresentation(of: context.model)
    }

    @MainActor
    func personDocumentPresentation(
        of model: AppModel
    ) -> PersonDossierDocumentPresentation {
        PersonDossierDocumentPresentation(
            selectedSourceID: model.selectedSourceID,
            selectedDocumentID: model.selectedDocumentID,
            documents: model.documents,
            documentDNAAnalysisPhases: model.documentDNAAnalysisPhases,
            documentDNADetailState: model.documentDNADetailState,
            invoicePaymentCandidateState: model.invoicePaymentCandidateState,
            dossierEntryState: model.dossierEntryState,
            workspaceSelection: model.workspaceSelection,
            dossierDetailState: model.dossierDetailState
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

private struct PersonDossierNavigationContext {
    let fixture: PersonDossierAppModelFixture
    let originSource: SourceRootRecord
    let otherSource: SourceRootRecord
    let originSourceDocuments: [DocumentRecord]
    let otherSourceDocuments: [DocumentRecord]
    let values: PersonDossierNavigationValues
    let openedSnapshot: PersonDossierSnapshot
    let mutatedSnapshot: PersonDossierSnapshot
    let documents: ScriptedPersonDossierDocumentLoader
    let service: ScriptedPersonDossierLoader
    let costsService: ScriptedPersonDossierCostsLoader
    let model: AppModel
}

private struct PersonDossierLifecycleContext {
    let fixture: PersonDossierAppModelFixture
    let originSource: SourceRootRecord
    let otherSource: SourceRootRecord
    let originDocuments: [DocumentRecord]
    let otherDocuments: [DocumentRecord]
    let values: PersonDossierNavigationValues
    let otherSnapshot: PersonDossierSnapshot
    let mutatedSnapshot: PersonDossierSnapshot
    let costSnapshot: DossierSnapshot
    let people: ScriptedPersonDossierLoader
    let costs: ScriptedPersonDossierCostsLoader
    let documents: ScriptedPersonDossierDocumentLoader
    let scheduler: PersonDossierWatchScheduler
    let model: AppModel
}

private struct PersonDossierLifecyclePresentation: Equatable {
    let sources: [SourceRootRecord]
    let dossiers: [DossierSummary]
    let personDossiers: [PersonDossierSummary]
    let selectedSourceID: UUID?
    let documents: [DocumentRecord]
    let phases: [UUID: DocumentDNAAnalysisPhase]
    let unavailableSourceIDs: Set<UUID>
    let selectedDocumentID: UUID?
    let documentDetail: DocumentDNADetailState
    let invoiceCandidates: InvoicePaymentCandidateDetailState
    let updatingCandidate: InvoicePaymentCandidate?
    let navigatingCandidate: InvoicePaymentCandidate?
    let isDecisionUpdateInFlight: Bool
    let retryingDocumentID: UUID?
    let scanState: AppScanState
    let workspace: AppWorkspaceSelection?
    let detail: DossierDetailState
    let entry: DossierEntryState
    let dossierChoices: [DossierSummary]
    let personDossierChoices: [PersonDossierSummary]
    let mutationState: DossierMutationState
    let errorCode: String?

    func replacing(
        detail: DossierDetailState? = nil,
        errorCode: String?? = nil
    ) -> Self {
        Self(
            sources: sources,
            dossiers: dossiers,
            personDossiers: personDossiers,
            selectedSourceID: selectedSourceID,
            documents: documents,
            phases: phases,
            unavailableSourceIDs: unavailableSourceIDs,
            selectedDocumentID: selectedDocumentID,
            documentDetail: documentDetail,
            invoiceCandidates: invoiceCandidates,
            updatingCandidate: updatingCandidate,
            navigatingCandidate: navigatingCandidate,
            isDecisionUpdateInFlight: isDecisionUpdateInFlight,
            retryingDocumentID: retryingDocumentID,
            scanState: scanState,
            workspace: workspace,
            detail: detail ?? self.detail,
            entry: entry,
            dossierChoices: dossierChoices,
            personDossierChoices: personDossierChoices,
            mutationState: mutationState,
            errorCode: errorCode ?? self.errorCode
        )
    }
}

private struct PersonDossierDocumentPresentation: Equatable {
    let selectedSourceID: UUID?
    let selectedDocumentID: UUID?
    let documents: [DocumentRecord]
    let documentDNAAnalysisPhases: [UUID: DocumentDNAAnalysisPhase]
    let documentDNADetailState: DocumentDNADetailState
    let invoicePaymentCandidateState: InvoicePaymentCandidateDetailState
    let dossierEntryState: DossierEntryState
    let workspaceSelection: AppWorkspaceSelection?
    let dossierDetailState: DossierDetailState
}

enum PersonDossierCorrectionCommand: CaseIterable, Sendable {
    case accept
    case reject
    case remove
    case reset

    var next: Self {
        switch self {
        case .accept: .reject
        case .reject: .remove
        case .remove: .reset
        case .reset: .accept
        }
    }
}

enum PersonDossierCorrectionSelectionRace: CaseIterable, Sendable {
    case source
    case document
    case dossier
    case dossierABA
}

enum PersonDossierRefreshPortOutcome: CaseIterable, Sendable {
    case returnWrongDossier
    case failure
}

enum PersonDossierLateCorrectionOutcome: CaseIterable, Sendable {
    case success
    case failure
}

enum PersonDossierLateRefreshOutcome: CaseIterable, Sendable {
    case success
    case failure
}

enum PersonDossierCorrectionInput: Sendable {
    case suggestion(PersonDossierSuggestion)
    case member(PersonDossierMember)
    case correction(PersonDossierCorrection)
}

enum PersonDossierNavigationRow: Sendable {
    case suggestion
    case correction
}

enum PersonDossierRaceScenario: CaseIterable, Sendable {
    case source
    case document
    case dnaGeneration
    case dossier
    case documentABA
}

enum PersonDossierRefreshRace: CaseIterable, Sendable {
    case sourceSelection
    case documentSelection
    case personMutation
    case dossierABA
}

enum PersonDossierWatcherSource: Sendable {
    case selected
    case other
}

enum PersonDossierLifecycleSelectedSource: Sendable {
    case origin
    case other
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
