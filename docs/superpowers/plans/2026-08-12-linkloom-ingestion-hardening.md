# LinkLoom Ingestion Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve every Critical and Important finding from the final ingestion-foundation review without weakening LinkLoom's local-first or original-file guarantees.

**Architecture:** Treat catalog scans as complete-or-failed before missing reconciliation, make database writes respect catalog-versus-ingestion field ownership, add page-aware hybrid PDF extraction, publish successful rescan completions through a separate stream, and verify the package on macOS CI. Each task is independently testable and ends with a review checkpoint and targeted commit.

**Tech Stack:** Swift 6.2+, Swift Testing, Swift Package Manager, GRDB 7.10.0, PDFKit, Core Graphics, Vision, FSEvents, SwiftUI, GitHub Actions on macOS 15+

## Global Constraints

- Preserve `docs/superpowers/specs/2026-08-08-linkloom-product-design.md` and `docs/superpowers/specs/2026-08-12-linkloom-ingestion-hardening-design.md` as the binding requirements.
- Never rename, move, delete, or intentionally modify original source files or their metadata.
- Temporary source or traversal failures must never become confirmed `.missing` transitions.
- Keep the implementation SwiftPM-first; full Xcode remains optional locally.
- Use strict TDD for every product-code change: failing test, observed relevant red, minimal implementation, observed green, focused verification, review checkpoint, targeted commit.
- The explicitly approved exception is `.github/workflows/swift.yml`: its red state is the absent GitHub check and its green state is the successful remote workflow run.
- Keep PR #2 draft until every task, local verification, independent review, policy check, and macOS Swift check pass.

---

### Task 1: Reject incomplete source enumeration

**Files:**
- Modify: `Sources/LinkLoomCore/Catalog/FileEnumerator.swift`
- Modify: `Tests/LinkLoomCoreTests/FileEnumeratorTests.swift`
- Modify: `Tests/LinkLoomCoreTests/CatalogServiceTests.swift`

**Interfaces:**
- Preserves: `FileEnumerating.files(in:) throws -> [FileCandidate]`.
- Adds internal test seam: `DefaultFileEnumerator.init(resourceValues:directoryEnumerator:)`.
- Produces: `FileEnumerationError.rootUnavailable` and `FileEnumerationError.incompleteTraversal` as internal error cases.
- Guarantees: a returned array always represents a complete traversal for supported files; thrown scans do not reconcile or update `lastScanAt`.

- [ ] **Step 1: Replace the metadata-skip test with failing completeness tests**

In `FileEnumeratorTests.swift`, replace `skipsFileWhoseMetadataBecomesUnavailable` with:

```swift
@Test func throwsWhenSupportedFileMetadataBecomesUnavailable() throws {
    let directory = try TemporaryDirectory()
    try directory.write("unavailable.pdf", bytes: Data("pdf".utf8))
    let enumerator = DefaultFileEnumerator { url, keys in
        if url.lastPathComponent == "unavailable.pdf" {
            throw MetadataProbeError()
        }
        return try url.resourceValues(forKeys: keys)
    }

    #expect(throws: MetadataProbeError.self) {
        try enumerator.files(in: directory.url)
    }
}

@Test func unsupportedFileDoesNotRequireMetadata() throws {
    let directory = try TemporaryDirectory()
    try directory.write("notes.txt", bytes: Data("ignored".utf8))
    let enumerator = DefaultFileEnumerator { _, _ in
        throw MetadataProbeError()
    }

    #expect(try enumerator.files(in: directory.url).isEmpty)
}

@Test func throwsWhenRootCannotBeEnumerated() {
    let missingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    #expect(throws: FileEnumerationError.self) {
        try DefaultFileEnumerator().files(in: missingRoot)
    }
}

@Test func throwsWhenTraversalReportsSubtreeError() throws {
    let directory = try TemporaryDirectory()
    let error = MetadataProbeError()
    let enumerator = DefaultFileEnumerator(
        resourceValues: { url, keys in try url.resourceValues(forKeys: keys) },
        directoryEnumerator: { root, keys, options, errorHandler in
            _ = errorHandler(root.appendingPathComponent("offline"), error)
            return FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: options
            )
        }
    )

    #expect(throws: FileEnumerationError.self) {
        try enumerator.files(in: directory.url)
    }
}
```

