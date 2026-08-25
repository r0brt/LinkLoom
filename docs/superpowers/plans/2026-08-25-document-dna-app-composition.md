# Document DNA App Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compose the fully local Document DNA analysis pipeline after text ingestion for both manual and watcher-triggered application runs.

**Architecture:** `LinkLoomApp` remains the executable composition root. It constructs the existing DNA repository, deterministic local analyzer, explicit version target, and analysis pipeline, then injects one small `LocalDocumentProcessor` into both the manual `AppModel` path and the incremental rescan path so both execute text ingestion before DNA analysis and propagate cancellation or run failures unchanged.

**Tech Stack:** Swift 6.2, Swift Testing, SwiftUI composition root, existing GRDB-backed LinkLoomCore pipelines, XCTest UI-smoke database probe

**Spec:** `docs/superpowers/specs/2026-08-24-document-dna-vertical-slice-design.md` (Sections 10, 13.4, and 14), refined by `docs/superpowers/specs/2026-08-25-document-dna-analysis-pipeline-design.md` (Sections 8, 10, and 15)

## Global Constraints

- Keep analysis entirely local; add no network call, external AI, telemetry, model download, or package dependency.
- Never rename, move, delete, or intentionally modify selected source documents.
- Keep `LinkLoomApp` as composition root and preserve the dependency direction from app to `LinkLoomAppFeature` and `LinkLoomCore`.
- Reuse the existing v5 schema, repository, local analyzer, and analysis pipeline without migrations or domain changes.
- Preserve sequential text-ingestion-before-DNA ordering, cooperative cancellation, actor isolation, and the existing source-scoped coordinators.
- A DNA run-level failure must escape watcher rescanning so `RescanScheduler` publishes no successful completion.
- Add no Document DNA UI, progress state, retry UI, entity resolution, relationships, dossiers, or contexts.

---

### Task 1: Prove and compose the shared local processing sequence

**Files:**

- Modify: `Package.swift`
- Create: `Tests/LinkLoomAppTests/AppCompositionTests.swift`
- Modify: `Sources/LinkLoomApp/LinkLoomApp.swift`

**Interfaces:**

- Consumes: `IngestionPipeline.processPending(source:limit:)`, `DocumentDNAAnalysisPipeline.processPending(sourceRootID:limit:)`, `PendingIngesting`, and `SourceRescanning`.
- Produces: internal `LocalDocumentProcessor: PendingIngesting` shared by manual and watcher paths; `IncrementalRescanner` sequences cataloging before that processor.

- [x] **Step 1: Register an executable-target test boundary and write failing sequencing tests**

Add `LinkLoomAppTests` to `Package.swift` with dependencies on `LinkLoomApp` and `LinkLoomCore`. In `AppCompositionTests.swift`, use `@testable import LinkLoomApp` and literal event assertions to cover:

```swift
@Test func localProcessorRunsTextIngestionBeforeDNAAnalysis() async throws {
    let events = EventRecorder()
    let source = sourceRecord()
    let processor = LocalDocumentProcessor(
        ingest: { source in await events.append("ingest:\(source.id)") },
        analyzeDNA: { sourceID in await events.append("dna:\(sourceID)") }
    )

    try await processor.processPending(source: source)

    #expect(await events.values == ["ingest:\(source.id)", "dna:\(source.id)"])
}
```

```swift
@Test func localProcessorDoesNotAnalyzeWhenTextIngestionFails() async {
    let dnaCalls = CallCounter()
    let processor = LocalDocumentProcessor(
        ingest: { _ in throw CompositionTestError.ingestionFailed },
        analyzeDNA: { _ in await dnaCalls.increment() }
    )

    await #expect(throws: CompositionTestError.ingestionFailed) {
        try await processor.processPending(source: sourceRecord())
    }
    #expect(await dnaCalls.value == 0)
}
```

