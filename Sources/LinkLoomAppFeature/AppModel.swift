import Combine
import Foundation
import LinkLoomCore

public enum AppScanState: Sendable, Equatable {
    case idle
    case scanning
    case extracting
}

public protocol CatalogScanning: Sendable {
    func scan(source: SourceRootRecord) async throws
}

public protocol PendingIngesting: Sendable {
    func processPending(source: SourceRootRecord) async throws
}

public protocol DocumentDNAStatusLoading: Sendable {
    func currentAnalysisStatuses(sourceRootID: UUID) async throws -> [DocumentDNAAnalysisStatus]
}

public protocol DocumentDNASnapshotLoading: Sendable {
    func currentSnapshot(documentID: UUID) async throws -> DocumentDNA?
}

public protocol DocumentDNAFailureRetrying: Sendable {
    func retryFailedAnalysis(documentID: UUID, sourceRootID: UUID) async throws
}

public protocol InvoicePaymentCandidateLoading: Sendable {
    func candidates(involving documentID: UUID) async throws
        -> [InvoicePaymentCandidateWithDecision]
}

public enum InvoicePaymentDecisionCommand: Sendable, Equatable {
    case set(InvoicePaymentUserDecision)
    case reset
}

public protocol InvoicePaymentDecisionUpdating: Sendable {
    func update(
        candidate: InvoicePaymentCandidate,
        command: InvoicePaymentDecisionCommand
    ) async throws
}

public enum DocumentDNADetailState: Sendable, Equatable {
    case none
    case loading(documentID: UUID)
    case available(DocumentDNA)
    case unavailable(documentID: UUID)
    case failed(documentID: UUID)
}

public enum InvoicePaymentCandidateDetailState: Sendable, Equatable {
    case none
    case loading(documentID: UUID)
    case available(
        documentID: UUID,
        candidates: [InvoicePaymentCandidateWithDecision]
    )
    case failed(documentID: UUID)
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var sources: [SourceRootRecord] = []
    @Published public var selectedSourceID: UUID?
    @Published public private(set) var documents: [DocumentRecord] = []
    @Published public private(set) var documentDNAAnalysisPhases: [
        UUID: DocumentDNAAnalysisPhase
    ] = [:]
    @Published public private(set) var selectedDocumentID: UUID?
    @Published public private(set) var documentDNADetailState: DocumentDNADetailState = .none
    @Published public private(set) var invoicePaymentCandidateState:
        InvoicePaymentCandidateDetailState = .none
    @Published public private(set) var invoicePaymentDecisionUpdatingCandidate:
        InvoicePaymentCandidate?
    @Published public private(set) var invoicePaymentCounterpartNavigatingCandidate:
        InvoicePaymentCandidate?
    @Published public private(set) var isInvoicePaymentDecisionUpdateInFlight = false
    @Published public private(set) var documentDNARetryingDocumentID: UUID?
    @Published public private(set) var scanState: AppScanState = .idle
    @Published public private(set) var lastErrorCode: String?
    @Published public private(set) var unavailableSourceIDs = Set<UUID>()
    @Published public private(set) var workspaceSelection: AppWorkspaceSelection?
    @Published public private(set) var dossiers: [DossierSummary] = []
    @Published public private(set) var dossierEntryState: DossierEntryState = .none
    @Published public private(set) var dossierDetailState: DossierDetailState = .none
    @Published public private(set) var dossierChoices: [DossierSummary] = []
    @Published public private(set) var dossierMutationState: DossierMutationState = .idle

    public var lastErrorMessage: String? {
        switch lastErrorCode {
        case "sourceAddFailure":
            "Die Quelle konnte nicht hinzugefügt werden. Bitte prüfe den Zugriff und versuche es erneut."
        case "scanFailure":
            "Die Analyse konnte nicht abgeschlossen werden. Bitte prüfe die Quelle und versuche es erneut."
        case "sourceRemoveFailure":
            "Die Quelle konnte nicht entfernt werden. Bitte versuche es erneut."
        case "documentLoadFailure":
            "Die Dokumente konnten nicht geladen werden. Bitte versuche es erneut."
        case "documentDNADetailLoadFailure":
            "Document DNA konnte nicht geladen werden. Bitte versuche es erneut."
        case "documentDNARetryFailure":
            "Document DNA konnte nicht erneut analysiert werden. Bitte versuche es erneut."
        case "invoicePaymentCandidateLoadFailure":
            "Verknüpfungskandidaten konnten nicht geladen werden. Bitte versuche es erneut."
        case "invoicePaymentDecisionUpdateFailure":
            "Die Entscheidung konnte nicht gespeichert werden. Bitte versuche es erneut."
        case "invoicePaymentCounterpartNavigationFailure":
            "Das Gegenstück konnte nicht angezeigt werden. Bitte lade die Kandidaten neu."
        case "incrementalRefreshFailure":
            "Die Ansicht konnte nach der Analyse nicht aktualisiert werden. Bitte versuche es erneut."
        case "dossierEntryLoadFailure", "dossierOpenFailure", "dossierLoadFailure":
            "Das Dossier konnte nicht geladen werden. Bitte versuche es erneut."
        case "dossierMutationFailure":
            "Die Dossier-Korrektur konnte nicht gespeichert werden. Bitte versuche es erneut."
        case "dossierRemoved":
            "Das Dossier ist nicht mehr verfügbar, weil sein Anker entfernt wurde."
        case .some:
            "Der Vorgang konnte nicht abgeschlossen werden. Bitte versuche es erneut."
        case nil:
            nil
        }
    }

    private let sourceRepository: SourceRootRepository
    private let sourceAccess: any SourceAccessing
    private let catalog: any CatalogScanning
    private let ingestion: any PendingIngesting
    private let dnaStatuses: (any DocumentDNAStatusLoading)?
    private let dnaSnapshots: (any DocumentDNASnapshotLoading)?
    private let dnaRetryer: (any DocumentDNAFailureRetrying)?
    private let invoicePaymentCandidates: (any InvoicePaymentCandidateLoading)?
    private let invoicePaymentDecisions: (any InvoicePaymentDecisionUpdating)?
    private let dossierLoader: (any DossierLoading)?
    private let dossierMutator: (any DossierMutating)?
    private let sourceLoader: @Sendable () async throws -> [SourceRootRecord]
    private let documentLoader: @Sendable (UUID) async throws -> [DocumentRecord]
    private let watchScheduler: (any SourceWatchScheduling)?
    private let sourceResolver: @Sendable (SourceRootRecord) throws -> URL
    private let reportRuntimeFailure: @MainActor @Sendable (AppRuntimeDiagnostic) -> Void
    private var isExclusiveSourceOperationActive = false
    private var activeReloadCount = 0
    private var watchedSourceIDs = Set<UUID>()
    private var watchChangesTask: Task<Void, Never>?
    private var rescanCompletionsTask: Task<Void, Never>?
    private var rescanDrainTask: Task<Void, Never>?
    private var incrementalRefreshGeneration = 0
    private var pendingRescanSourceIDs = Set<UUID>()
    private var isProcessingRescanCompletions = false
    private var watchLifecycleGeneration = 0
    private var documentDNADetailGeneration = 0
    private var invoicePaymentDecisionUpdateGeneration = 0
    private var invoicePaymentCounterpartNavigationGeneration = 0
    private var dossierLoadGeneration = 0
    private var dossierMutationGeneration = 0
    private var workspaceSelectionGeneration = 0

