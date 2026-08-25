import Foundation

public struct DocumentDNAAnalysisReport: Sendable, Equatable {
    public let completed: Int
    public let failed: Int

    public init(completed: Int, failed: Int) {
        self.completed = completed
        self.failed = failed
    }
}

public enum DocumentDNAAnalysisRunFailureReason: String, Sendable, Equatable {
    case pendingQuery
    case persistence
    case staleInput
    case cancelled
}

public struct DocumentDNAAnalysisRunError: Error, Sendable, Equatable {
    public let reason: DocumentDNAAnalysisRunFailureReason
    public let partialReport: DocumentDNAAnalysisReport

    public init(
        reason: DocumentDNAAnalysisRunFailureReason,
        partialReport: DocumentDNAAnalysisReport
    ) {
        self.reason = reason
        self.partialReport = partialReport
    }
}

public actor DocumentDNAAnalysisPipeline {
    private static let coordinator = DocumentDNAAnalysisRunCoordinator()

    private let analyzer: any DocumentDNAAnalyzing
    private let target: DocumentDNAAnalysisTarget
    private let now: @Sendable () -> Date
    private let coordinationEvent: @Sendable (DocumentDNAAnalysisCoordinationEvent) -> Void
    private let pendingAnalysis: @Sendable (
        UUID,
        DocumentDNAAnalysisTarget,
        Int
    ) async throws -> [PendingDocumentDNAAnalysis]
    private let recoverInterruptedAnalysis: @Sendable (UUID) async throws -> Void
    private let beginAnalysis: @Sendable (
        PendingDocumentDNAAnalysis,
        DocumentDNAAnalysisTarget,
        Date
    ) async throws -> Void
    private let markAnalysisFailed: @Sendable (
        PendingDocumentDNAAnalysis,
        DocumentDNAAnalysisTarget,
        DocumentDNAAnalysisFailureCode,
        Date
    ) async throws -> Void
    private let restoreAnalysisAfterInterruption: @Sendable (
        PendingDocumentDNAAnalysis,
        DocumentDNAAnalysisTarget
    ) async throws -> Void
    private let replace: @Sendable (DocumentDNA) async throws -> Void
    // Internal test checkpoint; the public initializer installs a no-op.
    private let postAnalysis: @Sendable (DocumentDNA) async -> Void

    public init(
        repository: DocumentDNARepository,
        analyzer: any DocumentDNAAnalyzing,
        target: DocumentDNAAnalysisTarget,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.analyzer = analyzer
        self.target = target
        self.now = now
        coordinationEvent = { _ in }
        pendingAnalysis = { sourceRootID, target, limit in
            try await repository.pendingAnalysis(
                sourceRootID: sourceRootID,
                target: target,
                limit: limit
            )
        }
        recoverInterruptedAnalysis = { sourceRootID in
            try await repository.recoverInterruptedAnalysis(sourceRootID: sourceRootID)
        }
        beginAnalysis = { candidate, target, date in
            try await repository.beginAnalysis(candidate, target: target, at: date)
        }
        markAnalysisFailed = { candidate, target, failureCode, date in
            try await repository.markAnalysisFailed(
                candidate,
                target: target,
                failureCode: failureCode,
                at: date
            )
        }
        restoreAnalysisAfterInterruption = { candidate, target in
            try await repository.restoreAnalysisAfterInterruption(candidate, target: target)
        }
        replace = { snapshot in
            try await repository.replace(snapshot)
        }
        postAnalysis = { _ in }
    }

    init(
        analyzer: any DocumentDNAAnalyzing,
        target: DocumentDNAAnalysisTarget,
        now: @escaping @Sendable () -> Date,
        pendingAnalysis: @escaping @Sendable (
            UUID,
            DocumentDNAAnalysisTarget,
            Int
        ) async throws -> [PendingDocumentDNAAnalysis],
        recoverInterruptedAnalysis: @escaping @Sendable (UUID) async throws -> Void,
        beginAnalysis: @escaping @Sendable (
            PendingDocumentDNAAnalysis,
            DocumentDNAAnalysisTarget,
            Date
        ) async throws -> Void,
        markAnalysisFailed: @escaping @Sendable (
            PendingDocumentDNAAnalysis,
            DocumentDNAAnalysisTarget,
            DocumentDNAAnalysisFailureCode,
            Date
        ) async throws -> Void,
        restoreAnalysisAfterInterruption: @escaping @Sendable (
            PendingDocumentDNAAnalysis,
            DocumentDNAAnalysisTarget
        ) async throws -> Void,
        replace: @escaping @Sendable (DocumentDNA) async throws -> Void,
        postAnalysis: @escaping @Sendable (DocumentDNA) async -> Void = { _ in },
        coordinationEvent: @escaping @Sendable (
            DocumentDNAAnalysisCoordinationEvent
        ) -> Void = { _ in }
    ) {
        self.analyzer = analyzer
        self.target = target
        self.now = now
        self.coordinationEvent = coordinationEvent
        self.pendingAnalysis = pendingAnalysis
        self.recoverInterruptedAnalysis = recoverInterruptedAnalysis
        self.beginAnalysis = beginAnalysis
        self.markAnalysisFailed = markAnalysisFailed
        self.restoreAnalysisAfterInterruption = restoreAnalysisAfterInterruption
        self.replace = replace
        self.postAnalysis = postAnalysis
    }

    public func processPending(
        sourceRootID: UUID,
        limit: Int = 2
    ) async throws -> DocumentDNAAnalysisReport {
        let emptyReport = DocumentDNAAnalysisReport(completed: 0, failed: 0)
        guard limit > 0 else { return emptyReport }

        do {
            try await Self.coordinator.acquire(
                sourceRootID: sourceRootID,
                onEvent: coordinationEvent
            )
        } catch {
            throw DocumentDNAAnalysisRunError(reason: .cancelled, partialReport: emptyReport)
        }
        do {
            let report = try await processPendingExclusively(
                sourceRootID: sourceRootID,
                limit: limit
            )
            await Self.coordinator.release(sourceRootID: sourceRootID)
            return report
        } catch {
            await Self.coordinator.release(sourceRootID: sourceRootID)
            throw error
        }
    }

    private func processPendingExclusively(
        sourceRootID: UUID,
        limit: Int
    ) async throws -> DocumentDNAAnalysisReport {
        let emptyReport = DocumentDNAAnalysisReport(completed: 0, failed: 0)

        do {
            try await recoverInterruptedAnalysis(sourceRootID)
        } catch is CancellationError {
            throw DocumentDNAAnalysisRunError(reason: .cancelled, partialReport: emptyReport)
        } catch {
            throw DocumentDNAAnalysisRunError(reason: .persistence, partialReport: emptyReport)
        }

        var completed = 0
        var failed = 0
        var batch: [PendingDocumentDNAAnalysis]
        do {
            batch = try await pendingAnalysis(sourceRootID, target, limit)
        } catch is CancellationError {
            throw DocumentDNAAnalysisRunError(reason: .cancelled, partialReport: emptyReport)
        } catch {
            throw DocumentDNAAnalysisRunError(reason: .pendingQuery, partialReport: emptyReport)
        }
        while !batch.isEmpty {
            let batchResult = await Self.processBatch(
                batch,
                analyzer: analyzer,
                target: target,
                now: now,
                beginAnalysis: beginAnalysis,
                markAnalysisFailed: markAnalysisFailed,
                restoreAnalysisAfterInterruption: restoreAnalysisAfterInterruption,
                replace: replace,
                postAnalysis: postAnalysis
            )
            completed += batchResult.report.completed
            failed += batchResult.report.failed
            if let failureReason = batchResult.failureReason {
                throw DocumentDNAAnalysisRunError(
                    reason: failureReason,
                    partialReport: DocumentDNAAnalysisReport(completed: completed, failed: failed)
                )
            }
            do {
                batch = try await pendingAnalysis(sourceRootID, target, limit)
            } catch is CancellationError {
                throw DocumentDNAAnalysisRunError(
                    reason: .cancelled,
                    partialReport: DocumentDNAAnalysisReport(
                        completed: completed,
                        failed: failed
                    )
                )
            } catch {
                throw DocumentDNAAnalysisRunError(
                    reason: .pendingQuery,
                    partialReport: DocumentDNAAnalysisReport(
                        completed: completed,
                        failed: failed
                    )
                )
            }
        }
        return DocumentDNAAnalysisReport(completed: completed, failed: failed)
    }

    private static func processBatch(
        _ batch: [PendingDocumentDNAAnalysis],
        analyzer: any DocumentDNAAnalyzing,
        target: DocumentDNAAnalysisTarget,
        now: @escaping @Sendable () -> Date,
        beginAnalysis: @escaping @Sendable (
            PendingDocumentDNAAnalysis,
            DocumentDNAAnalysisTarget,
            Date
        ) async throws -> Void,
        markAnalysisFailed: @escaping @Sendable (
            PendingDocumentDNAAnalysis,
            DocumentDNAAnalysisTarget,
            DocumentDNAAnalysisFailureCode,
            Date
        ) async throws -> Void,
        restoreAnalysisAfterInterruption: @escaping @Sendable (
            PendingDocumentDNAAnalysis,
            DocumentDNAAnalysisTarget
        ) async throws -> Void,
        replace: @escaping @Sendable (DocumentDNA) async throws -> Void,
        postAnalysis: @escaping @Sendable (DocumentDNA) async -> Void
    ) async -> DocumentDNABatchResult {
        await withTaskGroup(of: DocumentDNAProcessingOutcome.self) { group in
            for candidate in batch {
                group.addTask {
                    var didBegin = false
                    do {
                        let analyzedAt = now()
                        try Task.checkCancellation()
                        try await beginAnalysis(candidate, target, analyzedAt)
                        didBegin = true
                        try Task.checkCancellation()
                        let snapshot: DocumentDNA
                        do {
                            snapshot = try analyzer.analyze(
                                documentID: candidate.document.id,
                                contentHash: candidate.document.contentHash,
                                extraction: candidate.extraction,
                                analyzedAt: analyzedAt
                            )
                        } catch {
                            try Task.checkCancellation()
                            return await markFailure(
                                failureCode(forAnalyzerError: error),
                                candidate: candidate,
                                target: target,
                                at: analyzedAt,
                                markAnalysisFailed: markAnalysisFailed,
                                restoreAnalysisAfterInterruption:
                                    restoreAnalysisAfterInterruption
                            )
                        }
                        await postAnalysis(snapshot)
                        try Task.checkCancellation()
                        guard matchesExpectedIdentity(
                            snapshot,
                            candidate: candidate,
                            target: target
                        ) else {
                            return await markFailure(
                                .analysisFailure,
                                candidate: candidate,
                                target: target,
                                at: analyzedAt,
                                markAnalysisFailed: markAnalysisFailed,
                                restoreAnalysisAfterInterruption:
                                    restoreAnalysisAfterInterruption
                            )
                        }
                        try Task.checkCancellation()
                        do {
                            try await replace(snapshot)
                        } catch DocumentDNARepositoryError.invalidProvenance {
                            return await markFailure(
                                .invalidProvenance,
                                candidate: candidate,
                                target: target,
                                at: analyzedAt,
                                markAnalysisFailed: markAnalysisFailed,
                                restoreAnalysisAfterInterruption:
                                    restoreAnalysisAfterInterruption
                            )
                        }
                        return .completed
                    } catch is CancellationError {
                        guard didBegin else { return .runFailure(.cancelled) }
                        return await restoreAfterCancellation(
                            candidate,
                            target: target,
                            restoreAnalysisAfterInterruption:
                                restoreAnalysisAfterInterruption
                        )
                    } catch DocumentDNARepositoryError.staleInput {
                        return .runFailure(.staleInput)
                    } catch {
                        return .runFailure(.persistence)
                    }
                }
            }

            var completed = 0
            var failed = 0
            var failureReasons: [DocumentDNAAnalysisRunFailureReason] = []
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
            let priority: [DocumentDNAAnalysisRunFailureReason] = [
                .persistence,
                .staleInput,
                .cancelled,
            ]
            return DocumentDNABatchResult(
                report: DocumentDNAAnalysisReport(completed: completed, failed: failed),
                failureReason: priority.first(where: failureReasons.contains)
            )
        }
    }

    private static func matchesExpectedIdentity(
        _ snapshot: DocumentDNA,
        candidate: PendingDocumentDNAAnalysis,
        target: DocumentDNAAnalysisTarget
    ) -> Bool {
        snapshot.documentID == candidate.document.id
            && snapshot.schemaVersion == target.schemaVersion
            && snapshot.analyzerIdentifier == target.analyzerIdentifier
            && snapshot.analyzerVersion == target.analyzerVersion
            && snapshot.inputContentHash == candidate.document.contentHash
            && snapshot.inputExtractionVersion == candidate.extraction.analysisVersion
    }

    private static func markFailure(
        _ failureCode: DocumentDNAAnalysisFailureCode,
        candidate: PendingDocumentDNAAnalysis,
        target: DocumentDNAAnalysisTarget,
        at date: Date,
        markAnalysisFailed: @escaping @Sendable (
            PendingDocumentDNAAnalysis,
            DocumentDNAAnalysisTarget,
            DocumentDNAAnalysisFailureCode,
            Date
        ) async throws -> Void,
        restoreAnalysisAfterInterruption: @escaping @Sendable (
            PendingDocumentDNAAnalysis,
            DocumentDNAAnalysisTarget
        ) async throws -> Void
    ) async -> DocumentDNAProcessingOutcome {
        do {
            try await markAnalysisFailed(candidate, target, failureCode, date)
            return .failed
        } catch is CancellationError {
            return await restoreAfterCancellation(
                candidate,
                target: target,
                restoreAnalysisAfterInterruption: restoreAnalysisAfterInterruption
            )
        } catch DocumentDNARepositoryError.staleInput {
            return .runFailure(.staleInput)
        } catch {
            return .runFailure(.persistence)
        }
    }

    private static func restoreAfterCancellation(
        _ candidate: PendingDocumentDNAAnalysis,
        target: DocumentDNAAnalysisTarget,
        restoreAnalysisAfterInterruption: @escaping @Sendable (
            PendingDocumentDNAAnalysis,
            DocumentDNAAnalysisTarget
        ) async throws -> Void
    ) async -> DocumentDNAProcessingOutcome {
        let restored = await Task {
            do {
                try await restoreAnalysisAfterInterruption(candidate, target)
                return true
            } catch {
                return false
            }
        }.value
        return .runFailure(restored ? .cancelled : .persistence)
    }

    private static func failureCode(
        forAnalyzerError error: Error
    ) -> DocumentDNAAnalysisFailureCode {
        error is DocumentDNAValidationError ? .invalidFinding : .analysisFailure
    }
}

