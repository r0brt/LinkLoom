# LinkLoom P0 Reliability Hardening Design

**Date:** 2026-08-16

**Status:** Approved design for the three P0 findings from the 2026-08-15 engineering and Codex-readiness audit

## 1. Purpose

This design resolves exactly three immediate reliability and governance gaps in the current ingestion vertical slice:

1. a run-level ingestion failure must not be reported as a successful empty or partial run;
2. a fingerprint failure for a newly discovered supported file must not produce an apparently complete catalog scan;
3. the existing Swift test and release-build jobs must be required before changes can merge into `main`.

The changes preserve LinkLoom's local-first boundary and original-file invariant. LinkLoom must never rename, move, delete, or intentionally modify a source document.

## 2. Scope and Delivery Boundaries

The work is split into three independently reviewable and testable outcomes:

1. fail catalog scans before reconciliation when a new file cannot be fingerprinted;
2. distinguish expected per-document extraction failures from run-level ingestion failures and propagate the latter;
3. make `Policy / validate`, `Swift / test`, and `Swift / release-build` required branch-protection checks.

The following audit findings remain outside this design:

- streaming or page-at-a-time PDF rendering;
- structured logging and recovery UI;
- repository agent instructions;
- stale bookmark renewal and duplicate-root detection;
- periodic full-hash verification;
- dependency, secret-scanning, formatting, or linting automation;
- local Codex checkpoint cleanup;
- database index cleanup.

No new package dependency, database migration, document status, or UI state is introduced.

## 3. Catalog Scan Completeness

### 3.1 Required behavior

`CatalogService.scan(source:now:)` continues to tolerate a fingerprint failure for an already cataloged path by retaining that document and marking it unavailable during a successfully reconciled scan.

A fingerprint failure for a new path has different semantics because LinkLoom cannot create a valid `DocumentRecord` without a content hash. The scan must therefore throw the original fingerprint error immediately.

Because new-path fingerprints are computed before `DocumentRepository.reconcile`, a thrown error must guarantee all of the following:

- no new document is inserted;
- no existing document is updated;
- no existing document is marked missing;
- the source's `lastScanAt` value is unchanged;
- successfully computed fingerprints held in memory are discarded;
- a later scan can retry the complete source.

The design deliberately rejects both a nullable content hash and a partial-success catalog report. Those alternatives require new identity and completeness semantics that are unnecessary for this hardening slice.

### 3.2 Error surface

`CatalogService.scan(source:now:)` already throws, so no new public catalog error wrapper is required. Cancellation continues to propagate as `CancellationError`; any other new-path fingerprint error propagates unchanged.

## 4. Ingestion Run Contract

### 4.1 Public types

The ingestion pipeline gains a stable, typed run-level error contract:

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

`IngestionPipeline` changes its public operation to:

```swift
public func processPending(
    source: SourceRootRecord,
    limit: Int = 2
) async throws -> IngestionReport
```

`IngestionReport` remains the successful-run value and continues to count documents whose terminal state was durably persisted during the current invocation.

### 4.2 Successful outcomes

These outcomes do not throw:

- `limit <= 0` returns `IngestionReport(completed: 0, failed: 0)`;
- no pending documents returns the same zero report;
- a document extraction or document-path validation failure that is successfully persisted as `.failed` increments `failed` and processing continues;
- a successful extraction that is atomically persisted with `.ready` increments `completed`;
- completing all batches returns the accumulated report.

Password protection, unreadable media, unsupported media, no recognized text, insufficient embedded text, an outside-root relative path, and an extractor-specific failure remain per-document failures when the pipeline can durably write the matching `.failed` state.

### 4.3 Run-level failures

These outcomes throw `IngestionRunError`:

| Condition | Reason | Partial report |
| --- | --- | --- |
| Coordinator acquisition or active processing is cancelled | `cancelled` | Counts durably completed before cancellation |
| Security-scoped bookmark resolution or access fails | `sourceAccess` | Counts completed before source access failure, normally zero |
| Initial or later pending-document query fails | `pendingQuery` | Counts completed before the query failure |
| Recovering an interrupted status, setting `.extracting`, persisting `.failed`, or completing extraction state fails | `persistence` | Counts durably completed before the persistence failure |
| `ExtractionRepository.complete` rejects a changed content hash or stale state | `staleDocument` | Counts completed before the stale completion |