- [ ] **Step 2: Add a failing catalog-preservation regression**

Extend `CatalogFileEnumerator` with a stored optional error and `setError(_:)`. Add this test to `CatalogServiceTests`:

```swift
@Test func incompleteEnumerationPreservesKnownDocumentsAndLastScan() async throws {
    let fixture = try await CatalogFixture.make()
    let candidate = fixture.candidate("known.pdf", byteCount: 4, modifiedAt: 100)
    fixture.enumerator.setCandidates([candidate])
    await fixture.fingerprinter.set(candidate, hash: "known-hash")
    _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
    fixture.enumerator.setError(IncompleteEnumerationTestError())

    await #expect(throws: IncompleteEnumerationTestError.self) {
        try await fixture.service.scan(source: fixture.source, now: fixture.date(300))
    }

    let document = try #require(
        try await fixture.documents.all(sourceRootID: fixture.source.id).first
    )
    let storedSource = try #require(try await fixture.sources.all().first)
    #expect(document.availability == .available)
    #expect(storedSource.lastScanAt == fixture.date(200))
}
```

Expose `sources` on `CatalogFixture` so the assertion reads the persisted source.

- [ ] **Step 3: Run the focused tests and observe red**

Run:

```bash
swift test --filter FileEnumeratorTests
swift test --filter incompleteEnumerationPreservesKnownDocumentsAndLastScan
```

Expected: the old enumerator returns partial/empty results instead of throwing, and the catalog helper lacks error injection.

- [ ] **Step 4: Implement complete-or-throw enumeration**

In `FileEnumerator.swift`, define:

```swift
enum FileEnumerationError: Error {
    case rootUnavailable
    case incompleteTraversal(URL, any Error)
}
```

Store a directory-enumerator closure with this signature:

```swift
private let directoryEnumeratorOperation: @Sendable (
    URL,
    [URLResourceKey],
    FileManager.DirectoryEnumerationOptions,
    @escaping (URL, any Error) -> Bool
) -> FileManager.DirectoryEnumerator?
```

The public initializer uses `FileManager.default.enumerator`. The internal initializer accepts both test operations and keeps the existing resource-values-only initializer as a convenience.

In `files(in:)`:

1. create an error handler that records the first `(URL, Error)` and returns `false`;
2. throw `.rootUnavailable` when the enumerator is `nil`;
3. check `SupportedMediaType.detect(url)` before requesting metadata;
4. let metadata errors for supported extensions propagate;
5. after iteration, throw `.incompleteTraversal` when the handler recorded an error;
6. only then return the sorted candidates.

- [ ] **Step 5: Implement the catalog test error seam and verify green**

Make `CatalogFileEnumerator.files(in:)` throw its configured error before returning candidates. Run:

```bash
swift test --filter FileEnumeratorTests
swift test --filter CatalogServiceTests
```

Expected: all focused tests pass; incomplete scans preserve availability and last scan.

- [ ] **Step 6: Review and commit Task 1**

Request an independent review focused on traversal completeness and original-file availability semantics. Resolve all Critical/Important findings, then run `git diff --check` and commit:

```bash
git add Sources/LinkLoomCore/Catalog/FileEnumerator.swift Tests/LinkLoomCoreTests/FileEnumeratorTests.swift Tests/LinkLoomCoreTests/CatalogServiceTests.swift
git commit -m "fix: reject incomplete catalog scans"
```

---

### Task 2: Preserve ingestion-owned state during reconciliation

**Files:**
- Modify: `Sources/LinkLoomCore/Persistence/DocumentRepository.swift`
- Modify: `Tests/LinkLoomCoreTests/CatalogServiceTests.swift`

**Interfaces:**
- Preserves: `DocumentRepository.reconcile(sourceRootID:saving:excludingDocumentIDs:) async throws -> Int`.
- Produces: transaction-time field ownership; incoming catalog snapshots never overwrite current ingestion state when hashes match.
- Guarantees: changed content atomically resets extraction state, while unchanged content, metadata changes, moves, and availability changes preserve it.

- [ ] **Step 1: Write the failing stale-snapshot regression**

Add to `DocumentRepositoryTests`:

