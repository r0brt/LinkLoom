# LinkLoom P0 Reliability Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the three approved P0 audit findings by making catalog completeness fail-fast, propagating typed ingestion run failures, and requiring the existing Swift quality gates on `main`.

**Architecture:** Preserve the current SwiftPM module boundaries and database schema. `CatalogService` remains an all-or-nothing reconciliation boundary for new-file fingerprint failures, while `IngestionPipeline` separates durable per-document failures from typed run-level failures that propagate through the existing app and watcher protocols. GitHub branch protection is changed through its narrow required-status-checks endpoint and documented in the repository.

**Tech Stack:** Swift 6.2+, Swift Testing, Swift Package Manager, GRDB 7.10.0, SQLite/FTS5, SwiftUI, FSEvents, GitHub Actions, GitHub REST API

## Global Constraints

- Implement only the three outcomes approved in `docs/superpowers/specs/2026-08-16-p0-reliability-hardening-design.md`.
- LinkLoom must never rename, move, delete, or intentionally modify a source document.
- Do not add a package dependency, database migration, document status, UI state, logger, formatter, linter, or unrelated refactor.
- Keep `CatalogService.scan(source:now:)` throwing its original new-file fingerprint error; do not add a catalog error wrapper.
- Use the exact public ingestion error types and failure reasons defined in the approved design.
- Expected per-document extraction failures remain non-throwing when their `.failed` state is durably persisted.
- Every product behavior change starts with an observed relevant failing test.
- Each task ends in a focused Conventional Commit and an independently green verification gate.
- The local CLT-only environment requires `--enable-swift-testing` and explicit framework/rpath flags; do not treat plain `swift test` failure in that environment as a product regression.
- Apply the branch-protection setting only with explicit GitHub authorization and only after the hardening pull request's existing checks are green.

## File Structure

### Files modified by Task 1

- `Sources/LinkLoomCore/Catalog/CatalogService.swift` — propagate new-path fingerprint failures before reconciliation.
- `Tests/LinkLoomCoreTests/CatalogServiceTests.swift` — replace the partial-success test with an all-or-nothing regression.

### Files modified by Task 2

- `Sources/LinkLoomCore/Pipeline/IngestionPipeline.swift` — define the public run-error contract and classify pipeline outcomes.
- `Sources/LinkLoomApp/LinkLoomApp.swift` — propagate the now-throwing pipeline through the composition adapters.
- `Tests/LinkLoomCoreTests/IngestionPipelineTests.swift` — cover source, query, persistence, stale, cancellation, and successful document-failure semantics.
- `Tests/LinkLoomCoreTests/IngestionAcceptanceTests.swift` — adapt the acceptance helper to the throwing API.
- `Tests/LinkLoomCoreTests/RescanSchedulerTests.swift` — prove an `IngestionRunError` prevents a completion event.
- `Tests/LinkLoomAppFeatureTests/AppModelTests.swift` — prove an ingestion run failure becomes the existing `scanFailure` without removing visible documents.

### Files modified by Task 3

- `.github/BRANCH_PROTECTION.md` — make all three existing checks immediately required in the documented state.
- GitHub repository setting `main` branch protection — require `Policy / validate`, `Swift / test`, and `Swift / release-build` while preserving strict mode.

---

### Task 1: Abort a catalog scan when a new file cannot be fingerprinted

**Files:**
- Modify: `Sources/LinkLoomCore/Catalog/CatalogService.swift:110-120`
- Test: `Tests/LinkLoomCoreTests/CatalogServiceTests.swift:230-245`

**Interfaces:**
- Consumes: `FileFingerprinting.fingerprint(_:) async throws -> FileFingerprint`, `DocumentRepository.reconcile(sourceRootID:saving:excludingDocumentIDs:)`, and `SourceRootRepository.updateLastScan(id:at:)`.
- Produces: the existing `CatalogService.scan(source:now:) async throws -> ScanReport` with the stronger guarantee that a new-path fingerprint failure occurs before all reconciliation and source timestamp writes.

- [ ] **Step 1: Replace the partial-success test with the failing all-or-nothing regression**

