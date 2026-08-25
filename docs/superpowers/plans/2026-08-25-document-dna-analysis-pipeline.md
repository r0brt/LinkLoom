# Document DNA Analysis Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the fully local, source-scoped orchestration stage that durably manages Document DNA attempts and atomically analyzes every eligible persisted extraction.

**Architecture:** Extend the existing `DocumentDNARepository` actor with exact guarded transitions for `analyzing`, `failed`, recovery, cancellation restoration, and retry. Add a dedicated `DocumentDNAAnalysisPipeline` actor that mirrors the established ingestion reliability shape: a coordinator shared across instances, bounded task-group batches, deterministic document-failure isolation, typed run failures, and durable partial reports. The pipeline consumes only `PendingDocumentDNAAnalysis` values and never opens source files.

**Tech Stack:** Swift 6.2, Swift Concurrency actors and task groups, Foundation, GRDB 7.10.0, SQLite, Swift Testing

**Spec:** `docs/superpowers/specs/2026-08-25-document-dna-analysis-pipeline-design.md`

## Global Constraints

- Work only in `LinkLoomCore`, its tests, and the durable spec/plan documents; `LinkLoomCore` must remain independent of `LinkLoomAppFeature` and `LinkLoomApp`.
- Keep all processing local; add no network call, external AI, telemetry, model download, dependency, or remote configuration.
- Never open, rename, move, delete, or intentionally modify a source document; all tests use an in-memory SQLite database and synthetic stored text.
- Reuse the existing additive v5 DNA schema; add no migration and change no `document.status` value.
- Preserve the last completed snapshot on failure, cancellation, stale input, and transition-write failure.
- Use only `analysisFailure`, `invalidFinding`, and `invalidProvenance` as durable DNA failure codes; never persist extracted values, paths, or personal data in failure codes.
- Keep application model, SwiftUI, watcher, rescan scheduler, startup controller, executable composition, entity resolution, relationships, contexts, and dossiers out of this slice.
- Every production behavior starts with a focused failing Swift Testing test that is observed RED for the intended missing behavior before implementation.
- Use the repository's documented Command-Line-Tools Swift Testing fallback for all local test runs.
- Do not run the opt-in 10,000-document benchmark; this slice does not change catalog, fingerprinting, or scale behavior.

---

## File Map

- `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift` — owns exact attempt-state transactions and the existing atomic snapshot transaction.
- `Sources/LinkLoomCore/Pipeline/DocumentDNAAnalysisPipeline.swift` — owns public reports/errors, source-scoped orchestration, batching, failure mapping, and cancellation cleanup.
- `Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift` — proves attempt-state guards, recovery, retry, exact cleanup, and snapshot preservation against real GRDB rows.
- `Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift` — proves orchestration, concurrency, idempotence, error priority, recovery, cancellation, stale-input rejection, and real-analyzer integration.
- `docs/superpowers/specs/2026-08-25-document-dna-analysis-pipeline-design.md` — records approved status.
- `docs/superpowers/plans/2026-08-25-document-dna-analysis-pipeline.md` — records the TDD execution and verification evidence.

---

### Task 1: Guarded analyzing and failed repository transitions

**Files:**

- Modify: `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift:36-121`
- Modify: `Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift:1-360`

**Interfaces:**

- Consumes: `PendingDocumentDNAAnalysis`, `DocumentDNAAnalysisTarget`, `DocumentRecord`, `StoredExtraction`, and the existing `documentDNAAnalysisState` table.
- Produces:

```swift
public enum DocumentDNAAnalysisFailureCode: String, Sendable, Equatable {
    case analysisFailure
    case invalidFinding
    case invalidProvenance
}

public actor DocumentDNARepository {
    public func beginAnalysis(
        _ candidate: PendingDocumentDNAAnalysis,
        target: DocumentDNAAnalysisTarget,
        at date: Date
    ) async throws

    public func markAnalysisFailed(
        _ candidate: PendingDocumentDNAAnalysis,
        target: DocumentDNAAnalysisTarget,
        failureCode: DocumentDNAAnalysisFailureCode,
        at date: Date
    ) async throws
}
```

- [x] **Step 1: Add failing literal tests for begin and exact failed transition**

Add tests that load the existing fixture's one pending candidate, begin it at a fixed date, inspect the literal state row, and prove the candidate is no longer pending. Then transition the same exact attempt to each of the three enum failure codes and prove the row is `failed`, its tuple is unchanged, and the completed snapshot remains untouched.