```swift
@Test func reconciliationCannotOverwriteConcurrentReadyCompletion() async throws {
    let fixture = try await CatalogFixture.make()
    var staleCatalogSnapshot = fixture.document("a.pdf", status: .extracting)
    try await fixture.documents.save(staleCatalogSnapshot)
    try await fixture.documents.markStatus(
        id: staleCatalogSnapshot.id,
        status: .ready,
        pageCount: 2
    )
    staleCatalogSnapshot.lastSeenAt = fixture.date(200)

    _ = try await fixture.documents.reconcile(
        sourceRootID: fixture.source.id,
        saving: [staleCatalogSnapshot],
        excludingDocumentIDs: [staleCatalogSnapshot.id]
    )

    let stored = try #require(
        try await fixture.documents.all(sourceRootID: fixture.source.id).first
    )
    #expect(stored.status == .ready)
    #expect(stored.pageCount == 2)
    #expect(stored.lastSeenAt == fixture.date(200))
}
```

- [ ] **Step 2: Write the changed-content reset regression**

Add:

```swift
@Test func reconciliationResetsReadyStateWhenContentHashChanges() async throws {
    let fixture = try await CatalogFixture.make()
    var changedSnapshot = fixture.document("a.pdf", status: .extracting)
    try await fixture.documents.save(changedSnapshot)
    try await fixture.documents.markStatus(
        id: changedSnapshot.id,
        status: .ready,
        pageCount: 2
    )
    changedSnapshot.contentHash = "replacement-hash"
    changedSnapshot.byteCount = 9

    _ = try await fixture.documents.reconcile(
        sourceRootID: fixture.source.id,
        saving: [changedSnapshot],
        excludingDocumentIDs: [changedSnapshot.id]
    )

    let stored = try #require(
        try await fixture.documents.all(sourceRootID: fixture.source.id).first
    )
    #expect(stored.status == .discovered)
    #expect(stored.pageCount == nil)
    #expect(stored.failureCode == nil)
    #expect(stored.contentHash == "replacement-hash")
}
```

- [ ] **Step 3: Run both tests and observe red**

Run:

```bash
swift test --filter reconciliationCannotOverwriteConcurrentReadyCompletion
swift test --filter reconciliationResetsReadyStateWhenContentHashChanges
```

Expected: the first test reports `.extracting` instead of `.ready`; the second establishes the required reset behavior before the repository rewrite.

- [ ] **Step 4: Replace full-snapshot saves with transaction-time merges**

Inside `DocumentRepository.reconcile`, for each incoming document:

```swift
if var current = try DocumentRecord.fetchOne(db, key: incoming.id) {
    let contentChanged = current.contentHash != incoming.contentHash
    current.relativePath = incoming.relativePath
    current.contentHash = incoming.contentHash
    current.byteCount = incoming.byteCount
    current.modifiedAt = incoming.modifiedAt
    current.mediaType = incoming.mediaType
    current.availability = incoming.availability
    current.lastSeenAt = incoming.lastSeenAt
    if contentChanged {
        current.status = .discovered
        current.pageCount = nil
        current.failureCode = nil
    }
    try current.update(db)
} else {
    var inserted = incoming
    inserted.status = .discovered
    inserted.pageCount = nil
    inserted.failureCode = nil
    try inserted.insert(db)
}
```

Keep the existing single transaction and unique-path rollback behavior. Missing reconciliation must continue to alter only `availability` on rows not in `excludingDocumentIDs`.

- [ ] **Step 5: Verify all reconciliation and pipeline interactions**

Run:

```bash
swift test --filter DocumentRepositoryTests
swift test --filter CatalogServiceTests
swift test --filter IngestionPipelineTests
```

Expected: all pass, including moves preserving ready state, real content changes resetting state, and rollback on conflict.

- [ ] **Step 6: Review and commit Task 2**

Request an independent review focused on transaction atomicity, lost updates, relocation identity, and extraction persistence. Resolve all Critical/Important findings, run `git diff --check`, then commit:

```bash
git add Sources/LinkLoomCore/Persistence/DocumentRepository.swift Tests/LinkLoomCoreTests/CatalogServiceTests.swift
git commit -m "fix: preserve ingestion state during scans"
```

---

### Task 3: Extract mixed PDFs page by page