Replace `fingerprintFailureDoesNotStopOtherDocuments()` with this test:

```swift
@Test func newFingerprintFailureAbortsWithoutReconciliation() async throws {
    let fixture = try await CatalogFixture.make()
    let knownCandidate = fixture.candidate("known.pdf", byteCount: 4, modifiedAt: 100)
    fixture.enumerator.setCandidates([knownCandidate])
    await fixture.fingerprinter.set(knownCandidate, hash: "known-hash")
    _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
    let known = try #require(
        try await fixture.documents.all(sourceRootID: fixture.source.id).first
    )
    try await fixture.documents.markStatus(
        id: known.id,
        status: .ready,
        pageCount: 2
    )

    let first = fixture.candidate("a.pdf", byteCount: 5, modifiedAt: 300)
    let unreadable = fixture.candidate("b.pdf", byteCount: 6, modifiedAt: 301)
    let third = fixture.candidate("c.pdf", byteCount: 7, modifiedAt: 302)
    fixture.enumerator.setCandidates([first, unreadable, third])
    await fixture.fingerprinter.set(first, hash: "hash-a")
    await fixture.fingerprinter.set(third, hash: "hash-c")

    await #expect(throws: MissingFingerprintError.self) {
        try await fixture.service.scan(source: fixture.source, now: fixture.date(400))
    }

    let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)
    let storedKnown = try #require(documents.first)
    let storedSource = try #require(try await fixture.sources.all().first)
    #expect(documents.count == 1)
    #expect(storedKnown.id == known.id)
    #expect(storedKnown.relativePath == "known.pdf")
    #expect(storedKnown.status == .ready)
    #expect(storedKnown.pageCount == 2)
    #expect(storedKnown.availability == .available)
    #expect(storedSource.lastScanAt == fixture.date(200))
    #expect(await fixture.fingerprinter.callCount == 3)
}
```

The call-count assertion proves the scan stops after the unreadable candidate: one call seeded `known.pdf`, one fingerprints `a.pdf`, and one fails for `b.pdf`; `c.pdf` is never fingerprinted.

- [ ] **Step 2: Run the focused test and observe the existing behavior fail**

Run:

```bash
swift test --disable-sandbox --enable-swift-testing \
  --filter newFingerprintFailureAbortsWithoutReconciliation \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: FAIL because `CatalogService` catches `MissingFingerprintError`, persists `a.pdf` and `c.pdf`, marks `known.pdf` missing, and advances `lastScanAt` instead of throwing.

- [ ] **Step 3: Remove the new-path fingerprint catch-and-continue behavior**

In `CatalogService.scanWithoutCoordination`, replace the new-path fingerprint loop with:

```swift
var fingerprintedNewPathCandidates: [(FileCandidate, FileFingerprint)] = []
for candidate in newPathCandidates {
    let fingerprint = try await fingerprinter.fingerprint(candidate.url)
    fingerprintedNewPathCandidates.append((candidate, fingerprint))
}
```

Do not change the earlier existing-path branch at lines 82-91; an already cataloged file whose fresh fingerprint cannot be read must still be retained as `.unavailable` during an otherwise complete scan.

- [ ] **Step 4: Run the focused test and confirm the transaction boundary**

Run the exact command from Step 2.

Expected: PASS. The thrown error occurs before `documents.reconcile` and `sources.updateLastScan`.

- [ ] **Step 5: Run the complete catalog and repository suites**

Run:

```bash
swift test --disable-sandbox --enable-swift-testing \
  --filter 'Catalog reconciliation|Document repository' \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: all catalog and document-repository tests pass with zero failures.

- [ ] **Step 6: Check and commit the independently reviewable outcome**

Run:

```bash
git diff --check
git status --short
git add Sources/LinkLoomCore/Catalog/CatalogService.swift Tests/LinkLoomCoreTests/CatalogServiceTests.swift
git commit -m "fix: fail incomplete fingerprint scans"
```

**Acceptance criteria:**

- A new-path fingerprint error escapes unchanged.
- No document or source-root row changes when that error occurs.
- Existing-path fingerprint failure behavior remains unchanged.
- The focused and complete catalog suites are green.
- The commit contains only the two declared files.

