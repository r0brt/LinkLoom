import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Persisted ingestion pipeline")
struct IngestionPipelineTests {
    @Test func defaultLimitBoundsConcurrencyWithoutTruncatingPendingWork() async throws {
        let fixture = try await IngestionFixture.make(extractionDelay: .milliseconds(20))

        let report = try await fixture.pipeline.processPending(source: fixture.source)

        #expect(report == IngestionReport(completed: 2, failed: 1))
        #expect(await fixture.extractor.callCount == 3)
        #expect(await fixture.extractor.maximumConcurrentCallCount == 2)
    }

    @Test func overlappingRunsExtractEachDocumentOnlyOnce() async throws {
        let fixture = try await IngestionFixture.make(extractionDelay: .milliseconds(20))
        let gate = ConcurrentPipelineStartGate(expectedArrivals: 2)
        let pipeline = fixture.pipeline
        let source = fixture.source
        let first = Task {
            await gate.waitUntilReleased()
            return try await pipeline.processPending(source: source)
        }
        let second = Task {
            await gate.waitUntilReleased()
            return try await pipeline.processPending(source: source)
        }
        await gate.waitUntilAllArrived()

        await gate.release()
        _ = try await first.value
        _ = try await second.value

        #expect(await fixture.extractor.callCount == 3)
    }

    @Test func overlappingPipelineInstancesExtractEachDocumentOnlyOnce() async throws {
        let fixture = try await IngestionFixture.make(extractionDelay: .milliseconds(20))
        let sourceAccess = TestSourceAccess(rootURL: fixture.temporaryDirectory.url)
        let firstPipeline = IngestionPipeline(
            sourceAccess: sourceAccess,
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: fixture.extractor
        )
        let secondPipeline = IngestionPipeline(
            sourceAccess: sourceAccess,
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: fixture.extractor
        )
        let source = fixture.source
        let gate = ConcurrentPipelineStartGate(expectedArrivals: 2)
        let first = Task {
            await gate.waitUntilReleased()
            return try await firstPipeline.processPending(source: source)
        }
        let second = Task {
            await gate.waitUntilReleased()
            return try await secondPipeline.processPending(source: source)
        }
        await gate.waitUntilAllArrived()

        await gate.release()
        _ = try await first.value
        _ = try await second.value

        #expect(await fixture.extractor.callCount == 3)
    }

    @Test func secondSameSourceRunCompletesAfterFirstRunThrows() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady(excludingRelativePaths: ["a.pdf"])
        let sourceAccess = DelayedUnavailableSourceAccess()
        let failingPipeline = IngestionPipeline(
            sourceAccess: sourceAccess,
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: fixture.extractor
        )
        let source = fixture.source
        let first = Task {
            try await failingPipeline.processPending(source: source)
        }
        await sourceAccess.waitUntilStarted()
        let second = Task {
            try await fixture.pipeline.processPending(source: source)
        }

        await sourceAccess.release()
        do {
            _ = try await first.value
            Issue.record("Expected the first run to fail source access")
        } catch let error as IngestionRunError {
            #expect(error.reason == .sourceAccess)
        } catch {
            Issue.record("Expected IngestionRunError, received \(error)")
        }
        let report = try await second.value

