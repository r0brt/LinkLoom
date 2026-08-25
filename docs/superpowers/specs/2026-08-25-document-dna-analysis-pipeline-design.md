# Document DNA Analysis Pipeline Design

**Status:** Proposed for written-spec review

**Date:** 2026-08-25

**Scope:** Local orchestration of persisted Document DNA analysis

**Builds on:**

- `2026-08-08-linkloom-product-design.md`;
- `2026-08-12-linkloom-ingestion-hardening-design.md`;
- `2026-08-16-p0-reliability-hardening-design.md`;
- `2026-08-24-document-dna-vertical-slice-design.md`;
- the Document DNA analyzer and repository merged on `origin/main` in PRs
  #21 and #22.

## 1. Objective

Add the missing `LinkLoomCore` orchestration stage that turns coherent pending
Document DNA inputs into durable analysis attempts and complete snapshots. The
stage must process ready extracted documents locally, concurrently within a
small bound, and independently per source. It must be idempotent for unchanged
inputs and targets, recover from interrupted attempts, isolate deterministic
document failures, and reject stale work without replacing the last completed
snapshot.

This is a focused pipeline slice. It does not yet wire DNA analysis into the
application model, watcher, or executable composition root. That integration
is a separate reviewable outcome after the core orchestration contract is
proven.

## 2. Current State

`origin/main` already contains the inputs and outputs required by the pipeline:

- `DocumentDNAAnalyzing` consumes a document ID, content hash,
  `StoredExtraction`, and explicit analysis time;
- `LocalRulesDocumentDNAAnalyzer` supplies the fully local v1 implementation;
- `DocumentDNAAnalysisTarget` identifies the schema and analyzer versions;
- `DocumentDNARepository.pendingAnalysis` returns source-scoped coherent
  `DocumentRecord` and `StoredExtraction` pairs;
- `DocumentDNARepository.replace` validates current content/extraction inputs
  and exact provenance, replaces the full snapshot in one transaction, and
  records `ready` analysis state;
- `documentDNAAnalysisState` already supports `analyzing`, `ready`, and
  `failed`, but the repository exposes no attempt-transition operations;
- pending selection already skips a current snapshot and an exact `failed` or
  `analyzing` attempt while selecting changed targets or inputs;
- the existing `IngestionPipeline` establishes the accepted source-scoped
  coordination, bounded batching, partial-report, cancellation-restoration,
  and run-error shape.

The pipeline consumes only persisted extraction data. It does not resolve a
bookmark, open a source document, or start a security-scoped access session.

## 3. Chosen Approach

Add a dedicated `DocumentDNAAnalysisPipeline` actor and extend
`DocumentDNARepository` with exact attempt transitions. The pipeline mirrors
the proven reliability shape of `IngestionPipeline` while keeping DNA state
separate from `document.status`.

The alternatives are not selected:

1. A pipeline without durable attempt state cannot distinguish an interrupted
   analysis from never-started work and cannot block repeated deterministic
   failures.
2. A database lease queue with claim tokens and expiry would support multiple
   processes, but LinkLoom currently has one local application process. It
   would require extra schema and timing policy without improving this slice.
3. Folding DNA directly into `IngestionPipeline` would couple file access and
   text extraction to structured analysis, weaken independent retry/version
   semantics, and make the change substantially harder to review.

## 4. Scope

### 4.1 Included

- a source-scoped Document DNA analysis pipeline in `LinkLoomCore`;
- a configured, validated `DocumentDNAAnalysisTarget` supplied at
  initialization;
- durable `analyzing`, `failed`, and existing atomic `ready` transitions;
- deterministic, privacy-safe analysis failure codes;
- run-start recovery for orphaned `analyzing` attempts;
- explicit manual retry of failed attempts;
- bounded concurrent analysis with stable pending batches;
- source-scoped serialization shared by all pipeline instances;
- typed run failures with a durable partial report;
- cancellation cleanup that preserves the last completed snapshot;
- stale-input rejection for catalog or extraction changes;
- same-version idempotence and controlled target-version reanalysis;
- repository transition tests, pipeline tests, and one real-analyzer
  in-memory integration test.

### 4.2 Excluded

