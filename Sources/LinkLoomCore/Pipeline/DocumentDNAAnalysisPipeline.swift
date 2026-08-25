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
    private let analyzer: any DocumentDNAAnalyzing
    private let target: DocumentDNAAnalysisTarget
    private let now: @Sendable () -> Date
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

    public init(
        repository: DocumentDNARepository,
        analyzer: any DocumentDNAAnalyzing,
        target: DocumentDNAAnalysisTarget,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.analyzer = analyzer
        self.target = target
        self.now = now
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
        replace: @escaping @Sendable (DocumentDNA) async throws -> Void
    ) {
        self.analyzer = analyzer
        self.target = target
        self.now = now
        self.pendingAnalysis = pendingAnalysis
        self.recoverInterruptedAnalysis = recoverInterruptedAnalysis
        self.beginAnalysis = beginAnalysis
        self.markAnalysisFailed = markAnalysisFailed
        self.restoreAnalysisAfterInterruption = restoreAnalysisAfterInterruption
        self.replace = replace
    }

    public func processPending(
        sourceRootID: UUID,
        limit: Int = 2
    ) async throws -> DocumentDNAAnalysisReport {
        let emptyReport = DocumentDNAAnalysisReport(completed: 0, failed: 0)
        guard limit > 0 else { return emptyReport }

        var batch = try await pendingAnalysis(sourceRootID, target, limit)
        var completed = 0
        while !batch.isEmpty {
            let batchResult = await Self.processBatch(
                batch,
                analyzer: analyzer,
                target: target,
                now: now,
                beginAnalysis: beginAnalysis,
                replace: replace
            )
            completed += batchResult.report.completed
            if let failureReason = batchResult.failureReason {
                throw DocumentDNAAnalysisRunError(
                    reason: failureReason,
                    partialReport: DocumentDNAAnalysisReport(completed: completed, failed: 0)
                )
            }
            batch = try await pendingAnalysis(sourceRootID, target, limit)
        }
        return DocumentDNAAnalysisReport(completed: completed, failed: 0)
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
        replace: @escaping @Sendable (DocumentDNA) async throws -> Void
    ) async -> DocumentDNABatchResult {
        await withTaskGroup(of: DocumentDNAProcessingOutcome.self) { group in
            for candidate in batch {
                group.addTask {
                    do {
                        let analyzedAt = now()
                        try await beginAnalysis(candidate, target, analyzedAt)
                        let snapshot = try analyzer.analyze(
                            documentID: candidate.document.id,
                            contentHash: candidate.document.contentHash,
                            extraction: candidate.extraction,
                            analyzedAt: analyzedAt
                        )
                        try Task.checkCancellation()
                        try await replace(snapshot)
                        return .completed
                    } catch is CancellationError {
                        return .runFailure(.cancelled)
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
