# LinkLoom Hermetic UI Smoke Test Design

**Date:** 2026-08-21

**Status:** Approved design for an in-process macOS UI smoke test

## 1. Purpose

This design adds a repeatable product-readiness smoke test for the current
LinkLoom ingestion slice. The test exercises the real SwiftUI presentation,
application model, catalog, extraction pipeline, and SQLite persistence while
using only generated temporary documents and a temporary database.

The smoke test closes the visual and interaction evidence gap left by manual
testing on hosts where global macOS Accessibility permission is unavailable.
It does not introduce an Xcode project, a signed application bundle, an
external UI-testing dependency, or a second product workflow.

## 2. Decision and Constraints

The repository remains SwiftPM-only. SwiftPM does not provide the application
bundle and UI-test runner required for a process-level `XCUITest` target, so
the smoke test hosts LinkLoom's SwiftUI views in an in-process `NSWindow` and
drives their exposed accessibility actions.

The following constraints remain binding:

- macOS 15 or later and Swift 6.2 or later;
- no network access, telemetry, or external AI;
- no new package dependencies;
- no use of the user's real LinkLoom Application Support directory;
- no use of personal or repository-resident source documents;
- no rename, move, delete, or intentional modification of selected source
  documents;
- no production behavior change beyond test seams, stable accessibility
  metadata, and an equivalent accessibility action for the existing source
  removal command;
- no claim that the in-process test verifies packaging, signing, notarization,
  Launch Services, or inter-process automation.

## 3. Scope

The smoke workflow verifies:

1. startup renders a ready LinkLoom workspace backed by a temporary database;
2. the add-folder control selects and persists one temporary source;
3. the analyze control runs the real catalog and extraction pipeline;
4. supported temporary documents become ready when extraction succeeds;
5. a corrupt supported document remains visible with a failure status and
   failure code;
6. an unsupported temporary document is ignored;
7. the visible status summary and document table reflect persisted results;
8. rebuilding the model and view against the same temporary database restores
   the source and document state;
9. the source can be removed through the source row's accessibility action;
10. source paths, SHA-256 hashes, byte counts, modification dates, and POSIX
    modes match before and after the workflow;
11. a forced catalog-startup failure renders the existing recoverable startup
    error and retry control.

Filesystem watcher behavior, the opt-in 10,000-document boundary, and detailed
extractor edge cases remain covered by their existing focused tests. The new
smoke test does not duplicate those suites.

## 4. Architecture

The change has three boundaries:

1. **Production UI seams.** Existing views expose stable accessibility
   identifiers and accept deterministic folder selection during tests. The
   production path continues to use `NSOpenPanel`.
2. **Reusable startup presentation.** The startup phase view moves from the
   executable target into `LinkLoomAppFeature` so the executable and tests
   render the same implementation.
3. **Test-only harness.** `LinkLoomAppFeatureTests` creates temporary fixtures,
   hosts the production views in `NSWindow`, locates accessibility elements,
   invokes their actions, and waits on observable persisted conditions rather
   than fixed sleeps.

`LinkLoomCore` remains independent of the app and SwiftUI layers. The test
target may depend on both existing library targets, but no dependency direction
changes in production.

## 5. Production Components

### 5.1 Folder picker seam

`FolderPicker` stores a `@MainActor () -> [URL]` selection operation.

- `init()` builds the current `NSOpenPanel` behavior.
- An explicit initializer accepts a selection operation for tests.
- `selectFolders()` invokes the stored operation.

The seam does not read environment variables or add a hidden production mode.

### 5.2 Startup presentation

`AppStartupView` lives in `LinkLoomAppFeature` and receives:

- an observed `AppStartupController`;
- a `FolderPicker`, defaulting to the production picker;
- a closure that registers the ready `AppModel` for termination handling.

It renders the existing progress, ready content, recoverable startup error,
and retry button without changing the user-facing German copy. `LinkLoomApp`
uses this view as its window content and retains responsibility for constructing
the real model and termination coordinator.

### 5.3 Accessibility contract

The production views expose these stable identifiers:

| Identifier | Element |
| --- | --- |
| `startup.progress` | startup progress indicator |
| `startup.failure` | recoverable startup error container |
| `startup.retry` | retry button |
| `source.add` | add-folder button |
| `source.row.<UUID>` | source row |
| `scan.start` | analyze button |
| `scan.error` | runtime error message |
| `status.discovered` | discovered count |
| `status.extracting` | extracting count |
| `status.ready` | ready count |
| `status.failed` | failed count |
| `documents.table` | document table |