**Files:**
- Modify: `Sources/LinkLoomCore/Models/ExtractionModels.swift`
- Modify: `Sources/LinkLoomCore/Extraction/CompositeTextExtractor.swift`
- Modify: `Tests/LinkLoomCoreTests/CompositeTextExtractorTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/FixtureFactory.swift`
- Modify: `Tests/LinkLoomCoreTests/IngestionAcceptanceTests.swift`

**Interfaces:**
- Adds: `ExtractionMethod.hybridPDFTextAndOCR`.
- Preserves: `DocumentTextExtracting.extract(from:mediaType:)` and existing wholly textual/image-only routing.
- Produces: embedded pages with empty regions and OCR pages with Vision regions in original page order.

- [ ] **Step 1: Write the failing routing test**

Add to `CompositeTextExtractorTests`:

```swift
@Test func mixedPDFUsesEmbeddedTextAndOCRByPage() async throws {
    let image = try makePixelImage()
    let embedded = FakePDFTextExtractor(result: ExtractedDocument(
        method: .embeddedPDFText,
        pages: [
            ExtractedPage(pageIndex: 0, text: "Embedded contract text", regions: []),
            ExtractedPage(pageIndex: 1, text: "", regions: []),
        ]
    ))
    let renderer = FakePDFPageRenderer(images: [image, image])
    let ocr = FakeOCRRecognizer()
    let extractor = CompositeTextExtractor(
        pdfText: embedded,
        pdfRenderer: renderer,
        ocr: ocr
    )

    let result = try await extractor.extract(
        from: URL(fileURLWithPath: "/fixture/mixed.pdf"),
        mediaType: .pdf
    )

    #expect(result.method == .hybridPDFTextAndOCR)
    #expect(result.pages.map(\.pageIndex) == [0, 1])
    #expect(result.pages.map(\.text) == ["Embedded contract text", "page-1"])
    #expect(result.pages[0].regions.isEmpty)
    #expect(!result.pages[1].regions.isEmpty)
    #expect(await ocr.pageIndices == [1])
}
```

Change `FakeOCRRecognizer.recognize` so its successful return has concrete OCR provenance:

```swift
let text = "page-\(pageIndex)"
return ExtractedPage(
    pageIndex: pageIndex,
    text: text,
    regions: [TextRegion(
        text: text,
        confidence: 0.99,
        boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
    )]
)
```

- [ ] **Step 2: Write a failing real mixed-PDF acceptance test**

Add this fixture helper, which creates one selectable-text page followed by one raster-only page:

```swift
static func makeMixedPDF(
    embeddedText: String,
    scannedText: String
) throws -> URL {
    let image = try makeAcceptanceImage(scannedText)
    let url = temporaryPDFURL()
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let pdf = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    pdf.beginPDFPage(nil)
    draw(embeddedText, in: pdf)
    pdf.endPDFPage()
    pdf.beginPDFPage(nil)
    pdf.draw(image, in: mediaBox)
    pdf.endPDFPage()
    pdf.closePDF()
    return url
}
```

Add:

```swift
@Test func realMixedPDFPreservesEmbeddedAndRecognizedPages() async throws {
    let pdf = try FixtureFactory.makeMixedPDF(
        embeddedText: "Embedded agreement 2026",
        scannedText: "Scanned invoice CHF 7840"
    )
    defer { try? FileManager.default.removeItem(at: pdf) }

    let result = try await CompositeTextExtractor().extract(from: pdf, mediaType: .pdf)

    #expect(result.method == .hybridPDFTextAndOCR)
    #expect(result.pages[0].text.contains("Embedded agreement"))
    #expect(result.pages[0].regions.isEmpty)
    #expect(result.pages[1].text.contains("invoice"))
    #expect(!result.pages[1].regions.isEmpty)
}
```

- [ ] **Step 3: Run the mixed tests and observe red**

Run the fake routing test inside the sandbox and the Vision-backed test with the existing approved out-of-sandbox Swift command. Expected: the fake result returns `.embeddedPDFText` without rendering, and `.hybridPDFTextAndOCR` is undefined.

- [ ] **Step 4: Implement hybrid page routing minimally**

Add the enum case. In the successful embedded-PDF path:

1. collect pages whose `text` contains no non-whitespace characters;
2. return the embedded result immediately when none exist;
3. render the PDF once and require the rendered image count to equal the extracted page count;
4. OCR only the empty page indices;
5. replace those pages in a mutable page array;
6. retain an empty page for `noRecognizedText`;
7. return `.hybridPDFTextAndOCR` with pages sorted by `pageIndex`.