- changes to the v5 schema or a new migration;
- changes to the analyzer, golden fixtures, or DNA domain schema unless a
  pipeline test exposes a defect that must be handled in a separate scope;
- application-model, SwiftUI, watcher, rescan-scheduler, startup-controller,
  or executable-composition changes;
- progress UI, retry UI, or operator documentation;
- file access, OCR, extraction, FTS, catalog status, or source availability
  changes;
- entity resolution, relationships, dossiers, contexts, or user decisions;
- networking, external AI, telemetry, model downloads, or new dependencies.

## 5. Public Pipeline Contract

The pipeline adds these `Sendable` values:

```swift
public struct DocumentDNAAnalysisReport: Sendable, Equatable {
    public let completed: Int
    public let failed: Int
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
}
```

`completed` counts snapshots whose atomic replacement committed. `failed`
counts deterministic document failures whose exact failed state committed.
Work that is cancelled, stale, or uncertain is counted in neither field.

The pipeline API is:

```swift
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

The target is explicit rather than inferred from the analyzer protocol. This
keeps alternate local analyzers testable and ensures scheduling identity is
known before an analyzer is called. The later composition slice constructs the
target from `LocalRulesDocumentDNAAnalyzer`'s published version constants.

`limit` is both the maximum pending batch size and maximum number of analyzer
tasks in flight for this run. A non-positive limit returns an empty report and
performs no recovery, query, or analyzer work. The default of two matches the
existing ingestion pipeline's conservative local resource boundary.

## 6. Repository Attempt Contract

Add a stable failure-code enum:

```swift
public enum DocumentDNAAnalysisFailureCode: String, Sendable, Equatable {
    case analysisFailure
    case invalidFinding
    case invalidProvenance
}
```

Extend `DocumentDNARepository` with these operations:

```swift
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

public func restoreAnalysisAfterInterruption(
    _ candidate: PendingDocumentDNAAnalysis,
    target: DocumentDNAAnalysisTarget
) async throws

public func recoverInterruptedAnalysis(sourceRootID: UUID) async throws

