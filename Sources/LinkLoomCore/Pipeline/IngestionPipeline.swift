import Foundation

public struct IngestionReport: Sendable, Equatable {
    public let completed: Int
    public let failed: Int

    public init(completed: Int, failed: Int) {
        self.completed = completed
        self.failed = failed
    }
}

public actor IngestionPipeline {
    public static let analysisVersion = "text-v1"
    private static let coordinator = IngestionRunCoordinator()

    private let sourceAccess: any SourceAccessing
    private let documents: DocumentRepository
    private let extractions: ExtractionRepository
    private let extractor: any DocumentTextExtracting
    private let currentAnalysisVersion: String
    private let pendingDocuments: @Sendable (UUID, String, Int) async throws -> [DocumentRecord]

    public init(
        sourceAccess: any SourceAccessing,
        documents: DocumentRepository,
        extractions: ExtractionRepository,
        extractor: any DocumentTextExtracting
    ) {
        self.sourceAccess = sourceAccess
        self.documents = documents
        self.extractions = extractions
        self.extractor = extractor
        currentAnalysisVersion = Self.analysisVersion
        pendingDocuments = { sourceRootID, analysisVersion, limit in
            try await documents.pendingExtraction(
                sourceRootID: sourceRootID,
                analysisVersion: analysisVersion,
                limit: limit
            )
        }
    }

    init(
        sourceAccess: any SourceAccessing,
        documents: DocumentRepository,
        extractions: ExtractionRepository,
        extractor: any DocumentTextExtracting,
        analysisVersion: String
    ) {
        self.sourceAccess = sourceAccess
        self.documents = documents
        self.extractions = extractions
        self.extractor = extractor
        currentAnalysisVersion = analysisVersion
        pendingDocuments = { sourceRootID, analysisVersion, limit in
            try await documents.pendingExtraction(
                sourceRootID: sourceRootID,
                analysisVersion: analysisVersion,
                limit: limit
            )
        }
    }

    init(
        sourceAccess: any SourceAccessing,
        documents: DocumentRepository,
        extractions: ExtractionRepository,
        extractor: any DocumentTextExtracting,
        analysisVersion: String,
        pendingDocuments: @escaping @Sendable (UUID, String, Int) async throws -> [DocumentRecord]
    ) {
        self.sourceAccess = sourceAccess
        self.documents = documents
        self.extractions = extractions
        self.extractor = extractor
        currentAnalysisVersion = analysisVersion
        self.pendingDocuments = pendingDocuments
    }

    public func processPending(
        source: SourceRootRecord,
        limit: Int = 2
    ) async -> IngestionReport {
        guard limit > 0 else {
            return IngestionReport(completed: 0, failed: 0)
        }
        do {
            try await Self.coordinator.acquire(sourceRootID: source.id)
        } catch {
            return IngestionReport(completed: 0, failed: 0)
        }
        let report = await processPendingExclusively(source: source, limit: limit)
        await Self.coordinator.release(sourceRootID: source.id)
        return report
    }

    private func processPendingExclusively(
        source: SourceRootRecord,
        limit: Int
    ) async -> IngestionReport {
        let pending: [DocumentRecord]
        do {
            try await documents.recoverInterruptedExtraction(sourceRootID: source.id)
            pending = try await pendingDocuments(source.id, currentAnalysisVersion, limit)
        } catch {
            return IngestionReport(completed: 0, failed: 0)
        }
        guard !pending.isEmpty else {
            return IngestionReport(completed: 0, failed: 0)
        }
        let documents = self.documents
        let extractions = self.extractions
        let extractor = self.extractor
        let analysisVersion = currentAnalysisVersion

        do {
            return try await sourceAccess.withAccess(to: source.bookmarkData) { rootURL in
                var batch = pending
                var completed = 0
                var failed = 0
                while !batch.isEmpty {
                    let batchResult = await withTaskGroup(of: ProcessingOutcome.self) { group in
                        for document in batch {
                            group.addTask {
                                do {
                                    try await documents.markStatus(
                                        id: document.id,
                                        status: .extracting
                                    )
                                    try Task.checkCancellation()
                                    let documentURL = try Self.resolvedDocumentURL(
                                        relativePath: document.relativePath,
                                        rootURL: rootURL
                                    )
                                    let extraction = try await extractor.extract(
                                        from: documentURL,
                                        mediaType: document.mediaType
                                    )
                                    try Task.checkCancellation()
                                    try await extractions.complete(
                                        documentID: document.id,
                                        expectedContentHash: document.contentHash,
                                        analysisVersion: analysisVersion,
                                        extraction: extraction,
                                        at: .now
                                    )
                                    return .completed
                                } catch is CancellationError {
                                    let restored = await Task {
                                        do {
                                            try await documents.restoreAfterInterruption(document)
                                            return true
                                        } catch {
                                            return false
                                        }
                                    }.value
                                    return restored ? .cancelled : .deferred
                                } catch ExtractionPersistenceError.staleDocument {
                                    return .deferred
                                } catch {
                                    do {
                                        try await documents.markStatus(
                                            id: document.id,
                                            status: .failed,
                                            failureCode: Self.failureCode(for: error)
                                        )
                                        return .failed
                                    } catch {
                                        return .deferred
                                    }
                                }
                            }
                        }
                        var completed = 0
                        var failed = 0
                        var interrupted = false
                        for await outcome in group {
                            switch outcome {
                            case .completed:
                                completed += 1
                            case .failed:
                                failed += 1
                            case .cancelled, .deferred:
                                interrupted = true
                            }
                        }
                        return BatchResult(
                            report: IngestionReport(completed: completed, failed: failed),
                            interrupted: interrupted
                        )
                    }
                    completed += batchResult.report.completed
                    failed += batchResult.report.failed
                    if batchResult.interrupted || Task.isCancelled {
                        return IngestionReport(completed: completed, failed: failed)
                    }
                    do {
                        batch = try await pendingDocuments(source.id, analysisVersion, limit)
                    } catch {
                        return IngestionReport(completed: completed, failed: failed)
                    }
                }
                return IngestionReport(completed: completed, failed: failed)
            }
        } catch {
            return IngestionReport(completed: 0, failed: 0)
        }
    }

    private static func failureCode(for error: Error) -> String {
        switch error {
        case IngestionPipelineError.outsideSourceRoot:
            "outsideSourceRoot"
        case TextExtractionError.unsupportedMedia:
            "unsupportedMedia"
        case TextExtractionError.unreadableDocument:
            "unreadableDocument"
        case TextExtractionError.passwordProtected:
            "passwordProtected"
        case TextExtractionError.insufficientEmbeddedText:
            "insufficientEmbeddedText"
        case TextExtractionError.noRecognizedText:
            "noRecognizedText"
        case is CancellationError:
            "cancelled"
        default:
            "ingestionFailure"
        }
    }

    private static func resolvedDocumentURL(
        relativePath: String,
        rootURL: URL
    ) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !NSString(string: relativePath).isAbsolutePath,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw IngestionPipelineError.outsideSourceRoot
        }
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDocument = resolvedRoot
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootComponents = resolvedRoot.pathComponents
        let documentComponents = resolvedDocument.pathComponents
        guard documentComponents.count > rootComponents.count,
              Array(documentComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw IngestionPipelineError.outsideSourceRoot
        }
        return resolvedDocument
    }
}