The source row keeps its existing context menu. Its named custom accessibility
action, `Quelle entfernen`, calls the same `AppModel.removeSource(_:)`
operation and is available only under the same idle condition.

## 6. Test Harness and Data Flow

The test target adds a focused `LinkLoomUISmokeTests` suite plus small support
types for hosting, accessibility lookup, fixtures, snapshots, and
condition-based waiting.

The primary workflow is:

1. Create a unique temporary root containing a source directory and SQLite
   database path.
2. Generate a selectable-text PDF, an image-only PDF or PNG suitable for local
   Vision OCR, a corrupt PDF, and an unsupported text file.
3. Snapshot every source file's relative path, SHA-256, byte count,
   modification date, and POSIX mode.
4. Construct real repositories, `CatalogService`, `IngestionPipeline`, and
   `AppModel` against the temporary database. The manual smoke path omits the
   filesystem watcher because it explicitly invokes analysis.
5. Construct `AppStartupController`, host `AppStartupView` in an `NSWindow`,
   and wait until the ready workspace is accessible.
6. Invoke `source.add`; the injected `FolderPicker` returns the temporary
   source directory.
7. Wait until the source row and selected-source dashboard are accessible.
8. Invoke `scan.start` and wait until persisted documents reach their terminal
   ready or failed states and the scan returns to idle.
9. Assert the status counts, document rows, ready extractions, corrupt-PDF
   failure code, and absence of the unsupported file.
10. Tear down the hosted window and stop model watchers.
11. Construct a fresh model, controller, and hosted view using the same
    temporary database; assert that source and document state reappear.
12. Invoke the source row's remove action and assert that source, document,
    extraction, and full-text rows are removed.
13. Snapshot the source directory again and require exact equality.

The startup-failure workflow constructs a controller whose model factory throws
a deterministic test error, hosts the same `AppStartupView`, and asserts the
failure container and retry control are accessible. Retry is tested with a
second factory result that uses an isolated real model.

## 7. Synchronization and Failure Handling

The harness never waits by assuming that a fixed delay is sufficient. It pumps
the main run loop while polling an observable condition up to an explicit
deadline. Timeouts report the unmet accessibility identifier or durable model
state.

If a SwiftUI control cannot expose or perform the required accessibility action
inside the hosted window, the focused test must fail with that exact missing or
unsupported action. The implementation must not replace the failed UI action
with a direct `AppModel` call while continuing to label the result a UI test.

Expected per-document extraction failure is not a failed smoke run. The corrupt
PDF must be persisted as failed and surfaced by the UI while other supported
documents complete. Startup, source access, catalog, persistence, or harness
failures fail the smoke test.

## 8. Isolation and Cleanup

All documents, databases, windows, and helper state are owned by one temporary
test fixture. Cleanup closes the hosted window, stops watchers, releases the
database, and removes the temporary directory.

The test does not set or repurpose `HOME`. It passes explicit temporary URLs to
the repositories and model factory. Source snapshots are captured before any
LinkLoom operation and immediately before fixture cleanup.

## 9. Verification and CI

Implementation follows red-green-refactor:

1. add a focused test for each new UI seam and observe the expected failure;
2. add the minimum production seam or identifier needed to make it pass;
3. add the full smoke workflow and observe its failure before completing the
   harness behavior;
4. run the focused UI smoke suite;
5. run the complete Swift suite;
6. run `swift build -c release`;
7. run `git diff --check`, `git diff --cached --check`, and inspect
   `git status --short`.

The existing `Swift / test` job runs the smoke test as part of `swift test`.
No separate CI job is added unless the in-process test proves it needs distinct
runner configuration. The existing opt-in 10,000-document acceptance step
remains unchanged.

## 10. Acceptance Criteria

The task is complete when:

- the focused smoke suite passes without Accessibility permission;
- it uses only temporary generated documents and an explicit temporary
  database;
- it drives add, scan, retry, and remove through production SwiftUI
  accessibility actions;
- it verifies ready, failed, ignored, restarted, and removed states against the
  real persistence and extraction components;
- its before/after source snapshots are identical;
- existing source-integrity acceptance tests remain green;
- the complete suite and release build pass;
- no source document is changed and no local database or generated artifact is
  committed.
