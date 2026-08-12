import AppKit
import LinkLoomAppFeature
import LinkLoomCore
import SwiftUI

@main
@MainActor
struct LinkLoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        do {
            let sourceAccess = DefaultSourceAccess()
            let database = try AppDatabase.makeQueue(at: Self.databaseURL())
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
            _model = StateObject(wrappedValue: AppModel(
                sources: sources,
                documents: documents,
                sourceAccess: sourceAccess,
                catalog: CatalogScanner(service: catalog),
                ingestion: PendingIngester(pipeline: ingestion),
                watchScheduler: watchScheduler
            ))
        } catch {
            fatalError("LinkLoom database initialization failed")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    appDelegate.configure(model: model)
                    try? await model.reload()
                }
        }
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
        guard terminationCoordinator == nil else { return }
        terminationCoordinator = AppTerminationCoordinator { [weak model] in
            await model?.stopWatching()
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
        _ = await ingestion.processPending(source: source)
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
        _ = await pipeline.processPending(source: source)
    }
}
