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
        let pickerDiagnosticURL = configuration?.databaseURL?
            .deletingLastPathComponent()
            .appendingPathComponent("picker-diagnostic.txt")
        folderPicker = FolderPicker(selectFolders: {
            let urls = configuration?.sourceURL.map { [$0] } ?? []
            let message = "picker invoked: count=\(urls.count) "
                + "path=\(urls.first?.path ?? "none")"
            if let pickerDiagnosticURL {
                try? Data(message.utf8).write(to: pickerDiagnosticURL, options: .atomic)
            }
            return urls
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
#if LINKLOOM_UI_TESTING
        let sourceAccess: any SourceAccessing = UITestDiagnosticSourceAccess(
            diagnosticURL: resolvedDatabaseURL
                .deletingLastPathComponent()
                .appendingPathComponent("source-access-diagnostic.txt")
        )
#else
        let sourceAccess: any SourceAccessing = DefaultSourceAccess()
#endif
        let database = try AppDatabase.makeQueue(at: resolvedDatabaseURL)
        let sources = SourceRootRepository(dbWriter: database)
        let documents = DocumentRepository(dbWriter: database)
        let extractions = ExtractionRepository(dbWriter: database)
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
        let watchScheduler: (any SourceWatchScheduling)?
        if disablesWatcher {
            watchScheduler = nil
        } else {
            watchScheduler = RescanScheduler(
                watcher: FSEventsDirectoryWatcher(),
                rescanner: IncrementalRescanner(
                    catalog: catalog,
                    ingestion: ingestion
                )
            )
        }
        return AppModel(
            sources: sources,
            documents: documents,
            sourceAccess: sourceAccess,
            catalog: CatalogScanner(service: catalog),
            ingestion: PendingIngester(pipeline: ingestion),
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

private struct UITestDiagnosticSourceAccess: SourceAccessing {
    private let base = DefaultSourceAccess()
    private let diagnosticURL: URL

    init(diagnosticURL: URL) {
        self.diagnosticURL = diagnosticURL
    }

    func createBookmark(for url: URL) throws -> Data {
        do {
            let bookmark = try base.createBookmark(for: url)
            record("createBookmark succeeded: bytes=\(bookmark.count)")
            return bookmark
        } catch {
            let nsError = error as NSError
            record(
                "createBookmark failed: domain=\(nsError.domain) "
                    + "code=\(nsError.code) description=\(nsError.localizedDescription)"
            )
            throw error
        }
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        try base.resolve(bookmark)
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await base.withAccess(to: bookmark, operation: operation)
    }

    private func record(_ message: String) {
        try? Data(message.utf8).write(to: diagnosticURL, options: .atomic)
    }
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

private struct IncrementalRescanner: SourceRescanning {
    let catalog: CatalogService
    let ingestion: IngestionPipeline

    func rescan(source: SourceRootRecord) async throws {
        _ = try await catalog.scan(source: source)
        _ = try await ingestion.processPending(source: source)
    }
}

private struct CatalogScanner: CatalogScanning {
    let service: CatalogService

    func scan(source: SourceRootRecord) async throws {
        _ = try await service.scan(source: source)
    }
}

private struct PendingIngester: PendingIngesting {
    let pipeline: IngestionPipeline

    func processPending(source: SourceRootRecord) async throws {
        _ = try await pipeline.processPending(source: source)
    }
}
