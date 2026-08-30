import AppKit
#if LINKLOOM_UI_TESTING
@_spi(UITesting) import LinkLoomAppFeature
#else
import LinkLoomAppFeature
#endif
import LinkLoomCore
import OSLog
import SwiftUI

@main
@MainActor
struct LinkLoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var startup: AppStartupController
    private let folderPicker: FolderPicker

    private static let startupLogger = Logger(
        subsystem: "LinkLoom",
        category: "startup"
    )
    private static let runtimeLogger = Logger(
        subsystem: "LinkLoom",
        category: "runtime"
    )

    init() {
#if LINKLOOM_UI_TESTING
        let configurationResult: Result<UITestLaunchConfiguration, Error> = Result {
            try UITestLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        }
        let configuration = try? configurationResult.get()
        folderPicker = FolderPicker(selectFolders: {
            configuration?.sourceURL.map { [$0] } ?? []
        })
        let startupFailureGate = UITestStartupFailureGate(
            enabled: configuration?.failsStartupOnce == true
        )
        let makeModel: @MainActor () throws -> AppModel = {
            let configuration = try configurationResult.get()
            if startupFailureGate.consumeFailure() {
                throw UITestStartupError.deterministicFailure
            }
            return try Self.makeModel(
                databaseURL: configuration.databaseURL,
                disablesWatcher: configuration.disablesWatcher
            )
        }
#else
        folderPicker = FolderPicker()
        let makeModel: @MainActor () throws -> AppModel = {
            try Self.makeModel()
        }
#endif
        _startup = StateObject(wrappedValue: AppStartupController(
            makeModel: makeModel,
            prepareModel: { model in try await model.reload() },
            reportFailure: { error in
                let nsError = error as NSError
                Self.startupLogger.error(
                    "Local catalog startup failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
                )
            }
        ))
    }

    var body: some Scene {
        WindowGroup {
            startupContent
                .task {
                    await startup.startIfNeeded { model in
                        appDelegate.configure(model: model)
                    }
                }
        }
    }

    @ViewBuilder
    private var startupContent: some View {
        switch startup.phase {
        case .idle, .starting:
            ProgressView("LinkLoom wird gestartet …")
                .frame(minWidth: 520, minHeight: 320)
                .accessibilityIdentifier("startup.progress")
        case .ready:
            if let model = startup.model {
                ContentView(model: model, folderPicker: folderPicker)
            }
        case .failed:
            ContentUnavailableView {
                Label(
                    "LinkLoom konnte nicht gestartet werden",
                    systemImage: "externaldrive.badge.exclamationmark"
                )
            } description: {
                Text(
                    "Der lokale Katalog konnte nicht geöffnet werden. "
                        + "Deine Quelldokumente wurden nicht verändert."
                )
            } actions: {
                Button("Erneut versuchen") {
                    Task {
                        await startup.retry { model in
                            appDelegate.configure(model: model)
                        }
                    }
                }
                .accessibilityIdentifier("startup.retry")
            }
            .frame(minWidth: 520, minHeight: 320)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("startup.failure")
        }
    }

    private static func makeModel(
        databaseURL: URL? = nil,
        disablesWatcher: Bool = false
    ) throws -> AppModel {
        let resolvedDatabaseURL: URL
        if let databaseURL {
            resolvedDatabaseURL = databaseURL
        } else {
            resolvedDatabaseURL = try Self.databaseURL()
        }
        let sourceAccess: any SourceAccessing = DefaultSourceAccess()
        let database = try AppDatabase.makeQueue(at: resolvedDatabaseURL)
        let sources = SourceRootRepository(dbWriter: database)
        let documents = DocumentRepository(dbWriter: database)
        let extractions = ExtractionRepository(dbWriter: database)
        let dnaRepository = DocumentDNARepository(dbWriter: database)
        let catalog = CatalogService(
            sourceAccess: sourceAccess,
            enumerator: DefaultFileEnumerator(),
            fingerprinter: SHA256FileFingerprinter(),
            documents: documents,
            sources: sources
        )
        let ingestion = IngestionPipeline(
            sourceAccess: sourceAccess,
            documents: documents,
            extractions: extractions,
            extractor: CompositeTextExtractor()
        )
        let dnaAnalyzer = LocalRulesDocumentDNAAnalyzer()
        let dnaTarget = try DocumentDNAAnalysisTarget(
            schemaVersion: LocalRulesDocumentDNAAnalyzer.schemaVersion,
            analyzerIdentifier: LocalRulesDocumentDNAAnalyzer.analyzerIdentifier,
            analyzerVersion: LocalRulesDocumentDNAAnalyzer.analyzerVersion
        )
        let dnaAnalysis = DocumentDNAAnalysisPipeline(
            repository: dnaRepository,
            analyzer: dnaAnalyzer,
            target: dnaTarget
        )
        let dnaStatuses = CurrentDocumentDNAStatusLoader(
            repository: dnaRepository,
            target: dnaTarget
        )
        let dnaSnapshots = CurrentDocumentDNASnapshotLoader(
            repository: dnaRepository,
            target: dnaTarget
        )
        let invoicePaymentCandidates = CurrentInvoicePaymentCandidateLoader(
            lookup: InvoicePaymentCandidateLookup(
                repository: dnaRepository,
                target: dnaTarget
            )
        )
        let dnaRetryer = LocalDocumentDNAFailureRetryer(
            repository: dnaRepository,
            analysis: dnaAnalysis
        )
        let documentProcessor = LocalDocumentProcessor(
            ingestion: ingestion,
            dnaAnalysis: dnaAnalysis
        )
        let watchScheduler: (any SourceWatchScheduling)?
        if disablesWatcher {
            watchScheduler = nil
        } else {
            watchScheduler = RescanScheduler(
                watcher: FSEventsDirectoryWatcher(),
                rescanner: IncrementalRescanner(
                    catalog: catalog,
                    documentProcessor: documentProcessor
                )
            )
        }
        return AppModel(
            sources: sources,
            documents: documents,
            sourceAccess: sourceAccess,
            catalog: CatalogScanner(service: catalog),
            ingestion: documentProcessor,
            dnaStatuses: dnaStatuses,
            dnaSnapshots: dnaSnapshots,
            dnaRetryer: dnaRetryer,
            invoicePaymentCandidates: invoicePaymentCandidates,
            watchScheduler: watchScheduler,
            reportRuntimeFailure: { diagnostic in
                Self.runtimeLogger.error(
                    "Runtime operation failed: category=\(diagnostic.category.rawValue, privacy: .public) reason=\(diagnostic.reason.rawValue, privacy: .public)"
                )
            }
        )
    }

    private static func databaseURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("LinkLoom", isDirectory: true)
            .appendingPathComponent("linkloom.sqlite", isDirectory: false)
    }
}

