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

public enum DocumentDNADetailState: Sendable, Equatable {
    case none
    case loading(documentID: UUID)
    case available(DocumentDNA)
    case unavailable(documentID: UUID)
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
    @Published public private(set) var documentDNARetryingDocumentID: UUID?
    @Published public private(set) var scanState: AppScanState = .idle
    @Published public private(set) var lastErrorCode: String?
    @Published public private(set) var unavailableSourceIDs = Set<UUID>()

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
        case "incrementalRefreshFailure":
            "Die Ansicht konnte nach der Analyse nicht aktualisiert werden. Bitte versuche es erneut."
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

    public init(
        sources: SourceRootRepository,
        documents: DocumentRepository,
        sourceAccess: any SourceAccessing,
        catalog: any CatalogScanning,
        ingestion: any PendingIngesting,
        dnaStatuses: (any DocumentDNAStatusLoading)? = nil,
        dnaSnapshots: (any DocumentDNASnapshotLoading)? = nil,
        dnaRetryer: (any DocumentDNAFailureRetrying)? = nil,
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
        invalidateIncrementalRefreshes()
        let generation = incrementalRefreshGeneration
        do {
            let loadedSources = try await sourceRepository.all()
            let targetSourceID = loadedSources.contains(where: { $0.id == selectedSourceID })
                ? selectedSourceID
                : loadedSources.first?.id
            let presentation = try await loadDocumentPresentation(sourceID: targetSourceID)
            guard !Task.isCancelled,
                  generation == incrementalRefreshGeneration
            else {
                await finishReload()
                return
            }
            sources = loadedSources
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
        invalidateIncrementalRefreshes()
        var sourceWasRemoved = false
        do {
            try await sourceRepository.remove(id: source.id)
            sourceWasRemoved = true
            await watchScheduler?.stop(sourceID: source.id)
            watchedSourceIDs.remove(source.id)
            unavailableSourceIDs.remove(source.id)
            sources = try await sourceRepository.all()
            let removedSelection = selectedSourceID == source.id
            let targetSourceID = removedSelection ? sources.first?.id : selectedSourceID
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
        let generation = documentDNADetailGeneration
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

    private func clearDocumentSelection() {
        documentDNADetailGeneration += 1
        selectedDocumentID = nil
        documentDNADetailState = .none
        clearDocumentScopedFailure()
    }

    private func clearDocumentScopedFailure() {
        if lastErrorCode == "documentDNADetailLoadFailure"
            || lastErrorCode == "documentDNARetryFailure" {
            lastErrorCode = nil
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
        publish(presentation)
    }

    private func finishReload() async {
        activeReloadCount -= 1
        await processPendingRescanCompletions()
    }

    private func beginExclusiveSourceOperation() -> Bool {
        guard !isExclusiveSourceOperationActive else { return false }
        isExclusiveSourceOperationActive = true
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
        do {
            let refreshedSources = try await sourceLoader()
            guard !Task.isCancelled,
                  generation == incrementalRefreshGeneration
            else {
                return
            }
            let targetSourceID = refreshedSources.contains(where: { $0.id == selectedSourceID })
                ? selectedSourceID
                : refreshedSources.first?.id
            let selectionChanged = targetSourceID != selectedSourceID
            let selectedSourceCompleted = targetSourceID.map(sourceIDs.contains) ?? false
            guard selectionChanged || selectedSourceCompleted else {
                sources = refreshedSources
                return
            }
            let presentation = try await loadDocumentPresentation(sourceID: targetSourceID)
            guard !Task.isCancelled,
                  generation == incrementalRefreshGeneration
            else {
                return
            }
            sources = refreshedSources
            publishSelection(targetSourceID, presentation: presentation)
        } catch {
            guard !Task.isCancelled,
                  generation == incrementalRefreshGeneration,
                  selectionAtStart.map(sourceIDs.contains) ?? false
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