    public init(
        sources: SourceRootRepository,
        documents: DocumentRepository,
        sourceAccess: any SourceAccessing,
        catalog: any CatalogScanning,
        ingestion: any PendingIngesting,
        dnaStatuses: (any DocumentDNAStatusLoading)? = nil,
        dnaSnapshots: (any DocumentDNASnapshotLoading)? = nil,
        dnaRetryer: (any DocumentDNAFailureRetrying)? = nil,
        invoicePaymentCandidates: (any InvoicePaymentCandidateLoading)? = nil,
        invoicePaymentDecisions: (any InvoicePaymentDecisionUpdating)? = nil,
        dossierLoader: (any DossierLoading)? = nil,
        dossierMutator: (any DossierMutating)? = nil,
        watchScheduler: (any SourceWatchScheduling)? = nil,
        reportRuntimeFailure: @escaping @MainActor @Sendable (AppRuntimeDiagnostic) -> Void = { _ in }
    ) {
        sourceRepository = sources
        self.sourceAccess = sourceAccess
        self.catalog = catalog
        self.ingestion = ingestion
        self.dnaStatuses = dnaStatuses
        self.dnaSnapshots = dnaSnapshots
        self.dnaRetryer = dnaRetryer
        self.invoicePaymentCandidates = invoicePaymentCandidates
        self.invoicePaymentDecisions = invoicePaymentDecisions
        self.dossierLoader = dossierLoader
        self.dossierMutator = dossierMutator
        sourceLoader = { try await sources.all() }
        self.watchScheduler = watchScheduler
        self.reportRuntimeFailure = reportRuntimeFailure
        sourceResolver = { source in
            try sourceAccess.resolve(source.bookmarkData).url
        }
        documentLoader = { sourceID in
            try await documents.all(sourceRootID: sourceID)
        }
    }

    init(
        sources: SourceRootRepository,
        documents: DocumentRepository,
        sourceAccess: any SourceAccessing,
        catalog: any CatalogScanning,
        ingestion: any PendingIngesting,
        dnaStatuses: (any DocumentDNAStatusLoading)? = nil,
        dnaSnapshots: (any DocumentDNASnapshotLoading)? = nil,
        dnaRetryer: (any DocumentDNAFailureRetrying)? = nil,
        invoicePaymentCandidates: (any InvoicePaymentCandidateLoading)? = nil,
        invoicePaymentDecisions: (any InvoicePaymentDecisionUpdating)? = nil,
        dossierLoader: (any DossierLoading)? = nil,
        dossierMutator: (any DossierMutating)? = nil,
        documentLoader: @escaping @Sendable (UUID) async throws -> [DocumentRecord],
        reportRuntimeFailure: @escaping @MainActor @Sendable (AppRuntimeDiagnostic) -> Void = { _ in }
    ) {
        sourceRepository = sources
        self.sourceAccess = sourceAccess
        self.catalog = catalog
        self.ingestion = ingestion
        self.dnaStatuses = dnaStatuses
        self.dnaSnapshots = dnaSnapshots
        self.dnaRetryer = dnaRetryer
        self.invoicePaymentCandidates = invoicePaymentCandidates
        self.invoicePaymentDecisions = invoicePaymentDecisions
        self.dossierLoader = dossierLoader
        self.dossierMutator = dossierMutator
        sourceLoader = { try await sources.all() }
        self.documentLoader = documentLoader
        watchScheduler = nil
        self.reportRuntimeFailure = reportRuntimeFailure
        sourceResolver = { source in URL(fileURLWithPath: source.pathHint) }
    }

    init(
        sources: SourceRootRepository,
        documents: DocumentRepository,
        sourceAccess: any SourceAccessing,
        catalog: any CatalogScanning,
        ingestion: any PendingIngesting,
        dnaStatuses: (any DocumentDNAStatusLoading)? = nil,
        dnaSnapshots: (any DocumentDNASnapshotLoading)? = nil,
        dnaRetryer: (any DocumentDNAFailureRetrying)? = nil,
        invoicePaymentCandidates: (any InvoicePaymentCandidateLoading)? = nil,
        invoicePaymentDecisions: (any InvoicePaymentDecisionUpdating)? = nil,
        dossierLoader: (any DossierLoading)? = nil,
        dossierMutator: (any DossierMutating)? = nil,
        watchScheduler: any SourceWatchScheduling,
        sourceResolver: @escaping @Sendable (SourceRootRecord) throws -> URL,
        sourceLoader: (@Sendable () async throws -> [SourceRootRecord])? = nil,
        documentLoader: (@Sendable (UUID) async throws -> [DocumentRecord])? = nil,
        reportRuntimeFailure: @escaping @MainActor @Sendable (AppRuntimeDiagnostic) -> Void = { _ in }
    ) {
        sourceRepository = sources
        self.sourceAccess = sourceAccess
        self.catalog = catalog
        self.ingestion = ingestion
        self.dnaStatuses = dnaStatuses
        self.dnaSnapshots = dnaSnapshots
        self.dnaRetryer = dnaRetryer
        self.invoicePaymentCandidates = invoicePaymentCandidates
        self.invoicePaymentDecisions = invoicePaymentDecisions
        self.dossierLoader = dossierLoader
        self.dossierMutator = dossierMutator
        self.sourceLoader = sourceLoader ?? { try await sources.all() }
        self.documentLoader = documentLoader ?? { sourceID in
            try await documents.all(sourceRootID: sourceID)
        }
        self.watchScheduler = watchScheduler
        self.sourceResolver = sourceResolver
        self.reportRuntimeFailure = reportRuntimeFailure
    }

    public func reload() async throws {
        activeReloadCount += 1
        invalidateDossierLoad()
        invalidateDossierMutation()
        invalidateIncrementalRefreshes()
        let generation = incrementalRefreshGeneration
        do {
            let loadedSources = try await sourceRepository.all()
            let targetSourceID = loadedSources.contains(where: { $0.id == selectedSourceID })
                ? selectedSourceID
                : loadedSources.first?.id
            let loadedDossiers = try await dossierLoader?.summaries() ?? []
            let presentation = try await loadDocumentPresentation(sourceID: targetSourceID)
            guard !Task.isCancelled,
                  generation == incrementalRefreshGeneration
            else {
                await finishReload()
                return
            }
            sources = loadedSources
            dossiers = loadedDossiers
            publishSelection(targetSourceID, presentation: presentation)
            await startWatchingSavedSources()
            await finishReload()
        } catch {
            await finishReload()
            guard error is CancellationError
                    || generation == incrementalRefreshGeneration
            else {
                return
            }
            reportRuntimeFailure(AppRuntimeDiagnostic(category: .reload, error: error))
            throw error
        }
    }

    public func addSource(_ url: URL) async {
        guard beginExclusiveSourceOperation() else { return }
        defer { endExclusiveSourceOperation() }
        invalidateIncrementalRefreshes()
        var sourceWasPersisted = false
        do {
            let source = try await sourceRepository.add(
                url: url,
                sourceAccess: sourceAccess
            )
            sourceWasPersisted = true
            sources = try await sourceRepository.all()
            await startWatching(source)
            let presentation = try await loadDocumentPresentation(sourceID: source.id)
            guard !Task.isCancelled else { return }
            publishSelection(source.id, presentation: presentation)
            lastErrorCode = nil
        } catch {
            publishRuntimeFailure(
                code: sourceWasPersisted ? "documentLoadFailure" : "sourceAddFailure",
                category: sourceWasPersisted ? .documentLoad : .sourceAdd,
                error: error
            )
        }
    }

    public func scanSelectedSource() async {
        guard beginExclusiveSourceOperation() else { return }
        defer { endExclusiveSourceOperation() }
        guard let source = sources.first(where: { $0.id == selectedSourceID }) else {
            return
        }
        let workspaceAtStart = workspaceSelection
        invalidateIncrementalRefreshes()
        lastErrorCode = nil
        scanState = .scanning
        defer { scanState = .idle }
        var failureCategory = AppRuntimeFailureCategory.scan
        do {
            try await catalog.scan(source: source)
            scanState = .extracting
            failureCategory = .ingestion
            try await ingestion.processPending(source: source)
            failureCategory = .refresh
            sources = try await sourceRepository.all()
            _ = try await reloadDocuments()
            if case .dossier(let dossierID) = workspaceAtStart,
               workspaceSelection == .dossier(dossierID) {
                await refreshDossier(id: dossierID)
            }
        } catch {
            publishRuntimeFailure(
                code: "scanFailure",
                category: failureCategory,
                error: error
            )
        }
    }