Cancellation restoration remains mandatory. If restoring the original document state succeeds, the run throws `cancelled`. If restoration itself fails, the run throws `persistence` because the durable state is uncertain.

When more than one document in the same concurrent batch produces a run-level failure, the batch uses this deterministic priority:

1. `persistence`;
2. `staleDocument`;
3. `cancelled`.

The partial report never counts a deferred or uncertain document. It counts only `.ready` and `.failed` terminal states that were successfully committed.

### 4.4 Adapter and scheduler propagation

`PendingIngesting.processPending(source:)` remains `async throws` and forwards the pipeline error without translation.

`IncrementalRescanner.rescan(source:)` first awaits the catalog scan and then awaits the throwing ingestion run. Either failure escapes through `SourceRescanning.rescan(source:)`.

`RescanScheduler` already publishes a completion only after `SourceRescanning.rescan(source:)` returns successfully. No completion event may be published for an `IngestionRunError`.

The manual scan path in `AppModel.scanSelectedSource()` already catches `PendingIngesting` failures. A propagated ingestion run failure therefore returns the model to `.idle`, preserves the currently loaded documents, and publishes the existing `scanFailure` diagnostic code.

## 5. Branch Protection

The repository's existing classic branch protection for `main` must require all three current checks immediately:

```text
Policy / validate
Swift / test
Swift / release-build
```

The update must preserve the existing strict/up-to-date requirement and all other branch-protection controls. The implementation uses the narrow GitHub endpoint for required status checks rather than replacing the complete branch-protection object.

`.github/BRANCH_PROTECTION.md` must describe these three checks as the active required state. The previous transitional wording about enabling Swift checks only after reliable runs is removed because both jobs have already passed repeatedly, including on the current `main` commit.

## 6. Testing Strategy

Every product-code change follows test-driven development with a relevant observed failure before implementation.

### 6.1 Catalog regression

Replace the existing partial-success expectation for a new-file fingerprint failure with a regression that verifies:

- `CatalogService.scan` throws the configured fingerprint error;
- no candidate from that scan is persisted;
- previously known document availability and status remain unchanged;
- no missing reconciliation occurs;
- `lastScanAt` retains its pre-scan value.

### 6.2 Ingestion regressions

Update or add focused tests for these contracts:

- unavailable source access throws `sourceAccess` with a zero partial report and leaves documents pending;
- an initial pending query failure throws `pendingQuery` with a zero partial report;
- a later pending query failure throws `pendingQuery` with the completed batch count in `partialReport`;
- catalog change during extraction throws `staleDocument` and does not retain stale extraction rows;
- cancellation after `.extracting` restoration throws `cancelled` and leaves the document retryable;
- extraction failure that is successfully persisted remains a non-throwing report with `failed == 1`;
- failure to persist an extraction failure throws `persistence`;
- the app's pending-ingestion adapter propagates an ingestion run failure;
- an incremental rescan with an ingestion run failure publishes no completion event.

Tests must assert stable public reasons and reports, not GRDB error strings or implementation-specific call ordering.

### 6.3 Branch-protection verification

Before the setting change, a read-only GitHub API query must demonstrate that only `Policy / validate` is required. After the update, the same query must return exactly the three required contexts while `strict` remains `true`.

Repository verification includes:

- the complete 132-test suite;
- the opt-in 10,000-document acceptance test;
- a release build;
- `git diff --check`;
- a clean final worktree except for the intentional implementation commits;
- a final read-only branch-protection query.

## 7. Delivery Order and Review Gates

The implementation order is:

1. catalog fail-fast behavior;
2. ingestion run-level error propagation;
3. required Swift branch-protection checks and matching documentation.

Each outcome receives its own Red/Green cycle, focused commit, full-suite verification, and independent review before the next outcome begins. No outcome depends on uncommitted changes from a later task.

The branch-protection setting is applied only after the product-code tasks and their GitHub checks are green, preventing a newly required check from blocking the hardening pull request before the workflow has evaluated it.