Keep the current catch path for a wholly image-only PDF; it continues to return `.visionOCR`. Propagate cancellation and non-`noRecognizedText` OCR errors.

- [ ] **Step 5: Verify focused extraction and persisted acceptance**

Run:

```bash
swift test --filter CompositeTextExtractorTests
swift test --filter IngestionAcceptanceTests
swift test --filter IngestionPipelineTests
```

Expected: wholly textual PDFs do not render, wholly scanned PDFs OCR every page, mixed PDFs OCR only empty pages, and stored method strings include the new hybrid case without migration.

- [ ] **Step 6: Review and commit Task 3**

Request an independent review focused on page ordering, provenance, cancellation, blank pages, and backward compatibility. Resolve all Critical/Important findings, run `git diff --check`, then commit:

```bash
git add Sources/LinkLoomCore/Models/ExtractionModels.swift Sources/LinkLoomCore/Extraction/CompositeTextExtractor.swift Tests/LinkLoomCoreTests/CompositeTextExtractorTests.swift Tests/LinkLoomCoreTests/Support/FixtureFactory.swift Tests/LinkLoomCoreTests/IngestionAcceptanceTests.swift
git commit -m "feat: OCR mixed PDF pages locally"
```

---

### Task 4: Refresh app state after incremental rescans

**Files:**
- Modify: `Sources/LinkLoomCore/Watching/DirectoryWatcher.swift`
- Modify: `Sources/LinkLoomCore/Watching/RescanScheduler.swift`
- Modify: `Sources/LinkLoomApp/LinkLoomApp.swift`
- Modify: `Sources/LinkLoomAppFeature/AppModel.swift`
- Modify: `Tests/LinkLoomCoreTests/RescanSchedulerTests.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/AppModelTests.swift`

**Interfaces:**
- Changes: `SourceRescanning.rescan(source:) async throws`.
- Adds: `SourceWatchScheduling.rescanCompletions: AsyncStream<UUID>`.
- Preserves: `changes`, `start`, `isWatching`, `stop`, and `stopAll`.
- Guarantees: only successful rescans publish completion; selected-source completion reloads sources and documents; unrelated completion does not replace selected documents.

- [ ] **Step 1: Write failing scheduler completion tests**

Add to `RescanSchedulerTests`:

```swift
@Test func successfulRescanPublishesSourceCompletion() async throws {
    let watcher = RestartableDirectoryWatcher()
    let scheduler = RescanScheduler(
        watcher: watcher,
        rescanner: CountingSourceRescanner(),
        debounceDuration: .milliseconds(10)
    )
    let source = source(named: "Archive")
    let completions = UUIDRecorder()
    let observation = Task {
        for await sourceID in scheduler.rescanCompletions {
            await completions.record(sourceID)
        }
    }
    await scheduler.start(source: source, url: URL(fileURLWithPath: source.pathHint))
    await watcher.waitUntilStreamCount(1)
    watcher.emitToLatest(DirectoryChange(sourceRootID: source.id, kind: .contentChanged))

    try await waitUntil { await completions.values == [source.id] }
    observation.cancel()
    await scheduler.stopAll()
}

@Test func failedRescanDoesNotPublishCompletion() async throws {
    let watcher = RestartableDirectoryWatcher()
    let scheduler = RescanScheduler(
        watcher: watcher,
        rescanner: FailingSourceRescanner(),
        debounceDuration: .milliseconds(10)
    )
    let source = source(named: "Archive")
    let completions = UUIDRecorder()
    let observation = Task {
        for await sourceID in scheduler.rescanCompletions {
            await completions.record(sourceID)
        }
    }
    await scheduler.start(source: source, url: URL(fileURLWithPath: source.pathHint))
    await watcher.waitUntilStreamCount(1)
    watcher.emitToLatest(DirectoryChange(sourceRootID: source.id, kind: .contentChanged))
    try await ContinuousClock().sleep(for: .milliseconds(50))

    #expect(await completions.values.isEmpty)
    observation.cancel()
    await scheduler.stopAll()
}
```

- [ ] **Step 2: Run scheduler tests and observe red**

Run `swift test --filter RescanSchedulerTests`.

