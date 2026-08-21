import AppKit
import LinkLoomAppFeature
import LinkLoomCore
import OSLog
import SwiftUI

@main
@MainActor
struct LinkLoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var startup: AppStartupController

    private static let startupLogger = Logger(
        subsystem: "LinkLoom",
        category: "startup"
    )
    private static let runtimeLogger = Logger(
        subsystem: "LinkLoom",
        category: "runtime"
    )

    init() {
        _startup = StateObject(wrappedValue: AppStartupController(
            makeModel: { try Self.makeModel() },
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
        case .ready:
            if let model = startup.model {
                ContentView(model: model)
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
            }
            .frame(minWidth: 520, minHeight: 320)
        }
    }

    private static func makeModel() throws -> AppModel {
        let sourceAccess = DefaultSourceAccess()
        let database = try AppDatabase.makeQueue(at: databaseURL())
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
        let watchScheduler = RescanScheduler(
            watcher: FSEventsDirectoryWatcher(),
            rescanner: IncrementalRescanner(
                catalog: catalog,
                ingestion: ingestion
            )
        )
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