```swift
@Test func beginAnalysisWritesExactAttemptAndBlocksPendingSelection() async throws {
    let fixture = try await DocumentDNARepositoryFixture.make()
    let candidate = try #require(try await fixture.repository.pendingAnalysis(
        sourceRootID: fixture.source.id,
        target: fixture.target,
        limit: 1
    ).first)
    let startedAt = Date(timeIntervalSince1970: 1_800_000_100)

    try await fixture.repository.beginAnalysis(
        candidate,
        target: fixture.target,
        at: startedAt
    )

    #expect(try await fixture.analysisState(documentID: candidate.document.id) ==
        LiteralAnalysisState(
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            contentHash: "hash-ready",
            extractionVersion: "text-v1",
            status: "analyzing",
            failureCode: nil
        ))
    #expect(try await fixture.analysisStateUpdatedAt(
        documentID: candidate.document.id
    ) == startedAt)
    #expect(try await fixture.repository.pendingAnalysis(
        sourceRootID: fixture.source.id,
        target: fixture.target,
        limit: 1
    ).isEmpty)
}

@Test(arguments: DocumentDNAAnalysisFailureCode.allCases)
func markAnalysisFailedUpdatesOnlyExactAttempt(
    failureCode: DocumentDNAAnalysisFailureCode
) async throws {
    let fixture = try await DocumentDNARepositoryFixture.make()
    let prior = try await fixture.snapshot(analyzerVersion: "0")
    try await fixture.repository.replace(prior)
    let candidate = try #require(try await fixture.repository.pendingAnalysis(
        sourceRootID: fixture.source.id,
        target: fixture.target,
        limit: 1
    ).first)
    try await fixture.repository.beginAnalysis(candidate, target: fixture.target, at: .now)
    let failedAt = Date(timeIntervalSince1970: 1_800_000_200)

    try await fixture.repository.markAnalysisFailed(
        candidate,
        target: fixture.target,
        failureCode: failureCode,
        at: failedAt
    )

    #expect(try await fixture.analysisState(documentID: candidate.document.id)?.status == "failed")
    #expect(try await fixture.analysisState(documentID: candidate.document.id)?.failureCode == failureCode.rawValue)
    #expect(try await fixture.repository.storedSnapshot(documentID: candidate.document.id) == prior)
}
```

Make `DocumentDNAAnalysisFailureCode` conform to `CaseIterable` so the argument test covers the closed code set.

- [x] **Step 2: Run the two tests and verify RED**

Run:

```sh
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter 'beginAnalysisWritesExactAttemptAndBlocksPendingSelection|markAnalysisFailedUpdatesOnlyExactAttempt'
```

Expected: compilation fails because the failure-code enum and repository methods do not exist.

- [x] **Step 3: Implement the minimum exact begin transaction**

Add the enum and a private eligibility guard that reuses the candidate's literal tuple. `beginAnalysis` must perform a single `INSERT ... ON CONFLICT DO UPDATE` only after this SQL existence check returns true:

```sql
SELECT EXISTS (
    SELECT 1
    FROM document
    JOIN documentExtraction ON documentExtraction.documentID = document.id
    WHERE document.id = ?
      AND document.sourceRootID = ?
      AND document.status = 'ready'
      AND document.availability = 'available'
      AND document.contentHash = ?
      AND documentExtraction.analysisVersion = ?
      AND NOT EXISTS (
          SELECT 1 FROM documentDNA
          WHERE documentDNA.documentID = document.id
            AND documentDNA.schemaVersion = ?
            AND documentDNA.analyzerIdentifier = ?
            AND documentDNA.analyzerVersion = ?
            AND documentDNA.inputContentHash = document.contentHash
            AND documentDNA.inputExtractionVersion = documentExtraction.analysisVersion
      )
      AND NOT EXISTS (
          SELECT 1 FROM documentDNAAnalysisState
          WHERE documentDNAAnalysisState.documentID = document.id
            AND documentDNAAnalysisState.targetSchemaVersion = ?
            AND documentDNAAnalysisState.targetAnalyzerIdentifier = ?
            AND documentDNAAnalysisState.targetAnalyzerVersion = ?
            AND documentDNAAnalysisState.inputContentHash = document.contentHash
            AND documentDNAAnalysisState.inputExtractionVersion = documentExtraction.analysisVersion
            AND documentDNAAnalysisState.status IN ('failed', 'analyzing')
      )
)
```

Throw `.staleInput` when false. The upsert writes the target/input tuple, `status = 'analyzing'`, `failureCode = NULL`, and the supplied `Date` using GRDB's established date encoding.

- [x] **Step 4: Implement the minimum exact failed transaction and verify GREEN**

Use one guarded update:

```sql
UPDATE documentDNAAnalysisState
SET status = 'failed', failureCode = ?, updatedAt = ?
WHERE documentID = ?
  AND targetSchemaVersion = ?
  AND targetAnalyzerIdentifier = ?
  AND targetAnalyzerVersion = ?
  AND inputContentHash = ?
  AND inputExtractionVersion = ?
  AND status = 'analyzing'
  AND EXISTS (
      SELECT 1
      FROM document
      JOIN documentExtraction ON documentExtraction.documentID = document.id
      WHERE document.id = documentDNAAnalysisState.documentID
        AND document.status = 'ready'
        AND document.availability = 'available'
        AND document.contentHash = documentDNAAnalysisState.inputContentHash
        AND documentExtraction.analysisVersion =
            documentDNAAnalysisState.inputExtractionVersion
  )
```