public func retryFailedAnalysis(documentID: UUID) async throws
```

These names, argument labels, and behaviors are the binding repository
contract for this slice.

### 6.1 Begin

`beginAnalysis` runs in one database transaction. It verifies that the
candidate document still exists, is available and `ready`, retains the expected
content hash, and retains the expected extraction version. It also verifies
that the candidate remains eligible for the requested target. It then upserts
an `analyzing` row containing the exact target and input tuple with a null
failure code.

Beginning a new target may replace an older `ready` or obsolete attempt-state
row. It never deletes the prior `documentDNA` snapshot. A candidate that is no
longer coherent or eligible throws `DocumentDNARepositoryError.staleInput`.

### 6.2 Failure

`markAnalysisFailed` changes only the exact matching `analyzing` attempt to
`failed`, records one enum raw value, and updates the timestamp. It rechecks
current document and extraction inputs. It never changes `document.status` and
never deletes or replaces the prior completed DNA snapshot.

A missing, changed, deleted, or superseded attempt throws `staleInput`; an
arbitrary failure string is never accepted.

### 6.3 Cancellation restoration

`restoreAnalysisAfterInterruption` deletes only an `analyzing` row matching the
candidate's document, target, content hash, and extraction version. It is
idempotent: no matching row is already a safely restored or obsolete state.
It cannot delete a newer target/input state or a durable `ready`/`failed`
state.

The pipeline invokes restoration from a fresh unstructured task so cleanup can
run after the processing task has been cancelled. A database error during
restoration maps to run-level `persistence`, because retryability is then
uncertain.

### 6.4 Recovery and retry

`recoverInterruptedAnalysis` deletes only `analyzing` rows belonging to the
specified source. It runs after source-coordinator acquisition and before the
first pending query of every positive-limit run. It does not change `ready` or
`failed` rows and does not inspect or mutate source files.

`retryFailedAnalysis` deletes only a `failed` state for the requested document.
It is idempotent and does not immediately run analysis. The next source run
will select the document if it is otherwise eligible. It never clears
`analyzing` or `ready`, and it never deletes the completed snapshot.

## 7. Processing Flow

For a positive limit, `processPending` performs these steps:

1. acquire a static source-root coordinator shared across all
   `DocumentDNAAnalysisPipeline` instances;
2. recover interrupted attempts for that source;
3. query at most `limit` coherent pending candidates;
4. return an empty report when the first batch is empty;
5. process every candidate in the batch in a task group;
6. accumulate only durably completed or durably failed outcomes;
7. stop before another batch if a run-level outcome occurred;
8. otherwise query the next bounded batch and repeat until empty;
9. release the coordinator on every success and error path.

Each candidate task:

1. checks cancellation;
2. durably begins the exact attempt;
3. checks cancellation again;
4. invokes the synchronous local analyzer with the candidate values and one
   timestamp obtained from the injected clock;
5. checks cancellation before persistence;
6. calls the repository's existing atomic snapshot replacement;
7. returns completed only after that transaction commits.

The pipeline does not wrap the whole run in security-scoped access because it
never reads an original document.

## 8. Coordination and Concurrency

The source coordinator is private to the DNA stage and follows the existing
FIFO waiter/cancellation contract used by ingestion:

- overlapping runs for the same source serialize, including runs created by
  separate pipeline instances;
- different source IDs may analyze concurrently;
- cancellation while waiting removes only that waiter and yields a cancelled
  run with an empty partial report;
- a throwing or cancelled owner always releases the source for the next waiter.

The pipeline does not coordinate directly with `IngestionPipeline`. The future
composition slice invokes DNA only after ingestion for a source has returned.
Within DNA, the batch limit bounds analyzer concurrency. The repository actor
and GRDB retain their own serialized persistence guarantees.

## 9. Failure Mapping and Priority

Deterministic document failures are isolated and persisted:

| Origin | Durable failure code |
| --- | --- |
| `DocumentDNAValidationError` thrown by the analyzer | `invalidFinding` |
| repository provenance validation | `invalidProvenance` |
| any other analyzer error | `analysisFailure` |

After mapping one of these errors, the pipeline attempts to commit the exact
failed state. A successful failure-state write increments `failed` and permits
the batch and later batches to continue. Failure-state persistence errors are
run-level `persistence`. A stale input while marking failed is run-level
`staleInput`.

Run-level mapping is:

| Origin | Run reason |
| --- | --- |
| recovery, begin, completion, failure-state, or restoration database error | `persistence` |
| initial or later pending query error | `pendingQuery` |
| exact input/attempt guard failure | `staleInput` |
| task or coordinator-wait cancellation with successful cleanup | `cancelled` |

If multiple candidate tasks return run failures in one batch, the stable
priority is `persistence`, then `staleInput`, then `cancelled`. The task group
is drained before the error is thrown so its partial report reflects every
durable outcome from that batch. No later batch begins.

No raw extracted text, display value, path, person, organization, amount, or
reference is included in a failure code or required diagnostic.

## 10. Cancellation Semantics

Cancellation is checked before begin, after begin, after analysis, and before
snapshot persistence.

- Cancellation before begin creates no state.
- Cancellation after begin but before completion restores the exact attempt
  and preserves any older completed snapshot.
- Cancellation cannot interrupt a transaction into a partially replaced
  snapshot; GRDB either commits or rolls it back.
- Once replacement returns successfully, the document counts as completed even
  if cancellation arrives immediately afterward.
- If exact restoration fails, the run reports `persistence` rather than
  `cancelled` because durable retryability is uncertain.

A synchronous analyzer cannot be forcibly interrupted while its call is on the
stack. Its task observes cancellation immediately after the analyzer returns
and does not persist the candidate snapshot. The initial local rules analyzer
is bounded CPU work over stored pages and performs no blocking I/O.

## 11. Idempotence and Reanalysis

The existing pending query remains the scheduling authority:

- a current snapshot for the exact target, content hash, and extraction
  version results in zero analyzer calls and zero writes;
- an exact failed attempt remains blocked until explicit retry or an input or
  target change;
- an analyzer/schema target change makes the document eligible once;
- a content or extraction-version change makes the new coherent input eligible
  once text ingestion has returned the document to ready;
- successful replacement leaves exactly one header, one complete ordered child
  set, and one matching ready state;
- repeating the same run is empty again.

Stale completion never deletes the previous snapshot. `currentSnapshot` may
hide that old snapshot when it no longer matches, while `storedSnapshot`
remains available for diagnostics.

## 12. Test Strategy

### 12.1 Repository transition tests

- begin writes the exact `analyzing` tuple and blocks pending selection;
- begin rejects changed content, extraction, readiness, availability, current
  snapshots, and exact blocked attempts;
- failed transition accepts only the exact analyzing attempt and preserves an
  older snapshot;
- cancellation restoration is exact, idempotent, and cannot delete newer,
  ready, or failed state;
- recovery is source-scoped and removes only analyzing state;
- manual retry removes only failed state and preserves snapshots;
- state timestamps retain the existing GRDB date contract.

### 12.2 Pipeline tests

- first analysis persists a complete ready snapshot;
- unchanged same-version rerun performs zero analyzer calls and writes;
- analyzer and schema version changes each perform exactly one replacement;
- the configured limit bounds peak analyzer concurrency without truncating
  later work;
- overlapping instances serialize the same source and process every document
  once;
- different sources make analyzer progress concurrently;
- one deterministic analyzer failure does not block successful documents;
- exact failed input does not spin on the same or a later run;
- manual retry makes only the failed document eligible again;
- run-start recovery resumes an orphaned analyzing attempt;
- cancellation restores eligibility and preserves an older snapshot;
- restoration failure maps to persistence;
- content or extraction change during analysis rejects stale output;
- initial and later pending-query errors retain the correct partial report;
- same-batch failure priority is deterministic.

Test analyzers are `Sendable` actors or lock-protected values that expose call
count, peak concurrency, explicit suspension, and injected errors. Assertions
observe repository rows and public reports rather than private pipeline state.

### 12.3 Local integration test

Seed an in-memory database with one synthetic ready document and persisted
extracted pages from the existing care-home fixture vocabulary. Run the real
`LocalRulesDocumentDNAAnalyzer` through the real pipeline, reload the stored
snapshot through `DocumentDNARepository`, and compare the complete DNA value
to a literal expected value, including provenance and fixed timestamp.

No source URL is opened. No test uses real personal data or a network service.

### 12.4 Completion verification

Run the focused repository and pipeline suites, the complete Swift suite using
the documented Command-Line-Tools fallback when required, and the release
build. The opt-in 10,000-document benchmark is not required because this slice
does not change catalog, fingerprinting, or the accepted scale boundary.

## 13. Compatibility and Review Boundary

The change is additive at the public Swift API level and reuses the existing v5
tables. It changes pending eligibility only through newly persisted attempt
states that the schema and pending query already recognize. Removing the new
pipeline and transition APIs returns the application to the current behavior;
completed DNA snapshots remain valid and rebuildable.

The production diff should remain limited to:

- `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift`;
- a new `Sources/LinkLoomCore/Pipeline/DocumentDNAAnalysisPipeline.swift`;
- focused repository and pipeline tests;
- this specification and its implementation plan.

No `LinkLoomApp`, `LinkLoomAppFeature`, migration, package dependency, fixture,
source-document, GitHub configuration, or remote setting belongs in the slice.

## 14. Acceptance Criteria

The slice is complete when:

- ready persisted extractions can be analyzed and atomically stored through the
  new pipeline using only local code;
- unchanged target/input reruns invoke no analyzer and create no rows;
- target or coherent input changes cause exactly one complete replacement;
- deterministic document failures are durably isolated with only the three
  approved privacy-safe codes;
- exact failed attempts require manual retry unless target/input changes;
- orphaned analyzing attempts recover source-scoped at run start;
- cancellation restores retryability without removing the last good snapshot;
- stale work cannot replace or delete a completed snapshot;
- same-source runs serialize across pipeline instances while different sources
  can progress concurrently;
- bounded concurrency and typed partial-report behavior are covered by tests;
- the real local analyzer passes through the real in-memory pipeline;
- focused tests, the complete non-opt-in suite, and release build pass;
- no source file, UI, schema, network, dependency, telemetry, entity,
  relationship, context, or GitHub-setting change enters the pull request.

## 15. Next Boundary

After this pipeline is independently reviewed and merged, the next separate
slice may compose text ingestion followed by DNA analysis for manual and
watcher-triggered runs. That later design must decide how application progress
and retry are surfaced without weakening the core pipeline contracts defined
here.