Expected: `rescanCompletions` and throwing `SourceRescanning` are undefined.

- [ ] **Step 3: Implement the separate completion stream**

Create `AsyncStream<UUID>` and continuation alongside `changes`. In `scheduleRescan`, use:

```swift
do {
    try await rescanner.rescan(source: source)
    try Task.checkCancellation()
    rescanCompletionContinuation.yield(source.id)
} catch {
    // Failure remains retryable and publishes no successful completion.
}
```

Update all test rescanners to `async throws`. In `IncrementalRescanner`, remove the swallowed catalog error and implement:

```swift
func rescan(source: SourceRootRecord) async throws {
    _ = try await catalog.scan(source: source)
    _ = await ingestion.processPending(source: source)
}
```

- [ ] **Step 4: Write failing AppModel refresh tests**

Extend `FakeSourceWatchScheduler` with a nonisolated completion stream and `completeRescan(sourceID:)`. Add:

```swift
@Test @MainActor func selectedSourceRefreshesAfterIncrementalRescan() async throws {
    let fixture = try AppModelFixture()
    let source = try await fixture.addSource(named: "Archive")
    let scheduler = FakeSourceWatchScheduler()
    let model = AppModel(
        sources: fixture.sources,
        documents: fixture.documents,
        sourceAccess: fixture.sourceAccess,
        catalog: FakeCatalogScanner(),
        ingestion: FakePendingIngester(),
        watchScheduler: scheduler,
        sourceResolver: { _ in fixture.directory }
    )
    try await model.reload()
    let ready = fixture.document(sourceRootID: source.id, path: "new.pdf")
    try await fixture.documents.save(ready)
    try await fixture.sources.updateLastScan(id: source.id, at: Date(timeIntervalSince1970: 500))

    scheduler.completeRescan(sourceID: source.id)
    await waitUntil { model.documents == [ready] && model.sources.first?.lastScanAt != nil }
}
```

Add a second test with two sources: emit completion for the unselected source and assert the selected source's visible documents remain unchanged.

- [ ] **Step 5: Run AppModel tests and observe red**

Run `swift test --filter AppModelTests`.

Expected: the protocol lacks the stream and no observer refreshes model state.

- [ ] **Step 6: Implement completion observation and shutdown**

Add `rescanCompletionsTask` to `AppModel`. When starting watchers, create one observer for `watchScheduler.rescanCompletions`. On a source ID:

1. load sources into a local value;
2. assign them on `MainActor`;
3. preserve `selectedSourceID` if it still exists, otherwise select the first source;
4. call `reloadDocuments()` only if the completed ID equals the current selection;
5. set `lastErrorCode = "incrementalRefreshFailure"` only for a current refresh failure;
6. keep current visible documents on failure.

Cancel and nil both observer tasks in `stopWatching()` before awaiting `stopAll()`.

- [ ] **Step 7: Verify lifecycle, refresh, and build**

Run:

```bash
swift test --filter RescanSchedulerTests
swift test --filter AppModelTests
swift build
```

Expected: successful completions refresh selected state, failed rescans emit nothing, unrelated sources do not replace documents, and termination still stops all streams.

- [ ] **Step 8: Review and commit Task 4**

Request an independent review focused on stale async results, selection races, stream lifecycle, error signaling, and termination cleanup. Resolve all Critical/Important findings, run `git diff --check`, then commit:

```bash
git add Sources/LinkLoomCore/Watching/DirectoryWatcher.swift Sources/LinkLoomCore/Watching/RescanScheduler.swift Sources/LinkLoomApp/LinkLoomApp.swift Sources/LinkLoomAppFeature/AppModel.swift Tests/LinkLoomCoreTests/RescanSchedulerTests.swift Tests/LinkLoomAppFeatureTests/AppModelTests.swift
git commit -m "fix: refresh state after incremental rescans"
```

---

### Task 5: Add macOS Swift pull-request CI

**Files:**
- Create: `.github/workflows/swift.yml`
- Modify: `.github/BRANCH_PROTECTION.md`
- Modify: `CONTRIBUTING.md`

**Interfaces:**
- Produces GitHub check names: `Swift / test` and `Swift / release-build`.
- Runs on pull requests and pushes to `main` using `macos-15`.
- Uses committed `Package.resolved`; introduces no new dependency.