Require `db.changesCount == 1`, otherwise throw `.staleInput`. Re-run Step 2 and the complete `DocumentDNARepositoryTests` suite.

- [x] **Step 5: Add stale and superseded RED regressions**

Add separate tests that fetch a candidate and then change each of these before begin: content hash, extraction version, document status, availability, current snapshot, exact failed state, and exact analyzing state. Assert `.staleInput` and unchanged prior rows. Add failed-transition tests for a different target, different candidate content hash, changed current extraction, and a state already made `ready`; assert `.staleInput` and preservation.

```swift
@Test func beginRejectsCandidateAfterContentHashChanges() async throws
@Test func beginRejectsCandidateAfterExtractionVersionChanges() async throws
@Test func beginRejectsDocumentThatIsNotReadyOrAvailable() async throws
@Test func beginRejectsCurrentSnapshotAndExactBlockedAttempt() async throws
@Test func failedTransitionRejectsSupersededTupleAndTerminalState() async throws
```

The test mutation helpers must use literal SQL in the fixture and must never modify source files.

- [x] **Step 6: Run stale regressions RED, tighten guards, and verify GREEN**

Run the new test names with the fallback command. Confirm at least one case fails for each missing guard before modifying production code. Tighten only the SQL arguments/conditions required by those failures, then rerun the focused names and all repository tests.

- [x] **Step 7: Commit guarded attempt transitions**

```sh
git add Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift \
  Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift \
  docs/superpowers/specs/2026-08-25-document-dna-analysis-pipeline-design.md \
  docs/superpowers/plans/2026-08-25-document-dna-analysis-pipeline.md
git commit -m "feat(dna): add guarded analysis attempts"
```

---

### Task 2: Recovery, exact interruption restoration, and manual retry

**Files:**

- Modify: `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift:42-240`
- Modify: `Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift:1-500`

**Interfaces:**

- Consumes: Task 1's exact `analyzing` and `failed` state rows.
- Produces:

```swift
public actor DocumentDNARepository {
    public func restoreAnalysisAfterInterruption(
        _ candidate: PendingDocumentDNAAnalysis,
        target: DocumentDNAAnalysisTarget
    ) async throws

    public func recoverInterruptedAnalysis(sourceRootID: UUID) async throws

    public func retryFailedAnalysis(documentID: UUID) async throws
}
```

- [x] **Step 1: Write failing exact restoration tests**

Add one test that begins a candidate, restores it, proves the row is absent and the candidate is pending again, then restores it a second time to prove idempotence. Add literal state variants proving restoration does not delete a different target/input tuple or a `ready`/`failed` state.

```swift
@Test func interruptionRestorationIsExactAndIdempotent() async throws {
    let fixture = try await DocumentDNARepositoryFixture.make()
    let candidate = try #require(try await fixture.repository.pendingAnalysis(
        sourceRootID: fixture.source.id,
        target: fixture.target,
        limit: 1
    ).first)
    try await fixture.repository.beginAnalysis(candidate, target: fixture.target, at: .now)

    try await fixture.repository.restoreAnalysisAfterInterruption(
        candidate,
        target: fixture.target
    )
    try await fixture.repository.restoreAnalysisAfterInterruption(
        candidate,
        target: fixture.target
    )

    #expect(try await fixture.analysisState(documentID: candidate.document.id) == nil)
    #expect(try await fixture.repository.pendingAnalysis(
        sourceRootID: fixture.source.id,
        target: fixture.target,
        limit: 1
    ).map(\.document.id) == [candidate.document.id])
}
```

- [x] **Step 2: Run restoration test RED**

Run the fallback command filtered to `interruptionRestorationIsExactAndIdempotent`. Expected: compilation fails because the method does not exist.

- [x] **Step 3: Implement exact idempotent restoration and verify GREEN**

Delete only the full tuple with `status = 'analyzing'`:

```sql
DELETE FROM documentDNAAnalysisState
WHERE documentID = ?
  AND targetSchemaVersion = ?
  AND targetAnalyzerIdentifier = ?
  AND targetAnalyzerVersion = ?
  AND inputContentHash = ?
  AND inputExtractionVersion = ?
  AND status = 'analyzing'
```

Zero changed rows is success. A GRDB error propagates. Rerun all restoration variants.

- [x] **Step 4: Write failing source recovery and retry tests**

Create two sources, begin one attempt in each, and create ready/failed rows. Recover source A and assert only source A's analyzing row is removed. Then retry a failed document twice and assert only its failed row is removed while its prior snapshot and every ready/analyzing row remain.

