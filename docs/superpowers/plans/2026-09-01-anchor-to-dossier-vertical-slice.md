# Anchor-to-Dossier Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first persistent `Kosten und Zahlungen` dossier from a document anchor, with direct explainable confirmed invoice-payment membership, durable dossier-scoped corrections, robust reanalysis, and a complete accessible UI workflow.

**Architecture:** Persist only dossier identity and negative corrections in schema v7. `DossierRepository` reads current documents, DNA, content-valid decisions, and corrections inside one GRDB transaction, then uses a pure projector to return an immutable snapshot. `AppModel` consumes this through focused protocols, retains the existing source/document presentation flow, and publishes only generation-checked complete snapshots.

**Tech Stack:** Swift 6.2, macOS 15, SwiftUI, Combine, Swift Testing, GRDB 7.10.0, XCTest/XCUIAutomation, SQLite3.

**Spec:** `docs/superpowers/specs/2026-09-01-anchor-to-dossier-vertical-slice-design.md`

## Global Constraints

- Work in `/Users/robert/Documents/ChatGPT/LinkLoom`; do not create a Codex worktree.
- Start each implementation PR from the then-current `origin/main`; do not stack unpublished PR branches.
- Use branches `codex/feat/dossier-persistence`, `codex/feat/dossier-projection`, `codex/feat/dossier-app-model`, and `codex/feat/dossier-ui` in that order.
- Do not push, create a pull request, merge, or delete a remote branch without explicit user authorization for that action.
- Write a failing behavioral test first, run it and observe the expected failure, implement the minimum behavior, then rerun the focused test.
- Keep `LinkLoomCore` independent of `LinkLoomAppFeature` and `LinkLoomApp`.
- Do not add dependencies, network calls, external AI, telemetry, remote configuration, or generated artifacts.
- Never rename, move, delete, or modify selected source documents. Tests use synthetic temporary fixtures only.
- Preserve security-scoped access, cancellation, actor isolation, source-scoped coordination, content-bound invoice-payment decisions, and current source/document navigation semantics.
- Dossier membership is direct only. Do not materialize membership rows or introduce generic entities, graphs, transitive expansion, manual membership, rename, delete, merge, or subdossiers.
- Before every commit run `git diff --check` and `git diff --cached --check`; inspect `git status --short` for unintended files.
- Before every PR handoff run the focused tests, `swift test`, `swift build -c release`, and self-review the complete branch diff. PR 4 also runs the documented `xcodebuild` UI smoke command.

---

## File Structure

### PR 1 — persistent foundation

- Create `Sources/LinkLoomCore/Models/Dossier.swift`: persisted domain values and validation.
- Modify `Sources/LinkLoomCore/Persistence/AppDatabase.swift`: additive v7 migration.
- Create `Sources/LinkLoomCore/Persistence/DossierStore.swift`: transaction-local row storage used by the later repository.
- Create `Tests/LinkLoomCoreTests/DossierDomainTests.swift`: domain validation.
- Modify `Tests/LinkLoomCoreTests/AppDatabaseTests.swift`: migration, preservation, constraint, and cascade coverage.
- Create `Tests/LinkLoomCoreTests/DossierStoreTests.swift`: idempotent storage and exact exclusion revision behavior.

### PR 2 — atomic explainable projection

- Create `Sources/LinkLoomCore/Matching/InvoicePaymentCandidateProjector.swift`: shared pure aggregation of current candidates involving one document.
- Modify `Sources/LinkLoomCore/Matching/InvoicePaymentCandidateLookup.swift`: delegate aggregation without changing behavior.
- Modify `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift`: expose internal transaction-local current-snapshot readers.
- Modify `Sources/LinkLoomCore/Persistence/InvoicePaymentDecisionRepository.swift`: expose internal transaction-local current-decision reads with timestamps.
- Create `Sources/LinkLoomCore/Models/DossierSnapshot.swift`: summaries, members, explanations, support identities, corrections, and results.
- Create `Sources/LinkLoomCore/Dossiers/CostsAndPaymentsDossierProjector.swift`: pure direct-membership projection.
- Create `Sources/LinkLoomCore/Persistence/DossierProjectionReader.swift`: assemble one consistent projection input from a GRDB transaction.
- Create `Sources/LinkLoomCore/Persistence/DossierRepository.swift`: public async create/open/load/correct boundary.
- Create `Tests/LinkLoomCoreTests/InvoicePaymentCandidateProjectorTests.swift`: shared aggregation parity.
- Create `Tests/LinkLoomCoreTests/DossierProjectorTests.swift`: pure projection rules.
- Create `Tests/LinkLoomCoreTests/DossierRepositoryTests.swift`: transactions, resolution, corrections, lifecycle, stale input, and ABA.
- Create `Tests/LinkLoomCoreTests/Support/DossierFixture.swift`: synthetic database/DNA/decision fixture used only by dossier tests.

### PR 3 — AppModel orchestration

- Create `Sources/LinkLoomAppFeature/DossierAppState.swift`: app protocols and UI-independent state enums.
- Modify `Sources/LinkLoomAppFeature/AppModel.swift`: workspace, entry, snapshot, correction, refresh, and member-selection orchestration.
- Modify `Sources/LinkLoomAppFeature/AppRuntimeDiagnostic.swift`: privacy-safe dossier categories and stale mapping.
- Modify `Tests/LinkLoomAppFeatureTests/AppModelTests.swift`: asynchronous behavior and source/document reuse.
- Create `Tests/LinkLoomAppFeatureTests/DossierAppStateTests.swift`: state convenience and diagnostic mapping.

### PR 4 — visible vertical slice

- Create `Sources/LinkLoomAppFeature/DocumentDNAInspector.swift`: reusable existing document inspector.
- Modify `Sources/LinkLoomAppFeature/ScanDashboard.swift`: remove private inspector ownership while preserving source dashboard behavior.
- Create `Sources/LinkLoomAppFeature/WorkspaceSidebar.swift`: one source-and-dossier selection list.
- Delete `Sources/LinkLoomAppFeature/SourceSidebar.swift`: replaced by the unified sidebar.
- Create `Sources/LinkLoomAppFeature/DossierPresentation.swift`: German labels and explanation presentation.
- Create `Sources/LinkLoomAppFeature/CostsAndPaymentsDossierView.swift`: dossier workspace and correction actions.
- Modify `Sources/LinkLoomAppFeature/ContentView.swift`: route workspace details and own the shared inspector.
- Modify `Sources/LinkLoomApp/LinkLoomApp.swift`: construct and inject the repository through a composition adapter.
- Modify `Tests/LinkLoomAppFeatureTests/ScanDashboardTests.swift`: inspector extraction regression coverage.
- Create `Tests/LinkLoomAppFeatureTests/DossierPresentationTests.swift`: deterministic role, status, and explanation copy.
- Modify `Tests/LinkLoomAppTests/AppCompositionTests.swift`: adapter forwarding and cancellation.
- Modify `LinkLoomUITests/LinkLoomUISmokeTests.swift`: full create, navigate, correct, restart, restore workflow.
- Modify `LinkLoomUITests/Support/SQLiteProbe.swift`: dossier persistence and cascade evidence.
- Modify `README.md`: concise dossier workflow and local-only correction semantics.

---

# PR 1: Persist Dossier Identity and Corrections

## Task 1: Add validated persisted-domain values

**Files:**
- Create: `Sources/LinkLoomCore/Models/Dossier.swift`
- Create: `Tests/LinkLoomCoreTests/DossierDomainTests.swift`

**Interfaces:**
- Produces: `DossierKind`, `DossierRecord`, `DossierMembershipExclusion`, and `DossierValidationError`.
- `DossierRecord.init(id:kind:displayName:anchorDocumentID:createdAt:updatedAt:) throws` rejects blank names and `updatedAt < createdAt`.
- `DossierMembershipExclusion.init(dossierID:documentID:revisionID:excludedAt:)` carries durable, non-content-bound correction identity.

- [ ] **Step 1: Write the failing domain tests**