        #expect(report == IngestionReport(completed: 1, failed: 0))
        #expect(await fixture.extractor.callCount == 1)
    }

    @Test func traversalPathIsRejectedBeforeExtraction() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady()
        let externalDirectory = try TemporaryDirectory()
        try externalDirectory.write("secret.pdf", bytes: Data("outside".utf8))
        let relativePath = "../\(externalDirectory.url.lastPathComponent)/secret.pdf"
        let document = try await fixture.insertDiscoveredDocument(relativePath: relativePath)

        let report = try await fixture.pipeline.processPending(source: fixture.source)
        let stored = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.id == document.id }
        )

        #expect(report == IngestionReport(completed: 0, failed: 1))
        #expect(await fixture.extractor.callCount == 0)
        #expect(stored.failureCode == "outsideSourceRoot")
    }

    @Test func outwardPointingSymlinkIsRejectedBeforeExtraction() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady()
        let externalDirectory = try TemporaryDirectory()
        let externalFile = try externalDirectory.write(
            "secret.pdf",
            bytes: Data("outside".utf8)
        )
        let linkURL = fixture.temporaryDirectory.url.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: externalFile
        )
        let document = try await fixture.insertDiscoveredDocument(relativePath: "link.pdf")

        let report = try await fixture.pipeline.processPending(source: fixture.source)
        let stored = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.id == document.id }
        )

        #expect(report == IngestionReport(completed: 0, failed: 1))
        #expect(await fixture.extractor.callCount == 0)
        #expect(stored.failureCode == "outsideSourceRoot")
    }

    @Test func pendingExtractionIsScopedToSelectedSource() async throws {
        let db = try TestDatabase.make()
        let firstSource = SourceRootRecord(
            displayName: "First",
            pathHint: "/fixtures/first",
            bookmarkData: Data("first".utf8)
        )
        let secondSource = SourceRootRecord(
            displayName: "Second",
            pathHint: "/fixtures/second",
            bookmarkData: Data("second".utf8)
        )
        let firstDocument = DocumentRecord(
            sourceRootID: firstSource.id,
            relativePath: "first.pdf",
            contentHash: "hash-first",
            byteCount: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            mediaType: .pdf
        )
        let secondDocument = DocumentRecord(
            sourceRootID: secondSource.id,
            relativePath: "second.pdf",
            contentHash: "hash-second",
            byteCount: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            mediaType: .pdf
        )
        try await db.write { database in
            try firstSource.insert(database)
            try secondSource.insert(database)
            try firstDocument.insert(database)
            try secondDocument.insert(database)
        }
        let repository = DocumentRepository(dbWriter: db)

        let pending = try await repository.pendingExtraction(
            sourceRootID: firstSource.id,
            limit: 2
        )

        #expect(pending.map(\.id) == [firstDocument.id])
    }

    @Test func isolatesFailureAndPersistsSuccessfulExtractions() async throws {
        let fixture = try await IngestionFixture.make()

        let report = try await fixture.pipeline.processPending(
            source: fixture.source,
            limit: 3
        )
        let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let byPath = Dictionary(uniqueKeysWithValues: documents.map { ($0.relativePath, $0) })
        let first = try #require(byPath["a.pdf"])
        let failed = try #require(byPath["b.jpg"])
        let third = try #require(byPath["c.png"])
        let firstExtraction = try #require(
            try await fixture.extractions.extraction(documentID: first.id)
        )
        let thirdExtraction = try #require(
            try await fixture.extractions.extraction(documentID: third.id)
        )

        #expect(report == IngestionReport(completed: 2, failed: 1))
        #expect(first.status == .ready)
        #expect(first.pageCount == 1)
        #expect(first.failureCode == nil)
        #expect(failed.status == .failed)
        #expect(failed.pageCount == nil)
        #expect(failed.failureCode == "unreadableDocument")
        #expect(third.status == .ready)
        #expect(third.pageCount == 2)
        #expect(third.failureCode == nil)
        #expect(firstExtraction.documentID == first.id)
        #expect(firstExtraction.analysisVersion == "text-v1")
        #expect(firstExtraction.extraction == fixture.firstExtraction)
        #expect(thirdExtraction.documentID == third.id)
        #expect(thirdExtraction.analysisVersion == "text-v1")
        #expect(thirdExtraction.extraction == fixture.thirdExtraction)
        #expect(try await fixture.extractions.extraction(documentID: failed.id) == nil)
    }

    @Test func rerunWithSameAnalysisVersionDoesNotReextractReadyDocuments() async throws {
        let fixture = try await IngestionFixture.make()
        _ = try await fixture.pipeline.processPending(source: fixture.source, limit: 3)
        let callsAfterFirstRun = await fixture.extractor.callCount

        let report = try await fixture.pipeline.processPending(source: fixture.source, limit: 3)

        #expect(report == IngestionReport(completed: 0, failed: 0))
        #expect(callsAfterFirstRun == 3)
        #expect(await fixture.extractor.callCount == 3)
    }

    @Test func changedAnalysisVersionReextractsReadyDocuments() async throws {
        let fixture = try await IngestionFixture.make()
        _ = try await fixture.pipeline.processPending(source: fixture.source, limit: 3)
        let versionTwoPipeline = IngestionPipeline(
            sourceAccess: TestSourceAccess(rootURL: fixture.temporaryDirectory.url),
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: fixture.extractor,
            analysisVersion: "text-v2"
        )

        let report = try await versionTwoPipeline.processPending(source: fixture.source)
        let first = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.relativePath == "a.pdf" }
        )
        let stored = try #require(
            try await fixture.extractions.extraction(documentID: first.id)
        )
        let ftsRowCount = try await fixture.db.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM extractionFTS WHERE documentID = ?",
                arguments: [first.id]
            )!
        }

        #expect(report == IngestionReport(completed: 2, failed: 0))
        #expect(await fixture.extractor.callCount == 5)
        #expect(stored.analysisVersion == "text-v2")
        #expect(ftsRowCount == 1)
    }

    @Test func removingSourceDeletesRelationalAndFTSExtractionData() async throws {
        let fixture = try await IngestionFixture.make()
        _ = try await fixture.pipeline.processPending(source: fixture.source, limit: 3)
        let sources = SourceRootRepository(dbWriter: fixture.db)

        try await sources.remove(id: fixture.source.id)

        let counts = try await fixture.db.read { database in
            (
                documents: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM document")!,
                extractions: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM documentExtraction"
                )!,
                pages: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM extractedPage")!,
                fts: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM extractionFTS")!
            )
        }

        #expect(counts.documents == 0)
        #expect(counts.extractions == 0)
        #expect(counts.pages == 0)
        #expect(counts.fts == 0)
    }

    @Test func unavailableSourceThrowsRunErrorAndLeavesDocumentsPending() async throws {
        let fixture = try await IngestionFixture.make()
        let pipeline = IngestionPipeline(
            sourceAccess: UnavailableSourceAccess(),
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: fixture.extractor
        )

        do {
            _ = try await pipeline.processPending(source: fixture.source)
            Issue.record("Expected source access to fail the ingestion run")
        } catch let error as IngestionRunError {
            #expect(error == IngestionRunError(
                reason: .sourceAccess,
                partialReport: IngestionReport(completed: 0, failed: 0)
            ))
        } catch {
            Issue.record("Expected IngestionRunError, received \(error)")
        }
        let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)

        #expect(documents.allSatisfy { $0.status == .discovered })
        #expect(documents.allSatisfy { $0.failureCode == nil })
        #expect(await fixture.extractor.callCount == 0)
    }

    @Test func sourceAccessFailureAfterCompletedBatchPreservesPartialReport() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady(excludingRelativePaths: ["a.pdf"])
        let pipeline = IngestionPipeline(
            sourceAccess: PostOperationFailingSourceAccess(
                rootURL: fixture.temporaryDirectory.url
            ),
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: fixture.extractor
        )

        do {
            _ = try await pipeline.processPending(source: fixture.source)
            Issue.record("Expected source access cleanup to fail the ingestion run")
        } catch let error as IngestionRunError {
            #expect(error == IngestionRunError(
                reason: .sourceAccess,
                partialReport: IngestionReport(completed: 1, failed: 0)
            ))
        } catch {
            Issue.record("Expected IngestionRunError, received \(error)")
        }
    }

    @Test func completionPersistsExtractionAndReadyStatusTogether() async throws {
        let fixture = try await IngestionFixture.make()
        let document = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.relativePath == "a.pdf" }
        )
        try await fixture.documents.markStatus(id: document.id, status: .extracting)

        try await fixture.extractions.complete(
            documentID: document.id,
            expectedContentHash: document.contentHash,
            analysisVersion: "text-v1",
            extraction: fixture.firstExtraction,
            at: Date(timeIntervalSince1970: 500)
        )
        let storedDocument = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.id == document.id }
        )
        let storedExtraction = try #require(
            try await fixture.extractions.extraction(documentID: document.id)
        )

        #expect(storedDocument.status == .ready)
        #expect(storedDocument.pageCount == 1)
        #expect(storedDocument.failureCode == nil)
        #expect(storedExtraction.extraction == fixture.firstExtraction)
    }

    @Test func failedReadyStatusWriteRollsBackExtractionReplacement() async throws {
        let fixture = try await IngestionFixture.make()
        let document = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.relativePath == "a.pdf" }
        )
        try await fixture.extractions.replace(
            documentID: document.id,
            analysisVersion: "text-v1",
            extraction: fixture.firstExtraction,
            at: Date(timeIntervalSince1970: 400)
        )
        try await fixture.documents.markStatus(
            id: document.id,
            status: .extracting,
            pageCount: 1
        )
        try await fixture.db.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_ready_status
                BEFORE UPDATE OF status ON document
                WHEN NEW.status = 'ready'
                BEGIN
                    SELECT RAISE(ABORT, 'blocked ready status');
                END
                """)
        }
        var didThrow = false

        do {
            try await fixture.extractions.complete(
                documentID: document.id,
                expectedContentHash: document.contentHash,
                analysisVersion: "text-v2",
                extraction: fixture.thirdExtraction,
                at: Date(timeIntervalSince1970: 500)
            )
        } catch {
            didThrow = true
        }
        let storedDocument = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.id == document.id }
        )
        let storedExtraction = try #require(
            try await fixture.extractions.extraction(documentID: document.id)
        )

        #expect(didThrow)
        #expect(storedDocument.status == .extracting)
        #expect(storedDocument.pageCount == 1)
        #expect(storedExtraction.analysisVersion == "text-v1")
        #expect(storedExtraction.extraction == fixture.firstExtraction)
    }

    @Test func cancellationRestoresDiscoveredDocumentForRetry() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady(excludingRelativePaths: ["a.pdf"])
        let document = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.relativePath == "a.pdf" }
        )
        let extractor = CancellationProbeExtractor(extraction: fixture.firstExtraction)
        let pipeline = IngestionPipeline(
            sourceAccess: TestSourceAccess(rootURL: fixture.temporaryDirectory.url),
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: extractor
        )
        let source = fixture.source
        let processing = Task {
            try await pipeline.processPending(source: source)
        }
        await extractor.waitUntilStarted()

        processing.cancel()
        do {
            _ = try await processing.value
            Issue.record("Expected cancellation to fail the ingestion run")
        } catch let error as IngestionRunError {
            #expect(error == IngestionRunError(
                reason: .cancelled,
                partialReport: IngestionReport(completed: 0, failed: 0)
            ))
        } catch {
            Issue.record("Expected IngestionRunError, received \(error)")
        }
        let stored = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.id == document.id }
        )

        #expect(stored.status == .discovered)
        #expect(stored.failureCode == nil)
        #expect(try await fixture.extractions.extraction(documentID: document.id) == nil)
    }

    @Test func cancellationRestorationFailureMapsToPersistence() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady(excludingRelativePaths: ["a.pdf"])
        let document = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.relativePath == "a.pdf" }
        )
        try await fixture.db.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_interruption_restore
                BEFORE UPDATE OF status ON document
                WHEN OLD.status = 'extracting' AND NEW.status = 'discovered'
                BEGIN
                    SELECT RAISE(ABORT, 'blocked interruption restore');
                END
                """)
        }
        let extractor = CancellationProbeExtractor(extraction: fixture.firstExtraction)
        let pipeline = IngestionPipeline(
            sourceAccess: TestSourceAccess(rootURL: fixture.temporaryDirectory.url),
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: extractor
        )
        let processing = Task {
            try await pipeline.processPending(source: fixture.source)
        }
        await extractor.waitUntilStarted()

        processing.cancel()
        do {
            _ = try await processing.value
            Issue.record("Expected cancellation restoration failure to fail the ingestion run")
        } catch let error as IngestionRunError {
            #expect(error == IngestionRunError(
                reason: .persistence,
                partialReport: IngestionReport(completed: 0, failed: 0)
            ))
        } catch {
            Issue.record("Expected IngestionRunError, received \(error)")
        }

        let stored = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.id == document.id }
        )
        #expect(stored.status == .extracting)
        #expect(try await fixture.extractions.extraction(documentID: document.id) == nil)
    }

    @Test func interruptedExtractingDocumentResumesOnNextRun() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady(excludingRelativePaths: ["a.pdf"])
        let document = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.relativePath == "a.pdf" }
        )
        try await fixture.documents.markStatus(id: document.id, status: .extracting)

        let report = try await fixture.pipeline.processPending(source: fixture.source)
        let stored = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.id == document.id }
        )

        #expect(report == IngestionReport(completed: 1, failed: 0))
        #expect(stored.status == .ready)
        #expect(stored.pageCount == 1)
        #expect(await fixture.extractor.callCount == 1)
    }

    @Test func catalogChangeDuringExtractionRejectsStaleCompletion() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady(excludingRelativePaths: ["a.pdf"])
        let original = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.relativePath == "a.pdf" }
        )
        let extractor = CatalogRaceExtractor(extraction: fixture.firstExtraction)
        let pipeline = IngestionPipeline(
            sourceAccess: TestSourceAccess(rootURL: fixture.temporaryDirectory.url),
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: extractor
        )
        let source = fixture.source
        let processing = Task {
            try await pipeline.processPending(source: source)
        }
        await extractor.waitUntilStarted()
        var changed = original
        changed.contentHash = "hash-after-catalog-update"
        changed.byteCount = 99
        changed.status = .discovered
        try await fixture.documents.save(changed)

        await extractor.release()
        do {
            _ = try await processing.value
            Issue.record("Expected stale extraction completion to fail the ingestion run")
        } catch let error as IngestionRunError {
            #expect(error == IngestionRunError(
                reason: .staleDocument,
                partialReport: IngestionReport(completed: 0, failed: 0)
            ))
        } catch {
            Issue.record("Expected IngestionRunError, received \(error)")
        }
        let stored = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.id == original.id }
        )

        #expect(stored.status == .discovered)
        #expect(stored.contentHash == "hash-after-catalog-update")
        #expect(try await fixture.extractions.extraction(documentID: original.id) == nil)
    }

    @Test func initialPendingQueryFailureThrowsZeroPartialReport() async throws {
        let fixture = try await IngestionFixture.make()
        let pipeline = IngestionPipeline(
            sourceAccess: TestSourceAccess(rootURL: fixture.temporaryDirectory.url),
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: fixture.extractor,
            analysisVersion: "text-v1",
            pendingDocuments: { _, _, _ in
                throw PendingQueryError.failed
            }
        )

        do {
            _ = try await pipeline.processPending(source: fixture.source)
            Issue.record("Expected the initial pending query to fail the ingestion run")
        } catch let error as IngestionRunError {
            #expect(error == IngestionRunError(
                reason: .pendingQuery,
                partialReport: IngestionReport(completed: 0, failed: 0)
            ))
        } catch {
            Issue.record("Expected IngestionRunError, received \(error)")
        }
    }

    @Test func failureStatusPersistenceErrorFailsTheRun() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady(excludingRelativePaths: ["b.jpg"])
        try await fixture.db.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_failed_status
                BEFORE UPDATE OF status ON document
                WHEN NEW.status = 'failed'
                BEGIN
                    SELECT RAISE(ABORT, 'blocked failed status');
                END
                """)
        }

        do {
            _ = try await fixture.pipeline.processPending(source: fixture.source)
            Issue.record("Expected failed-status persistence to fail the ingestion run")
        } catch let error as IngestionRunError {
            #expect(error == IngestionRunError(
                reason: .persistence,
                partialReport: IngestionReport(completed: 0, failed: 0)
            ))
        } catch {
            Issue.record("Expected IngestionRunError, received \(error)")
        }

        let failedDocument = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.relativePath == "b.jpg" }
        )
        #expect(failedDocument.status == .extracting)
        #expect(failedDocument.failureCode == nil)
    }

    @Test func sameBatchPersistenceFailureWinsOverStaleDocumentFailure() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady(excludingRelativePaths: ["a.pdf", "b.jpg"])
        let original = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.relativePath == "a.pdf" }
        )
        try await fixture.db.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_failed_status
                BEFORE UPDATE OF status ON document
                WHEN NEW.status = 'failed'
                BEGIN
                    SELECT RAISE(ABORT, 'blocked failed status');
                END
                """)
        }
        let extractor = MixedFailureExtractor(extraction: fixture.firstExtraction)
        let pipeline = IngestionPipeline(
            sourceAccess: TestSourceAccess(rootURL: fixture.temporaryDirectory.url),
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: extractor
        )
        let processing = Task {
            try await pipeline.processPending(source: fixture.source, limit: 2)
        }
        await extractor.waitUntilStarted()
        var changed = original
        changed.contentHash = "hash-after-catalog-update"
        changed.byteCount = 99
        changed.status = .discovered
        try await fixture.documents.save(changed)

        await extractor.release()
        do {
            _ = try await processing.value
            Issue.record("Expected mixed same-batch failures to fail the ingestion run")
        } catch let error as IngestionRunError {
            #expect(error == IngestionRunError(
                reason: .persistence,
                partialReport: IngestionReport(completed: 0, failed: 0)
            ))
        } catch {
            Issue.record("Expected IngestionRunError, received \(error)")
        }
    }

    @Test func laterPendingQueryFailurePreservesCompletedBatchCount() async throws {
        let fixture = try await IngestionFixture.make()
        try await fixture.markSeedDocumentsReady(excludingRelativePaths: ["a.pdf"])
        let document = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.relativePath == "a.pdf" }
        )
        let queries = PendingQuerySequence(firstBatch: [document])
        let pipeline = IngestionPipeline(
            sourceAccess: TestSourceAccess(rootURL: fixture.temporaryDirectory.url),
            documents: fixture.documents,
            extractions: fixture.extractions,
            extractor: fixture.extractor,
            analysisVersion: "text-v1",
            pendingDocuments: { _, _, _ in
                try await queries.next()
            }
        )

        do {
            _ = try await pipeline.processPending(source: fixture.source, limit: 1)
            Issue.record("Expected the later pending query to fail the ingestion run")
        } catch let error as IngestionRunError {
            #expect(error == IngestionRunError(
                reason: .pendingQuery,
                partialReport: IngestionReport(completed: 1, failed: 0)
            ))
        } catch {
            Issue.record("Expected IngestionRunError, received \(error)")
        }
        let stored = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id)
                .first { $0.id == document.id }
        )

        #expect(stored.status == .ready)
        #expect(try await fixture.extractions.extraction(documentID: document.id) != nil)
    }
}