```swift
@Test func recoveryRemovesOnlyAnalyzingAttemptsForRequestedSource() async throws {
    let fixture = try await DocumentDNARepositoryFixture.makeWithTwoSourcesAndStates()

    try await fixture.repository.recoverInterruptedAnalysis(sourceRootID: fixture.source.id)

    #expect(try await fixture.analysisStatus(relativePath: "source-a-analyzing.pdf") == nil)
    #expect(try await fixture.analysisStatus(relativePath: "source-a-failed.pdf") == "failed")
    #expect(try await fixture.analysisStatus(relativePath: "source-a-ready.pdf") == "ready")
    #expect(try await fixture.analysisStatus(relativePath: "source-b-analyzing.pdf") == "analyzing")
}

@Test func retryIsIdempotentAndClearsOnlyFailedState() async throws {
    let fixture = try await DocumentDNARepositoryFixture.makeWithRetryStates()
    let failedID = try #require(await fixture.documentID(relativePath: "failed.pdf"))

    try await fixture.repository.retryFailedAnalysis(documentID: failedID)
    try await fixture.repository.retryFailedAnalysis(documentID: failedID)

    #expect(try await fixture.analysisStatus(relativePath: "failed.pdf") == nil)
    #expect(try await fixture.analysisStatus(relativePath: "ready.pdf") == "ready")
    #expect(try await fixture.analysisStatus(relativePath: "analyzing.pdf") == "analyzing")
    #expect(try await fixture.repository.storedSnapshot(documentID: failedID) != nil)
}
```

- [x] **Step 5: Run recovery/retry tests RED**

Run the fallback command filtered to both new names. Expected: compilation fails because both methods are missing.

- [x] **Step 6: Implement scoped recovery and failed-only retry, then verify GREEN**

Recovery SQL:

```sql
DELETE FROM documentDNAAnalysisState
WHERE status = 'analyzing'
  AND documentID IN (
      SELECT id FROM document WHERE sourceRootID = ?
  )
```

Retry SQL:

```sql
DELETE FROM documentDNAAnalysisState
WHERE documentID = ? AND status = 'failed'
```

Both operations are idempotent. Rerun the focused tests and the full repository suite.

- [x] **Step 7: Commit recovery and retry behavior**

```sh
git add Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift \
  Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift \
  docs/superpowers/plans/2026-08-25-document-dna-analysis-pipeline.md
git commit -m "feat(dna): recover and retry analysis attempts"
```

---

### Task 3: Happy-path pipeline, bounded batches, and version idempotence

**Files:**

- Create: `Sources/LinkLoomCore/Pipeline/DocumentDNAAnalysisPipeline.swift`
- Create: `Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift`

**Interfaces:**

- Consumes: the Task 1-2 repository operations, `DocumentDNAAnalyzing`, `DocumentDNAAnalysisTarget`, and `DocumentDNARepository.replace`.
- Produces:

```swift
public struct DocumentDNAAnalysisReport: Sendable, Equatable {
    public let completed: Int
    public let failed: Int

    public init(completed: Int, failed: Int)
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
    )
}

public actor DocumentDNAAnalysisPipeline {
    public init(
        repository: DocumentDNARepository,
        analyzer: any DocumentDNAAnalyzing,
        target: DocumentDNAAnalysisTarget,
        now: @escaping @Sendable () -> Date = Date.init
    )

    public func processPending(
        sourceRootID: UUID,
        limit: Int = 2
    ) async throws -> DocumentDNAAnalysisReport
}
```

- [x] **Step 1: Create the real in-memory pipeline fixture and first failing test**

The fixture must seed synthetic ready documents through real GRDB repositories, build a target, and supply a `RecordingDocumentDNAAnalyzer` actor that returns one valid classification snapshot per candidate while recording call count and peak concurrency.

```swift
@Suite("Document DNA analysis pipeline")
struct DocumentDNAAnalysisPipelineTests {
    @Test func firstRunPersistsEveryPendingSnapshot() async throws {
        let fixture = try await DocumentDNAAnalysisPipelineFixture.make(documentCount: 3)

        let report = try await fixture.pipeline.processPending(
            sourceRootID: fixture.source.id,
            limit: 2
        )

        #expect(report == DocumentDNAAnalysisReport(completed: 3, failed: 0))
        #expect(await fixture.analyzer.callCount == 3)
        for documentID in fixture.documentIDs {
            #expect(try await fixture.repository.currentSnapshot(
                documentID: documentID,
                target: fixture.target
            ) != nil)
        }
    }
}
```

The analyzer must build literal evidence from the seeded page's `Rechnung` span `(pageIndex: 0, startUTF16: 0, lengthUTF16: 8)` and set the snapshot target/input fields from its arguments.

- [x] **Step 2: Run the first pipeline test RED**

Run the fallback command filtered to `firstRunPersistsEveryPendingSnapshot`. Expected: compilation fails because the pipeline/report types do not exist.

