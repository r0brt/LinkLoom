# Document DNA Repository Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the focused GRDB repository contract that selects coherent pending Document DNA inputs, persists complete snapshots atomically, distinguishes stored from current snapshots, rejects stale inputs, and validates exact provenance.

**Architecture:** A single `DocumentDNARepository` actor owns reads and writes across the four existing DNA tables so snapshot replacement and the matching `ready` analysis state share one transaction. Pending candidates contain a `DocumentRecord` plus its `StoredExtraction`, read from one database snapshot; `currentSnapshot` additionally checks the configured analysis target and current catalog/extraction inputs, while `storedSnapshot` remains available for diagnostics. This slice does not add the analysis pipeline or public APIs for analyzing/failed/cancelled attempt transitions.

**Tech Stack:** Swift 6.2, Swift Concurrency actors, GRDB 7.10.0, SQLite, Swift Testing, Foundation UTF-16 APIs.

**Spec:** `docs/superpowers/specs/2026-08-24-document-dna-vertical-slice-design.md`

## Global Constraints

- Work only in `LinkLoomCore`; it must not depend on `LinkLoomAppFeature` or `LinkLoomApp`.
- Keep all processing local and add no network call, external AI, telemetry, dependency, or remote configuration.
- Never access or mutate source documents; repository tests use an in-memory SQLite database and synthetic strings.
- Reuse the existing additive `v5_document_dna` schema; this slice adds no migration.
- Preserve the previous completed snapshot on stale input, invalid provenance, cancellation before the write, or any transactional write failure.
- Do not change `document.status`; it remains owned by text ingestion.
- Use literal expectations against real GRDB repositories. Every production behavior starts with a focused failing test that is observed RED.
- Do not add pipeline, composition-root, app-model, SwiftUI, entity-resolution, relationship, or dossier behavior.

---

### Task 1: Pending analysis contract

**Files:**

- Create: `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift`
- Create: `Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift`
- Modify: `Sources/LinkLoomCore/Persistence/ExtractionRepository.swift`

**Interfaces:**

- Consumes: existing `DocumentRecord`, `StoredExtraction`, `documentDNA`, and `documentDNAAnalysisState` rows.
- Produces:

```swift
public struct DocumentDNAAnalysisTarget: Sendable, Equatable {
    public let schemaVersion: Int
    public let analyzerIdentifier: String
    public let analyzerVersion: String

    public init(
        schemaVersion: Int,
        analyzerIdentifier: String,
        analyzerVersion: String
    ) throws
}

public struct PendingDocumentDNAAnalysis: Sendable, Equatable {
    public let document: DocumentRecord
    public let extraction: StoredExtraction
}

public enum DocumentDNARepositoryError: Error, Sendable, Equatable {
    case invalidTarget
    case staleInput
    case invalidProvenance
}

public actor DocumentDNARepository {
    public init(dbWriter: any DatabaseWriter)

    public func pendingAnalysis(
        sourceRootID: UUID,
        target: DocumentDNAAnalysisTarget,
        limit: Int
    ) async throws -> [PendingDocumentDNAAnalysis]
}
```

- [x] **Step 1: Add the real in-memory fixture and failing pending-selection tests**

Create `DocumentDNARepositoryTests.swift` with a `DocumentDNARepositoryFixture` that inserts one synthetic source, inserts `DocumentRecord` values directly through GRDB, and persists synthetic `ExtractedDocument` values through `ExtractionRepository.replace`. Use the literal page text `Rechnung\nBewohnerin: Elise Muster`, extraction version `text-v1`, and content hashes derived only from fixture literals.

Add these tests before the repository types exist:

```swift
@Suite("Document DNA repository")
struct DocumentDNARepositoryTests {
    @Test func pendingAnalysisReturnsOnlyAvailableReadyDocumentsWithExtraction() async throws {
        let fixture = try await DocumentDNARepositoryFixture.make()

        let pending = try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 10
        )

        #expect(pending.map(\.document.relativePath) == ["a-ready.pdf"])
        #expect(pending.map(\.document.contentHash) == ["hash-ready"])
        #expect(pending.map(\.extraction.analysisVersion) == ["text-v1"])
        #expect(pending.map(\.extraction.extraction.pages.map(\.text)) == [[
            "Rechnung\nBewohnerin: Elise Muster",
        ]])
    }

    @Test func pendingAnalysisIsStableSourceScopedAndLimited() async throws {
        let fixture = try await DocumentDNARepositoryFixture.makeWithOrderedReadyDocuments()

        let pending = try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 2
        )
        let empty = try await fixture.repository.pendingAnalysis(
            sourceRootID: fixture.source.id,
            target: fixture.target,
            limit: 0
        )

        #expect(pending.map(\.document.relativePath) == ["a.pdf", "b.pdf"])
        #expect(empty.isEmpty)
    }
}
```