```swift
import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Dossier domain")
struct DossierDomainTests {
    @Test func dossierRejectsBlankNameAndBackwardsUpdateTime() {
        let createdAt = Date(timeIntervalSince1970: 100)
        #expect(throws: DossierValidationError.invalidRecord) {
            try DossierRecord(
                id: UUID(), kind: .costsAndPayments, displayName: " \n",
                anchorDocumentID: UUID(), createdAt: createdAt, updatedAt: createdAt
            )
        }
        #expect(throws: DossierValidationError.invalidRecord) {
            try DossierRecord(
                id: UUID(), kind: .costsAndPayments,
                displayName: "Kosten und Zahlungen", anchorDocumentID: UUID(),
                createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(-1)
            )
        }
    }

    @Test func exclusionIdentityIsIndependentOfDocumentContent() {
        let dossierID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let documentID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let revisionID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let exclusion = DossierMembershipExclusion(
            dossierID: dossierID, documentID: documentID, revisionID: revisionID,
            excludedAt: Date(timeIntervalSince1970: 200)
        )
        #expect(exclusion.dossierID == dossierID)
        #expect(exclusion.documentID == documentID)
        #expect(exclusion.revisionID == revisionID)
    }
}
```

- [ ] **Step 2: Run the test and verify the missing-type failure**

Run: `swift test --filter DossierDomainTests`

Expected: compilation fails because `DossierRecord` and related types do not exist.

- [ ] **Step 3: Add the minimum domain implementation**

```swift
import Foundation

public enum DossierKind: String, CaseIterable, Sendable, Equatable {
    case costsAndPayments
}

public enum DossierValidationError: Error, Sendable, Equatable {
    case invalidRecord
}

public struct DossierRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: DossierKind
    public let displayName: String
    public let anchorDocumentID: UUID
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID, kind: DossierKind, displayName: String,
        anchorDocumentID: UUID, createdAt: Date, updatedAt: Date
    ) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              updatedAt >= createdAt else {
            throw DossierValidationError.invalidRecord
        }
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.anchorDocumentID = anchorDocumentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DossierMembershipExclusion: Sendable, Equatable {
    public let dossierID: UUID
    public let documentID: UUID
    public let revisionID: UUID
    public let excludedAt: Date

    public init(
        dossierID: UUID, documentID: UUID, revisionID: UUID, excludedAt: Date
    ) {
        self.dossierID = dossierID
        self.documentID = documentID
        self.revisionID = revisionID
        self.excludedAt = excludedAt
    }
}
```

- [ ] **Step 4: Run the focused test and verify it passes**

Run: `swift test --filter DossierDomainTests`

Expected: both tests pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomCore/Models/Dossier.swift Tests/LinkLoomCoreTests/DossierDomainTests.swift
git diff --cached --check
git commit -m "feat(dossier): add persisted domain values"
```

## Task 2: Add the additive v7 migration

**Files:**
- Modify: `Sources/LinkLoomCore/Persistence/AppDatabase.swift`
- Modify: `Tests/LinkLoomCoreTests/AppDatabaseTests.swift`

**Interfaces:**
- Produces tables `dossier` and `dossierMembershipExclusion` exactly as specified.
- Migration name: `v7_costs_and_payments_dossiers`.
- Consumes: current v6 `document` rows and foreign-key cascade behavior.

- [ ] **Step 1: Add failing schema, preservation, constraint, and cascade tests**

Add tests named:

```swift
@Test func dossierMigrationCreatesConstrainedSchema() throws
@Test func dossierMigrationPreservesV6DataWithoutBackfill() throws
@Test func dossierMigrationRejectsDuplicateAnchorAndInvalidKind() throws
@Test func deletingAnchorDocumentCascadesDossierAndExclusions() throws
@Test func deletingExcludedDocumentCascadesOnlyItsExclusion() throws
```

The first test must assert both exact column arrays, the composite unique key
`["kind", "anchorDocumentID"]`, the exclusion primary key
`["dossierID", "documentID"]`, and unique `revisionID`. The preservation test
migrates only through `v6_invoice_payment_user_decisions`, inserts one current
decision, runs `AppDatabase.migrate`, then requires that decision unchanged and
both new tables empty.

- [ ] **Step 2: Run the migration tests and verify failure**

Run: `swift test --filter AppDatabaseTests`

Expected: new tests fail because the v7 tables are absent.

- [ ] **Step 3: Register the exact migration**

```swift
migrator.registerMigration("v7_costs_and_payments_dossiers") { db in
    try db.create(table: "dossier") { table in
        table.column("id", .text).primaryKey()
        table.column("kind", .text).notNull()
            .check(sql: "kind = 'costsAndPayments'")
        table.column("displayName", .text).notNull()
            .check(sql: "length(trim(displayName)) > 0")
        table.column("anchorDocumentID", .text).notNull()
            .references("document", onDelete: .cascade)
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.uniqueKey(["kind", "anchorDocumentID"])
        table.check(sql: "updatedAt >= createdAt")
    }
    try db.create(
        index: "dossier_anchor_document",
        on: "dossier",
        columns: ["anchorDocumentID"]
    )
    try db.create(table: "dossierMembershipExclusion") { table in
        table.column("dossierID", .text).notNull()
            .references("dossier", onDelete: .cascade)
        table.column("documentID", .text).notNull()
            .references("document", onDelete: .cascade)
        table.column("revisionID", .text).notNull().unique()
        table.column("excludedAt", .datetime).notNull()
        table.primaryKey(["dossierID", "documentID"])
    }
}
```

- [ ] **Step 4: Run focused migration tests**

Run: `swift test --filter AppDatabaseTests`

Expected: all database tests pass, including v1-through-v7 migration.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomCore/Persistence/AppDatabase.swift Tests/LinkLoomCoreTests/AppDatabaseTests.swift
git diff --cached --check
git commit -m "feat(dossier): add v7 persistence schema"
```

## Task 3: Add the transaction-local dossier store

**Files:**
- Create: `Sources/LinkLoomCore/Persistence/DossierStore.swift`
- Create: `Tests/LinkLoomCoreTests/DossierStoreTests.swift`

**Interfaces:**
- Produces internal synchronous methods that accept `GRDB.Database`, so PR 2 can compose all reads and writes in one outer transaction.
- Exact methods:

```swift
enum DossierStore {
    static func all(in db: Database) throws -> [DossierRecord]
    static func record(in db: Database, id: UUID) throws -> DossierRecord?
    static func insertOrFetchAnchored(
        in db: Database, proposed: DossierRecord
    ) throws -> DossierRecord
    static func exclusions(
        in db: Database, dossierID: UUID
    ) throws -> [DossierMembershipExclusion]
    static func insertExclusion(
        in db: Database, exclusion: DossierMembershipExclusion
    ) throws
    static func deleteExclusion(
        in db: Database, dossierID: UUID, documentID: UUID,
        expectedRevisionID: UUID
    ) throws -> Bool
}
```

- [ ] **Step 1: Write failing store tests**

```swift
@Test func insertOrFetchAnchoredIsIdempotent() throws {
    let fixture = try DossierStoreFixture.make()
    let proposed = try fixture.dossier(id: fixture.firstDossierID)
    try fixture.db.write { db in
        let first = try DossierStore.insertOrFetchAnchored(in: db, proposed: proposed)
        let second = try DossierStore.insertOrFetchAnchored(
            in: db, proposed: try fixture.dossier(id: fixture.secondDossierID)
        )
        #expect(first == proposed)
        #expect(second == proposed)
        #expect(try DossierStore.all(in: db) == [proposed])
    }
}

@Test func deleteExclusionRequiresExactRevision() throws {
    let fixture = try DossierStoreFixture.make()
    try fixture.db.write { db in
        let dossier = try DossierStore.insertOrFetchAnchored(
            in: db, proposed: try fixture.dossier(id: fixture.firstDossierID)
        )
        let exclusion = fixture.exclusion(dossierID: dossier.id)
        try DossierStore.insertExclusion(in: db, exclusion: exclusion)
        #expect(try !DossierStore.deleteExclusion(
            in: db, dossierID: dossier.id, documentID: fixture.paymentID,
            expectedRevisionID: UUID()
        ))
        #expect(try DossierStore.deleteExclusion(
            in: db, dossierID: dossier.id, documentID: fixture.paymentID,
            expectedRevisionID: exclusion.revisionID
        ))
    }
}
```

`DossierStoreFixture.make()` creates a migrated in-memory database, one source,
and distinct anchor/payment `document` rows using the complete current document
column list.

- [ ] **Step 2: Run and observe the missing-store failure**

Run: `swift test --filter DossierStoreTests`

Expected: compilation fails because `DossierStore` is undefined.

- [ ] **Step 3: Implement exact row decoding and conflict behavior**

Use explicit SQL and decode enum values before constructing validated domain
values. `insertOrFetchAnchored` first inserts with `ON CONFLICT(kind,
anchorDocumentID) DO NOTHING`, then fetches by that unique identity and throws
`DossierStoreError.invalidStoredState` if no row exists. Exclusion insertion is
plain `INSERT`; domain-level idempotence and support validation remain PR 2's
repository responsibility. `all(in:)` orders by `createdAt, id`; exclusions
order by `excludedAt, documentID`.

