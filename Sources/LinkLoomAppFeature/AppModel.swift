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

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var sources: [SourceRootRecord] = []
    @Published public var selectedSourceID: UUID?
    @Published public private(set) var documents: [DocumentRecord] = []
    @Published public private(set) var scanState: AppScanState = .idle
    @Published public private(set) var lastErrorCode: String?

    private let sourceRepository: SourceRootRepository
    private let documentRepository: DocumentRepository
    private let sourceAccess: any SourceAccessing
    private let catalog: any CatalogScanning
    private let ingestion: any PendingIngesting
    private let documentLoader: @Sendable (UUID) async throws -> [DocumentRecord]
    private var isExclusiveSourceOperationActive = false

    public init(
        sources: SourceRootRepository,
        documents: DocumentRepository,
        sourceAccess: any SourceAccessing,
        catalog: any CatalogScanning,
        ingestion: any PendingIngesting
    ) {
        sourceRepository = sources
        documentRepository = documents
        self.sourceAccess = sourceAccess
        self.catalog = catalog
        self.ingestion = ingestion
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
        documentLoader: @escaping @Sendable (UUID) async throws -> [DocumentRecord]
    ) {
        sourceRepository = sources
        documentRepository = documents
        self.sourceAccess = sourceAccess
        self.catalog = catalog
        self.ingestion = ingestion
        self.documentLoader = documentLoader
    }

    public func reload() async throws {
        sources = try await sourceRepository.all()
        if !sources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = sources.first?.id
        }
        _ = try await reloadDocuments()
    }

    public func addSource(_ url: URL) async {
        guard beginExclusiveSourceOperation() else { return }
        defer { endExclusiveSourceOperation() }
        do {
            let source = try await sourceRepository.add(
                url: url,
                sourceAccess: sourceAccess
            )
            sources = try await sourceRepository.all()
            selectedSourceID = source.id
            documents = try await documentRepository.all(sourceRootID: source.id)
            lastErrorCode = nil
        } catch {
            lastErrorCode = "sourceAddFailure"
        }
    }

    public func scanSelectedSource() async {
        guard beginExclusiveSourceOperation() else { return }
        defer { endExclusiveSourceOperation() }
        guard let source = sources.first(where: { $0.id == selectedSourceID }) else {
            return
        }
        lastErrorCode = nil
        scanState = .scanning
        defer { scanState = .idle }
        do {
            try await catalog.scan(source: source)
            scanState = .extracting
            try await ingestion.processPending(source: source)
            sources = try await sourceRepository.all()
            _ = try await reloadDocuments()
        } catch {
            lastErrorCode = "scanFailure"
        }
    }

    public func removeSource(_ source: SourceRootRecord) async {
        guard beginExclusiveSourceOperation() else { return }
        defer { endExclusiveSourceOperation() }
        do {
            try await sourceRepository.remove(id: source.id)
            sources = try await sourceRepository.all()
            if selectedSourceID == source.id {
                selectedSourceID = sources.first?.id
            }
            _ = try await reloadDocuments()
            lastErrorCode = nil
        } catch {
            lastErrorCode = "sourceRemoveFailure"
        }
    }

    public func selectSource(id: UUID?) async {
        guard !isExclusiveSourceOperationActive else { return }
        selectedSourceID = id
        do {
            if try await reloadDocuments() {
                lastErrorCode = nil
            }
        } catch {
            lastErrorCode = "documentLoadFailure"
        }
    }

    private func reloadDocuments() async throws -> Bool {
        guard let selectedSourceID else {
            documents = []
            return true
        }
        do {
            let loadedDocuments = try await documentLoader(selectedSourceID)
            guard self.selectedSourceID == selectedSourceID else { return false }
            documents = loadedDocuments
            return true
        } catch {
            guard self.selectedSourceID == selectedSourceID else { return false }
            throw error
        }
    }

    private func beginExclusiveSourceOperation() -> Bool {
        guard !isExclusiveSourceOperationActive else { return false }
        isExclusiveSourceOperationActive = true
        return true
    }

    private func endExclusiveSourceOperation() {
        isExclusiveSourceOperationActive = false
    }
}