- [ ] **Step 1: Record the observed red configuration state**

Run:

```bash
gh pr checks 2 --repo r0brt/LinkLoom
```

Expected: only `Policy / validate` exists; there is no macOS Swift test or release-build check.

- [ ] **Step 2: Add the workflow**

Create `.github/workflows/swift.yml`:

```yaml
name: Swift

on:
  pull_request:
  push:
    branches: [main]

concurrency:
  group: swift-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  test:
    name: Swift / test
    runs-on: macos-15
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - name: Toolchain
        run: |
          swift --version
          xcodebuild -version
      - name: Test
        run: swift test

  release-build:
    name: Swift / release-build
    runs-on: macos-15
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - name: Toolchain
        run: |
          swift --version
          xcodebuild -version
      - name: Release build
        run: swift build -c release
```

- [ ] **Step 3: Update governance documentation**

In `.github/BRANCH_PROTECTION.md`, list `Swift / test` and `Swift / release-build` after `Policy / validate` and state that they should be made required after their first reliable PR run. In `CONTRIBUTING.md`, update the Required checks section to name all three checks and retain the stabilization-before-ruleset instruction.

- [ ] **Step 4: Validate locally and review the workflow**

Run:

```bash
git diff --check
git diff -- .github/workflows/swift.yml .github/BRANCH_PROTECTION.md CONTRIBUTING.md
```

Request an independent review focused on permissions, runner/toolchain compatibility, check names, timeouts, concurrency, and ruleset documentation. Resolve all Critical/Important findings.

- [ ] **Step 5: Commit Task 5**

```bash
git add .github/workflows/swift.yml .github/BRANCH_PROTECTION.md CONTRIBUTING.md
git commit -m "ci: verify Swift package on macOS"
```

---

### Task 6: Final verification and Draft PR update

**Files:**
- No planned local file changes. Any review correction must begin with a focused failing regression test and receive its own targeted commit.
- Update remotely: Draft PR #2 description and branch.

**Interfaces:**
- Consumes all five hardening tasks.
- Produces a current, reviewed Draft PR with local and GitHub verification evidence.
- Does not merge automatically.

- [ ] **Step 1: Run the fresh complete local suite**

Use the established Command Line Tools framework include/rpath flags and elevated Vision access:

```bash
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: all normal tests pass and the 10,000-document benchmark is skipped.

- [ ] **Step 2: Run the opt-in boundary benchmark**

Run the same Swift flags with:

```bash
LINKLOOM_PERF_TEST=1 swift test --filter catalogHandlesTenThousandDocumentsIdempotently
```

Expected: 10,000 records after both scans and zero additional second-pass fingerprints. Record wall-clock test time without adding a threshold.

- [ ] **Step 3: Run release build and repository checks**

Run:

```bash
swift build --disable-sandbox -c release \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
git diff --check
git status --short
```

Expected: release build succeeds, diff check is silent, and only `.build/` is untracked before the final push.

- [ ] **Step 4: Request a full independent pre-push review**

Review `origin/main..HEAD` against both product specs and both implementation plans. Require explicit resolution of the five original findings. Do not push with any Critical or Important finding.

- [ ] **Step 5: Push the targeted commits and update Draft PR #2**

Push without force. Update the PR description with:

- the five hardening outcomes;
- current normal-test count;
- current 10,000-document benchmark time;
- release-build evidence;
- the new macOS check names;
- migration/rollback implications of the hybrid method and existing `modifiedAt` encoding.

- [ ] **Step 6: Observe real GitHub green**

Run:

```bash
gh pr checks 2 --repo r0brt/LinkLoom --watch --interval 5
```

Expected: `Policy / validate`, `Swift / test`, and `Swift / release-build` all pass. If a Swift check fails, use `github:gh-fix-ci`, inspect the exact Actions logs, and reproduce it locally. If the failure is runner-only, document the runner/toolchain evidence before changing configuration. Follow TDD for any product-code correction.

- [ ] **Step 7: Final merge-readiness review**

Fetch all review threads and current PR metadata. Confirm:

- no unresolved review conversations;
- branch is current with `main`;
- PR is conflict-free and mergeable;
- all three checks pass;
- independent review returns no Critical or Important findings.

Only then report a Go and ask for the explicit transition from Draft to Ready. Do not merge as part of this plan.