```swift
enum DossierStoreError: Error, Equatable {
    case invalidStoredState
}

static func deleteExclusion(
    in db: Database, dossierID: UUID, documentID: UUID,
    expectedRevisionID: UUID
) throws -> Bool {
    try db.execute(
        sql: """
            DELETE FROM dossierMembershipExclusion
            WHERE dossierID = ? AND documentID = ? AND revisionID = ?
            """,
        arguments: [dossierID, documentID, expectedRevisionID]
    )
    return db.changesCount == 1
}
```

- [ ] **Step 4: Run focused Core persistence tests**

Run: `swift test --filter DossierStoreTests`

Expected: all store tests pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomCore/Persistence/DossierStore.swift Tests/LinkLoomCoreTests/DossierStoreTests.swift
git diff --cached --check
git commit -m "feat(dossier): persist anchored records and corrections"
```

## PR 1 completion gate

- [ ] Run `swift test --filter 'Dossier|AppDatabaseTests'`.
- [ ] Run `swift test`.
- [ ] Run `swift build -c release`.
- [ ] Run `git diff origin/main...HEAD --check` and inspect `git status --short`.
- [ ] Review the entire branch for schema rollback risk, accidental public mutation APIs, unrelated files, secrets, local databases, `.build`, and `.superpowers` artifacts.
- [ ] Stop. Obtain explicit authorization before push or PR creation. Merge authorization remains separate.

---

# PR 2: Project Current Explainable Membership

## Task 4: Share candidate aggregation and transaction-local reads

**Files:**
- Create: `Sources/LinkLoomCore/Matching/InvoicePaymentCandidateProjector.swift`
- Modify: `Sources/LinkLoomCore/Matching/InvoicePaymentCandidateLookup.swift`
- Modify: `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift`
- Modify: `Sources/LinkLoomCore/Persistence/InvoicePaymentDecisionRepository.swift`
- Create: `Tests/LinkLoomCoreTests/InvoicePaymentCandidateProjectorTests.swift`
- Modify: `Tests/LinkLoomCoreTests/InvoicePaymentCandidateLookupTests.swift`
- Modify: `Tests/LinkLoomCoreTests/InvoicePaymentDecisionRepositoryTests.swift`

**Interfaces:**

```swift
struct InvoicePaymentCandidateProjectionInput: Sendable {
    let selected: CurrentDocumentDNA
    let matchesByNormalizedReference: [String: [CurrentDocumentDNA]]
}

struct InvoicePaymentCandidateProjector: Sendable {
    init(resolver: InvoicePaymentCandidateResolver = InvoicePaymentCandidateResolver())
    func normalizedReferences(in selected: CurrentDocumentDNA) -> [String]
    func candidates(
        from input: InvoicePaymentCandidateProjectionInput
    ) -> [InvoicePaymentCandidate]
}

extension DocumentDNARepository {
    static func currentSnapshot(
        in db: Database, documentID: UUID,
        target: DocumentDNAAnalysisTarget
    ) throws -> CurrentDocumentDNA?
    static func currentSnapshotsMatchingReference(
        in db: Database, normalizedValue: String,
        target: DocumentDNAAnalysisTarget
    ) throws -> [CurrentDocumentDNA]
}

extension InvoicePaymentDecisionRepository {
    static func currentRecords(
        in db: Database, keys: [InvoicePaymentDecisionKey]
    ) throws -> [InvoicePaymentDecisionKey: InvoicePaymentDecisionRecord]
}
```

- [ ] **Step 1: Add failing parity and timestamp tests**

The projector tests construct one invoice and two payments with duplicate
normalized references and require the same deduplication, ambiguity downgrade,
and deterministic order currently asserted by lookup tests. Add a repository
test that requires `currentRecords(in:keys:)` to return only exact current rows
and preserve `updatedAt`.

```swift
@Test func projectorDeduplicatesReferencesAndPreservesLookupOrder() throws {
    let fixture = try CandidateProjectionFixture.make()
    let projected = InvoicePaymentCandidateProjector().candidates(
        from: fixture.input
    )
    #expect(projected.map { ($0.invoice.document.id, $0.payment.document.id) }
        == fixture.expectedPairs)
    #expect(projected.allSatisfy { $0.disposition == .suggestion })
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `swift test --filter 'InvoicePaymentCandidate(Projector|Lookup)Tests|InvoicePaymentDecisionRepositoryTests'`

Expected: projector types and transaction-local readers are missing.

- [ ] **Step 3: Extract without changing matching semantics**

Move the reference-qualifier selection, normalized-reference collection,
pair deduplication, ambiguity recomputation, and ordering from
`InvoicePaymentCandidateLookup` into the pure projector. The lookup loads the
same matching snapshots as before, builds `matchesByNormalizedReference`, and
delegates. Refactor existing async repository methods to call the new internal
static readers inside their current `dbWriter.read` closures.

```swift
func candidates(
    from input: InvoicePaymentCandidateProjectionInput
) -> [InvoicePaymentCandidate] {
    var candidatesByPair: [InvoicePaymentCandidatePair: InvoicePaymentCandidate] = [:]
    for reference in normalizedReferences(in: input.selected) {
        let documents = input.matchesByNormalizedReference[reference] ?? []
        for candidate in resolver.candidates(matching: reference, in: documents)
        where candidate.invoice.document.id == input.selected.document.id
            || candidate.payment.document.id == input.selected.document.id {
            let pair = InvoicePaymentCandidatePair(candidate)
            if let old = candidatesByPair[pair], strength(old) >= strength(candidate) {
                continue
            }
            candidatesByPair[pair] = candidate
        }
    }
    return normalizeAmbiguityAndSort(Array(candidatesByPair.values))
}
```

- [ ] **Step 4: Run focused and existing matching tests**

Run: `swift test --filter 'InvoicePaymentCandidate(Projector|Lookup|Resolver)Tests|InvoicePaymentDecisionRepositoryTests|DocumentDNARepositoryTests'`

Expected: all pass with unchanged existing candidate results.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomCore/Matching/InvoicePaymentCandidateProjector.swift Sources/LinkLoomCore/Matching/InvoicePaymentCandidateLookup.swift Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift Sources/LinkLoomCore/Persistence/InvoicePaymentDecisionRepository.swift Tests/LinkLoomCoreTests/InvoicePaymentCandidateProjectorTests.swift Tests/LinkLoomCoreTests/InvoicePaymentCandidateLookupTests.swift Tests/LinkLoomCoreTests/InvoicePaymentDecisionRepositoryTests.swift
git diff --cached --check
git commit -m "refactor(dossier): share current candidate projection"
```

## Task 5: Add immutable dossier snapshots and the pure projector

**Files:**
- Create: `Sources/LinkLoomCore/Models/DossierSnapshot.swift`
- Create: `Sources/LinkLoomCore/Dossiers/CostsAndPaymentsDossierProjector.swift`
- Create: `Tests/LinkLoomCoreTests/DossierProjectorTests.swift`

**Interfaces:**

```swift
public enum DossierMemberRole: Sendable, Equatable { case anchor, invoice, payment }

public struct DossierMembershipSupportIdentity: Sendable, Equatable {
    public let decisionKey: InvoicePaymentDecisionKey
    public let decisionUpdatedAt: Date
    public let invoiceDNAAnalyzedAt: Date
    public let paymentDNAAnalyzedAt: Date
    public let resolverVersion: String
}

public struct DossierMembershipExplanation: Sendable, Equatable {
    public let role: DossierMemberRole
    public let relationshipType: DocumentRelationshipType?
    public let signals: [InvoicePaymentCandidateSignal]
}

public struct DossierMember: Identifiable, Sendable, Equatable {
    public var id: UUID { document.id }
    public let document: DocumentRecord
    public let sourceDisplayName: String
    public let documentType: DocumentType?
    public let explanation: DossierMembershipExplanation
    public let support: DossierMembershipSupportIdentity?
}

public struct DossierCorrection: Identifiable, Sendable, Equatable {
    public var id: UUID { document.id }
    public let exclusion: DossierMembershipExclusion
    public let document: DocumentRecord
    public let sourceDisplayName: String
    public let documentType: DocumentType?
}

public struct DossierProjectionToken: Sendable, Equatable {
    public let dossierUpdatedAt: Date
    public let anchorContentHash: String
    public let memberSupports: [DossierMembershipSupportIdentity]
    public let exclusionRevisionIDs: [UUID]
}