private enum DocumentDNAProcessingOutcome: Sendable {
    case completed
    case failed
    case runFailure(DocumentDNAAnalysisRunFailureReason)
}

private struct DocumentDNABatchResult: Sendable {
    let report: DocumentDNAAnalysisReport
    let failureReason: DocumentDNAAnalysisRunFailureReason?
}

enum DocumentDNAAnalysisCoordinationEvent: Sendable, Equatable {
    case acquired
    case waiterRegistered
    case waiterCancelled
}

private actor DocumentDNAAnalysisRunCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
        let onEvent: @Sendable (DocumentDNAAnalysisCoordinationEvent) -> Void
    }

    private var activeSourceRootIDs = Set<UUID>()
    private var waiters: [UUID: [Waiter]] = [:]

    func acquire(
        sourceRootID: UUID,
        onEvent: @escaping @Sendable (DocumentDNAAnalysisCoordinationEvent) -> Void
    ) async throws {
        try Task.checkCancellation()
        if activeSourceRootIDs.insert(sourceRootID).inserted {
            onEvent(.acquired)
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
                        continuation: continuation,
                        onEvent: onEvent
                    ))
                    onEvent(.waiterRegistered)
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
        next.onEvent(.acquired)
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
        waiter.onEvent(.waiterCancelled)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