---

### Task 2: Propagate typed ingestion run failures without reclassifying document failures

**Files:**
- Modify: `Sources/LinkLoomCore/Pipeline/IngestionPipeline.swift:3-330`
- Modify: `Sources/LinkLoomApp/LinkLoomApp.swift:97-120`
- Test: `Tests/LinkLoomCoreTests/IngestionPipelineTests.swift:8-840`
- Test: `Tests/LinkLoomCoreTests/IngestionAcceptanceTests.swift:154-180`
- Test: `Tests/LinkLoomCoreTests/RescanSchedulerTests.swift:186-213,459-465`
- Test: `Tests/LinkLoomAppFeatureTests/AppModelTests.swift:35-54,1091-1095,1561-1567`

**Interfaces:**
- Consumes: the approved catalog behavior from Task 1, `DocumentRepository`, `ExtractionRepository`, `DocumentTextExtracting`, `SourceAccessing`, `PendingIngesting`, and `SourceRescanning`.
- Produces: `IngestionRunFailureReason`, `IngestionRunError`, and `IngestionPipeline.processPending(source:limit:) async throws -> IngestionReport` exactly as defined in the approved design.
- Downstream contract: `PendingIngester` and `IncrementalRescanner` use `try await`; `AppModel` and `RescanScheduler` retain their existing generic error handling.

- [ ] **Step 1: Rewrite the source-access regression to require a typed run error**

Replace `unavailableSourceLeavesDocumentsPendingForRetry()` with:

```swift
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
```

- [ ] **Step 2: Add initial and later pending-query run-error regressions**

Add this test before `laterPendingQueryFailurePreservesCompletedBatchCount()`:

```swift
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
```

Replace the final report assertion in `laterPendingQueryFailurePreservesCompletedBatchCount()` with this error capture while retaining its stored-document assertions:

```swift
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
```

- [ ] **Step 3: Rewrite stale-completion and cancellation regressions to require typed errors**

In `cancellationRestoresDiscoveredDocumentForRetry()`, change the task and result handling to:

```swift
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
```

Keep the existing assertions that the document returns to `.discovered`, has no failure code, and has no extraction rows.

In `catalogChangeDuringExtractionRejectsStaleCompletion()`, change the task and result handling to:

```swift
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
```

Keep the existing assertions that the changed content hash remains `.discovered` and no stale extraction rows survive.

- [ ] **Step 4: Add a persistence-failure regression at the document-failure boundary**

Add:

```swift
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
```

The existing `isolatesFailureAndPersistsSuccessfulExtractions()` remains the positive counterpart proving that an extractor error is a normal `failed` count when persistence succeeds.

- [ ] **Step 5: Run the pipeline suite and observe the Red state**

Run:

```bash
swift test --disable-sandbox --enable-swift-testing \
  --filter 'Persisted ingestion pipeline' \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: FAIL to compile because `IngestionRunError` and `IngestionRunFailureReason` do not exist and `processPending` is not yet throwing. This is the required initial Red state.

- [ ] **Step 6: Add the public ingestion run-error contract**

Immediately after `IngestionReport`, add:

```swift
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
```

Change the public signature to:

```swift
public func processPending(
    source: SourceRootRecord,
    limit: Int = 2
) async throws -> IngestionReport
```

- [ ] **Step 7: Make all successful call sites compile against the throwing API**

Apply these exact rules to every `processPending` call found by `rg -n 'processPending\(' Sources Tests --glob '*.swift'`:

```swift
let report = try await pipeline.processPending(source: source)
_ = try await pipeline.processPending(source: source)
return try await pipeline.processPending(source: source)
```

Specifically:

- in `IngestionPipelineTests.swift`, add `try` to every successful direct call and use `try await first.value` / `try await second.value` for throwing tasks;
- in `IngestionAcceptanceTests.swift`, change line 179 to `_ = try await pipeline.processPending(source: sourceRecord)`;
- in `LinkLoomApp.swift`, change both composition adapters to `_ = try await ingestion.processPending(source: source)` and `_ = try await pipeline.processPending(source: source)`.

Do not catch the error in either adapter.

- [ ] **Step 8: Run the source-access test and observe the behavioral Red state**

Run:

```bash
swift test --disable-sandbox --enable-swift-testing \
  --filter unavailableSourceThrowsRunErrorAndLeavesDocumentsPending \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: FAIL because the current implementation still converts the unavailable source into a successful zero report.