public struct DossierSnapshot: Sendable, Equatable {
    public let dossier: DossierRecord
    public let members: [DossierMember]
    public let corrections: [DossierCorrection]
    public let token: DossierProjectionToken
}
```

Internal `CostsAndPaymentsDossierProjectionInput` carries one dossier, its
anchor, all candidate documents, candidates, exact current decision records,
source display names, and exclusions. The projector throws
`DossierProjectionError.invalidStoredState` only for impossible persisted
invariants such as a missing anchor row.

- [ ] **Step 1: Write failing pure behavior tests**

Add explicit tests for anchor-only projection, direct confirmed membership,
undecided/excluded/content-stale rejection, dossier exclusion, no transitive
second hop, deduplication, deterministic source/path/UUID order, missing
availability, optional current document type, explanation signals, and support
timestamps.

```swift
@Test func confirmedDirectCounterpartHasExplainableSupport() throws {
    let fixture = try DossierProjectorFixture.confirmedPair()
    let snapshot = try CostsAndPaymentsDossierProjector().project(fixture.input)
    #expect(snapshot.members.map(\.document.id) == [fixture.invoiceID, fixture.paymentID])
    #expect(snapshot.members[0].explanation.role == .anchor)
    #expect(snapshot.members[1].explanation.role == .payment)
    #expect(snapshot.members[1].explanation.signals.map(\.kind)
        == [.referenceNumber, .monetaryAmount, .organization])
    #expect(snapshot.members[1].support == fixture.expectedSupport)
}
```

- [ ] **Step 2: Run and verify missing projector failure**

Run: `swift test --filter DossierProjectorTests`

Expected: compilation fails because snapshot and projector types are absent.

- [ ] **Step 3: Implement direct-only projection**

For every candidate involving the anchor, build its exact
`InvoicePaymentDecisionKey`, require a current `.confirmed` record, reject a
matching exclusion, and create one member. Use the candidate's two
`snapshot.analyzedAt` values plus decision `updatedAt` in the support identity.
Always prepend the anchor, even without current DNA.

```swift
let confirmed = input.candidates.compactMap { candidate -> DossierMember? in
    guard let counterpart = candidate.counterpart(to: input.anchor.id),
          let key = try? InvoicePaymentDecisionKey(candidate: candidate),
          let record = input.decisionsByKey[key],
          record.decision == .confirmed,
          !input.excludedDocumentIDs.contains(counterpart.document.id)
    else { return nil }
    return DossierMember(
        document: counterpart.document,
        sourceDisplayName: input.sourceDisplayNames[counterpart.document.sourceRootID]
            ?? counterpart.document.sourceRootID.uuidString,
        documentType: counterpart.documentType,
        explanation: DossierMembershipExplanation(
            role: counterpart.document.id == candidate.invoice.document.id
                ? .invoice : .payment,
            relationshipType: key.relationshipType,
            signals: candidate.signals
        ),
        support: DossierMembershipSupportIdentity(
            decisionKey: key,
            decisionUpdatedAt: record.updatedAt,
            invoiceDNAAnalyzedAt: candidate.invoice.snapshot.analyzedAt,
            paymentDNAAnalyzedAt: candidate.payment.snapshot.analyzedAt,
            resolverVersion: candidate.resolverVersion
        )
    )
}
```

Add small internal initializers/extensions for `InvoicePaymentDecisionKey`,
candidate counterpart selection, and `CurrentDocumentDNA.documentType` (the
first `.documentType` finding decoded as `DocumentType`) rather than
duplicating role or classification logic in the repository.

- [ ] **Step 4: Run all projector tests**

Run: `swift test --filter DossierProjectorTests`

Expected: all projection cases pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomCore/Models/DossierSnapshot.swift Sources/LinkLoomCore/Dossiers/CostsAndPaymentsDossierProjector.swift Tests/LinkLoomCoreTests/DossierProjectorTests.swift
git diff --cached --check
git commit -m "feat(dossier): project direct explainable membership"
```

## Task 6: Add atomic load and create-or-open resolution

**Files:**
- Create: `Sources/LinkLoomCore/Persistence/DossierProjectionReader.swift`
- Create: `Sources/LinkLoomCore/Persistence/DossierRepository.swift`
- Create: `Tests/LinkLoomCoreTests/DossierRepositoryTests.swift`
- Create: `Tests/LinkLoomCoreTests/Support/DossierFixture.swift`

**Interfaces:**

```swift
public struct DossierSummary: Identifiable, Sendable, Equatable {
    public var id: UUID { dossier.id }
    public let dossier: DossierRecord
    public let anchor: DocumentRecord
}

public enum DossierEntryDisposition: Sendable, Equatable {
    case create
    case open(DossierSummary)
    case choose([DossierSummary])
}

public enum DossierOpenResult: Sendable, Equatable {
    case opened(DossierSnapshot)
    case choose([DossierSummary])
}

public enum DossierRepositoryError: Error, Sendable, Equatable {
    case invalidAnchor
    case dossierNotFound
    case staleInput
    case invalidStoredState
}

public actor DossierRepository {
    public init(
        dbWriter: any DatabaseWriter,
        target: DocumentDNAAnalysisTarget,
        resolver: InvoicePaymentCandidateResolver = InvoicePaymentCandidateResolver(),
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    )
    public func summaries() async throws -> [DossierSummary]
    public func entryDisposition(for documentID: UUID) async throws
        -> DossierEntryDisposition
    public func createOrOpen(anchorDocumentID: UUID) async throws
        -> DossierOpenResult
    public func snapshot(id: UUID) async throws -> DossierSnapshot
}

struct DossierProjectionReader {
    init(
        target: DocumentDNAAnalysisTarget,
        candidateProjector: InvoicePaymentCandidateProjector
    )
    func isEligibleAnchor(in db: Database, documentID: UUID) throws -> Bool
    func summary(in db: Database, dossier: DossierRecord) throws -> DossierSummary
    func snapshot(in db: Database, dossier: DossierRecord) throws
        -> DossierSnapshot
    func snapshot(in db: Database, dossierID: UUID) throws -> DossierSnapshot
}
```

`DossierRepository.matchingSummaries(in:documentID:dossiers:)` is a private
synchronous helper. It projects each supplied dossier in the caller's existing
transaction, retains snapshots whose member IDs contain `documentID`, converts
them with `DossierProjectionReader.summary`, and returns creation-date/UUID
order.

- [ ] **Step 1: Write failing repository resolution tests**

Add tests for invalid non-DNA anchor, anchored idempotence, member reuse,
multiple-match choice without row insertion, same display name across distinct
anchors, summaries ordered by creation date then UUID, and anchor-only snapshot
after stale DNA.

```swift
@Test func multipleMembershipMatchesRequireChoiceWithoutCreating() async throws {
    let fixture = try await DossierFixture.multipleMatchingDossiers()
    let before = try await fixture.dossierCount()
    let result = try await fixture.repository.createOrOpen(
        anchorDocumentID: fixture.sharedPayment.id
    )
    guard case .choose(let choices) = result else {
        Issue.record("Expected ambiguous dossier choice")
        return
    }
    #expect(choices.map(\.id) == fixture.expectedChoiceIDs)
    #expect(try await fixture.dossierCount() == before)
}
```

- [ ] **Step 2: Run and verify missing repository failure**

Run: `swift test --filter DossierRepositoryTests`

Expected: compilation fails because repository APIs are absent.

- [ ] **Step 3: Implement one-transaction projection and resolution**

`DossierProjectionReader` must call only transaction-local static helpers. It
loads the anchor's current normalized reference set, all matching current DNA
snapshots, current decisions including timestamps, source names, documents for
corrections, and exclusions before invoking the pure projector.

`createOrOpen` captures proposed UUID/time, then performs resolution and any
insert inside one `dbWriter.write` closure:

```swift
public func createOrOpen(anchorDocumentID: UUID) async throws
    -> DossierOpenResult
{
    let proposedID = makeUUID()
    let timestamp = now()
    return try await dbWriter.write { db in
        guard try projectionReader.isEligibleAnchor(
            in: db, documentID: anchorDocumentID
        ) else { throw DossierRepositoryError.invalidAnchor }
        let dossiers = try DossierStore.all(in: db)
        if let anchored = dossiers.first(where: {
            $0.kind == .costsAndPayments
                && $0.anchorDocumentID == anchorDocumentID
        }) {
            return .opened(try projectionReader.snapshot(in: db, dossier: anchored))
        }
        let matches = try matchingSummaries(
            in: db, documentID: anchorDocumentID, dossiers: dossiers
        )
        if matches.count == 1, let match = matches.first {
            return .opened(try projectionReader.snapshot(in: db, dossierID: match.id))
        }
        if matches.count > 1 { return .choose(matches) }
        let proposed = try DossierRecord(
            id: proposedID, kind: .costsAndPayments,
            displayName: "Kosten und Zahlungen",
            anchorDocumentID: anchorDocumentID,
            createdAt: timestamp, updatedAt: timestamp
        )
        let stored = try DossierStore.insertOrFetchAnchored(in: db, proposed: proposed)
        return .opened(try projectionReader.snapshot(in: db, dossier: stored))
    }
}
```

