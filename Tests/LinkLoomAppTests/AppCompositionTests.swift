import Foundation
import Testing
@testable import LinkLoomApp
import LinkLoomCore

@Suite("App composition")
struct AppCompositionTests {
    @Test func localProcessorRunsTextIngestionBeforeDNAAnalysis() async throws {
        let events = EventRecorder()
        let source = sourceRecord()
        let processor = LocalDocumentProcessor(
            ingest: { source in
                await events.append("ingest:\(source.id)")
            },
            analyzeDNA: { sourceID in
                await events.append("dna:\(sourceID)")
            }
        )

        try await processor.processPending(source: source)

        #expect(await events.snapshot() == [
            "ingest:\(source.id)",
            "dna:\(source.id)",
        ])
    }

    @Test func localProcessorDoesNotAnalyzeWhenTextIngestionFails() async {
        let dnaCalls = CallCounter()
        let processor = LocalDocumentProcessor(
            ingest: { _ in throw CompositionTestError.ingestionFailed },
            analyzeDNA: { _ in await dnaCalls.increment() }
        )

        await #expect(throws: CompositionTestError.ingestionFailed) {
            try await processor.processPending(source: sourceRecord())
        }
        #expect(await dnaCalls.count == 0)
    }

    @Test func localProcessorPropagatesDNAFailure() async {
        let processor = LocalDocumentProcessor(
            ingest: { _ in },
            analyzeDNA: { _ in throw CompositionTestError.dnaFailed }
        )

        await #expect(throws: CompositionTestError.dnaFailed) {
            try await processor.processPending(source: sourceRecord())
        }
    }

    @Test func localProcessorHonorsCancellationBetweenStages() async {
        let dnaCalls = CallCounter()
        let processor = LocalDocumentProcessor(
            ingest: { _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            },
            analyzeDNA: { _ in await dnaCalls.increment() }
        )

        let processing = Task {
            try await processor.processPending(source: sourceRecord())
        }

        await #expect(throws: CancellationError.self) {
            try await processing.value
        }
        #expect(await dnaCalls.count == 0)
    }

    @Test func localDNARetryerClearsExactFailureBeforeProcessingSourceQueue() async throws {
        let events = EventRecorder()
        let documentID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let retryer = LocalDocumentDNAFailureRetryer(
            clearFailedAnalysis: { id in await events.append("clear:\(id)") },
            processPending: { id in await events.append("process:\(id)") }
        )

        try await retryer.retryFailedAnalysis(
            documentID: documentID,
            sourceRootID: sourceID
        )

        #expect(await events.snapshot() == [
            "clear:\(documentID)",
            "process:\(sourceID)",
        ])
    }

    @Test func localDNARetryerDoesNotProcessWhenClearingFailureFails() async {
        let processCalls = CallCounter()
        let retryer = LocalDocumentDNAFailureRetryer(
            clearFailedAnalysis: { _ in throw CompositionTestError.dnaFailed },
            processPending: { _ in await processCalls.increment() }
        )

        await #expect(throws: CompositionTestError.dnaFailed) {
            try await retryer.retryFailedAnalysis(
                documentID: UUID(),
                sourceRootID: UUID()
            )
        }
        #expect(await processCalls.count == 0)
    }

    @Test func localDNARetryerHonorsCancellationBetweenStages() async {
        let processCalls = CallCounter()
        let retryer = LocalDocumentDNAFailureRetryer(
            clearFailedAnalysis: { _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            },
            processPending: { _ in await processCalls.increment() }
        )
        let retry = Task {
            try await retryer.retryFailedAnalysis(
                documentID: UUID(),
                sourceRootID: UUID()
            )
        }

        await #expect(throws: CancellationError.self) {
            try await retry.value
        }
        #expect(await processCalls.count == 0)
    }

    @Test func incrementalRescanRunsCatalogThenTextThenDNA() async throws {
        let events = EventRecorder()
        let source = sourceRecord()
        let processor = LocalDocumentProcessor(
            ingest: { _ in await events.append("ingest") },
            analyzeDNA: { _ in await events.append("dna") }
        )
        let rescanner = IncrementalRescanner(
            scanCatalog: { _ in await events.append("catalog") },
            processDocuments: { source in
                try await processor.processPending(source: source)
            }
        )

        try await rescanner.rescan(source: source)

        #expect(await events.snapshot() == ["catalog", "ingest", "dna"])
    }

    @Test func incrementalRescanHonorsCancellationAfterCatalog() async {
        let documentProcessingCalls = CallCounter()
        let rescanner = IncrementalRescanner(
            scanCatalog: { _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            },
            processDocuments: { _ in
                await documentProcessingCalls.increment()
            }
        )

        let rescanning = Task {
            try await rescanner.rescan(source: sourceRecord())
        }

        await #expect(throws: CancellationError.self) {
            try await rescanning.value
        }
        #expect(await documentProcessingCalls.count == 0)
    }

    @Test func incrementalRescanPropagatesDNAFailure() async {
        let events = EventRecorder()
        let processor = LocalDocumentProcessor(
            ingest: { _ in await events.append("ingest") },
            analyzeDNA: { _ in
                await events.append("dna")
                throw CompositionTestError.dnaFailed
            }
        )
        let rescanner = IncrementalRescanner(
            scanCatalog: { _ in await events.append("catalog") },
            processDocuments: { source in
                try await processor.processPending(source: source)
            }
        )

        await #expect(throws: CompositionTestError.dnaFailed) {
            try await rescanner.rescan(source: sourceRecord())
        }
        #expect(await events.snapshot() == ["catalog", "ingest", "dna"])
    }
}

private enum CompositionTestError: Error {
    case ingestionFailed
    case dnaFailed
}

private actor EventRecorder {
    private var recordedValues: [String] = []

    func append(_ value: String) {
        recordedValues.append(value)
    }

    func snapshot() -> [String] {
        recordedValues
    }
}

private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func sourceRecord() -> SourceRootRecord {
    SourceRootRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        displayName: "Archive",
        pathHint: "/tmp/archive",
        bookmarkData: Data([0x01]),
        createdAt: Date(timeIntervalSince1970: 1)
    )
}