- [ ] **Step 9: Replace run orchestration with typed failure propagation**

Replace `processPending` and `processPendingExclusively` with:

```swift
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
        throw IngestionRunError(reason: .cancelled, partialReport: emptyReport)
    } catch {
        throw IngestionRunError(reason: .sourceAccess, partialReport: emptyReport)
    }
}
```

- [ ] **Step 10: Extract deterministic per-document and per-batch classification**

Add these private helpers inside `IngestionPipeline` before `failureCode(for:)`:

```swift
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
```

The unstructured `Task` intentionally preserves the repository's existing restoration behavior: the cleanup must execute even after the processing task has been cancelled.

Replace the existing bottom-level outcome types with:

```swift
private enum ProcessingOutcome: Sendable {
    case completed
    case failed
    case runFailure(IngestionRunFailureReason)
}

private struct BatchResult: Sendable {
    let report: IngestionReport
    let failureReason: IngestionRunFailureReason?
}
```

Leave `IngestionRunCoordinator` unchanged.

- [ ] **Step 11: Run focused Red/Green verification for every run-level reason**

Run:

```bash
swift test --disable-sandbox --enable-swift-testing \
  --filter 'unavailableSourceThrowsRunErrorAndLeavesDocumentsPending|initialPendingQueryFailureThrowsZeroPartialReport|laterPendingQueryFailurePreservesCompletedBatchCount|catalogChangeDuringExtractionRejectsStaleCompletion|cancellationRestoresDiscoveredDocumentForRetry|failureStatusPersistenceErrorFailsTheRun|isolatesFailureAndPersistsSuccessfulExtractions' \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: all seven tests pass. The positive extraction-failure test must still return a report rather than throw.

- [ ] **Step 12: Add the UI error-contract regression**

Add after `scanFailureAppearsWithoutRemovingExistingDocuments()`:

```swift
@Test @MainActor func ingestionFailureAppearsWithoutRemovingExistingDocuments() async throws {
    let fixture = try AppModelFixture()
    let source = try await fixture.addSource(named: "Archive")
    let existingDocument = fixture.document(
        sourceRootID: source.id,
        path: "existing.pdf"
    )
    try await fixture.documents.save(existingDocument)
    let model = AppModel(
        sources: fixture.sources,
        documents: fixture.documents,
        sourceAccess: fixture.sourceAccess,
        catalog: FakeCatalogScanner(),
        ingestion: FailingPendingIngester()
    )
    try await model.reload()

    await model.scanSelectedSource()

    #expect(model.scanState == .idle)
    #expect(model.lastErrorCode == "scanFailure")
    #expect(model.documents == [existingDocument])
}
```

Change `FailingPendingIngester` to throw the public run error:

```swift
private struct FailingPendingIngester: PendingIngesting {
    func processPending(source: SourceRootRecord) async throws {
        throw IngestionRunError(
            reason: .sourceAccess,
            partialReport: IngestionReport(completed: 0, failed: 0)
        )
    }
}
```

Remove `AppModelTestError.ingestionFailed`, which becomes unused.

- [ ] **Step 13: Make the scheduler regression use the exact ingestion error contract**

Rename `failedRescanDoesNotPublishCompletion()` to `ingestionRunFailureDoesNotPublishCompletion()` and replace `FailingSourceRescanner.rescan` with:

```swift
func rescan(source: SourceRootRecord) async throws {
    didRun = true
    throw IngestionRunError(
        reason: .sourceAccess,
        partialReport: IngestionReport(completed: 0, failed: 0)
    )
}
```

Keep the existing assertion that `rescanCompletions` remains empty.

- [ ] **Step 14: Run the complete pipeline, app-model, scheduler, and acceptance suites**

Run:

```bash
swift test --disable-sandbox --enable-swift-testing \
  --filter 'Persisted ingestion pipeline|Diagnostic app model|Incremental rescan scheduler|Local ingestion acceptance' \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: all selected suites pass. The normal performance fixture remains skipped unless `LINKLOOM_PERF_TEST=1` is set.