- [ ] **Step 4: Run repository and matching tests**

Run: `swift test --filter 'DossierRepositoryTests|DossierProjectorTests|InvoicePaymentCandidate'`

Expected: all pass; existing candidate behavior remains unchanged.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomCore/Persistence/DossierProjectionReader.swift Sources/LinkLoomCore/Persistence/DossierRepository.swift Sources/LinkLoomCore/Models/DossierSnapshot.swift Tests/LinkLoomCoreTests/DossierRepositoryTests.swift Tests/LinkLoomCoreTests/Support/DossierFixture.swift
git diff --cached --check
git commit -m "feat(dossier): load and resolve atomic snapshots"
```

## Task 7: Add validated corrections and reanalysis guarantees

**Files:**
- Modify: `Sources/LinkLoomCore/Persistence/DossierRepository.swift`
- Modify: `Tests/LinkLoomCoreTests/DossierRepositoryTests.swift`

**Interfaces:**

```swift
public func excludeMember(
    dossierID: UUID, documentID: UUID,
    expectedSupport: DossierMembershipSupportIdentity
) async throws -> DossierSnapshot

public func resetExclusion(
    dossierID: UUID, documentID: UUID,
    expectedRevisionID: UUID
) async throws -> DossierSnapshot
```

- [ ] **Step 1: Add failing correction and lifecycle tests**

Add named cases for successful exclusion without decision mutation, anchor
rejection, stale support, duplicate exclusion, exact revision reset, reset
after replacement ABA, path/source move with stable ID, content change,
exact-content return with retained exclusion, missing availability, anchor
cascade, and A-B-A DNA timestamps.

```swift
@Test func oldSupportCannotExcludeAfterExactContentReturns() async throws {
    let fixture = try await DossierFixture.confirmedPair()
    let opened = try await fixture.openedSnapshot()
    let oldSupport = try #require(opened.members.last?.support)
    try await fixture.changePaymentContentAndReanalyze()
    try await fixture.restoreOriginalContentAndReanalyze(at: fixture.laterDate)
    await #expect(throws: DossierRepositoryError.staleInput) {
        try await fixture.repository.excludeMember(
            dossierID: opened.dossier.id,
            documentID: fixture.payment.id,
            expectedSupport: oldSupport
        )
    }
    #expect(try await fixture.exclusionCount() == 0)
}
```

- [ ] **Step 2: Run and observe failures**

Run: `swift test --filter DossierRepositoryTests`

Expected: correction APIs are missing and lifecycle assertions fail.

- [ ] **Step 3: Implement write-time reprojection preconditions**

Both methods run one `dbWriter.write` closure, fetch the dossier or throw
`dossierNotFound`, project current state, validate the exact expected identity,
write once, and return a reprojected snapshot before the closure ends.

```swift
guard let current = snapshot.members.first(where: {
    $0.document.id == documentID && $0.support == expectedSupport
}), current.explanation.role != .anchor else {
    throw DossierRepositoryError.staleInput
}
let exclusion = DossierMembershipExclusion(
    dossierID: dossierID,
    documentID: documentID,
    revisionID: makeUUID(),
    excludedAt: now()
)
try DossierStore.insertExclusion(in: db, exclusion: exclusion)
return try projectionReader.snapshot(in: db, dossier: dossier)
```

Map uniqueness from a repeated exclusion to `staleInput`; do not overwrite its
revision. Reset requires `deleteExclusion` to return `true`, otherwise throw
`staleInput`. Never update or delete `invoicePaymentUserDecision`.

- [ ] **Step 4: Run all Core dossier tests**

Run: `swift test --filter Dossier`

Expected: all domain, migration, store, projector, repository, reanalysis, and
ABA tests pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomCore/Persistence/DossierRepository.swift Tests/LinkLoomCoreTests/DossierRepositoryTests.swift
git diff --cached --check
git commit -m "feat(dossier): validate reversible membership corrections"
```

## PR 2 completion gate

- [ ] Run `swift test --filter 'Dossier|InvoicePaymentCandidate|InvoicePaymentDecisionRepositoryTests|DocumentDNARepositoryTests'`.
- [ ] Run `swift test`.
- [ ] Run `swift build -c release`.
- [ ] Run `git diff origin/main...HEAD --check` and inspect `git status --short`.
- [ ] Self-review transaction boundaries, SQL query privacy, candidate parity, direct-only membership, old-decision visibility, A-B-A identities, and the absence of persisted membership rows.
- [ ] Stop. Obtain explicit authorization before push or PR creation. Start PR 3 only from updated `origin/main` after PR 2 is merged.

---

# PR 3: Orchestrate Dossiers in AppModel

## Task 8: Add app ports, workspace state, listing, and entry disposition

**Files:**
- Create: `Sources/LinkLoomAppFeature/DossierAppState.swift`
- Modify: `Sources/LinkLoomAppFeature/AppModel.swift`
- Modify: `Sources/LinkLoomAppFeature/AppRuntimeDiagnostic.swift`
- Create: `Tests/LinkLoomAppFeatureTests/DossierAppStateTests.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/AppModelTests.swift`

**Interfaces:**

```swift
public protocol DossierLoading: Sendable {
    func summaries() async throws -> [DossierSummary]
    func entryDisposition(for documentID: UUID) async throws
        -> DossierEntryDisposition
    func snapshot(id: UUID) async throws -> DossierSnapshot
}

public protocol DossierMutating: Sendable {
    func createOrOpen(anchorDocumentID: UUID) async throws -> DossierOpenResult
    func excludeMember(
        dossierID: UUID, documentID: UUID,
        expectedSupport: DossierMembershipSupportIdentity
    ) async throws -> DossierSnapshot
    func resetExclusion(
        dossierID: UUID, documentID: UUID, expectedRevisionID: UUID
    ) async throws -> DossierSnapshot
}

public enum AppWorkspaceSelection: Hashable, Sendable {
    case source(UUID)
    case dossier(UUID)
}

public enum DossierEntryState: Sendable, Equatable {
    case none
    case loading(documentID: UUID)
    case available(documentID: UUID, disposition: DossierEntryDisposition)
    case failed(documentID: UUID)
}

public enum DossierDetailState: Sendable, Equatable {
    case none
    case loading(dossierID: UUID, previous: DossierSnapshot?)
    case available(DossierSnapshot)
    case failed(dossierID: UUID, previous: DossierSnapshot?)

    public var snapshot: DossierSnapshot? {
        switch self {
        case .none:
            nil
        case .loading(_, let previous), .failed(_, let previous):
            previous
        case .available(let snapshot):
            snapshot
        }
    }
}
```

Add published `workspaceSelection`, `dossiers`, `dossierEntryState`, and
`dossierDetailState`. Add optional `dossierLoader` and `dossierMutator`
dependencies to all three existing `AppModel` initializers.

- [ ] **Step 1: Add failing reload, selection, entry, and diagnostic tests**

```swift
@Test func selectingEligibleDocumentPublishesOnlyItsLatestEntryDisposition() async throws {
    let loader = ScriptedDossierLoader(entrySteps: [.blocked(.create), .openSecond])
    let model = try await makeDossierModel(loader: loader)
    let first = model.documents[0]
    let second = model.documents[1]
    let firstTask = Task { await model.selectDocument(id: first.id) }
    await loader.waitUntilBlocked()
    await model.selectDocument(id: second.id)
    await loader.releaseBlocked()
    await firstTask.value
    #expect(model.dossierEntryState == .available(
        documentID: second.id, disposition: .open(loader.secondSummary)
    ))
}
```

Also require initial `reload()` to publish dossier summaries atomically with
sources, source selection to set `.source(id)`, cancellation to clear only the
matching loading entry, and `DossierRepositoryError.staleInput` to map to the
existing `.staleDocument` privacy-safe reason.

- [ ] **Step 2: Run and verify missing app state**

Run: `swift test --filter 'DossierAppStateTests|AppModelTests'`

Expected: new protocols, state, and properties are absent.

- [ ] **Step 3: Implement generation-guarded advisory loading**