- [x] **Step 3: Implement public values and the minimum sequential pipeline GREEN**

Implement the public values exactly as declared. Add a first pipeline loop that, for each pending candidate, gets one `Date`, calls `beginAnalysis`, invokes `analyzer.analyze`, checks cancellation, and calls `repository.replace`. Loop pending batches until empty and return accumulated counts. This first implementation may process the batch sequentially; concurrency is added only after its failing test.

```swift
var batch = try await pendingAnalysis(sourceRootID, target, limit)
var completed = 0
while !batch.isEmpty {
    for candidate in batch {
        let analyzedAt = now()
        try await repository.beginAnalysis(candidate, target: target, at: analyzedAt)
        let snapshot = try analyzer.analyze(
            documentID: candidate.document.id,
            contentHash: candidate.document.contentHash,
            extraction: candidate.extraction,
            analyzedAt: analyzedAt
        )
        try Task.checkCancellation()
        try await repository.replace(snapshot)
        completed += 1
    }
    batch = try await pendingAnalysis(sourceRootID, target, limit)
}
return DocumentDNAAnalysisReport(completed: completed, failed: 0)
```

Use a production initializer that stores concrete repository operations and an internal initializer with injected `@Sendable` closures for pending/recovery/begin/fail/restore/replace only when later failure tests require deterministic injection.

Re-run the first test and confirm GREEN.

- [x] **Step 4: Add same-version, target-version, and zero-limit tests RED**

Add tests proving:

```swift
@Test func unchangedRerunPerformsNoAnalyzerOrStateWork() async throws
@Test func analyzerAndSchemaChangesEachReplaceExactlyOnce() async throws
@Test func nonPositiveLimitPerformsNoRecoveryQueryOrAnalysis() async throws
```

For the rerun, capture analyzer calls and DNA row counts after the first run, run again, and require an empty report, unchanged counts, and unchanged calls. For version changes, instantiate pipelines with analyzer-version 2 and then schema-version 2, require one completion for each change, then an empty rerun. For zero/negative limits, use injected closures that record any invocation and assert none occur.

- [x] **Step 5: Run version/limit tests RED and implement only missing behavior GREEN**

Use the repository pending query as the sole idempotence mechanism. Guard non-positive limits before coordinator/recovery/query. Do not add an in-memory processed-ID cache. Re-run all four pipeline tests.

- [x] **Step 6: Add bounded-concurrency test RED**

Seed five documents. The analyzer suspends each call for 20 milliseconds while tracking active and peak counts.

```swift
@Test func limitBoundsConcurrencyWithoutTruncatingLaterBatches() async throws {
    let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
        documentCount: 5,
        analysisDelay: .milliseconds(20)
    )

    let report = try await fixture.pipeline.processPending(
        sourceRootID: fixture.source.id,
        limit: 2
    )

    #expect(report == DocumentDNAAnalysisReport(completed: 5, failed: 0))
    #expect(await fixture.analyzer.peakConcurrency == 2)
}
```

Expected before the change: GREEN report but peak concurrency is 1.

- [x] **Step 7: Replace sequential batch work with a bounded task group GREEN**

Add private outcomes and batch results:

```swift
private enum DocumentDNAProcessingOutcome: Sendable {
    case completed
    case failed
    case runFailure(DocumentDNAAnalysisRunFailureReason)
}

private struct DocumentDNABatchResult: Sendable {
    let report: DocumentDNAAnalysisReport
    let failureReason: DocumentDNAAnalysisRunFailureReason?
}
```

Add exactly one child task per candidate in the already limited batch, drain every outcome, and sum durable results. Re-run the concurrency test, all pipeline tests, and repository tests.

- [x] **Step 8: Commit happy-path pipeline**

```sh
git add Sources/LinkLoomCore/Pipeline/DocumentDNAAnalysisPipeline.swift \
  Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift \
  docs/superpowers/plans/2026-08-25-document-dna-analysis-pipeline.md
git commit -m "feat(dna): analyze pending snapshots"
```

---

### Task 4: Deterministic failures, typed run errors, stale input, and cancellation

**Files:**

- Modify: `Sources/LinkLoomCore/Pipeline/DocumentDNAAnalysisPipeline.swift`
- Modify: `Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift`

**Interfaces:**

- Consumes: Task 3 pipeline values and Task 1-2 exact repository transitions.
- Produces: complete failure mapping and restoration behavior required by design sections 9-10.

- [x] **Step 1: Write failing deterministic document-failure isolation tests**

Configure three candidates so the analyzer returns success, throws `DocumentDNAValidationError.invalidFinding`, and throws a synthetic analyzer error. Add an invalid-provenance analyzer result whose exact text does not match the stored page. Require two failed rows with `invalidFinding`/`analysisFailure` in the first test and `invalidProvenance` in the provenance test, while successful documents commit and prior snapshots remain.