The first test catches selecting discovered, unavailable, missing-extraction, or other-source rows. The second catches missing SQL ordering, source scope, limit handling, or a second read that mismatches a document with its extraction.

- [x] **Step 2: Add failing target/current-state selection tests**

Seed snapshot and state rows directly in the fixture so the pending-query contract is tested independently from the later write API. Add literal cases proving:

```swift
@Test func pendingAnalysisSkipsCurrentSnapshotsAndExactBlockedAttempts() async throws {
    let fixture = try await DocumentDNARepositoryFixture.makeWithPendingStateCases()

    let pending = try await fixture.repository.pendingAnalysis(
        sourceRootID: fixture.source.id,
        target: fixture.target,
        limit: 10
    )

    #expect(pending.map(\.document.relativePath) == [
        "analyzer-changed.pdf",
        "content-changed.pdf",
        "extraction-changed.pdf",
        "no-snapshot.pdf",
        "schema-changed.pdf",
    ])
}

@Test func targetRejectsInvalidVersionIdentity() {
    #expect(throws: DocumentDNARepositoryError.invalidTarget) {
        try DocumentDNAAnalysisTarget(
            schemaVersion: 0,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1"
        )
    }
    #expect(throws: DocumentDNARepositoryError.invalidTarget) {
        try DocumentDNAAnalysisTarget(
            schemaVersion: 1,
            analyzerIdentifier: " ",
            analyzerVersion: "1"
        )
    }
}
```

The state-case fixture includes exact `failed` and exact `analyzing` attempts, which must not be returned; changing any target or input field makes the row eligible again. A matching completed snapshot is not pending regardless of a missing redundant state row.

- [x] **Step 3: Run the focused suite and verify RED**

Run the repository fallback test command with `--filter DocumentDNARepositoryTests`.

Expected: compilation fails because `DocumentDNARepository`, `DocumentDNAAnalysisTarget`, `PendingDocumentDNAAnalysis`, and `DocumentDNARepositoryError` do not exist.

- [x] **Step 4: Implement the minimal target and coherent pending query**

Create the three public value/error types and the actor. Validate the target with `schemaVersion > 0` plus non-blank identifier/version strings.

Implement one SQL query that joins `document` to `documentExtraction`, filters available/ready/current source rows, excludes a matching completed `documentDNA` header, and excludes only exact `failed` or `analyzing` state rows. Compare all target/input fields literally:

```sql
documentDNA.schemaVersion = target.schemaVersion
AND documentDNA.analyzerIdentifier = target.analyzerIdentifier
AND documentDNA.analyzerVersion = target.analyzerVersion
AND documentDNA.inputContentHash = document.contentHash
AND documentDNA.inputExtractionVersion = documentExtraction.analysisVersion
```

Order by `document.relativePath`, apply the positive limit, and decode each selected document plus extraction inside the same `dbWriter.read` closure.

Refactor only the existing extraction row decoding into this internal helper so both repositories use identical persisted-page decoding without changing the public extraction API:

```swift
static func extraction(
    in db: Database,
    documentID: UUID
) throws -> StoredExtraction?
```

- [x] **Step 5: Run focused tests and verify GREEN**

Run the Step 3 command. Expected: all pending/target cases pass, and existing `ExtractionRepository` consumers still compile.

- [x] **Step 6: Commit the pending contract**

```sh
git add Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift \
  Sources/LinkLoomCore/Persistence/ExtractionRepository.swift \
  Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift
git commit -m "feat(dna): add pending repository query"
```

---

### Task 2: Atomic snapshot replacement and stored/current reads

**Files:**

- Modify: `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift`
- Modify: `Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift`

**Interfaces:**

- Consumes: Task 1 target, repository, pending candidate, existing v5 tables, and validated `DocumentDNA` values.
- Produces:

```swift
public func replace(_ snapshot: DocumentDNA) async throws

public func storedSnapshot(documentID: UUID) async throws -> DocumentDNA?

public func currentSnapshot(
    documentID: UUID,
    target: DocumentDNAAnalysisTarget
) async throws -> DocumentDNA?
```

- [x] **Step 1: Add failing complete round-trip and state tests**

Create a literal valid snapshot containing:

- `documentType=invoice` with evidence `(page 0, start 0, length 8, exactText "Rechnung", OCR index [0])`;
- `person=elise muster` with evidence `(page 0, start 21, length 12, exactText "Elise Muster", OCR index [1])`.

Add:

```swift
@Test func replaceRoundTripsCompleteSnapshotAndMarksMatchingStateReady() async throws {
    let fixture = try await DocumentDNARepositoryFixture.make()
    let snapshot = try fixture.snapshot()

    try await fixture.repository.replace(snapshot)

    #expect(try await fixture.repository.storedSnapshot(documentID: snapshot.documentID) == snapshot)
    let state = try await fixture.analysisState(documentID: snapshot.documentID)
    #expect(state == LiteralAnalysisState(
        schemaVersion: 1,
        analyzerIdentifier: "local-rules",
        analyzerVersion: "1",
        contentHash: "hash-ready",
        extractionVersion: "text-v1",
        status: "ready",
        failureCode: nil
    ))
}
```

The expected snapshot is constructed independently from literal values, not by reading rows back into the expected value.

- [x] **Step 2: Add failing replacement/idempotence and rollback tests**

Add one reanalysis test that persists analyzer version `1`, proves target `1` has no pending candidate, proves target `2` has one, persists a version `2` snapshot, then asserts target `2` is empty and literal row counts are exactly header `1`, findings `2`, evidence `2`, state `1`.

Add one rollback test that:

1. persists a version `1` snapshot;
2. installs a SQLite trigger that aborts evidence insertion;
3. attempts version `2` replacement;
4. asserts the thrown GRDB error;
5. asserts the version `1` snapshot and version `1` ready state remain byte-for-value equivalent;
6. asserts row counts remain `1/2/2/1`.

This test catches deleting the prior snapshot outside the transaction, appending children, or updating state before all evidence commits.

- [x] **Step 3: Add failing current-versus-stored read tests**

Add independent literal tests:

```swift
@Test func currentSnapshotRequiresMatchingTargetAndCurrentInputs() async throws {
    let fixture = try await DocumentDNARepositoryFixture.make()
    let snapshot = try fixture.snapshot()
    try await fixture.repository.replace(snapshot)

    #expect(try await fixture.repository.currentSnapshot(
        documentID: snapshot.documentID,
        target: fixture.target
    ) == snapshot)
    #expect(try await fixture.repository.currentSnapshot(
        documentID: snapshot.documentID,
        target: fixture.target(analyzerVersion: "2")
    ) == nil)

    try await fixture.changeExtractionVersion(to: "text-v2")
    #expect(try await fixture.repository.currentSnapshot(
        documentID: snapshot.documentID,
        target: fixture.target
    ) == nil)
    #expect(try await fixture.repository.storedSnapshot(documentID: snapshot.documentID) == snapshot)
}
```

Use a separate test for a changed catalog content hash so extraction-version and content-hash branches cannot mask each other.

- [x] **Step 4: Run the focused suite and verify RED**

Run the Task 1 focused command.

Expected: compilation fails because `replace`, `storedSnapshot`, and `currentSnapshot` do not exist.

- [x] **Step 5: Implement complete transactional persistence and decoding**

Inside one `dbWriter.write` transaction:

1. delete the old `documentDNA` header so cascades remove old children;
2. insert the snapshot header;
3. insert findings with enumerated `sortOrder`;
4. insert evidence with enumerated `evidenceOrder` and JSON-encoded OCR indexes;
5. upsert the exact matching `documentDNAAnalysisState` as `ready` with `failureCode = NULL`.

Implement a single private row decoder that orders findings by `sortOrder`, evidence by `evidenceOrder`, JSON-decodes `[Int]`, and reconstructs values through the throwing domain initializers. `storedSnapshot` uses it directly. `currentSnapshot` first requires header target/input equality with the current `document.contentHash` and `documentExtraction.analysisVersion`; stale snapshots remain readable only through `storedSnapshot`.

- [x] **Step 6: Run focused tests and verify GREEN**

Run the Task 1 focused command. Expected: round-trip, replacement, rollback, pending-idempotence, and current/stored read tests pass.

- [x] **Step 7: Commit atomic persistence and reads**

```sh
git add Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift \
  Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift
git commit -m "feat(dna): persist atomic snapshots"
```

---

### Task 3: Stale-input and exact-provenance rejection

**Files:**

- Modify: `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift`
- Modify: `Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift`

**Interfaces:**

- Consumes: Task 2 `replace(_:)`, the snapshot input identity, and persisted extracted pages/regions.
- Produces: `replace(_:)` throws `DocumentDNARepositoryError.staleInput` or `.invalidProvenance` before deleting the previous completed snapshot.

- [x] **Step 1: Add failing stale content-hash test**

Persist the fixture snapshot, change only `document.contentHash` to `hash-changed`, then call `replace` with an analyzer-version-2 snapshot still bound to `hash-ready`.

Assert exactly:

```swift
await #expect(throws: DocumentDNARepositoryError.staleInput) {
    try await fixture.repository.replace(staleSnapshot)
}
#expect(try await fixture.repository.storedSnapshot(documentID: staleSnapshot.documentID) == original)
```

Also assert that a stale first write creates zero DNA/state rows.

- [x] **Step 2: Run the stale content test and verify RED**

Run the focused suite filtered to the stale-content test.