- [ ] **Step 15: Run a release build to verify executable composition**

Run:

```bash
swift build --disable-sandbox -c release \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: PASS. This compile gate proves `PendingIngester` and `IncrementalRescanner` propagate the throwing pipeline without an accidental catch.

- [ ] **Step 16: Check and commit the independently reviewable outcome**

Run:

```bash
git diff --check
git status --short
git add Sources/LinkLoomCore/Pipeline/IngestionPipeline.swift Sources/LinkLoomApp/LinkLoomApp.swift Tests/LinkLoomCoreTests/IngestionPipelineTests.swift Tests/LinkLoomCoreTests/IngestionAcceptanceTests.swift Tests/LinkLoomCoreTests/RescanSchedulerTests.swift Tests/LinkLoomAppFeatureTests/AppModelTests.swift
git commit -m "fix: propagate ingestion run failures"
```

**Acceptance criteria:**

- `processPending` is `async throws` and exposes the approved public error types.
- Source access, pending-query, persistence, stale-state, and cancellation failures throw stable reasons with correct partial reports.
- A successfully persisted per-document extraction failure remains a non-throwing `failed` count.
- Cancellation restores the prior retryable document state or reports `persistence` if restoration fails.
- AppModel maps the propagated error to the existing `scanFailure` while preserving visible documents.
- RescanScheduler publishes no completion for the exact ingestion run error.
- The executable release-builds successfully.
- The commit contains only the six declared files.

---

### Task 3: Require the existing Swift quality gates on `main`

**Files and external state:**
- Modify: `.github/BRANCH_PROTECTION.md:20-35`
- Update: GitHub classic branch protection for `r0brt/LinkLoom`, branch `main`, required status checks only

**Interfaces:**
- Consumes: successful `Policy / validate`, `Swift / test`, and `Swift / release-build` check runs from `.github/workflows/pr-policy.yml` and `.github/workflows/swift.yml`.
- Produces: `strict == true` with exactly the three required contexts while preserving all other protection settings.
- Authorization boundary: do not invoke the PATCH request unless GitHub setting mutation is explicitly authorized for the execution session.

- [ ] **Step 1: Verify authentication, repository, pull request, and green checks**

Run:

```bash
gh auth status
gh repo view --json nameWithOwner,defaultBranchRef --jq '{nameWithOwner,defaultBranch:.defaultBranchRef.name}'
gh pr view --json number,state,isDraft,url --jq '{number,state,isDraft,url}'
gh pr checks
```

Expected:

- active GitHub account is authorized for `r0brt/LinkLoom`;
- default branch is `main`;
- the current branch has an open pull request;
- `Policy / validate`, `Swift / test`, and `Swift / release-build` are all successful.

If the current branch has no pull request or any check is not successful, do not change branch protection. Complete the normal publish/CI workflow first, then repeat this step.

- [ ] **Step 2: Capture the Red configuration state**

Run:

```bash
gh api repos/r0brt/LinkLoom/branches/main/protection/required_status_checks \
  --jq '{strict,contexts}'