private enum IngestionPipelineError: Error {
    case outsideSourceRoot
}

private enum ProcessingOutcome: Sendable {
    case completed
    case failed
    case cancelled
    case deferred
}

private struct BatchResult: Sendable {
    let report: IngestionReport
    let interrupted: Bool
}

private actor IngestionRunCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var activeSourceRootIDs = Set<UUID>()
    private var waiters: [UUID: [Waiter]] = [:]

    func acquire(sourceRootID: UUID) async throws {
        try Task.checkCancellation()
        if activeSourceRootIDs.insert(sourceRootID).inserted {
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[sourceRootID, default: []].append(Waiter(
                        id: waiterID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID, sourceRootID: sourceRootID)
            }
        }
    }

    func release(sourceRootID: UUID) {
        guard var sourceWaiters = waiters[sourceRootID], !sourceWaiters.isEmpty else {
            activeSourceRootIDs.remove(sourceRootID)
            waiters[sourceRootID] = nil
            return
        }
        let next = sourceWaiters.removeFirst()
        waiters[sourceRootID] = sourceWaiters.isEmpty ? nil : sourceWaiters
        next.continuation.resume()
    }

    private func cancelWaiter(id: UUID, sourceRootID: UUID) {
        guard var sourceWaiters = waiters[sourceRootID],
              let index = sourceWaiters.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let waiter = sourceWaiters.remove(at: index)
        waiters[sourceRootID] = sourceWaiters.isEmpty ? nil : sourceWaiters
        waiter.continuation.resume(throwing: CancellationError())
    }
}