Expected: the write succeeds or replaces the old snapshot instead of throwing `staleInput`.

- [x] **Step 3: Add the minimal transactional content-hash guard**

Before any delete, fetch the current ready document and extraction inside the same write transaction. Require the current document ID and `contentHash` to equal the snapshot input. Throw `.staleInput` on absence, non-ready status, or mismatch.

- [x] **Step 4: Run the stale content test and verify GREEN**

Run the Step 2 command. Expected: stale write is rejected and the prior snapshot remains.

- [x] **Step 5: Add failing extraction-version stale test**

Persist the original snapshot, replace only the stored extraction version with `text-v2`, and attempt a version-2 DNA snapshot still bound to `text-v1`. Assert `.staleInput`, unchanged prior DNA/state, and unchanged document status.

- [x] **Step 6: Run the extraction-version test and verify RED**

Run only the extraction-version stale test. Expected: it succeeds because only content hash is guarded.

- [x] **Step 7: Add the minimal extraction-version guard and verify GREEN**

Require the current `documentExtraction.analysisVersion` to equal `snapshot.inputExtractionVersion` in the pre-delete transaction guard, then rerun the extraction-version test and the full focused repository suite.

- [x] **Step 8: Add failing literal-text and page provenance tests**

Add separate snapshots whose domain values are valid but whose stored-page provenance is not:

- page index `9` for a one-page extraction;
- page-0 range `(0, 8)` with exact text `Vertragx` instead of `Rechnung`;
- page-0 range starting beyond the UTF-16 page length.

Each test asserts `.invalidProvenance`, no rows on a first write, and preservation of an existing snapshot on replacement.

- [x] **Step 9: Run the text/page provenance tests and verify RED**

Run the focused suite filtered to each new test. Expected: persistence accepts the domain-valid but source-invalid evidence.

- [x] **Step 10: Validate page/range/excerpt before replacement and verify GREEN**

For every evidence value, locate the persisted page by zero-based `pageIndex`; validate a positive in-bounds UTF-16 `NSRange`; slice `page.text as NSString`; require equality with `exactText`. Throw `.invalidProvenance` before deleting old rows. Rerun all Step 8 tests.

- [x] **Step 11: Add failing exact OCR-region provenance test**

For the fixture extraction, supply classification evidence `(0, 8)` with OCR indexes `[1]` even though it intersects only region `0`. Add a second case with empty indexes. Both domain values are valid; both repository writes must throw `.invalidProvenance` and preserve prior data.

- [x] **Step 12: Run OCR provenance tests and verify RED**

Run the two OCR cases. Expected: they persist because text-only provenance validation does not compare OCR regions.

- [x] **Step 13: Validate the complete intersecting OCR index set and verify GREEN**

Reconstruct each region range using the persisted ordering and newline separator:

```swift
let precedingLength = page.regions[..<index]
    .reduce(0) { $0 + ($1.text as NSString).length + 1 }
```

Compute every region whose range has positive intersection with the evidence range and require exact equality with `ocrRegionIndexes`. Rerun OCR cases and the entire repository suite.

- [x] **Step 14: Commit stale/provenance protection**

```sh
git add Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift \
  Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift
git commit -m "fix(dna): reject stale repository writes"
```

---

### Task 4: Complete verification and review preparation

**Files:**

- Modify: `docs/superpowers/plans/2026-08-25-document-dna-repository.md` only to mark completed steps.

**Interfaces:**

- Consumes: Tasks 1-3.
- Produces: a clean branch and exact review evidence for one repository-only pull request.

- [x] **Step 1: Run focused repository tests**

Run the fallback Swift command with `--filter DocumentDNARepositoryTests`. Expected: every pending, read, replacement, rollback, stale-input, and provenance test passes.

- [x] **Step 2: Run the complete suite**

Run the complete fallback Swift Testing command. Expected: all non-opt-in tests pass; the opt-in 10,000-document test remains skipped because this slice does not change catalog scale behavior.

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
```

Inspect the complete diff and confirm it contains only `.gitignore`, the implementation plan, `DocumentDNARepository`, the narrow shared extraction decoder refactor, and repository tests. Confirm no migration, pipeline, app/UI, source-file, network, telemetry, dependency, database artifact, build artifact, or real personal data is present.

- [x] **Step 5: Request independent review and resolve findings**

Review against sections 6, 8, 10, 11, and 13.2 of the accepted spec. Resolve every Important/Critical finding with a new failing regression test before changing production code, then repeat Steps 1-4.

- [x] **Step 6: Push and create the focused pull request**

Use a Conventional Commit PR title at most 72 characters. Report exact local/CI verification, explain the local-only privacy boundary, state that v5 is reused with no migration, identify additive API compatibility and rollback risk, and explain any diff above 500 lines. Do not merge without a separate explicit authorization after required checks pass.