private actor PendingQuerySequence {
    private let firstBatch: [DocumentRecord]
    private var callCount = 0

    init(firstBatch: [DocumentRecord]) {
        self.firstBatch = firstBatch
    }

    func next() throws -> [DocumentRecord] {
        callCount += 1
        if callCount == 1 {
            return firstBatch
        }
        throw PendingQueryError.failed
    }
}

private enum PendingQueryError: Error {
    case failed
}

private actor ConcurrentPipelineStartGate {
    private let expectedArrivals: Int
    private var arrivalCount = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(expectedArrivals: Int) {
        self.expectedArrivals = expectedArrivals
    }

    func waitUntilReleased() async {
        arrivalCount += 1
        if arrivalCount == expectedArrivals {
            for waiter in arrivalWaiters {
                waiter.resume()
            }
            arrivalWaiters.removeAll()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilAllArrived() async {
        if arrivalCount == expectedArrivals { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }
}

private struct IngestionFixture {
    let temporaryDirectory: TemporaryDirectory
    let db: DatabaseQueue
    let source: SourceRootRecord
    let documents: DocumentRepository
    let extractions: ExtractionRepository
    let extractor: SelectiveTextExtractor
    let pipeline: IngestionPipeline
    let firstExtraction: ExtractedDocument
    let thirdExtraction: ExtractedDocument

    static func make(
        extractionDelay: Duration = .zero
    ) async throws -> IngestionFixture {
        let temporaryDirectory = try TemporaryDirectory()
        try temporaryDirectory.write("a.pdf", bytes: Data("first".utf8))
        try temporaryDirectory.write("b.jpg", bytes: Data("failed".utf8))
        try temporaryDirectory.write("c.png", bytes: Data("third".utf8))
        let db = try TestDatabase.make()
        let source = SourceRootRecord(
            displayName: "Fixtures",
            pathHint: temporaryDirectory.url.path,
            bookmarkData: Data("bookmark".utf8),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let documentRecords = [
            DocumentRecord(
                sourceRootID: source.id,
                relativePath: "a.pdf",
                contentHash: "hash-a",
                byteCount: 5,
                modifiedAt: Date(timeIntervalSince1970: 101),
                mediaType: .pdf,
                lastSeenAt: Date(timeIntervalSince1970: 200)
            ),
            DocumentRecord(
                sourceRootID: source.id,
                relativePath: "b.jpg",
                contentHash: "hash-b",
                byteCount: 6,
                modifiedAt: Date(timeIntervalSince1970: 102),
                mediaType: .jpeg,
                lastSeenAt: Date(timeIntervalSince1970: 200)
            ),
            DocumentRecord(
                sourceRootID: source.id,
                relativePath: "c.png",
                contentHash: "hash-c",
                byteCount: 5,
                modifiedAt: Date(timeIntervalSince1970: 103),
                mediaType: .png,
                lastSeenAt: Date(timeIntervalSince1970: 200)
            ),
        ]
        try await db.write { database in
            try source.insert(database)
            for document in documentRecords {
                try document.insert(database)
            }
        }
        let firstExtraction = ExtractedDocument(
            method: .embeddedPDFText,
            pages: [ExtractedPage(
                pageIndex: 0,
                text: "First text",
                regions: [TextRegion(
                    text: "First",
                    confidence: 0.95,
                    boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
                )]
            )]
        )
        let thirdExtraction = ExtractedDocument(
            method: .visionOCR,
            pages: [
                ExtractedPage(pageIndex: 0, text: "Third page one", regions: []),
                ExtractedPage(pageIndex: 1, text: "Third page two", regions: []),
            ]
        )
        let documents = DocumentRepository(dbWriter: db)
        let extractions = ExtractionRepository(dbWriter: db)
        let extractor = SelectiveTextExtractor(
            firstExtraction: firstExtraction,
            thirdExtraction: thirdExtraction,
            delay: extractionDelay
        )
        let pipeline = IngestionPipeline(
            sourceAccess: TestSourceAccess(rootURL: temporaryDirectory.url),
            documents: documents,
            extractions: extractions,
            extractor: extractor
        )
        return IngestionFixture(
            temporaryDirectory: temporaryDirectory,
            db: db,
            source: source,
            documents: documents,
            extractions: extractions,
            extractor: extractor,
            pipeline: pipeline,
            firstExtraction: firstExtraction,
            thirdExtraction: thirdExtraction
        )
    }

    func markSeedDocumentsReady(
        excludingRelativePaths: Set<String> = []
    ) async throws {
        for document in try await documents.all(sourceRootID: source.id) {
            guard !excludingRelativePaths.contains(document.relativePath) else { continue }
            let extraction = document.relativePath == "c.png" ? thirdExtraction : firstExtraction
            try await documents.markStatus(id: document.id, status: .extracting)
            try await extractions.complete(
                documentID: document.id,
                expectedContentHash: document.contentHash,
                analysisVersion: "text-v1",
                extraction: extraction,
                at: Date(timeIntervalSince1970: 250)
            )
        }
    }

    func insertDiscoveredDocument(relativePath: String) async throws -> DocumentRecord {
        let document = DocumentRecord(
            sourceRootID: source.id,
            relativePath: relativePath,
            contentHash: "hash-\(UUID().uuidString)",
            byteCount: 7,
            modifiedAt: Date(timeIntervalSince1970: 300),
            mediaType: .pdf,
            lastSeenAt: Date(timeIntervalSince1970: 300)
        )
        try await db.write { database in
            try document.insert(database)
        }
        return document
    }
}

private actor SelectiveTextExtractor: DocumentTextExtracting {
    private let firstExtraction: ExtractedDocument
    private let thirdExtraction: ExtractedDocument
    private let delay: Duration
    private(set) var callCount = 0
    private var activeCallCount = 0
    private(set) var maximumConcurrentCallCount = 0

    init(
        firstExtraction: ExtractedDocument,
        thirdExtraction: ExtractedDocument,
        delay: Duration
    ) {
        self.firstExtraction = firstExtraction
        self.thirdExtraction = thirdExtraction
        self.delay = delay
    }

    func extract(
        from url: URL,
        mediaType: SupportedMediaType
    ) async throws -> ExtractedDocument {
        callCount += 1
        activeCallCount += 1
        maximumConcurrentCallCount = max(maximumConcurrentCallCount, activeCallCount)
        defer { activeCallCount -= 1 }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        switch url.lastPathComponent {
        case "a.pdf":
            return firstExtraction
        case "b.jpg":
            throw TextExtractionError.unreadableDocument
        case "c.png":
            return thirdExtraction
        default:
            throw TextExtractionError.unsupportedMedia
        }
    }
}

private actor CancellationProbeExtractor: DocumentTextExtracting {
    private let extraction: ExtractedDocument
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(extraction: ExtractedDocument) {
        self.extraction = extraction
    }

    func extract(
        from url: URL,
        mediaType: SupportedMediaType
    ) async throws -> ExtractedDocument {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        try await Task.sleep(for: .seconds(60))
        return extraction
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor CatalogRaceExtractor: DocumentTextExtracting {
    private let extraction: ExtractedDocument
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(extraction: ExtractedDocument) {
        self.extraction = extraction
    }

    func extract(
        from url: URL,
        mediaType: SupportedMediaType
    ) async throws -> ExtractedDocument {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return extraction
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor MixedFailureExtractor: DocumentTextExtracting {
    private let extraction: ExtractedDocument
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(extraction: ExtractedDocument) {
        self.extraction = extraction
    }

    func extract(
        from url: URL,
        mediaType: SupportedMediaType
    ) async throws -> ExtractedDocument {
        if url.lastPathComponent == "b.jpg" {
            throw TextExtractionError.unreadableDocument
        }
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return extraction
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct TestSourceAccess: SourceAccessing {
    let rootURL: URL

    func createBookmark(for url: URL) throws -> Data {
        Data("bookmark".utf8)
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        ResolvedSource(url: rootURL, bookmarkWasStale: false)
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await operation(rootURL)
    }
}

private struct UnavailableSourceAccess: SourceAccessing {
    func createBookmark(for url: URL) throws -> Data {
        throw UnavailableSourceError()
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        throw UnavailableSourceError()
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        throw UnavailableSourceError()
    }
}

private struct UnavailableSourceError: Error {}

private struct PostOperationFailingSourceAccess: SourceAccessing {
    let rootURL: URL

    func createBookmark(for url: URL) throws -> Data {
        Data("bookmark".utf8)
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        ResolvedSource(url: rootURL, bookmarkWasStale: false)
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        _ = try await operation(rootURL)
        throw UnavailableSourceError()
    }
}

private actor DelayedUnavailableSourceAccess: SourceAccessing {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    nonisolated func createBookmark(for url: URL) throws -> Data {
        Data("bookmark".utf8)
    }

    nonisolated func resolve(_ bookmark: Data) throws -> ResolvedSource {
        throw UnavailableSourceError()
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        throw UnavailableSourceError()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
