# LinkLoom Ingestion Hardening Design

**Date:** 2026-08-12

**Status:** Approved design for the pre-merge hardening of the ingestion-foundation slice

## 1. Purpose

This design closes five merge-blocking gaps found during the full review of the ingestion-foundation pull request. It supplements, but does not silently rewrite, the approved product design and implementation plan:

- `docs/superpowers/specs/2026-08-08-linkloom-product-design.md`
- `docs/superpowers/plans/2026-08-08-linkloom-ingestion-foundation.md`

The original local-first boundary and original-file invariants remain binding. LinkLoom must never rename, move, delete, or intentionally modify a source document. Temporary source failures must not be persisted as confirmed deletion.

## 2. Scope

The hardening slice includes exactly these outcomes:

1. incomplete filesystem enumeration cannot mark known documents missing;
2. catalog reconciliation cannot overwrite a concurrent extraction completion with stale processing state;
3. a PDF containing both embedded-text pages and image-only pages receives page-level OCR where required;
4. successful incremental rescans refresh visible app state;
5. pull requests run Swift tests and a release build on a supported macOS GitHub runner.

Document DNA, semantic search, entity resolution, relationship inference, production packaging, signing, and deployment remain outside this slice.

## 3. Complete Enumeration Before Missing Reconciliation

### 3.1 Required behavior

`DefaultFileEnumerator` must distinguish a complete traversal from an incomplete or unavailable traversal.

- If the source root cannot be opened, enumeration throws.
- If `FileManager` reports an error while traversing any subtree, enumeration stops and throws.
- If resource metadata cannot be read for a supported file, enumeration throws.
- Unsupported files remain ignored and do not require metadata reads.
- `CatalogService` performs reconciliation, including `.missing` transitions, only after a complete enumeration.
- A failed enumeration leaves all existing catalog records and the source's last-scan timestamp unchanged.

The design intentionally fails the whole scan instead of persisting a partial subtree result. Partial traversal state would require durable subtree completeness and availability semantics that are not needed for the first vertical slice.

### 3.2 Error surface

Enumeration errors propagate through the existing throwing `FileEnumerating.files(in:)` and `CatalogService.scan(source:)` interfaces. The app already treats scan errors as recoverable. Filesystem watcher root-unavailability signals remain transient app state and do not trigger missing reconciliation.

## 4. Catalog-Owned Reconciliation Fields

### 4.1 Ownership rule

Catalog reconciliation owns these document fields:

- `relativePath`
- `contentHash`
- `byteCount`
- `modifiedAt`
- `mediaType`
- `availability`
- `lastSeenAt`

The ingestion pipeline owns:

- `status`
- `pageCount`
- `failureCode`
- persisted extraction rows and FTS content

### 4.2 Atomic update behavior

Reconciliation must not save stale full `DocumentRecord` snapshots over current database rows.

Within the existing reconciliation transaction:

- new documents are inserted as `.discovered`;
- unchanged-content updates modify only catalog-owned fields;
- changed-content updates modify catalog-owned fields and atomically reset `status` to `.discovered`, `pageCount` to `NULL`, and `failureCode` to `NULL`;
- a move with the same hash preserves the current ingestion-owned fields;
- missing reconciliation changes only `availability` to `.missing`.

This field-level write model removes the catalog-versus-ingestion lost-update race without introducing a process-global coordinator or serializing unrelated extraction work.

## 5. Hybrid PDF Extraction

### 5.1 Plan clarification

The original implementation plan routes a PDF to OCR only when its document-wide embedded character count is insufficient. The approved product design separately requires OCR for image-based PDF pages. This supplement resolves that mismatch in favor of the product requirement: fallback is page-aware for mixed PDFs.

### 5.2 Extraction behavior

For each PDF page:

- preserve non-whitespace embedded text when it exists;
- render and OCR a page whose embedded text contains no non-whitespace characters;
- retain the original page index;
- if OCR reports `noRecognizedText`, retain that page as empty rather than failing an otherwise useful mixed document;
- propagate cancellation, password protection, unreadable-document errors, and other non-empty-page OCR failures through the established failure isolation boundary.

Wholly textual PDFs continue to use embedded extraction without rendering. Wholly image-only PDFs continue to render and OCR every page.

### 5.3 Provenance model

`ExtractionMethod` gains `hybridPDFTextAndOCR`. A hybrid result uses:

- empty `regions` for pages sourced from embedded PDF text;
- Vision regions for OCR-derived pages.

This keeps provenance traceable without introducing a second page-level method field or a database migration. Existing stored method strings remain decodable.

## 6. Incremental Rescan Completion and UI Refresh

### 6.1 Separate event channels

Filesystem lifecycle events and completed rescans have different meanings and remain separate.

`SourceWatchScheduling` exposes a second stream of source IDs for successful rescan completions. `RescanScheduler` yields a source ID only after its `SourceRescanning.rescan(source:)` operation completes successfully. To represent success, `SourceRescanning.rescan(source:)` becomes throwing; catalog or ingestion failure prevents a completion event.

### 6.2 AppModel behavior

`AppModel` observes rescan completions in addition to directory lifecycle changes.

On completion:

- reload the saved source list so `lastScanAt` becomes current;
- preserve the current selection when that source still exists;
- reload documents only when the completed source is selected;
- ignore stale async results using the model's existing selection guards;
- report a refresh failure through the existing diagnostic error channel without discarding currently visible documents.

Stopping watchers must cancel both observer tasks before `stopAll()` returns.

## 7. macOS Pull-Request CI

Add a GitHub Actions workflow for pull requests and pushes to `main` using a supported macOS runner.

The workflow must:

- check out the repository;
- report `swift --version` and `xcodebuild -version` for diagnostics;
- run `swift test`;
- run `swift build -c release`;
- use concurrency cancellation for superseded runs;
- avoid network services beyond SwiftPM dependency resolution from the committed lockfile.

The workflow is configuration rather than executable product behavior. Its red state is the absence of a macOS build/test check on the draft pull request; its green state is a successful GitHub Actions run after the workflow is pushed. Unit-test Red/Green does not apply to this configuration file, by explicit approval for this hardening slice.

After the workflow runs reliably, repository administrators should add its check names to the `main` ruleset as required checks, as already directed by `.github/BRANCH_PROTECTION.md`.

## 8. Testing Strategy

Every product-code change follows strict TDD with an observed relevant failure before implementation.

Required regressions:

1. a traversal or supported-file metadata error aborts scanning and preserves existing availability and last-scan state;
2. extraction completion between catalog read and reconciliation remains `.ready` when content is unchanged, while a real content change resets to `.discovered`;
3. a two-page PDF with one embedded-text page and one image-only page returns a hybrid result with both pages populated and correct provenance;
4. a successful incremental rescan refreshes selected documents and source metadata, while another source's completion does not replace the selected document list;
5. normal tests skip the 10,000-document benchmark, the opt-in benchmark remains green, and the release build succeeds.

Final verification includes the complete Swift suite, the opt-in 10,000-document benchmark, a release build, `git diff --check`, independent code review, the macOS GitHub Actions result, and the existing policy check.

## 9. Delivery and GitHub State

The five changes remain in Draft PR #2 and are implemented as targeted, reviewable commits. The PR stays draft until all Critical and Important findings are resolved, the branch is current with `main`, local verification is green, and GitHub policy plus macOS build/test checks pass.

No merge occurs automatically as part of implementation. After a final independent review returns a merge-ready verdict, the PR may be marked ready and merged only through the repository's required Squash-and-merge flow.