```swift
@Test func deterministicFailuresAreIsolatedWithStableCodes() async throws {
    let fixture = try await DocumentDNAAnalysisPipelineFixture.makeWithAnalyzerOutcomes([
        .success,
        .error(DocumentDNAValidationError.invalidFinding),
        .error(SyntheticAnalyzerError.rejected),
    ])

    let report = try await fixture.pipeline.processPending(
        sourceRootID: fixture.source.id,
        limit: 3
    )

    #expect(report == DocumentDNAAnalysisReport(completed: 1, failed: 2))
    #expect(try await fixture.failureCodesInPathOrder() == [
        nil, "invalidFinding", "analysisFailure",
    ])
}
```

- [x] **Step 2: Run failure tests RED, implement mapping, verify GREEN**

In candidate processing:

```swift
private static func failureCode(for error: Error) -> DocumentDNAAnalysisFailureCode {
    switch error {
    case is DocumentDNAValidationError:
        .invalidFinding
    case DocumentDNARepositoryError.invalidProvenance:
        .invalidProvenance
    default:
        .analysisFailure
    }
}
```

Analyzer errors are mapped and written through `markAnalysisFailed`. Repository `.invalidProvenance` from `replace` is also mapped and written. A successful failed-state write returns `.failed`; a persistence error while writing it returns `.runFailure(.persistence)`; `.staleInput` returns `.runFailure(.staleInput)`. Re-run the focused tests.

- [x] **Step 3: Add pending-query and partial-report RED tests**

Use the internal injected pending closure to throw on call 1 and, separately, after one successful batch. Assert:

```swift
DocumentDNAAnalysisRunError(
    reason: .pendingQuery,
    partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
)

DocumentDNAAnalysisRunError(
    reason: .pendingQuery,
    partialReport: DocumentDNAAnalysisReport(completed: 1, failed: 0)
)
```

Add injected begin/failure/replace errors and require `.persistence`. Add a same-batch injected persistence and stale-input pair and require persistence priority with all durable sibling outcomes counted.

- [x] **Step 4: Run typed-error tests RED, implement stable mapping and priority GREEN**

Catch cancellation separately from query errors. After each batch, select failure reason using:

```swift
let priority: [DocumentDNAAnalysisRunFailureReason] = [
    .persistence,
    .staleInput,
    .cancelled,
]
```

Stop before another batch when any run failure exists. Throw `DocumentDNAAnalysisRunError` with the accumulated durable report. Re-run focused tests.

- [x] **Step 5: Add stale-during-analysis RED tests**

Suspend the analyzer after begin. Change the catalog content hash in one test and the extraction version in another, then release analysis. Require `.staleInput`, a zero report, the old snapshot unchanged, and no partial replacement rows.

```swift
@Test func contentChangeDuringAnalysisRejectsStaleSnapshot() async throws
@Test func extractionVersionChangeDuringAnalysisRejectsStaleSnapshot() async throws
```

- [x] **Step 6: Run stale tests RED, preserve repository stale classification GREEN**

Map only `DocumentDNARepositoryError.staleInput` to `.staleInput`; do not classify arbitrary GRDB or analyzer errors as stale. Re-run both stale tests and all typed-error tests.

- [x] **Step 7: Add cancellation restoration RED tests**

Suspend analysis after the exact attempt is durable, cancel the run task, release the analyzer, and require:

```swift
DocumentDNAAnalysisRunError(
    reason: .cancelled,
    partialReport: DocumentDNAAnalysisReport(completed: 0, failed: 0)
)
```

Assert the attempt row is absent, the prior snapshot is unchanged, and the candidate is pending again. Add an internal restore closure that throws and require `.persistence` instead. Add pre-cancelled and cancellation-before-begin tests proving no state is created.

- [x] **Step 8: Run cancellation tests RED, add exact unstructured cleanup GREEN**

Check cancellation before begin, after begin, after analyzer return, and before replace. On cancellation after begin, run:

```swift
let restored = await Task {
    do {
        try await restoreAnalysisAfterInterruption(candidate, target: target)
        return true
    } catch {
        return false
    }
}.value
return .runFailure(restored ? .cancelled : .persistence)
```

Once `replace` returns, return `.completed` without another cancellation check. Re-run cancellation, stale, failure, and full pipeline suites.

- [x] **Step 9: Commit failure and cancellation reliability**

```sh
git add Sources/LinkLoomCore/Pipeline/DocumentDNAAnalysisPipeline.swift \
  Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift \
  docs/superpowers/plans/2026-08-25-document-dna-analysis-pipeline.md
git commit -m "fix(dna): preserve analysis retryability"
```

---

### Task 5: Source coordination, startup recovery, retry, and real-analyzer integration

**Files:**

- Modify: `Sources/LinkLoomCore/Pipeline/DocumentDNAAnalysisPipeline.swift`
- Modify: `Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift`