    public func removeSource(_ source: SourceRootRecord) async {
        guard beginExclusiveSourceOperation() else { return }
        defer { endExclusiveSourceOperation() }
        let workspaceAtStart = workspaceSelection
        invalidateIncrementalRefreshes()
        var sourceWasRemoved = false
        do {
            try await sourceRepository.remove(id: source.id)
            sourceWasRemoved = true
            await watchScheduler?.stop(sourceID: source.id)
            watchedSourceIDs.remove(source.id)
            unavailableSourceIDs.remove(source.id)
            let refreshedSources = try await sourceRepository.all()
            let refreshedDossiers = try await dossierLoader?.summaries() ?? []
            let removedSelection = selectedSourceID == source.id
            let targetSourceID = removedSelection
                ? refreshedSources.first?.id
                : selectedSourceID
            if case .dossier(let dossierID) = workspaceAtStart,
               workspaceSelection == .dossier(dossierID) {
                let presentation = try await loadDocumentPresentation(
                    sourceID: targetSourceID
                )
                guard !Task.isCancelled,
                      workspaceSelection == .dossier(dossierID)
                else {
                    return
                }
                sources = refreshedSources
                dossiers = refreshedDossiers
                selectedSourceID = targetSourceID
                publish(presentation)
                lastErrorCode = nil
                await refreshDossier(id: dossierID)
                return
            }
            sources = refreshedSources
            dossiers = refreshedDossiers
            if removedSelection {
                publishSelection(
                    nil,
                    presentation: DocumentPresentation(documents: [], dnaAnalysisPhases: [:])
                )
            }
            let presentation = try await loadDocumentPresentation(sourceID: targetSourceID)
            guard !Task.isCancelled else { return }
            publishSelection(targetSourceID, presentation: presentation)
            lastErrorCode = nil
        } catch {
            publishRuntimeFailure(
                code: sourceWasRemoved ? "documentLoadFailure" : "sourceRemoveFailure",
                category: sourceWasRemoved ? .documentLoad : .sourceRemove,
                error: error
            )
        }
    }

    public func selectSource(id: UUID?) async {
        guard !isExclusiveSourceOperationActive else { return }
        invalidateDossierLoad()
        invalidateDossierMutation()
        invalidateIncrementalRefreshes()
        let generation = incrementalRefreshGeneration
        do {
            let presentation = try await loadDocumentPresentation(sourceID: id)
            guard !Task.isCancelled,
                  generation == incrementalRefreshGeneration
            else {
                return
            }
            publishSelection(id, presentation: presentation)
            lastErrorCode = nil
        } catch {
            guard generation == incrementalRefreshGeneration else { return }
            publishRuntimeFailure(
                code: "documentLoadFailure",
                category: .documentLoad,
                error: error
            )
        }
    }

    public func selectDocument(id: UUID?) async {
        documentDNADetailGeneration += 1
        invalidateDossierLoad()
        invalidateDossierMutation()
        invalidateInvoicePaymentDecisionUpdate()
        invalidateInvoicePaymentCounterpartNavigation()
        let generation = documentDNADetailGeneration
        invoicePaymentCandidateState = .none
        dossierEntryState = .none
        dossierChoices = []
        clearDocumentScopedFailure()
        guard let id else {
            selectedDocumentID = nil
            documentDNADetailState = .none
            return
        }
        guard documents.contains(where: { $0.id == id }) else {
            selectedDocumentID = nil
            documentDNADetailState = .none
            return
        }
        selectedDocumentID = id
        guard documentDNAAnalysisPhases[id] == .ready,
              let dnaSnapshots
        else {
            documentDNADetailState = .unavailable(documentID: id)
            return
        }
        documentDNADetailState = .loading(documentID: id)
        do {
            let snapshot = try await dnaSnapshots.currentSnapshot(documentID: id)
            guard generation == documentDNADetailGeneration,
                  selectedDocumentID == id
            else {
                return
            }
            guard !Task.isCancelled else {
                documentDNADetailState = .unavailable(documentID: id)
                return
            }
            guard let snapshot,
                  snapshot.documentID == id
            else {
                documentDNADetailState = .unavailable(documentID: id)
                return
            }
            documentDNADetailState = .available(snapshot)
            if lastErrorCode == "documentDNADetailLoadFailure" {
                lastErrorCode = nil
            }
            await loadInvoicePaymentCandidates(
                involving: id,
                generation: generation
            )
            await loadDossierEntryDisposition(
                documentID: id,
                snapshot: snapshot,
                generation: generation
            )
        } catch is CancellationError {
            guard generation == documentDNADetailGeneration,
                  selectedDocumentID == id
            else {
                return
            }
            documentDNADetailState = .unavailable(documentID: id)
        } catch {
            guard generation == documentDNADetailGeneration,
                  selectedDocumentID == id
            else {
                return
            }
            guard !Task.isCancelled else {
                documentDNADetailState = .unavailable(documentID: id)
                return
            }
            documentDNADetailState = .failed(documentID: id)
            publishRuntimeFailure(
                code: "documentDNADetailLoadFailure",
                category: .documentDNADetailLoad,
                error: error
            )
        }
    }