#if LINKLOOM_UI_TESTING
private enum UITestStartupError: Error {
    case deterministicFailure
}
#endif

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationCoordinator: AppTerminationCoordinator?

    func configure(model: AppModel) {
        let stopWatching: @MainActor @Sendable () async -> Void = { [weak model] in
            await model?.stopWatching()
        }
        if let terminationCoordinator {
            terminationCoordinator.updateStopWatching(stopWatching)
        } else {
            terminationCoordinator = AppTerminationCoordinator(
                stopWatching: stopWatching
            )
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let terminationCoordinator else { return .terminateNow }
        _ = terminationCoordinator.requestTermination { allowed in
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }
}

struct IncrementalRescanner: SourceRescanning {
    private let scanCatalog: @Sendable (SourceRootRecord) async throws -> Void
    private let processDocuments: @Sendable (SourceRootRecord) async throws -> Void

    init(catalog: CatalogService, documentProcessor: LocalDocumentProcessor) {
        scanCatalog = { source in
            _ = try await catalog.scan(source: source)
        }
        processDocuments = { source in
            try await documentProcessor.processPending(source: source)
        }
    }

    init(
        scanCatalog: @escaping @Sendable (SourceRootRecord) async throws -> Void,
        processDocuments: @escaping @Sendable (SourceRootRecord) async throws -> Void
    ) {
        self.scanCatalog = scanCatalog
        self.processDocuments = processDocuments
    }

    func rescan(source: SourceRootRecord) async throws {
        try await scanCatalog(source)
        try Task.checkCancellation()
        try await processDocuments(source)
    }
}

private struct CatalogScanner: CatalogScanning {
    let service: CatalogService

    func scan(source: SourceRootRecord) async throws {
        _ = try await service.scan(source: source)
    }
}

struct LocalDocumentProcessor: PendingIngesting {
    private let ingest: @Sendable (SourceRootRecord) async throws -> Void
    private let analyzeDNA: @Sendable (UUID) async throws -> Void

    init(
        ingestion: IngestionPipeline,
        dnaAnalysis: DocumentDNAAnalysisPipeline
    ) {
        ingest = { source in
            _ = try await ingestion.processPending(source: source)
        }
        analyzeDNA = { sourceID in
            _ = try await dnaAnalysis.processPending(sourceRootID: sourceID)
        }
    }

    init(
        ingest: @escaping @Sendable (SourceRootRecord) async throws -> Void,
        analyzeDNA: @escaping @Sendable (UUID) async throws -> Void
    ) {
        self.ingest = ingest
        self.analyzeDNA = analyzeDNA
    }

    func processPending(source: SourceRootRecord) async throws {
        try await ingest(source)
        try Task.checkCancellation()
        try await analyzeDNA(source.id)
    }
}

struct CurrentDocumentDNAStatusLoader: DocumentDNAStatusLoading {
    let repository: DocumentDNARepository
    let target: DocumentDNAAnalysisTarget

    func currentAnalysisStatuses(
        sourceRootID: UUID
    ) async throws -> [DocumentDNAAnalysisStatus] {
        try await repository.currentAnalysisStatuses(
            sourceRootID: sourceRootID,
            target: target
        )
    }
}

struct CurrentDocumentDNASnapshotLoader: DocumentDNASnapshotLoading {
    let repository: DocumentDNARepository
    let target: DocumentDNAAnalysisTarget

    func currentSnapshot(documentID: UUID) async throws -> DocumentDNA? {
        try await repository.currentSnapshot(documentID: documentID, target: target)
    }
}

struct CurrentInvoicePaymentCandidateLoader: InvoicePaymentCandidateLoading {
    let lookup: InvoicePaymentCandidateLookup

    func candidates(involving documentID: UUID) async throws
        -> [InvoicePaymentCandidate]
    {
        try await lookup.candidates(involving: documentID)
    }
}

struct LocalDocumentDNAFailureRetryer: DocumentDNAFailureRetrying {
    private let clearFailedAnalysis: @Sendable (UUID) async throws -> Void
    private let processPending: @Sendable (UUID) async throws -> Void

    init(
        repository: DocumentDNARepository,
        analysis: DocumentDNAAnalysisPipeline
    ) {
        clearFailedAnalysis = { documentID in
            try await repository.retryFailedAnalysis(documentID: documentID)
        }
        processPending = { sourceRootID in
            _ = try await analysis.processPending(sourceRootID: sourceRootID)
        }
    }

    init(
        clearFailedAnalysis: @escaping @Sendable (UUID) async throws -> Void,
        processPending: @escaping @Sendable (UUID) async throws -> Void
    ) {
        self.clearFailedAnalysis = clearFailedAnalysis
        self.processPending = processPending
    }

    func retryFailedAnalysis(documentID: UUID, sourceRootID: UUID) async throws {
        try await clearFailedAnalysis(documentID)
        try Task.checkCancellation()
        try await processPending(sourceRootID)
    }
}