```swift
@Test func incrementalRescanRunsCatalogThenTextThenDNA() async throws {
    let events = EventRecorder()
    let source = sourceRecord()
    let processor = LocalDocumentProcessor(
        ingest: { _ in await events.append("ingest") },
        analyzeDNA: { _ in await events.append("dna") }
    )
    let rescanner = IncrementalRescanner(
        scanCatalog: { _ in await events.append("catalog") },
        processDocuments: { source in try await processor.processPending(source: source) }
    )

    try await rescanner.rescan(source: source)

    #expect(await events.values == ["catalog", "ingest", "dna"])
}
```

Add separate tests proving a propagated DNA error escapes both `LocalDocumentProcessor` and `IncrementalRescanner`, and proving cancellation observed between completed ingestion and DNA prevents the DNA closure from running.

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```sh
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter AppCompositionTests
```

Expected: compilation fails because `LocalDocumentProcessor` and test-visible sequencing initializers do not yet exist. This is the intended missing composition behavior, not a typo or fixture failure.

- [x] **Step 3: Implement the minimum shared processor and composition wiring**

In `LinkLoomApp.swift`, add an internal `LocalDocumentProcessor` with production and closure-injected initializers:

```swift
struct LocalDocumentProcessor: PendingIngesting {
    private let ingest: @Sendable (SourceRootRecord) async throws -> Void
    private let analyzeDNA: @Sendable (UUID) async throws -> Void

    init(ingestion: IngestionPipeline, dnaAnalysis: DocumentDNAAnalysisPipeline) {
        ingest = { source in _ = try await ingestion.processPending(source: source) }
        analyzeDNA = { sourceID in
            _ = try await dnaAnalysis.processPending(sourceRootID: sourceID)
        }
    }

    init(
        ingest: @escaping @Sendable (SourceRootRecord) async throws -> Void,
        analyzeDNA: @escaping @Sendable (UUID) async throws -> Void
    ) {
        self.ingest = ingest
        self.analyzeDNA = analyzeDNA
    }

    func processPending(source: SourceRootRecord) async throws {
        try await ingest(source)
        try Task.checkCancellation()
        try await analyzeDNA(source.id)
    }
}
```

Give `IncrementalRescanner` a production initializer and a closure-injected initializer. Its `rescan` method must call catalog scan, check cancellation, and invoke the shared processor without translating errors.

Inside `makeModel`, construct:

```swift
let dnaRepository = DocumentDNARepository(dbWriter: database)
let dnaAnalyzer = LocalRulesDocumentDNAAnalyzer()
let dnaTarget = try DocumentDNAAnalysisTarget(
    schemaVersion: LocalRulesDocumentDNAAnalyzer.schemaVersion,
    analyzerIdentifier: LocalRulesDocumentDNAAnalyzer.analyzerIdentifier,
    analyzerVersion: LocalRulesDocumentDNAAnalyzer.analyzerVersion
)
let dnaAnalysis = DocumentDNAAnalysisPipeline(
    repository: dnaRepository,
    analyzer: dnaAnalyzer,
    target: dnaTarget
)
let documentProcessor = LocalDocumentProcessor(
    ingestion: ingestion,
    dnaAnalysis: dnaAnalysis
)
```

Inject `documentProcessor` as `AppModel.ingestion` and into `IncrementalRescanner`. Remove the ingestion-only `PendingIngester` adapter.

- [x] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command again.

Expected: all `AppCompositionTests` pass, with the literal manual and watcher event order, failure propagation, and cancellation behavior verified.

- [x] **Step 5: Commit the focused executable composition**

```sh
git add Package.swift Sources/LinkLoomApp/LinkLoomApp.swift \
  Tests/LinkLoomAppTests/AppCompositionTests.swift \
  docs/superpowers/plans/2026-08-25-document-dna-app-composition.md
git commit -m "feat(app): compose local document DNA analysis"
```

### Task 2: Extend the hermetic product smoke evidence to Document DNA

**Files:**

- Modify: `LinkLoomUITests/Support/SQLiteProbe.swift`

**Interfaces:**

