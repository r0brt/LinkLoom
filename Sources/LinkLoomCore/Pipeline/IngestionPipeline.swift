import Foundation

public struct IngestionReport: Sendable, Equatable {
    public let completed: Int
    public let failed: Int

    public init(completed: Int, failed: Int) {
        self.completed = completed
        self.failed = failed
    }
}

public enum IngestionRunFailureReason: String, Sendable, Equatable {
    case cancelled
    case sourceAccess
    case pendingQuery
    case persistence
    case staleDocument
}

public struct IngestionRunError: Error, Sendable, Equatable {
    public let reason: IngestionRunFailureReason
    public let partialReport: IngestionReport

    public init(
        reason: IngestionRunFailureReason,
        partialReport: IngestionReport
    ) {
        self.reason = reason
        self.partialReport = partialReport
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
    ) async throws -> IngestionReport {
        let emptyReport = IngestionReport(completed: 0, failed: 0)
        guard limit > 0 else { return emptyReport }
        do {
            try await Self.coordinator.acquire(sourceRootID: source.id)
        } catch {
            throw IngestionRunError(reason: .cancelled, partialReport: emptyReport)
        }
        do {
            let report = try await processPendingExclusively(source: source, limit: limit)
            await Self.coordinator.release(sourceRootID: source.id)
            return report
        } catch {
            await Self.coordinator.release(sourceRootID: source.id)
            throw error
        }
    }

    private func processPendingExclusively(
        source: SourceRootRecord,
        limit: Int
    ) async throws -> IngestionReport {
        let emptyReport = IngestionReport(completed: 0, failed: 0)
        do {
            try await documents.recoverInterruptedExtraction(sourceRootID: source.id)
        } catch is CancellationError {
            throw IngestionRunError(reason: .cancelled, partialReport: emptyReport)
        } catch {
            throw IngestionRunError(reason: .persistence, partialReport: emptyReport)
        }
        let initialBatch: [DocumentRecord]
        do {
            initialBatch = try await pendingDocuments(source.id, currentAnalysisVersion, limit)
        } catch is CancellationError {
            throw IngestionRunError(reason: .cancelled, partialReport: emptyReport)
        } catch {
            throw IngestionRunError(reason: .pendingQuery, partialReport: emptyReport)
        }
        guard !initialBatch.isEmpty else { return emptyReport }
        let documents = self.documents
        let extractions = self.extractions
        let extractor = self.extractor
        let analysisVersion = currentAnalysisVersion
        let pendingDocuments = self.pendingDocuments
        let runReport = IngestionRunReport()

        do {
            return try await sourceAccess.withAccess(to: source.bookmarkData) { rootURL in
                var batch = initialBatch
                var completed = 0
                var failed = 0
                while !batch.isEmpty {
                    let batchResult = await Self.processBatch(
                        batch,
                        rootURL: rootURL,
                        documents: documents,
                        extractions: extractions,
                        extractor: extractor,
                        analysisVersion: analysisVersion
                    )
                    completed += batchResult.report.completed
                    failed += batchResult.report.failed
                    let report = IngestionReport(completed: completed, failed: failed)
                    await runReport.update(report)
                    if let failureReason = batchResult.failureReason {
                        throw IngestionRunError(
                            reason: failureReason,
                            partialReport: report
                        )
                    }
                    if Task.isCancelled {
                        throw IngestionRunError(reason: .cancelled, partialReport: report)
                    }
                    do {
                        batch = try await pendingDocuments(source.id, analysisVersion, limit)
                    } catch is CancellationError {
                        throw IngestionRunError(reason: .cancelled, partialReport: report)
                    } catch {
                        throw IngestionRunError(reason: .pendingQuery, partialReport: report)
                    }
                }
                return IngestionReport(completed: completed, failed: failed)
            }
        } catch let error as IngestionRunError {
            throw error
        } catch is CancellationError {
            throw IngestionRunError(
                reason: .cancelled,
                partialReport: await runReport.value
            )
        } catch {
            throw IngestionRunError(
                reason: .sourceAccess,
                partialReport: await runReport.value
            )
        }
    }

    private static func processBatch(
        _ batch: [DocumentRecord],
        rootURL: URL,
        documents: DocumentRepository,
        extractions: ExtractionRepository,
        extractor: any DocumentTextExtracting,
        analysisVersion: String
    ) async -> BatchResult {
        await withTaskGroup(of: ProcessingOutcome.self) { group in
            for document in batch {
                group.addTask {
                    await processDocument(
                        document,
                        rootURL: rootURL,
                        documents: documents,
                        extractions: extractions,
                        extractor: extractor,
                        analysisVersion: analysisVersion
                    )
                }
            }
            var completed = 0
            var failed = 0
            var failureReasons: [IngestionRunFailureReason] = []
            for await outcome in group {
                switch outcome {
                case .completed:
                    completed += 1
                case .failed:
                    failed += 1
                case let .runFailure(reason):
                    failureReasons.append(reason)
                }
            }
            let priority: [IngestionRunFailureReason] = [
                .persistence,
                .staleDocument,
                .cancelled,
            ]
            return BatchResult(
                report: IngestionReport(completed: completed, failed: failed),
                failureReason: priority.first(where: failureReasons.contains)
            )
        }
    }

    private static func processDocument(
        _ document: DocumentRecord,
        rootURL: URL,
        documents: DocumentRepository,
        extractions: ExtractionRepository,
        extractor: any DocumentTextExtracting,
        analysisVersion: String
    ) async -> ProcessingOutcome {
        do {
            try await documents.markStatus(id: document.id, status: .extracting)
        } catch is CancellationError {
            return await restoreAfterCancellation(document, documents: documents)
        } catch {
            return .runFailure(.persistence)
        }

        let extraction: ExtractedDocument
        do {
            try Task.checkCancellation()
            let documentURL = try resolvedDocumentURL(
                relativePath: document.relativePath,
                rootURL: rootURL
            )
            extraction = try await extractor.extract(
                from: documentURL,
                mediaType: document.mediaType
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            return await restoreAfterCancellation(document, documents: documents)
        } catch {
            do {
                try await documents.markStatus(
                    id: document.id,
                    status: .failed,
                    failureCode: failureCode(for: error)
                )
                return .failed
            } catch is CancellationError {
                return await restoreAfterCancellation(document, documents: documents)
            } catch {
                return .runFailure(.persistence)
            }
        }

        do {
            try await extractions.complete(
                documentID: document.id,
                expectedContentHash: document.contentHash,
                analysisVersion: analysisVersion,
                extraction: extraction,
                at: .now
            )
            return .completed
        } catch is CancellationError {
            return await restoreAfterCancellation(document, documents: documents)
        } catch ExtractionPersistenceError.staleDocument {
            return .runFailure(.staleDocument)
        } catch {
            return .runFailure(.persistence)
        }
    }

    private static func restoreAfterCancellation(
        _ document: DocumentRecord,
        documents: DocumentRepository
    ) async -> ProcessingOutcome {
        let restored = await Task {
            do {
                try await documents.restoreAfterInterruption(document)
                return true
            } catch {
                return false
            }
        }.value
        return restored ? .runFailure(.cancelled) : .runFailure(.persistence)
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
    case runFailure(IngestionRunFailureReason)
}

private struct BatchResult: Sendable {
    let report: IngestionReport
    let failureReason: IngestionRunFailureReason?
}

private actor IngestionRunReport {
    private var report = IngestionReport(completed: 0, failed: 0)

    var value: IngestionReport { report }

    func update(_ report: IngestionReport) {
        self.report = report
    }
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