```

Expected current output:

```json
{"strict":true,"contexts":["Policy / validate"]}
```

This is the configuration Red state: the two existing Swift jobs are not enforced.

- [ ] **Step 3: Update the repository documentation to the active required state**

Replace `.github/BRANCH_PROTECTION.md` lines 20-35 with:

````markdown
## Required status checks

Require all of these checks:

```text
Policy / validate
Swift / test
Swift / release-build
```

The workflows in [`workflows/pr-policy.yml`](workflows/pr-policy.yml) and [`workflows/swift.yml`](workflows/swift.yml) supply these checks. When application tooling is added, also require its build, automated test, lint, type-check, and security checks. A new check should first run reliably on pull requests before administrators make it required.
````

- [ ] **Step 4: Validate and commit the documentation change**

Run:

```bash
git diff --check
git diff -- .github/BRANCH_PROTECTION.md
git add .github/BRANCH_PROTECTION.md
git commit -m "ci: require Swift quality gates"
```

Expected: one documentation file in the focused commit.

- [ ] **Step 5: Publish the documentation commit and re-confirm green checks**

Use the repository's approved publish workflow for the current branch. After the new commit has reached the open pull request, run:

```bash
gh pr checks --watch
```

Expected: `Policy / validate`, `Swift / test`, and `Swift / release-build` all complete successfully for the final hardening commit.

- [ ] **Step 6: Apply the narrow required-status-checks update**

After explicit authorization, run:

```bash
printf '%s\n' '{"strict":true,"contexts":["Policy / validate","Swift / test","Swift / release-build"]}' | \
  gh api --method PATCH \
    repos/r0brt/LinkLoom/branches/main/protection/required_status_checks \
    --input -
```

Do not PATCH `/branches/main/protection`; the narrower endpoint avoids replacing review, force-push, deletion, linear-history, admin-enforcement, or conversation-resolution settings.

- [ ] **Step 7: Verify the Green configuration state**

Run:

```bash
gh api repos/r0brt/LinkLoom/branches/main/protection/required_status_checks \
  --jq '{strict,contexts:(.contexts | sort)}'
```

Expected output:

```json
{"strict":true,"contexts":["Policy / validate","Swift / release-build","Swift / test"]}
```

- [ ] **Step 8: Record the rollback command without executing it**

If the Swift workflow is later renamed or becomes unavailable, the exact recovery command is:

```bash
printf '%s\n' '{"strict":true,"contexts":["Policy / validate"]}' | \
  gh api --method PATCH \
    repos/r0brt/LinkLoom/branches/main/protection/required_status_checks \
    --input -
```

Do not execute the rollback during normal implementation.

**Acceptance criteria:**

- The final hardening commit has green policy, test, and release-build checks before the setting changes.
- Branch protection remains strict.
- Exactly the three approved contexts are required.
- Existing non-status branch-protection controls are untouched.
- `.github/BRANCH_PROTECTION.md` matches the live setting.
- The focused commit contains only `.github/BRANCH_PROTECTION.md`.

---

## Final Verification

- [ ] **Step 1: Run the complete Swift suite**

```bash
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: 135 tests in 14 suites pass, with the 10,000-document fixture skipped.

- [ ] **Step 2: Run the opt-in 10,000-document acceptance test**

```bash
LINKLOOM_PERF_TEST=1 swift test --disable-sandbox --enable-swift-testing \
  --filter catalogHandlesTenThousandDocumentsIdempotently \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: one test passes; both scans retain 10,000 records and the second scan performs zero fingerprints.

- [ ] **Step 3: Run the release build**

```bash
swift build --disable-sandbox -c release \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: `LinkLoomApp` links successfully in release configuration.

- [ ] **Step 4: Verify repository and GitHub state**

```bash
git diff --check
git status -sb
git log -4 --oneline
gh pr checks
gh api repos/r0brt/LinkLoom/branches/main/protection/required_status_checks \
  --jq '{strict,contexts:(.contexts | sort)}'
```

Expected:

- no unstaged or uncommitted implementation changes;
- three focused implementation commits after the design/plan documentation commits;
- all pull-request checks green;
- strict branch protection with `Policy / validate`, `Swift / release-build`, and `Swift / test` required.

## Plan Self-Review Checklist

- All three approved P0 findings map to exactly one task.
- Task 1 fails before all catalog writes and preserves existing-path failure behavior.
- Task 2 distinguishes durable document failures from five typed run-level reasons.
- Task 2 updates every compile-time caller of the now-throwing API.
- Task 3 changes only required status checks and preserves every other protection control.
- Each product behavior has an explicit Red command and expected failure.
- Every task has focused files, verification, acceptance criteria, and a Conventional Commit.
- P1 and P2 audit findings remain excluded.