After a current invoice/payment DNA snapshot is published, start the advisory
entry lookup under the existing `documentDNADetailGeneration`. Non-eligible
DNA sets `.none` without calling the dossier loader. A late, failed, or
cancelled result must verify generation and selected document before changing
state. Source workspace selection remains explicit rather than inferred from
`selectedSourceID`.

```swift
private func loadDossierEntryDisposition(
    documentID: UUID, generation: Int
) async {
    guard let dossierLoader else { return }
    dossierEntryState = .loading(documentID: documentID)
    do {
        let disposition = try await dossierLoader.entryDisposition(for: documentID)
        guard !Task.isCancelled,
              generation == documentDNADetailGeneration,
              selectedDocumentID == documentID else { return }
        dossierEntryState = .available(
            documentID: documentID, disposition: disposition
        )
    } catch is CancellationError {
        guard generation == documentDNADetailGeneration,
              selectedDocumentID == documentID else { return }
        dossierEntryState = .none
    } catch {
        guard generation == documentDNADetailGeneration,
              selectedDocumentID == documentID else { return }
        dossierEntryState = .failed(documentID: documentID)
        publishRuntimeFailure(
            code: "dossierEntryLoadFailure",
            category: .dossierLoad,
            error: error
        )
    }
}
```

- [ ] **Step 4: Run focused AppModel tests**

Run: `swift test --filter 'DossierAppStateTests|AppModelTests'`

Expected: new and existing AppModel tests pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomAppFeature/DossierAppState.swift Sources/LinkLoomAppFeature/AppModel.swift Sources/LinkLoomAppFeature/AppRuntimeDiagnostic.swift Tests/LinkLoomAppFeatureTests/DossierAppStateTests.swift Tests/LinkLoomAppFeatureTests/AppModelTests.swift
git diff --cached --check
git commit -m "feat(dossier): load workspace and entry state"
```

## Task 9: Orchestrate create, open, and ambiguous choice atomically

**Files:**
- Modify: `Sources/LinkLoomAppFeature/DossierAppState.swift`
- Modify: `Sources/LinkLoomAppFeature/AppModel.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/AppModelTests.swift`

**Interfaces:**

```swift
public enum DossierMutationState: Sendable, Equatable {
    case idle
    case opening(documentID: UUID)
    case excluding(dossierID: UUID, documentID: UUID)
    case resetting(dossierID: UUID, documentID: UUID)
}

@Published public private(set) var dossierChoices: [DossierSummary]
@Published public private(set) var dossierMutationState: DossierMutationState

public func openOrCreateDossierForSelectedDocument() async
public func chooseDossier(id: UUID) async
public func selectDossier(id: UUID) async
```

- [ ] **Step 1: Add failing atomic publication tests**

Cover opened result, ambiguous choice without workspace mutation, explicit
choice loading, duplicate button suppression, loading failure, cancellation,
selection change, and document A-B-A while opening.

```swift
@Test func openFailureKeepsPreviousWorkspaceAndSnapshot() async throws {
    let service = ScriptedDossierService(openSteps: [.failure])
    let model = try await makeDossierModel(service: service)
    let oldWorkspace = model.workspaceSelection
    let oldDetail = model.dossierDetailState
    await model.openOrCreateDossierForSelectedDocument()
    #expect(model.workspaceSelection == oldWorkspace)
    #expect(model.dossierDetailState == oldDetail)
    #expect(model.lastErrorCode == "dossierOpenFailure")
}
```

- [ ] **Step 2: Run and observe missing methods**

Run: `swift test --filter AppModelTests`

Expected: compilation fails for dossier mutation methods and state.

- [ ] **Step 3: Implement staged publish with separate generations**

Add `dossierLoadGeneration` and `dossierMutationGeneration`. Capture the
document generation, document ID, workspace, and mutation generation before
awaiting. Publish `.dossier(snapshot.dossier.id)`, updated summaries, and
`.available(snapshot)` together only after every guard passes. `.choose`
updates only `dossierChoices`. `chooseDossier` loads the selected snapshot and
uses the same staged publication.

- [ ] **Step 4: Run AppModel tests**

Run: `swift test --filter AppModelTests`

Expected: all create/open/choice and legacy tests pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomAppFeature/DossierAppState.swift Sources/LinkLoomAppFeature/AppModel.swift Tests/LinkLoomAppFeatureTests/AppModelTests.swift
git diff --cached --check
git commit -m "feat(dossier): orchestrate atomic create and open"
```

## Task 10: Reuse document selection inside the dossier workspace

**Files:**
- Modify: `Sources/LinkLoomAppFeature/AppModel.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/AppModelTests.swift`

**Interfaces:**

```swift
public func selectDossierMember(documentID: UUID) async
```

Internal `DocumentSelectionPresentation` contains the target source ID,
`DocumentPresentation`, current `DocumentRecord`, `DocumentDNA`, and annotated
candidates. `loadDocumentSelection(expected:)` is shared by dossier member
selection and counterpart navigation.

- [ ] **Step 1: Add failing same-source, cross-source, stale, and ABA tests**

```swift
@Test func crossSourceDossierMemberUsesDocumentFlowAndKeepsDossierWorkspace() async throws {
    let model = try await makeOpenDossierModelWithCrossSourcePayment()
    let dossierID = try #require(model.dossierDetailState.snapshot?.dossier.id)
    await model.selectDossierMember(documentID: model.paymentDocument.id)
    #expect(model.workspaceSelection == .dossier(dossierID))
    #expect(model.selectedSourceID == model.paymentDocument.sourceRootID)
    #expect(model.selectedDocumentID == model.paymentDocument.id)
    #expect(model.documentDNADetailState == .available(model.paymentDNA))
    guard case .available(let documentID, _) = model.invoicePaymentCandidateState else {
        Issue.record("Expected current payment candidates")
        return
    }
    #expect(documentID == model.paymentDocument.id)
}
```

Also prove missing document, changed hash, loader failure, cancellation, member
A-B-A, and `Gegenstück anzeigen` from a dossier member retain `.dossier(id)`
while the existing source-workspace counterpart test still updates
`.source(counterpartSourceID)`.

- [ ] **Step 2: Run and observe selection failures**

Run: `swift test --filter AppModelTests`

Expected: dossier member method is absent and counterpart publication does not
yet distinguish workspace ownership.

- [ ] **Step 3: Extract and reuse the atomic document load**

Keep the current validation order: load target source presentation, require
the same document ID/source/hash, require ready DNA, load matching snapshot,
load current candidates, then publish. Parameterize final workspace behavior:
source navigation uses `.source(targetSourceID)`; dossier navigation retains
the captured `.dossier(dossierID)`.

- [ ] **Step 4: Run all navigation tests**

Run: `swift test --filter AppModelTests`