**Interfaces:**

- Consumes: complete Task 1-4 pipeline and repository contracts.
- Produces: cross-instance source coordination and final integrated local behavior.

- [x] **Step 1: Add overlapping same-source instance RED test**

Create two pipeline instances sharing repository/target/analyzer. Block the first analyzer call, start the second run, and prove the analyzer never sees duplicate active work. Release and require one combined completion per document, with the second run returning only work left after the first.

```swift
@Test func overlappingInstancesSerializeSameSourceWithoutDuplicateAnalysis() async throws {
    let fixture = try await DocumentDNAAnalysisPipelineFixture.make(
        documentCount: 2,
        analyzerStartsBlocked: true
    )
    let secondPipeline = fixture.makePipeline()

    async let first = fixture.pipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
    await fixture.analyzer.waitUntilFirstCallStarts()
    async let second = secondPipeline.processPending(sourceRootID: fixture.source.id, limit: 1)
    await fixture.analyzer.releaseAll()

    let reports = try await [first, second]
    #expect(reports.reduce(0) { $0 + $1.completed } == 2)
    #expect(await fixture.analyzer.callCount == 2)
    #expect(await fixture.analyzer.duplicateDocumentCalls == 0)
}
```

- [x] **Step 2: Run same-source test RED and add shared coordinator GREEN**

Implement a private actor with the same FIFO/cancellable waiter shape as `IngestionRunCoordinator`, but scoped to DNA:

```swift
private actor DocumentDNAAnalysisRunCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var activeSourceRootIDs = Set<UUID>()
    private var waiters: [UUID: [Waiter]] = [:]

    func acquire(sourceRootID: UUID) async throws
    func release(sourceRootID: UUID)
    private func cancelWaiter(id: UUID, sourceRootID: UUID)
}
```

Store one `private static let coordinator`. Acquire after the positive-limit guard and release on every path. Cancellation while waiting maps to `.cancelled` with an empty report. Re-run the same-source test.

- [x] **Step 3: Add different-source concurrency and cancelled-waiter RED tests**

Seed one document per source. Require both analyzer calls to start before either is released. For a queued same-source run, cancel only the waiter and prove the owner continues, the cancelled run throws `.cancelled`, and the next waiter can run after release.

```swift
@Test func differentSourcesAnalyzeConcurrently() async throws
@Test func cancellingQueuedRunDoesNotCancelOwnerOrNextWaiter() async throws
```

- [x] **Step 4: Run coordinator edge tests RED, finish FIFO cancellation GREEN**

Port the proven `withTaskCancellationHandler`/checked-continuation logic from `IngestionRunCoordinator` exactly, changing only type names. Re-run all coordination tests.

- [x] **Step 5: Add run-start recovery and manual retry pipeline tests RED**

Seed an orphaned analyzing attempt, invoke the pipeline, and require one completion. Seed an exact failed attempt, require an empty run, call `retryFailedAnalysis`, and require exactly one failed or completed attempt according to the configured analyzer outcome; the second rerun must again be empty.

```swift
@Test func runStartRecoveryResumesOrphanedAnalyzingAttempt() async throws
@Test func manualRetryMakesOnlyExactFailedDocumentEligible() async throws
```

- [x] **Step 6: Invoke recovery before first query and verify retry GREEN**

After coordinator acquisition, call `recoverInterruptedAnalysis(sourceRootID:)`. Map cancellation to `.cancelled` and other errors to `.persistence`, both with an empty report. Do not recover for non-positive limits. Re-run focused tests.

```swift
do {
    try await recoverInterruptedAnalysis(sourceRootID)
} catch is CancellationError {
    throw DocumentDNAAnalysisRunError(reason: .cancelled, partialReport: emptyReport)
} catch {
    throw DocumentDNAAnalysisRunError(reason: .persistence, partialReport: emptyReport)
}
```

- [x] **Step 7: Add real local analyzer integration test RED**

Seed one literal extraction:

```text
Rechnung
Rechnungssteller: Pflegezentrum Sonnenrain AG
Bewohnerin: Elise Muster
Rechnungsnummer: RE-2026-0815
Total CHF 1200.00
```

Use fixed document UUID, hash, extraction version, target constants, and `Date`. Run `LocalRulesDocumentDNAAnalyzer` through the real pipeline. Reload the complete snapshot and compare it to a literal expected `DocumentDNA` assembled in the test with exact UTF-16 ranges and empty OCR region indexes. Also verify report `(1, 0)` and unchanged `document.status == .ready`.

- [x] **Step 8: Run integration RED, adjust only fixture literals, verify GREEN**

The production pipeline must already support this flow. If the test fails because a literal does not match the accepted local analyzer contract, correct only the synthetic test input/expected offsets after checking the existing analyzer tests. Do not modify analyzer rules in this slice. Then run all pipeline and repository tests.