- Consumes: existing real UI workflow, v5 `documentDNA`, `documentDNAFinding`, `documentDNAEvidence`, and `documentDNAAnalysisState` tables.
- Produces: read-only evidence that both successfully extracted fixture documents receive complete local-rules DNA snapshots and all DNA rows cascade when the source is removed.

- [x] **Step 1: Add durable DNA acceptance evidence**

Extend `SmokeDatabaseEvidence` with literal counts:

```swift
let dnaSnapshotCount: Int
let dnaFindingCount: Int
let dnaAnalysisStateCount: Int
let dnaReadyStateCount: Int
let dnaClassificationCount: Int
let localRulesSnapshotCount: Int
let dnaEvidenceCount: Int
```

Collect them using read-only SQL. Require two snapshots, two matching ready states, two document-type findings, and two `local-rules` v1 snapshot headers in `matchesCompletedWorkflow`. The fixture text intentionally produces `unknown` classification, so require zero DNA evidence rows. In `matchesRemovedWorkflow`, require all four DNA tables to contain zero rows after source removal.

- [x] **Step 2: Record the local full-Xcode verification boundary**

The executable composition already followed a behavior-test RED/GREEN cycle in Task 1. The process-level smoke assertion is additional acceptance coverage and requires full Xcode, which is unavailable on the local Command-Line-Tools host. Run the authoritative command to capture that environment limitation without weakening the assertion:

```sh
xcodebuild test \
  -project LinkLoom.xcodeproj \
  -scheme LinkLoomUISmoke \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/LinkLoomDerivedData \
  -resultBundlePath /tmp/LinkLoomUISmoke.xcresult
```

Expected locally: `xcodebuild` reports that full Xcode is unavailable. Expected in CI: the smoke test passes only when the composition-root wiring produces two DNA snapshots.

- [x] **Step 3: Run available focused verification**

Run `swift test --filter AppCompositionTests` and `swift build`. Confirm the modified smoke support compiles through the authoritative Xcode job; do not weaken or skip the CI assertion because the local host lacks full Xcode.

- [x] **Step 4: Commit the smoke acceptance evidence**

```sh
git add LinkLoomUITests/Support/SQLiteProbe.swift
git commit -m "test(ui): verify local document DNA persistence"
```

### Task 3: Complete verification and independent review

**Files:**

- Review: all changes since `origin/main`
- Modify only if verification or independent review identifies an in-scope defect.

**Interfaces:**

- Consumes: Tasks 1-2 and repository definition-of-done commands.
- Produces: fresh verification evidence and an independent merge-readiness verdict without pushing or merging.

- [ ] **Step 1: Run focused composition tests**

Run the fallback test command with `--filter AppCompositionTests` and require zero failures.

- [ ] **Step 2: Run the complete non-opt-in suite**

Run the documented fallback `swift test` command and require every non-opt-in test to pass. Do not run the 10,000-document benchmark because catalog, fingerprinting, and scale behavior are unchanged.

- [ ] **Step 3: Run the production release build**

```sh
swift build -c release
```

Require exit status 0.

- [ ] **Step 4: Verify diff hygiene and scope**

```sh
git diff --check origin/main...HEAD
git diff --cached --check
git status --short
git diff --stat origin/main...HEAD
git diff origin/main...HEAD
```

Confirm there are no source files, databases, `.build/`, `.superpowers/`, secrets, dependency changes, schema changes, UI changes, or unrelated cleanup.

- [ ] **Step 5: Request independent read-only review**

Dispatch a fresh reviewer with `BASE_SHA=$(git rev-parse origin/main)` and `HEAD_SHA=$(git rev-parse HEAD)`. Require review of ordering, cancellation, source coordination, error propagation, privacy, actor isolation, test quality, and scope. Resolve every Critical or Important finding and rerun affected verification.

- [ ] **Step 6: Report handoff without push or merge**

Report branch, commits, exact verification, the local full-Xcode limitation, review verdict, and remaining GitHub CI requirement. Do not push, open/merge a pull request, change GitHub settings, or delete any branch without explicit authorization.