Expected: current counterpart tests and new dossier member tests pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomAppFeature/AppModel.swift Tests/LinkLoomAppFeatureTests/AppModelTests.swift
git diff --cached --check
git commit -m "feat(dossier): reuse atomic document selection"
```

## Task 11: Orchestrate corrections and robust reprojection

**Files:**
- Modify: `Sources/LinkLoomAppFeature/AppModel.swift`
- Modify: `Sources/LinkLoomAppFeature/AppRuntimeDiagnostic.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/AppModelTests.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/DossierAppStateTests.swift`

**Interfaces:**

```swift
public func excludeDossierMember(_ member: DossierMember) async
public func resetDossierCorrection(_ correction: DossierCorrection) async
public func refreshSelectedDossier() async
```

Add runtime categories `.dossierLoad` and `.dossierMutation`; use stable codes
`dossierEntryLoadFailure`, `dossierOpenFailure`, `dossierLoadFailure`,
`dossierMutationFailure`, and `dossierRemoved`.

`lastErrorMessage` maps the load/open codes to
`Das Dossier konnte nicht geladen werden. Bitte versuche es erneut.`, mutation
failure to
`Die Dossier-Korrektur konnte nicht gespeichert werden. Bitte versuche es erneut.`,
and removal to
`Das Dossier ist nicht mehr verfügbar, weil sein Anker entfernt wurde.`

- [ ] **Step 1: Add failing mutation and refresh tests**

Cover exact support forwarding, exact revision forwarding, successful complete
snapshot replacement, failure preservation, silent cancellation, duplicate
suppression, mutation completion after dossier switch, dossier A-B-A,
watcher completion from another source, failed watcher refresh, and selected
anchor cascade fallback.

```swift
@Test func staleRemoveCompletionCannotReplaceReopenedDossierABA() async throws {
    let service = BlockingDossierService()
    let model = try await makeOpenDossierModel(service: service)
    let member = try #require(model.dossierDetailState.snapshot?.members.last)
    let dossierID = try #require(model.dossierDetailState.snapshot?.dossier.id)
    let removal = Task { await model.excludeDossierMember(member) }
    await service.waitForRemove()
    await model.selectSource(id: model.source.id)
    await model.selectDossier(id: dossierID)
    await service.releaseRemove()
    await removal.value
    #expect(model.dossierDetailState.snapshot == service.reopenedSnapshot)
}
```

- [ ] **Step 2: Run and observe mutation/refresh failures**

Run: `swift test --filter 'AppModelTests|DossierAppStateTests'`

Expected: correction and refresh methods are missing.

- [ ] **Step 3: Implement guarded mutation and reanalysis refresh**

Capture dossier ID, current detail token, mutation generation, and exact
member support or exclusion revision. On success require all identities before
replacing `.available(snapshot)`. On failure retain `.failed(id, previous:)` or
the previous available state as specified and publish a bounded diagnostic.
Cancellation returns without diagnostics.

Extend successful manual scan and watcher `refreshAfterRescan` paths: if the
captured workspace is `.dossier(id)`, reload that dossier after any completed
source. `dossierNotFound` clears dossier selection, selects the first remaining
source workspace, clears dossier detail, and publishes `dossierRemoved` once.

- [ ] **Step 4: Run full AppFeature tests**

Run: `swift test --filter LinkLoomAppFeatureTests`

Expected: all AppModel, diagnostic, startup, picker, and presentation tests pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomAppFeature/AppModel.swift Sources/LinkLoomAppFeature/AppRuntimeDiagnostic.swift Tests/LinkLoomAppFeatureTests/AppModelTests.swift Tests/LinkLoomAppFeatureTests/DossierAppStateTests.swift
git diff --cached --check
git commit -m "feat(dossier): guard corrections and reanalysis refresh"
```

## PR 3 completion gate

- [ ] Run `swift test --filter 'AppModelTests|DossierAppStateTests|ScanDashboardTests|AppStartupControllerTests|FolderPickerTests|UITestLaunchConfigurationTests|UITestStartupFailureGateTests'`.
- [ ] Run `swift test`.
- [ ] Run `swift build -c release`.
- [ ] Run `git diff origin/main...HEAD --check` and inspect `git status --short`.
- [ ] Self-review every await boundary for generation, workspace ID, document ID, support/token identity, cancellation, last-snapshot retention, and legacy counterpart behavior.
- [ ] Stop. Obtain explicit authorization before push or PR creation. Start PR 4 only from updated `origin/main` after PR 3 is merged.

---

# PR 4: Integrate the Vertical UI Slice

## Task 12: Extract the reusable Document DNA inspector

**Files:**
- Create: `Sources/LinkLoomAppFeature/DocumentDNAInspector.swift`
- Modify: `Sources/LinkLoomAppFeature/ScanDashboard.swift`
- Modify: `Sources/LinkLoomAppFeature/ContentView.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/ScanDashboardTests.swift`

**Interfaces:**

```swift
struct DocumentDNAInspector: View {
    @ObservedObject var model: AppModel
    let document: DocumentRecord?
}
```

`ContentView` owns `.inspector(isPresented:)`; `ScanDashboard` retains only
source header, status cards, and document table. Move existing DNA,
invoice-payment, evidence, retry, decision, and counterpart view code without
changing copy or accessibility identifiers.

- [ ] **Step 1: Add a failing shared-inspector compile contract**

Extend `ScanDashboardTests` with a `@MainActor` test that references the new
`DocumentDNAInspector` type and its exact initializer. Keep the existing tests
that assert every document type, signal, decision, and one-based evidence
mapping so the move cannot change presentation semantics.

```swift
@Test @MainActor
func sharedDocumentDNAInspectorTypeIsAvailable() {
    let _: (AppModel, DocumentRecord?) -> DocumentDNAInspector = {
        DocumentDNAInspector(model: $0, document: $1)
    }
}
```

- [ ] **Step 2: Run the presentation tests before moving code**

Run: `swift test --filter ScanDashboardTests`

Expected: compilation fails because `DocumentDNAInspector` does not exist.

- [ ] **Step 3: Move inspector ownership without behavior changes**

Use this top-level presentation in `ContentView`:

```swift
.inspector(isPresented: Binding(
    get: { model.selectedDocumentID != nil },
    set: { shown in
        guard !shown else { return }
        Task { await model.selectDocument(id: nil) }
    }
)) {
    DocumentDNAInspector(
        model: model,
        document: model.documents.first { $0.id == model.selectedDocumentID }
    )
}
```

- [ ] **Step 4: Run focused tests and existing UI smoke**

Run: `swift test --filter ScanDashboardTests`

Then run the exact `xcodebuild test` command from `README.md`.

Expected: presentation tests and the pre-dossier smoke workflow pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomAppFeature/DocumentDNAInspector.swift Sources/LinkLoomAppFeature/ScanDashboard.swift Sources/LinkLoomAppFeature/ContentView.swift Tests/LinkLoomAppFeatureTests/ScanDashboardTests.swift
git diff --cached --check
git commit -m "refactor(app): share the document DNA inspector"
```

## Task 13: Add the unified sidebar and dossier workspace

**Files:**
- Create: `Sources/LinkLoomAppFeature/WorkspaceSidebar.swift`
- Delete: `Sources/LinkLoomAppFeature/SourceSidebar.swift`
- Create: `Sources/LinkLoomAppFeature/DossierPresentation.swift`
- Create: `Sources/LinkLoomAppFeature/CostsAndPaymentsDossierView.swift`
- Modify: `Sources/LinkLoomAppFeature/ContentView.swift`
- Create: `Tests/LinkLoomAppFeatureTests/DossierPresentationTests.swift`

**Interfaces:**

```swift
struct DossierMemberPresentation: Equatable {
    let roleTitle: String
    let documentTypeTitle: String
    let location: String
    let availabilityTitle: String
    let signals: [InvoicePaymentSignalPresentation]
}

struct CostsAndPaymentsDossierView: View {
    @ObservedObject var model: AppModel
}
```

- [ ] **Step 1: Add failing deterministic copy tests**

```swift
@Test func dossierMemberPresentationExplainsRoleLocationAndAvailability() {
    let presentation = DossierMemberPresentation(
        member: fixture.paymentMember,
        selectedSourceID: fixture.invoiceSourceID
    )
    #expect(presentation.roleTitle == "Zahlung")
    #expect(presentation.documentTypeTitle == "Zahlungsbestätigung")
    #expect(presentation.location == "Zahlungen · payment.pdf")
    #expect(presentation.availabilityTitle == "Verfügbar")
    #expect(presentation.signals.map(\.title)
        == ["Referenz", "Betrag und Währung", "Organisation"])
}
```

Also test anchor copy `Ankerdokument`, missing/unavailable labels, create/open/
choose action titles, and that dynamic IDs use persisted UUID strings.

- [ ] **Step 2: Run and observe missing presentation failure**

Run: `swift test --filter DossierPresentationTests`

Expected: dossier presentation types do not exist.

- [ ] **Step 3: Implement the visible workspace**

`WorkspaceSidebar` uses one `List(selection:)` tagged with
`AppWorkspaceSelection`, a `Dossiers` section with
`dossier.row.<UUID>`, a `Quellen` section preserving source context menus, and
the unchanged `source.add` button.

`ContentView` routes `.dossier` to `CostsAndPaymentsDossierView` and all source
or initial states to `ScanDashboard`. The dossier view exposes:

- `dossier.sidebar` on the `Dossiers` sidebar section;
- `dossier.workspace` on the root;
- the `Kosten und Zahlungen` heading and a visibly labelled anchor;
- source, relative path, current document type or `Nicht verfügbar`,
  availability, role, and current relationship signals for each member;
- member rows `dossier.member.<UUID>`;
- remove actions `dossier.member.remove.<UUID>` only for supported non-anchors;
- correction rows and reset actions using the specified IDs;
- `dossier.error` while retaining any previous snapshot;
- a retry action that invokes `refreshSelectedDossier()` without clearing the
  previous snapshot;
- the entry action in `DocumentDNAInspector` with
  `document-dna.costs-dossier`, disabled during entry load or mutation;
- a chooser bound to `model.dossierChoices`.

- [ ] **Step 4: Run all AppFeature tests**

Run: `swift test --filter LinkLoomAppFeatureTests`

Expected: all presentation and AppModel tests pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomAppFeature/WorkspaceSidebar.swift Sources/LinkLoomAppFeature/DossierPresentation.swift Sources/LinkLoomAppFeature/CostsAndPaymentsDossierView.swift Sources/LinkLoomAppFeature/ContentView.swift Tests/LinkLoomAppFeatureTests/DossierPresentationTests.swift
git add -u Sources/LinkLoomAppFeature/SourceSidebar.swift
git diff --cached --check
git commit -m "feat(app): add costs and payments dossier workspace"
```