    public func openOrCreateDossierForSelectedDocument() async {
        guard !isExclusiveSourceOperationActive,
              case .idle = dossierMutationState,
              let dossierMutator,
              let dossierLoader,
              let documentID = selectedDocumentID,
              case .available(let entryDocumentID, _) = dossierEntryState,
              entryDocumentID == documentID
        else {
            return
        }
        dossierMutationGeneration &+= 1
        let mutationGeneration = dossierMutationGeneration
        let selectionGeneration = documentDNADetailGeneration
        let workspace = workspaceSelection
        invalidateDossierLoad()
        dossierMutationState = .opening(documentID: documentID)
        dossierChoices = []
        defer {
            if mutationGeneration == dossierMutationGeneration {
                dossierMutationState = .idle
            }
        }

        do {
            let result = try await dossierMutator.createOrOpen(
                anchorDocumentID: documentID
            )
            guard !Task.isCancelled,
                  mutationGeneration == dossierMutationGeneration,
                  selectionGeneration == documentDNADetailGeneration,
                  selectedDocumentID == documentID,
                  workspaceSelection == workspace
            else {
                return
            }
            switch result {
            case .opened(let snapshot):
                let refreshedSummaries = try await dossierLoader.summaries()
                guard !Task.isCancelled,
                      mutationGeneration == dossierMutationGeneration,
                      selectionGeneration == documentDNADetailGeneration,
                      selectedDocumentID == documentID,
                      workspaceSelection == workspace
                else {
                    return
                }
                publishDossier(snapshot, summaries: refreshedSummaries)
            case .choose(let choices):
                dossierChoices = choices
                if lastErrorCode == "dossierOpenFailure" {
                    lastErrorCode = nil
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  mutationGeneration == dossierMutationGeneration,
                  selectionGeneration == documentDNADetailGeneration,
                  selectedDocumentID == documentID,
                  workspaceSelection == workspace
            else {
                return
            }
            publishRuntimeFailure(
                code: "dossierOpenFailure",
                category: .dossierMutation,
                error: error
            )
        }
    }

    public func chooseDossier(id: UUID) async {
        guard let summary = dossierChoices.first(where: { $0.id == id }) else { return }
        await loadDossier(id: id, selectedSummary: summary)
    }

    public func selectDossier(id: UUID) async {
        await loadDossier(id: id, selectedSummary: nil)
    }

    private func loadDossier(
        id: UUID,
        selectedSummary: DossierSummary?
    ) async {
        guard !isExclusiveSourceOperationActive,
              let dossierLoader
        else {
            return
        }
        invalidateIncrementalRefreshes()
        invalidateDossierMutation()
        invalidateDossierLoad()
        let generation = dossierLoadGeneration
        let previous = dossierDetailState.snapshot
        dossierDetailState = .loading(dossierID: id, previous: previous)
        do {
            let snapshot = try await dossierLoader.snapshot(id: id)
            guard generation == dossierLoadGeneration,
                  case .loading(let loadingID, _) = dossierDetailState,
                  loadingID == id
            else {
                return
            }
            guard !Task.isCancelled else {
                dossierDetailState = previous.map(DossierDetailState.available) ?? .none
                return
            }
            guard snapshot.dossier.id == id else {
                throw DossierRepositoryError.invalidStoredState
            }
            if let selectedSummary {
                var updated = dossiers.filter { $0.id != selectedSummary.id }
                updated.append(selectedSummary)
                updated.sort {
                    if $0.dossier.createdAt != $1.dossier.createdAt {
                        return $0.dossier.createdAt < $1.dossier.createdAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
                dossiers = updated
            }
            publishDossier(snapshot)
        } catch is CancellationError {
            guard generation == dossierLoadGeneration,
                  case .loading(let loadingID, _) = dossierDetailState,
                  loadingID == id
            else {
                return
            }
            dossierDetailState = previous.map(DossierDetailState.available) ?? .none
        } catch {
            guard generation == dossierLoadGeneration,
                  case .loading(let loadingID, _) = dossierDetailState,
                  loadingID == id
            else {
                return
            }
            guard !Task.isCancelled else {
                dossierDetailState = previous.map(DossierDetailState.available) ?? .none
                return
            }
            dossierDetailState = .failed(dossierID: id, previous: previous)
            publishRuntimeFailure(
                code: "dossierLoadFailure",
                category: .dossierLoad,
                error: error
            )
        }
    }

    private func refreshDossier(id: UUID) async {
        guard let dossierLoader,
              workspaceSelection == .dossier(id)
        else {
            return
        }
        dossierLoadGeneration &+= 1
        let generation = dossierLoadGeneration
        let previous = dossierDetailState.snapshot
        dossierDetailState = .loading(dossierID: id, previous: previous)
        do {
            let snapshot = try await dossierLoader.snapshot(id: id)
            guard generation == dossierLoadGeneration,
                  workspaceSelection == .dossier(id),
                  case .loading(let loadingID, _) = dossierDetailState,
                  loadingID == id
            else {
                return
            }
            guard !Task.isCancelled else {
                dossierDetailState = previous.map(DossierDetailState.available) ?? .none
                return
            }
            guard snapshot.dossier.id == id else {
                throw DossierRepositoryError.invalidStoredState
            }
            publishDossier(snapshot, preservingTransientState: true)
        } catch is CancellationError {
            guard generation == dossierLoadGeneration,
                  workspaceSelection == .dossier(id),
                  case .loading(let loadingID, _) = dossierDetailState,
                  loadingID == id
            else {
                return
            }
            dossierDetailState = previous.map(DossierDetailState.available) ?? .none
        } catch DossierRepositoryError.dossierNotFound {
            guard !Task.isCancelled else {
                restoreDossierDetailIfCurrent(
                    dossierID: id,
                    generation: generation,
                    previous: previous
                )
                return
            }
            do {
                try await publishRemovedDossierFallback(
                    dossierID: id,
                    generation: generation,
                    previous: previous
                )
            } catch is CancellationError {
                restoreDossierDetailIfCurrent(
                    dossierID: id,
                    generation: generation,
                    previous: previous
                )
                return
            } catch {
                guard generation == dossierLoadGeneration,
                      workspaceSelection == .dossier(id),
                      case .loading(let loadingID, let loadingPrevious) = dossierDetailState,
                      loadingID == id,
                      loadingPrevious == previous
                else {
                    return
                }
                guard !Task.isCancelled else {
                    dossierDetailState = previous.map(DossierDetailState.available) ?? .none
                    return
                }
                dossierDetailState = .failed(dossierID: id, previous: previous)
                publishRuntimeFailure(
                    code: "dossierLoadFailure",
                    category: .dossierLoad,
                    error: error
                )
            }
        } catch {
            guard generation == dossierLoadGeneration,
                  workspaceSelection == .dossier(id),
                  case .loading(let loadingID, _) = dossierDetailState,
                  loadingID == id
            else {
                return
            }
            guard !Task.isCancelled else {
                dossierDetailState = previous.map(DossierDetailState.available) ?? .none
                return
            }
            dossierDetailState = .failed(dossierID: id, previous: previous)
            publishRuntimeFailure(
                code: "dossierLoadFailure",
                category: .dossierLoad,
                error: error
            )
        }
    }

    private func publishRemovedDossierFallback(
        dossierID: UUID,
        generation: Int,
        previous: DossierSnapshot?
    ) async throws {
        guard let dossierLoader else { return }
        let refreshedSources = try await sourceLoader()
        let refreshedDossiers = try await dossierLoader.summaries()
        let targetSourceID = refreshedSources.first?.id
        let presentation = try await loadDocumentPresentation(sourceID: targetSourceID)
        guard generation == dossierLoadGeneration,
              workspaceSelection == .dossier(dossierID),
              case .loading(let loadingID, let loadingPrevious) = dossierDetailState,
              loadingID == dossierID,
              loadingPrevious == previous
        else {
            return
        }
        guard !Task.isCancelled else {
            dossierDetailState = previous.map(DossierDetailState.available) ?? .none
            return
        }
        sources = refreshedSources
        dossiers = refreshedDossiers
        dossierDetailState = .none
        dossierChoices = []
        publishSelection(targetSourceID, presentation: presentation)
        publishRuntimeFailure(
            code: "dossierRemoved",
            category: .dossierLoad,
            error: DossierRepositoryError.dossierNotFound
        )
    }

    private func restoreDossierDetailIfCurrent(
        dossierID: UUID,
        generation: Int,
        previous: DossierSnapshot?
    ) {
        guard generation == dossierLoadGeneration,
              workspaceSelection == .dossier(dossierID),
              case .loading(let loadingID, let loadingPrevious) = dossierDetailState,
              loadingID == dossierID,
              loadingPrevious == previous
        else {
            return
        }
        dossierDetailState = previous.map(DossierDetailState.available) ?? .none
    }

    public func showInvoicePaymentCounterpart(
        candidate: InvoicePaymentCandidate
    ) async {
        guard invoicePaymentCounterpartNavigatingCandidate == nil,
              !isInvoicePaymentDecisionUpdateInFlight,
              case .available(let selectedDocumentID, let candidates) =
                invoicePaymentCandidateState,
              self.selectedDocumentID == selectedDocumentID,
              let visibleAnnotation = candidates.first(where: {
                  $0.candidate == candidate
              }),
              let sourceID = selectedSourceID,
              let workspace = workspaceSelection,
              let counterpart = counterpart(
                  in: candidate,
                  selectedDocumentID: selectedDocumentID
              )
        else {
            return
        }
        let expectedDossierToken: DossierProjectionToken?
        switch workspace {
        case .source:
            expectedDossierToken = nil
        case .dossier(let dossierID):
            guard let snapshot = dossierDetailState.snapshot,
                  snapshot.dossier.id == dossierID
            else {
                return
            }
            expectedDossierToken = snapshot.token
        }
        invalidateDossierLoad()
        invoicePaymentCounterpartNavigationGeneration &+= 1
        let navigationGeneration = invoicePaymentCounterpartNavigationGeneration
        let selectionGeneration = documentDNADetailGeneration
        invoicePaymentCounterpartNavigatingCandidate = candidate
        defer {
            if navigationGeneration == invoicePaymentCounterpartNavigationGeneration {
                invoicePaymentCounterpartNavigatingCandidate = nil
            }
        }

        do {
            let loaded = try await loadDocumentSelection(expected: counterpart)
            guard let loadedCounterpartCandidate = loaded.candidates.first(where: {
                sameInvoicePaymentIdentity($0.candidate, candidate)
            }) else {
                throw InvoicePaymentCounterpartNavigationError.staleCandidate
            }
            let annotatedCandidates = loaded.candidates.map { annotation in
                guard annotation.candidate == loadedCounterpartCandidate.candidate else {
                    return annotation
                }
                return InvoicePaymentCandidateWithDecision(
                    candidate: annotation.candidate,
                    decision: visibleAnnotation.decision
                )
            }
            guard !Task.isCancelled,
                  navigationGeneration
                    == invoicePaymentCounterpartNavigationGeneration,
                  selectionGeneration == documentDNADetailGeneration,
                  self.selectedSourceID == sourceID,
                  self.selectedDocumentID == selectedDocumentID,
                  workspaceSelection == workspace,
                  matchesDossierContext(
                    workspace,
                    expectedToken: expectedDossierToken
                  )
            else {
                return
            }
            let targetWorkspace: AppWorkspaceSelection = switch workspace {
            case .source:
                .source(loaded.sourceID)
            case .dossier(let dossierID):
                .dossier(dossierID)
            }
            let publishedGeneration = publishDocumentSelection(
                loaded.replacingCandidates(annotatedCandidates),
                workspace: targetWorkspace
            )
            await loadDossierEntryDisposition(
                documentID: loaded.document.id,
                snapshot: loaded.snapshot,
                generation: publishedGeneration
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  navigationGeneration
                    == invoicePaymentCounterpartNavigationGeneration,
                  selectionGeneration == documentDNADetailGeneration,
                  self.selectedSourceID == sourceID,
                  self.selectedDocumentID == selectedDocumentID,
                  workspaceSelection == workspace,
                  matchesDossierContext(
                    workspace,
                    expectedToken: expectedDossierToken
                  )
            else {
                return
            }
            publishRuntimeFailure(
                code: "invoicePaymentCounterpartNavigationFailure",
                category: .documentLoad,
                error: error
            )
        }
    }

    public func selectDossierMember(documentID: UUID) async {
        guard !isExclusiveSourceOperationActive,
              case .dossier(let dossierID) = workspaceSelection,
              let dossierSnapshot = dossierDetailState.snapshot,
              dossierSnapshot.dossier.id == dossierID,
              let member = dossierSnapshot.members.first(where: {
                  $0.document.id == documentID
              })
        else {
            return
        }
        invalidateDossierLoad()
        documentDNADetailGeneration &+= 1
        invalidateInvoicePaymentDecisionUpdate()
        invalidateInvoicePaymentCounterpartNavigation()
        let generation = documentDNADetailGeneration
        let expectedToken = dossierSnapshot.token
        dossierEntryState = .none

        do {
            let loaded = try await loadDocumentSelection(expected: member.document)
            guard !Task.isCancelled,
                  generation == documentDNADetailGeneration,
                  workspaceSelection == .dossier(dossierID),
                  dossierDetailState.snapshot?.dossier.id == dossierID,
                  dossierDetailState.snapshot?.token == expectedToken
            else {
                return
            }
            let publishedGeneration = publishDocumentSelection(
                loaded,
                workspace: .dossier(dossierID)
            )
            await loadDossierEntryDisposition(
                documentID: loaded.document.id,
                snapshot: loaded.snapshot,
                generation: publishedGeneration
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation == documentDNADetailGeneration,
                  workspaceSelection == .dossier(dossierID),
                  dossierDetailState.snapshot?.dossier.id == dossierID,
                  dossierDetailState.snapshot?.token == expectedToken
            else {
                return
            }
            publishRuntimeFailure(
                code: "documentLoadFailure",
                category: .documentLoad,
                error: error
            )
        }
    }

    public func excludeDossierMember(_ member: DossierMember) async {
        guard !isExclusiveSourceOperationActive,
              case .idle = dossierMutationState,
              let dossierMutator,
              case .dossier(let dossierID) = workspaceSelection,
              let current = dossierDetailState.snapshot,
              current.dossier.id == dossierID,
              current.members.contains(member),
              member.explanation.role != .anchor,
              let support = member.support
        else {
            return
        }
        dossierMutationGeneration &+= 1
        let generation = dossierMutationGeneration
        let expectedToken = current.token
        invalidateDossierLoad()
        dossierMutationState = .excluding(
            dossierID: dossierID,
            documentID: member.id
        )
        defer {
            if generation == dossierMutationGeneration {
                dossierMutationState = .idle
            }
        }
        do {
            let snapshot = try await dossierMutator.excludeMember(
                dossierID: dossierID,
                documentID: member.id,
                expectedSupport: support
            )
            guard snapshot.dossier.id == dossierID else {
                throw DossierRepositoryError.invalidStoredState
            }
            guard !Task.isCancelled,
                  generation == dossierMutationGeneration,
                  workspaceSelection == .dossier(dossierID),
                  dossierDetailState.snapshot?.dossier.id == dossierID,
                  dossierDetailState.snapshot?.token == expectedToken
            else {
                return
            }
            publishDossier(snapshot)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation == dossierMutationGeneration,
                  workspaceSelection == .dossier(dossierID),
                  dossierDetailState.snapshot?.dossier.id == dossierID,
                  dossierDetailState.snapshot?.token == expectedToken
            else {
                return
            }
            publishRuntimeFailure(
                code: "dossierMutationFailure",
                category: .dossierMutation,
                error: error
            )
        }
    }

    public func resetDossierCorrection(_ correction: DossierCorrection) async {
        guard !isExclusiveSourceOperationActive,
              case .idle = dossierMutationState,
              let dossierMutator,
              case .dossier(let dossierID) = workspaceSelection,
              let current = dossierDetailState.snapshot,
              current.dossier.id == dossierID,
              current.corrections.contains(correction),
              correction.exclusion.dossierID == dossierID
        else {
            return
        }
        dossierMutationGeneration &+= 1
        let generation = dossierMutationGeneration
        let expectedToken = current.token
        invalidateDossierLoad()
        dossierMutationState = .resetting(
            dossierID: dossierID,
            documentID: correction.id
        )
        defer {
            if generation == dossierMutationGeneration {
                dossierMutationState = .idle
            }
        }
        do {
            let snapshot = try await dossierMutator.resetExclusion(
                dossierID: dossierID,
                documentID: correction.id,
                expectedRevisionID: correction.exclusion.revisionID
            )
            guard snapshot.dossier.id == dossierID else {
                throw DossierRepositoryError.invalidStoredState
            }
            guard !Task.isCancelled,
                  generation == dossierMutationGeneration,
                  workspaceSelection == .dossier(dossierID),
                  dossierDetailState.snapshot?.dossier.id == dossierID,
                  dossierDetailState.snapshot?.token == expectedToken
            else {
                return
            }
            publishDossier(snapshot)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation == dossierMutationGeneration,
                  workspaceSelection == .dossier(dossierID),
                  dossierDetailState.snapshot?.dossier.id == dossierID,
                  dossierDetailState.snapshot?.token == expectedToken
            else {
                return
            }
            publishRuntimeFailure(
                code: "dossierMutationFailure",
                category: .dossierMutation,
                error: error
            )
        }
    }

    public func refreshSelectedDossier() async {
        guard !isExclusiveSourceOperationActive,
              case .dossier(let dossierID) = workspaceSelection
        else {
            return
        }
        await refreshDossier(id: dossierID)
    }

    private func matchesDossierContext(
        _ workspace: AppWorkspaceSelection,
        expectedToken: DossierProjectionToken?
    ) -> Bool {
        switch workspace {
        case .source:
            return expectedToken == nil
        case .dossier(let dossierID):
            guard let expectedToken else { return false }
            return dossierDetailState.snapshot?.dossier.id == dossierID
                && dossierDetailState.snapshot?.token == expectedToken
        }
    }

    public func updateInvoicePaymentDecision(
        candidate: InvoicePaymentCandidate,
        command: InvoicePaymentDecisionCommand
    ) async {
        guard !isInvoicePaymentDecisionUpdateInFlight,
              invoicePaymentCounterpartNavigatingCandidate == nil,
              let invoicePaymentDecisions,
              case .available(let documentID, let candidates) = invoicePaymentCandidateState,
              selectedDocumentID == documentID,
              candidates.contains(where: { $0.candidate == candidate })
        else {
            return
        }
        invoicePaymentDecisionUpdateGeneration &+= 1
        let updateGeneration = invoicePaymentDecisionUpdateGeneration
        let selectionGeneration = documentDNADetailGeneration
        isInvoicePaymentDecisionUpdateInFlight = true
        invoicePaymentDecisionUpdatingCandidate = candidate
        defer {
            isInvoicePaymentDecisionUpdateInFlight = false
            if updateGeneration == invoicePaymentDecisionUpdateGeneration {
                invoicePaymentDecisionUpdatingCandidate = nil
            }
        }
        do {
            try await invoicePaymentDecisions.update(
                candidate: candidate,
                command: command
            )
            guard case .available(let currentDocumentID, let currentCandidates) =
                invoicePaymentCandidateState,
                currentDocumentID == documentID,
                selectedDocumentID == documentID,
                selectionGeneration == documentDNADetailGeneration,
                updateGeneration == invoicePaymentDecisionUpdateGeneration
            else {
                return
            }
            let decision: InvoicePaymentCandidateDecisionState
            switch command {
            case .set(.confirmed):
                decision = .confirmed
            case .set(.excluded):
                decision = .excluded
            case .reset:
                decision = .undecided
            }
            invoicePaymentCandidateState = .available(
                documentID: documentID,
                candidates: currentCandidates.map { annotated in
                    guard annotated.candidate == candidate else { return annotated }
                    return InvoicePaymentCandidateWithDecision(
                        candidate: annotated.candidate,
                        decision: decision
                    )
                }
            )
            if lastErrorCode == "invoicePaymentDecisionUpdateFailure" {
                lastErrorCode = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard selectionGeneration == documentDNADetailGeneration,
                  updateGeneration == invoicePaymentDecisionUpdateGeneration,
                  selectedDocumentID == documentID
            else {
                return
            }
            publishRuntimeFailure(
                code: "invoicePaymentDecisionUpdateFailure",
                category: .invoicePaymentDecisionUpdate,
                error: error
            )
        }
    }

    public func retrySelectedDocumentDNA() async {
        guard let dnaRetryer,
              let documentID = selectedDocumentID,
              let sourceRootID = selectedSourceID,
              documentDNARetryingDocumentID == nil,
              let analysisPhase = documentDNAAnalysisPhases[documentID],
              case .failed = analysisPhase,
              documents.contains(where: {
                  $0.id == documentID && $0.sourceRootID == sourceRootID
              }),
              beginExclusiveSourceOperation()
        else {
            return
        }
        documentDNARetryingDocumentID = documentID
        let selectionGeneration = documentDNADetailGeneration
        if lastErrorCode == "documentDNARetryFailure"
            || lastErrorCode == "incrementalRefreshFailure" {
            lastErrorCode = nil
        }
        defer {
            documentDNARetryingDocumentID = nil
            endExclusiveSourceOperation()
        }

        do {
            try await dnaRetryer.retryFailedAnalysis(
                documentID: documentID,
                sourceRootID: sourceRootID
            )
        } catch {
            guard !Self.isDocumentDNACancellation(error) else { return }
            guard !Task.isCancelled,
                  selectionGeneration == documentDNADetailGeneration,
                  selectedSourceID == sourceRootID,
                  selectedDocumentID == documentID
            else {
                return
            }
            publishRuntimeFailure(
                code: "documentDNARetryFailure",
                category: .documentDNARetry,
                error: error
            )
            return
        }

        guard !Task.isCancelled,
              selectionGeneration == documentDNADetailGeneration,
              selectedSourceID == sourceRootID,
              selectedDocumentID == documentID
        else {
            return
        }
        do {
            let presentation = try await loadDocumentPresentation(sourceID: sourceRootID)
            guard !Task.isCancelled,
                  selectionGeneration == documentDNADetailGeneration,
                  selectedSourceID == sourceRootID,
                  selectedDocumentID == documentID
            else {
                return
            }
            publish(presentation)
            await selectDocument(id: documentID)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  selectionGeneration == documentDNADetailGeneration,
                  selectedSourceID == sourceRootID,
                  selectedDocumentID == documentID
            else {
                return
            }
            publishRuntimeFailure(
                code: "incrementalRefreshFailure",
                category: .incrementalRefresh,
                error: error
            )
        }
    }

    public func stopWatching() async {
        invalidateIncrementalRefreshes()
        watchLifecycleGeneration &+= 1
        let stoppingGeneration = watchLifecycleGeneration
        let changesTask = watchChangesTask
        let completionsTask = rescanCompletionsTask
        let drainTask = rescanDrainTask
        changesTask?.cancel()
        completionsTask?.cancel()
        drainTask?.cancel()
        watchChangesTask = nil
        rescanCompletionsTask = nil
        rescanDrainTask = nil
        pendingRescanSourceIDs.removeAll()
        watchedSourceIDs.removeAll()
        await changesTask?.value
        await completionsTask?.value
        await drainTask?.value
        guard stoppingGeneration == watchLifecycleGeneration else { return }
        await watchScheduler?.stopAll()
    }

    private func reloadDocuments(
        expectedIncrementalRefreshGeneration: Int? = nil
    ) async throws -> Bool {
        let sourceID = selectedSourceID
        let generation = expectedIncrementalRefreshGeneration
            ?? incrementalRefreshGeneration
        do {
            let presentation = try await loadDocumentPresentation(sourceID: sourceID)
            guard !Task.isCancelled,
                  selectedSourceID == sourceID,
                  generation == incrementalRefreshGeneration
            else {
                return false
            }
            publish(presentation)
            return true
        } catch {
            guard selectedSourceID == sourceID,
                  generation == incrementalRefreshGeneration
            else {
                return false
            }
            throw error
        }
    }

    private func loadDocumentPresentation(
        sourceID: UUID?
    ) async throws -> DocumentPresentation {
        guard let sourceID else {
            return DocumentPresentation(documents: [], dnaAnalysisPhases: [:])
        }
        let loadedDocuments = try await documentLoader(sourceID)
        let loadedDNAStatuses = try await dnaStatuses?.currentAnalysisStatuses(
            sourceRootID: sourceID
        ) ?? []
        let visibleDocumentIDs = Set(loadedDocuments.map(\.id))
        let phases: [UUID: DocumentDNAAnalysisPhase] = loadedDNAStatuses.reduce(
            into: [:]
        ) { phases, status in
            if visibleDocumentIDs.contains(status.documentID) {
                phases[status.documentID] = status.phase
            }
        }
        return DocumentPresentation(
            documents: loadedDocuments,
            dnaAnalysisPhases: phases
        )
    }

    private func publish(_ presentation: DocumentPresentation) {
        clearDocumentSelection()
        documents = presentation.documents
        documentDNAAnalysisPhases = presentation.dnaAnalysisPhases
    }

    private func publishDossier(
        _ snapshot: DossierSnapshot,
        summaries: [DossierSummary]? = nil,
        preservingTransientState: Bool = false
    ) {
        if let summaries {
            dossiers = summaries
        }
        workspaceSelectionGeneration &+= 1
        workspaceSelection = .dossier(snapshot.dossier.id)
        dossierDetailState = .available(snapshot)
        if !preservingTransientState {
            dossierChoices = []
        }
        if lastErrorCode == "dossierLoadFailure"
            || lastErrorCode == "dossierRemoved"
            || (!preservingTransientState
                && (lastErrorCode == "dossierOpenFailure"
                    || lastErrorCode == "dossierMutationFailure")) {
            lastErrorCode = nil
        }
    }

    private func clearDocumentSelection() {
        documentDNADetailGeneration += 1
        invalidateInvoicePaymentDecisionUpdate()
        invalidateInvoicePaymentCounterpartNavigation()
        selectedDocumentID = nil
        documentDNADetailState = .none
        invoicePaymentCandidateState = .none
        dossierEntryState = .none
        clearDocumentScopedFailure()
    }

    private func clearDocumentScopedFailure() {
        if lastErrorCode == "documentDNADetailLoadFailure"
            || lastErrorCode == "documentDNARetryFailure"
            || lastErrorCode == "invoicePaymentCandidateLoadFailure"
            || lastErrorCode == "invoicePaymentDecisionUpdateFailure"
            || lastErrorCode == "invoicePaymentCounterpartNavigationFailure"
            || lastErrorCode == "dossierEntryLoadFailure" {
            lastErrorCode = nil
        }
    }

    private func counterpart(
        in candidate: InvoicePaymentCandidate,
        selectedDocumentID: UUID
    ) -> DocumentRecord? {
        if candidate.invoice.document.id == selectedDocumentID {
            return candidate.payment.document
        }
        if candidate.payment.document.id == selectedDocumentID {
            return candidate.invoice.document
        }
        return nil
    }

    private func sameInvoicePaymentIdentity(
        _ lhs: InvoicePaymentCandidate,
        _ rhs: InvoicePaymentCandidate
    ) -> Bool {
        lhs.invoice.document.id == rhs.invoice.document.id
            && lhs.invoice.document.sourceRootID == rhs.invoice.document.sourceRootID
            && lhs.invoice.document.contentHash == rhs.invoice.document.contentHash
            && lhs.payment.document.id == rhs.payment.document.id
            && lhs.payment.document.sourceRootID == rhs.payment.document.sourceRootID
            && lhs.payment.document.contentHash == rhs.payment.document.contentHash
    }

    private func loadDocumentSelection(
        expected document: DocumentRecord
    ) async throws -> DocumentSelectionPresentation {
        guard let dnaSnapshots else {
            throw DocumentSelectionError.staleDocument
        }
        let presentation = try await loadDocumentPresentation(
            sourceID: document.sourceRootID
        )
        guard let currentDocument = presentation.documents.first(where: {
            $0.id == document.id
                && $0.sourceRootID == document.sourceRootID
                && $0.contentHash == document.contentHash
        }),
            presentation.dnaAnalysisPhases[currentDocument.id] == .ready
        else {
            throw DocumentSelectionError.staleDocument
        }
        let snapshot = try await dnaSnapshots.currentSnapshot(
            documentID: currentDocument.id
        )
        guard let snapshot,
              snapshot.documentID == currentDocument.id,
              snapshot.inputContentHash == currentDocument.contentHash
        else {
            throw DocumentSelectionError.staleDocument
        }
        let candidates = try await invoicePaymentCandidates?.candidates(
            involving: currentDocument.id
        ) ?? []
        return DocumentSelectionPresentation(
            sourceID: currentDocument.sourceRootID,
            presentation: presentation,
            document: currentDocument,
            snapshot: snapshot,
            candidates: candidates
        )
    }

    @discardableResult
    private func publishDocumentSelection(
        _ selection: DocumentSelectionPresentation,
        workspace: AppWorkspaceSelection
    ) -> Int {
        documentDNADetailGeneration &+= 1
        invalidateInvoicePaymentDecisionUpdate()
        selectedSourceID = selection.sourceID
        documents = selection.presentation.documents
        documentDNAAnalysisPhases = selection.presentation.dnaAnalysisPhases
        selectedDocumentID = selection.document.id
        documentDNADetailState = .available(selection.snapshot)
        invoicePaymentCandidateState = .available(
            documentID: selection.document.id,
            candidates: selection.candidates
        )
        workspaceSelectionGeneration &+= 1
        workspaceSelection = workspace
        dossierEntryState = .none
        clearDocumentScopedFailure()
        if lastErrorCode == "documentLoadFailure" {
            lastErrorCode = nil
        }
        return documentDNADetailGeneration
    }

    private func invalidateInvoicePaymentDecisionUpdate() {
        invoicePaymentDecisionUpdateGeneration &+= 1
        invoicePaymentDecisionUpdatingCandidate = nil
    }

    private func invalidateInvoicePaymentCounterpartNavigation() {
        invoicePaymentCounterpartNavigationGeneration &+= 1
        invoicePaymentCounterpartNavigatingCandidate = nil
    }

    private func invalidateDossierLoad() {
        workspaceSelectionGeneration &+= 1
        dossierLoadGeneration &+= 1
        invalidateIncrementalRefreshes()
        if case .loading(_, let previous) = dossierDetailState {
            dossierDetailState = previous.map(DossierDetailState.available) ?? .none
        }
    }

    private func invalidateDossierMutation() {
        dossierMutationGeneration &+= 1
        dossierMutationState = .idle
    }

    private func loadInvoicePaymentCandidates(
        involving documentID: UUID,
        generation: Int
    ) async {
        guard let invoicePaymentCandidates else { return }
        invoicePaymentCandidateState = .loading(documentID: documentID)
        do {
            let candidates = try await invoicePaymentCandidates.candidates(
                involving: documentID
            )
            guard generation == documentDNADetailGeneration,
                  selectedDocumentID == documentID
            else {
                return
            }
            guard !Task.isCancelled else {
                invoicePaymentCandidateState = .none
                return
            }
            invoicePaymentCandidateState = .available(
                documentID: documentID,
                candidates: candidates
            )
            if lastErrorCode == "invoicePaymentCandidateLoadFailure" {
                lastErrorCode = nil
            }
        } catch is CancellationError {
            guard generation == documentDNADetailGeneration,
                  selectedDocumentID == documentID
            else {
                return
            }
            invoicePaymentCandidateState = .none
        } catch {
            guard generation == documentDNADetailGeneration,
                  selectedDocumentID == documentID
            else {
                return
            }
            guard !Task.isCancelled else {
                invoicePaymentCandidateState = .none
                return
            }
            invoicePaymentCandidateState = .failed(documentID: documentID)
            publishRuntimeFailure(
                code: "invoicePaymentCandidateLoadFailure",
                category: .invoicePaymentCandidateLoad,
                error: error
            )
        }
    }

    private func loadDossierEntryDisposition(
        documentID: UUID,
        snapshot: DocumentDNA,
        generation: Int
    ) async {
        guard let dossierLoader,
              snapshot.findings.contains(where: {
                  $0.kind == .documentType
                      && ($0.normalizedValue == DocumentType.invoice.rawValue
                          || $0.normalizedValue
                            == DocumentType.paymentConfirmation.rawValue)
              })
        else {
            guard generation == documentDNADetailGeneration,
                  selectedDocumentID == documentID
            else {
                return
            }
            dossierEntryState = .none
            return
        }
        dossierEntryState = .loading(documentID: documentID)
        do {
            let disposition = try await dossierLoader.entryDisposition(for: documentID)
            guard generation == documentDNADetailGeneration,
                  selectedDocumentID == documentID
            else {
                return
            }
            guard !Task.isCancelled else {
                dossierEntryState = .none
                return
            }
            dossierEntryState = .available(
                documentID: documentID,
                disposition: disposition
            )
            if lastErrorCode == "dossierEntryLoadFailure" {
                lastErrorCode = nil
            }
        } catch is CancellationError {
            guard generation == documentDNADetailGeneration,
                  selectedDocumentID == documentID
            else {
                return
            }
            dossierEntryState = .none
        } catch {
            guard generation == documentDNADetailGeneration,
                  selectedDocumentID == documentID
            else {
                return
            }
            guard !Task.isCancelled else {
                dossierEntryState = .none
                return
            }
            dossierEntryState = .failed(documentID: documentID)
            publishRuntimeFailure(
                code: "dossierEntryLoadFailure",
                category: .dossierLoad,
                error: error
            )
        }
    }

    private static func isDocumentDNACancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? DocumentDNAAnalysisRunError)?.reason == .cancelled
    }

    private func publishSelection(
        _ sourceID: UUID?,
        presentation: DocumentPresentation
    ) {
        selectedSourceID = sourceID
        workspaceSelectionGeneration &+= 1
        workspaceSelection = sourceID.map(AppWorkspaceSelection.source)
        dossierChoices = []
        publish(presentation)
    }

    private func finishReload() async {
        activeReloadCount -= 1
        await processPendingRescanCompletions()
    }

    private func beginExclusiveSourceOperation() -> Bool {
        guard !isExclusiveSourceOperationActive else { return false }
        isExclusiveSourceOperationActive = true
        invalidateDossierLoad()
        invalidateDossierMutation()
        return true
    }

    private func endExclusiveSourceOperation() {
        isExclusiveSourceOperationActive = false
        guard !pendingRescanSourceIDs.isEmpty,
              rescanCompletionsTask != nil
        else {
            return
        }
        let previousDrainTask = rescanDrainTask
        previousDrainTask?.cancel()
        rescanDrainTask = Task { [weak self] in
            await previousDrainTask?.value
            guard !Task.isCancelled else { return }
            await self?.processPendingRescanCompletions()
        }
    }

    private func invalidateIncrementalRefreshes() {
        incrementalRefreshGeneration &+= 1
    }

    private func startWatchingSavedSources() async {
        guard watchScheduler != nil else { return }
        if watchChangesTask == nil, rescanCompletionsTask == nil {
            watchLifecycleGeneration &+= 1
        }
        startReceivingWatchChangesIfNeeded()
        startReceivingRescanCompletionsIfNeeded()
        let savedSourceIDs = Set(sources.map(\.id))
        for removedSourceID in watchedSourceIDs.subtracting(savedSourceIDs) {
            await watchScheduler?.stop(sourceID: removedSourceID)
            watchedSourceIDs.remove(removedSourceID)
            unavailableSourceIDs.remove(removedSourceID)
        }
        for source in sources where !watchedSourceIDs.contains(source.id) {
            await startWatching(source)
        }
    }

    private func startWatching(_ source: SourceRootRecord) async {
        guard let watchScheduler,
              !watchedSourceIDs.contains(source.id)
        else {
            return
        }
        let startingGeneration = watchLifecycleGeneration
        do {
            let preparedSource = try await sourceRepository.renewBookmarkIfStale(
                source,
                sourceAccess: sourceAccess
            )
            guard startingGeneration == watchLifecycleGeneration,
                  !watchedSourceIDs.contains(source.id)
            else {
                return
            }
            if let index = sources.firstIndex(where: { $0.id == preparedSource.id }) {
                sources[index] = preparedSource
            }
            let url = try sourceResolver(preparedSource)
            watchedSourceIDs.insert(source.id)
            unavailableSourceIDs.remove(source.id)
            await watchScheduler.start(source: preparedSource, url: url)
            if !(await watchScheduler.isWatching(sourceID: source.id)) {
                watchedSourceIDs.remove(source.id)
                unavailableSourceIDs.insert(source.id)
            }
        } catch {
            unavailableSourceIDs.insert(source.id)
            reportRuntimeFailure(AppRuntimeDiagnostic(category: .watcherStart, error: error))
        }
    }

    private func startReceivingWatchChangesIfNeeded() {
        guard watchChangesTask == nil, let watchScheduler else { return }
        let changes = watchScheduler.changes
        watchChangesTask = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled else { return }
                await self?.receive(change)
            }
        }
    }

    private func startReceivingRescanCompletionsIfNeeded() {
        guard rescanCompletionsTask == nil, let watchScheduler else { return }
        let completions = watchScheduler.rescanCompletions
        rescanCompletionsTask = Task { [weak self] in
            for await sourceID in completions {
                guard !Task.isCancelled else { return }
                await self?.receiveRescanCompletion(sourceID: sourceID)
            }
        }
    }

    private func receiveRescanCompletion(sourceID: UUID) async {
        invalidateIncrementalRefreshes()
        pendingRescanSourceIDs.insert(sourceID)
        await processPendingRescanCompletions()
    }

    private func processPendingRescanCompletions() async {
        guard !isProcessingRescanCompletions,
              !isExclusiveSourceOperationActive,
              activeReloadCount == 0
        else {
            return
        }
        isProcessingRescanCompletions = true
        defer { isProcessingRescanCompletions = false }
        while !pendingRescanSourceIDs.isEmpty,
              !isExclusiveSourceOperationActive,
              activeReloadCount == 0,
              !Task.isCancelled {
            let sourceIDs = pendingRescanSourceIDs
            let generation = incrementalRefreshGeneration
            await refreshAfterRescan(
                sourceIDs: sourceIDs,
                generation: generation
            )
            if generation == incrementalRefreshGeneration {
                pendingRescanSourceIDs.subtract(sourceIDs)
            }
        }
    }

    private func refreshAfterRescan(sourceIDs: Set<UUID>, generation: Int) async {
        let selectionAtStart = selectedSourceID
        let workspaceAtStart = workspaceSelection
        let workspaceGenerationAtStart = workspaceSelectionGeneration
        do {
            let refreshedSources = try await sourceLoader()
            guard !Task.isCancelled,
                  generation == incrementalRefreshGeneration,
                  workspaceGenerationAtStart == workspaceSelectionGeneration
            else {
                return
            }
            let targetSourceID = refreshedSources.contains(where: { $0.id == selectedSourceID })
                ? selectedSourceID
                : refreshedSources.first?.id
            let selectionChanged = targetSourceID != selectedSourceID
            let selectedSourceCompleted = targetSourceID.map(sourceIDs.contains) ?? false
            if case .dossier(let dossierID) = workspaceAtStart {
                if selectionChanged || selectedSourceCompleted {
                    let presentation = try await loadDocumentPresentation(
                        sourceID: targetSourceID
                    )
                    guard !Task.isCancelled,
                          generation == incrementalRefreshGeneration,
                          workspaceGenerationAtStart == workspaceSelectionGeneration,
                          workspaceSelection == .dossier(dossierID)
                    else {
                        return
                    }
                    selectedSourceID = targetSourceID
                    publish(presentation)
                }
                guard !Task.isCancelled,
                      generation == incrementalRefreshGeneration,
                      workspaceGenerationAtStart == workspaceSelectionGeneration,
                      workspaceSelection == .dossier(dossierID)
                else {
                    return
                }
                sources = refreshedSources
                await refreshDossier(id: dossierID)
                return
            }
            guard selectionChanged || selectedSourceCompleted else {
                sources = refreshedSources
                return
            }
            let presentation = try await loadDocumentPresentation(sourceID: targetSourceID)
            guard !Task.isCancelled,
                  generation == incrementalRefreshGeneration,
                  workspaceGenerationAtStart == workspaceSelectionGeneration
            else {
                return
            }
            sources = refreshedSources
            publishSelection(targetSourceID, presentation: presentation)
        } catch {
            guard !Task.isCancelled,
                  generation == incrementalRefreshGeneration,
                  workspaceGenerationAtStart == workspaceSelectionGeneration,
                  workspaceSelection == workspaceAtStart,
                  ((selectionAtStart.map(sourceIDs.contains) ?? false)
                    || {
                        if case .dossier = workspaceAtStart { return true }
                        return false
                    }())
            else {
                return
            }
            publishRuntimeFailure(
                code: "incrementalRefreshFailure",
                category: .incrementalRefresh,
                error: error
            )
        }
    }

    private func publishRuntimeFailure(
        code: String,
        category: AppRuntimeFailureCategory,
        error: any Error
    ) {
        lastErrorCode = code
        reportRuntimeFailure(AppRuntimeDiagnostic(category: category, error: error))
    }

    private func receive(_ change: DirectoryChange) async {
        guard watchedSourceIDs.contains(change.sourceRootID) else { return }
        switch change.kind {
        case .rootUnavailable:
            let isStillWatching = await watchScheduler?.isWatching(
                sourceID: change.sourceRootID
            )
            guard !Task.isCancelled,
                  watchedSourceIDs.contains(change.sourceRootID)
            else {
                return
            }
            if isStillWatching == false {
                watchedSourceIDs.remove(change.sourceRootID)
            }
            unavailableSourceIDs.insert(change.sourceRootID)
        case .rootAvailable:
            unavailableSourceIDs.remove(change.sourceRootID)
        case .contentChanged:
            break
        }
    }
}

private struct DocumentPresentation {
    let documents: [DocumentRecord]
    let dnaAnalysisPhases: [UUID: DocumentDNAAnalysisPhase]
}

private struct DocumentSelectionPresentation {
    let sourceID: UUID
    let presentation: DocumentPresentation
    let document: DocumentRecord
    let snapshot: DocumentDNA
    let candidates: [InvoicePaymentCandidateWithDecision]

    func replacingCandidates(
        _ candidates: [InvoicePaymentCandidateWithDecision]
    ) -> Self {
        Self(
            sourceID: sourceID,
            presentation: presentation,
            document: document,
            snapshot: snapshot,
            candidates: candidates
        )
    }
}

private enum DocumentSelectionError: Error {
    case staleDocument
}

private enum InvoicePaymentCounterpartNavigationError: Error {
    case staleCandidate
}