- [x] **Step 9: Commit coordination and integration**

```sh
git add Sources/LinkLoomCore/Pipeline/DocumentDNAAnalysisPipeline.swift \
  Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift \
  docs/superpowers/plans/2026-08-25-document-dna-analysis-pipeline.md
git commit -m "test(dna): verify coordinated local analysis"
```

---

### Task 6: Complete verification, independent review, and pull request

**Files:**

- Modify: `docs/superpowers/plans/2026-08-25-document-dna-analysis-pipeline.md` only to mark completed checkboxes and record exact evidence.
- Modify production/tests only when a fresh failing regression proves a review or verification defect.

**Interfaces:**

- Consumes: all Task 1-5 deliverables.
- Produces: a clean, reviewable branch and a focused pull request; no merge.

## Final verification evidence

Final independent verification passed at `66b8243f413f8bfae1b858bd75bf6b8063a78d59`.
The final review verdict was **PASS** with no Critical, Important, or Minor
findings. An analyzer-output identity defect was reproduced, then fixed by the
six-field pre-replace identity guard; its two named identity regressions pass,
including five parameter cases.

- Identity regressions: 2/2 (five parameter cases included).
- Focused repository and pipeline suites: 64/64.
- Complete documented CLT fallback suite: 263/263 across 23 suites. The only
  skip is the intentionally opt-in `catalogHandlesTenThousandDocumentsIdempotently`
  benchmark.
- Release build: documented fallback passed in 45.18 seconds. No warning is
  attributable to this branch; only the known non-branch SwiftPM user-cache
  warnings were emitted.
- `origin/main` and merge base are both
  `8ff3f43ad41898cbbc638e0281fad84babadbd33`; the branch is 0 behind.
  Diff, cached-diff, and status checks are clean.
- The complete review confirms the approved six-file scope only: repository
  transition API/tests, the local Core pipeline/tests, and its specification
  and plan. Processing consumes persisted local extraction data, reuses v5
  without a migration, and introduces no app/UI, watcher, composition,
  dependency, source-document, network, telemetry, database artifact, or
  generated-artifact change.

- [x] **Step 1: Run focused repository and pipeline suites**

```sh
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter 'DocumentDNARepositoryTests|DocumentDNAAnalysisPipelineTests'
```

Expected: every attempt-transition, orchestration, concurrency, failure, retry, recovery, stale, cancellation, partial-report, and integration test passes.

- [x] **Step 2: Run the complete non-opt-in suite**

Run the same fallback command without `--filter`. Expected: all tests pass and `catalogHandlesTenThousandDocumentsIdempotently` is the only opt-in skip.

- [x] **Step 3: Run the release build**

```sh
swift build -c release
```

Expected: production build succeeds without warnings attributable to this branch.

- [x] **Step 4: Verify diff hygiene and scope**

```sh
git diff --check origin/main...HEAD
git diff --cached --check
git status --short
git diff --stat origin/main...HEAD
git diff --name-status origin/main...HEAD
```

Inspect the full diff. It must contain only the approved spec/plan, repository transition API/tests, and the new pipeline/tests. Confirm absence of migration, app/UI, watcher, composition, package dependency, source-file, network, telemetry, real personal data, database, `.build`, `.superpowers`, GitHub setting, and generated artifacts.

- [x] **Step 5: Request independent code review**

Use `superpowers:requesting-code-review` and request a fresh reviewer focused on:

- exact tuple guards and atomic snapshot preservation;
- source-scoped cross-instance coordination and waiter cancellation;
- deterministic failure mapping and same-batch priority;
- cancellation cleanup and stale-input races;
- idempotence/version changes and bounded concurrency;
- local privacy and scope boundaries.

Resolve every Critical/Important finding through `superpowers:receiving-code-review`: reproduce it with a failing test, observe RED, make the minimal fix, rerun focused tests, and repeat Steps 1-4.

- [x] **Step 6: Commit final plan evidence**

```sh
git add docs/superpowers/plans/2026-08-25-document-dna-analysis-pipeline.md
git diff --cached --check
git commit -m "docs: record DNA pipeline verification"
```

- [ ] **Step 7: Push and open the focused pull request**

Push without force. Create a PR with title:

```text
feat(dna): add coordinated analysis pipeline
```

The PR body must report exact focused/full/release verification, explain that processing uses only persisted local extraction data, state that v5 is reused with no migration, list the three privacy-safe failure codes, identify additive API compatibility and rollback risk, explain any diff above 500 non-generated lines, and explicitly state that app composition/UI/network/dependencies are excluded.

- [ ] **Step 8: Wait for required checks and report without merging**

Confirm `Policy / validate`, `Swift / test`, `Swift / release-build`, and `Swift / UI smoke` pass. Report the PR URL, head commit, exact CI results, remaining risks, and independent-review verdict. Do not merge until the user provides a new explicit merge authorization.