## Task 14: Wire the Core repository through the composition root

**Files:**
- Modify: `Sources/LinkLoomApp/LinkLoomApp.swift`
- Modify: `Tests/LinkLoomAppTests/AppCompositionTests.swift`

**Interfaces:**

```swift
struct CurrentDossierService: DossierLoading, DossierMutating {
    private let loadSummaries: @Sendable () async throws -> [DossierSummary]
    private let loadEntry: @Sendable (UUID) async throws -> DossierEntryDisposition
    private let loadSnapshot: @Sendable (UUID) async throws -> DossierSnapshot
    private let open: @Sendable (UUID) async throws -> DossierOpenResult
    private let exclude: @Sendable (
        UUID, UUID, DossierMembershipSupportIdentity
    ) async throws -> DossierSnapshot
    private let reset: @Sendable (UUID, UUID, UUID) async throws
        -> DossierSnapshot

    init(repository: DossierRepository)
    init(
        summaries: @escaping @Sendable () async throws -> [DossierSummary],
        entry: @escaping @Sendable (UUID) async throws -> DossierEntryDisposition,
        snapshot: @escaping @Sendable (UUID) async throws -> DossierSnapshot,
        createOrOpen: @escaping @Sendable (UUID) async throws -> DossierOpenResult,
        exclude: @escaping @Sendable (
            UUID, UUID, DossierMembershipSupportIdentity
        ) async throws -> DossierSnapshot,
        reset: @escaping @Sendable (UUID, UUID, UUID) async throws
            -> DossierSnapshot
    )
}
```

Each method delegates exactly once. Mutation methods call
`Task.checkCancellation()` before repository mutation. `makeModel` constructs
one `DossierRepository(dbWriter:database,target:dnaTarget)`, wraps it once, and
passes the same service as loader and mutator.

- [ ] **Step 1: Add failing adapter forwarding tests**

Add tests for summaries, entry, snapshot, create/open, exclude, reset,
propagated error, and cancellation before mutation. Use closure-based internal
initializer seams following `CurrentInvoicePaymentDecisionUpdater`.

```swift
@Test func dossierServiceHonorsCancellationBeforeMutation() async {
    let recorder = DossierServiceRecorder()
    let service = CurrentDossierService(
        summaries: { [] },
        entry: { _ in .create },
        snapshot: { _ in throw CompositionTestError.dossierFailed },
        createOrOpen: { id in await recorder.record(id); throw CancellationError() },
        exclude: { _, _, _ in throw CompositionTestError.dossierFailed },
        reset: { _, _, _ in throw CompositionTestError.dossierFailed }
    )
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await service.createOrOpen(anchorDocumentID: UUID())
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await recorder.ids.isEmpty)
}
```

- [ ] **Step 2: Run and verify missing adapter failure**

Run: `swift test --filter AppCompositionTests`

Expected: `CurrentDossierService` is absent.

- [ ] **Step 3: Implement adapter and production construction**

Provide a repository initializer and an internal closure initializer for
tests. Every read delegates directly; every mutation checks cancellation then
delegates. Pass `dossierLoader: dossierService` and
`dossierMutator: dossierService` into `AppModel`.

- [ ] **Step 4: Run composition and AppModel tests**

Run: `swift test --filter 'AppCompositionTests|AppModelTests'`

Expected: all adapter and orchestration tests pass.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add Sources/LinkLoomApp/LinkLoomApp.swift Tests/LinkLoomAppTests/AppCompositionTests.swift
git diff --cached --check
git commit -m "feat(app): compose dossier services"
```

## Task 15: Extend the hermetic product smoke test and operator docs

**Files:**
- Modify: `LinkLoomUITests/LinkLoomUISmokeTests.swift`
- Modify: `LinkLoomUITests/Support/SQLiteProbe.swift`
- Modify: `README.md`

**Interfaces:**
- `SmokeDatabaseEvidence` adds `dossierCount` and `dossierExclusionCount`.
- Completed-with-correction evidence requires `(1, 1)`; restored evidence
  requires `(1, 0)`; source-removal evidence requires `(0, 0)`.
- `SQLiteProbe.documentID(relativePath:)` and `SQLiteProbe.onlyDossierID()`
  return lowercase persisted UUID strings for dynamic accessibility IDs and
  fail unless exactly one row matches.

- [ ] **Step 1: Extend the smoke test before UI assumptions are accepted**

After confirming the existing candidate, the test must:

1. click `document-dna.costs-dossier`;
2. require `dossier.workspace`, one anchor, and the payment member;
3. select the payment member and require its Document DNA inspector;
4. click the existing `invoice-payment-candidates.0.show-counterpart` and
   require the invoice while the dossier workspace remains selected;
5. click `dossier.member.remove.<paymentUUID>` and require its disappearance
   plus `dossier.correction.<paymentUUID>`;
6. terminate and require database counts `(1, 1)`;
7. relaunch, select `dossier.row.<dossierUUID>`, and require the correction;
8. complete the existing DNA retry workflow from the source workspace;
9. return to the dossier, click `dossier.correction.reset.<paymentUUID>`, and
   require the payment member to return;
10. require database counts `(1, 0)`;
11. remove the source and require dossier and exclusion counts `(0, 0)`;
12. retain the exact before/after source integrity assertion.

Derive persisted UUIDs in `SQLiteProbe` by querying relative paths rather than
hard-coding runtime-generated IDs.

- [ ] **Step 2: Run the smoke test and verify the first missing UI element**

Run the exact `xcodebuild test` command from `README.md`.

Expected before completing UI wiring: failure locating
`document-dna.costs-dossier` or `dossier.workspace`.

- [ ] **Step 3: Finish accessibility behavior and documentation**

Adjust only dossier UI accessibility grouping/hit targets required by the
process test. Do not add test-only production paths. Update `README.md` with a
short `Kosten und Zahlungen` section explaining explicit creation, direct
confirmed membership, dossier-only correction, reset, local processing, and
unchanged originals.

- [ ] **Step 4: Run focused, full, release, and UI verification**

Run:

```bash
swift test --filter 'Dossier|AppModelTests|AppCompositionTests|ScanDashboardTests'
swift test
swift build -c release
```

Then run the exact `xcodebuild test` UI smoke command from `README.md`.

Expected: all commands exit 0; the UI result bundle records the complete
dossier workflow and source integrity remains identical.

- [ ] **Step 5: Check and commit**

```bash
git diff --check
git add LinkLoomUITests/LinkLoomUISmokeTests.swift LinkLoomUITests/Support/SQLiteProbe.swift README.md
git diff --cached --check
git commit -m "test(app): cover persistent dossier workflow"
```

## PR 4 completion gate

- [ ] Run focused dossier, AppModel, composition, and presentation tests.
- [ ] Run `swift test` and confirm zero failures.
- [ ] Run `swift build -c release` and confirm exit 0.
- [ ] Run the exact process-level UI smoke command from `README.md` and retain screenshots/result bundle references for the PR.
- [ ] Run `git diff origin/main...HEAD --check`, `git diff --cached --check`, and inspect `git status --short`.
- [ ] Inspect the complete diff for accessibility stability, German copy, source integrity, production/test separation, migration disclosure, privacy-safe diagnostics, and unrelated changes.
- [ ] Verify no secrets, personal data, local SQLite files, `.build`, `.superpowers`, or result bundles are tracked.
- [ ] Stop. Obtain explicit authorization before push or PR creation. Push, PR creation, merge, and remote-branch deletion each remain separately authorization-bound.

---

## Sequential Delivery Contract

After each PR is merged, fetch `origin`, confirm the new `origin/main`, and
create the next named branch from that exact commit. Do not cherry-pick an
unmerged predecessor or combine PR scopes to save time. Each PR description
must report exact focused/full/release verification, migration and rollback
implications, security/privacy impact, and UI screenshots when visible.

The four user-visible outcomes are intentionally cumulative:

1. PR 1 proves durable dossier/correction storage without exposing behavior.
2. PR 2 proves current explainable membership and robust reanalysis in Core.
3. PR 3 proves atomic application orchestration entirely through test fakes.
4. PR 4 exposes and smoke-tests the complete vertical slice.
