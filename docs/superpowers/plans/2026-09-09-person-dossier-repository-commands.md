# Person Dossier Repository Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the authoritative, typed repository boundary for creating, opening, choosing, loading, and correcting person dossiers while returning one transactionally consistent `PersonDossierSnapshot` for every successful operation.

**Architecture:** Extend the existing `DossierRepository` actor without changing its costs-and-payments API. Public person-only input and result values carry complete current-support identities. A new internal `PersonDossierProjectionReader` assembles the already-approved pure `PersonDossierProjector` input inside one GRDB read or write transaction, using the indexed exact-name and reference-cohort queries delivered by PR 2. Every mutation first reprojects and validates the exact projection token plus the displayed candidate/member/correction identity, mutates dossier-local confirmation or exclusion rows, then reprojects before the transaction commits. No AppModel, composition, or UI code participates in this pull request.

**Tech Stack:** Swift 6, Swift Package Manager, GRDB/SQLite, Swift Testing

**Spec:** `docs/superpowers/specs/2026-09-06-person-anchored-main-dossier-design.md` sections 5, 6, 7.3, 9, 10.3, 11, 14.1, 17.3, and PR 3 in section 18

## Global Constraints

- Start from the then-current `origin/main` on `codex/feat/person-dossier-repository-commands`; keep all work in the local LinkLoom checkout, not a Codex worktree.
- Follow strict red-green-refactor for every behavior change: add one focused failing test, run it and record the expected failure, implement only enough to pass, rerun the focused test, then commit the coherent unit.
- Keep the existing costs-and-payments repository methods and output types source- and behavior-compatible.
- Keep `LinkLoomCore` independent of `LinkLoomAppFeature` and `LinkLoomApp`.
- Do not modify `AppModel`, application ports, composition, SwiftUI, accessibility, navigation, Package dependencies, migrations, Golden fixtures, metric evaluation, or the opt-in 10,000-document acceptance fixture.
- Read only the local database. Do not add network calls, external AI, telemetry, or dependencies.
- Never rename, move, delete, or intentionally modify selected source files. Lifecycle tests mutate only synthetic database records in temporary test databases.
- Person lookup must continue to use `document_dna_finding_kind_value`; relationship expansion must query only references from directly or manually included current invoices.
- A same normalized name is only a possible match. Only `(originDocumentID, primaryRole, normalizedName)` is an idempotent identity.
- Every successful public load or mutation returns one complete immutable snapshot. Errors and cancellation return no snapshot; failed writes leave no partial anchor, dossier, confirmation, or exclusion.
- `DossierRepositoryError` values and diagnostics must not contain names, evidence text, paths, hashes, or bookmark data.
- Use Conventional Commit subjects at or below 72 characters. Do not push, open a pull request, merge, or delete branches without the user's separate authorization at execution time.

## Current `main` Baseline

- Inspected `main` at `1723f97b46e5ce853a41bc55a316a3773b3addbf` (`feat(dossier): retrieve and project person candidates (#47)`), synchronized with `origin/main` and otherwise clean before this plan file was created.
- `DossierRepository` is an actor with costs-only summaries, entry disposition, create/open, snapshot, exclude, and reset operations. It already performs costs mutations and post-mutation projection in one `DatabaseWriter.write` closure.
- `DossierStore` already round-trips typed `.personMatter` dossiers and persists mutually exclusive confirmation/exclusion records, but it has no exact person-anchor lookup helpers.
- `PersonDossierAnchorStore` already provides `record(in:id:)` and idempotent `insertOrFetch(in:proposed:)`; migration v8 supplies the stable-origin uniqueness key and the non-unique normalized-name index.
- `DocumentDNARepository.currentSnapshotsMatchingPerson(in:normalizedName:target:)` and `currentSnapshotsMatchingReference(in:normalizedValue:target:)` already reconstruct only indexed, target-current cohorts.
- `PersonDossierProjector` is pure and already owns conservative direct membership, suggestion classification, confirmation/exclusion precedence, origin state, deterministic ordering/token creation, and defensive one-hop expansion.
- `InvoicePaymentCandidateProjector` and `InvoicePaymentDecisionRepository.currentRecords(in:keys:)` already provide bounded candidate construction and exact content-bound decision reads.
- Existing PR 2 Golden, metric, and opt-in 10,000-document tests remain authoritative and unchanged; PR 3 exercises the repository orchestration around those primitives.

## Required Public Interfaces

Create the person-only boundary values in `Sources/LinkLoomCore/Models/PersonDossierRepository.swift`:

```swift
public struct PersonDossierAnchorSelection: Sendable, Equatable {
    public let support: PersonDossierFindingSupportIdentity

    public init(
        document: DocumentRecord,
        snapshot: DocumentDNA,
        finding: DocumentDNAFinding
    ) throws
}

public struct PersonDossierSummary: Identifiable, Sendable, Equatable {
    public var id: UUID { dossier.id }
    public let dossier: DossierRecord
    public let anchor: PersonDossierAnchor
}

public enum PersonDossierEntryDisposition: Sendable, Equatable {
    case create
    case open(PersonDossierSummary)
    case choose([PersonDossierSummary])
}

public enum PersonDossierOpenResult: Sendable, Equatable {
    case opened(PersonDossierSnapshot)
    case choose([PersonDossierSummary])
}

public enum PersonDossierCreationChoice: Sendable, Equatable {
    case existing(dossierID: UUID)
    case new
}
```

The initializer must construct a `CurrentDocumentDNA`, derive `PersonDossierRole` from the exact selected finding, require a supported primary role, and construct the complete `PersonDossierFindingSupportIdentity`. Structurally invalid input throws `DossierValidationError.invalidRecord`; currentness is checked only inside the repository transaction.

Extend `DossierRepository` with these public methods:

```swift
public func personDossierSummaries() async throws -> [PersonDossierSummary]

public func personDossierEntryDisposition(
    for selection: PersonDossierAnchorSelection
) async throws -> PersonDossierEntryDisposition

public func createOrOpenPersonDossier(
    from selection: PersonDossierAnchorSelection
) async throws -> PersonDossierOpenResult

public func chooseOrCreatePersonDossier(
    from selection: PersonDossierAnchorSelection,
    choice: PersonDossierCreationChoice
) async throws -> PersonDossierSnapshot

public func personDossierSnapshot(id: UUID) async throws -> PersonDossierSnapshot

public func acceptPersonSuggestion(
    dossierID: UUID,
    documentID: UUID,
    expectedSupport: PersonDossierCandidateSupportIdentity,
    expectedToken: PersonDossierProjectionToken
) async throws -> PersonDossierSnapshot

public func rejectPersonSuggestion(
    dossierID: UUID,
    documentID: UUID,
    expectedSupport: PersonDossierCandidateSupportIdentity,
    expectedToken: PersonDossierProjectionToken
) async throws -> PersonDossierSnapshot

public func removePersonMember(
    dossierID: UUID,
    documentID: UUID,
    expectedSupport: PersonDossierMembershipSupport,
    expectedToken: PersonDossierProjectionToken
) async throws -> PersonDossierSnapshot

public func resetPersonCorrection(
    dossierID: UUID,
    documentID: UUID,
    expectedDecision: PersonDossierCorrectionDecision,
    expectedToken: PersonDossierProjectionToken
) async throws -> PersonDossierSnapshot
```

Add this deterministic computed property to `PersonDossierMember` so the future UI does not invent a support choice:

```swift
public var commandSupport: PersonDossierMembershipSupport {
    get throws
}
```

The implementation chooses the manual-confirmation support when `isConfirmationAuthoritative`, otherwise the first canonical `.exactPrimary` support, otherwise `.confirmedPayment(preferredPaymentSupport)`. A member without one of those valid supports throws `DossierValidationError.invalidRecord`; the repository maps that impossible projected state to `.invalidStoredState`. Repository removal validates equality with this exact value as well as the full projection token.

## Transaction and Error Contract

- `personDossierEntryDisposition`, `createOrOpenPersonDossier`, and `chooseOrCreatePersonDossier` reconstruct the selected support from the target-current database snapshot. A missing document or missing target-current DNA is `.invalidAnchor`; a current snapshot whose exact person finding/input identity differs from the supplied support is `.staleInput`.
- An existing stable-origin tuple opens its dossier regardless of other same-name anchors. If that anchor exists without exactly one person dossier, report `.invalidStoredState`.
- With no stable-origin match, zero normalized-name matches permits creation. One or more normalized-name matches returns `.choose`; it never guesses identity and writes nothing.
- `.existing(dossierID:)` is valid only while that dossier is still among the exact normalized-name choices. Otherwise return `.staleInput` without writing.
- `.new` explicitly creates a distinct homonym dossier. Anchor and dossier insertion plus the first complete projection occur inside one write transaction. The stored dossier title is exactly `Meine Mutter im Pflegeheim`.
- Creation copies the selected person finding and full input identity. It captures a `PersonDossierBirthDate` only when the current origin snapshot contains exactly one primary-role person finding in total and exactly one `birthDate` finding.
- Stable-origin insert/fetch makes retries and concurrent creation idempotent. If another transaction won, open the winner; never create a second dossier.
- Every mutation calls `Task.checkCancellation()` inside the write transaction, loads and projects current state, requires exact token equality, requires the exact displayed command identity for `documentID`, mutates, checks cancellation again, and returns a fresh projection from the same transaction.
- Accept inserts a `DossierMembershipConfirmation` whose accepted fields are copied exactly from `expectedSupport.person` and whose `candidateKind` is `expectedSupport.kind`.
- Reject inserts a `DossierMembershipExclusion`.
- Removing an automatic or relationship-derived member inserts an exclusion. Removing a manually confirmed member first deletes the exact confirmation revision, then inserts the exclusion in the same transaction.
- Reset validates the full current `PersonDossierCorrectionDecision` and deletes only its exact confirmation or exclusion revision. Resetting the exclusion created by manual-member removal does not recreate the old confirmation.
- Confirmation and exclusion coexistence for one document is `.invalidStoredState`; do not repair malformed storage implicitly.
- Primary-key/unique constraint races that mean the displayed state lost are `.staleInput`. Preserve `CancellationError` and unexpected `DatabaseError`; map known store, DNA, decision, validation, and person-projector corruption to `.invalidStoredState`.

---

### Task 1: Define typed person-repository inputs and command identity

**Files:**
- Add approved plan to the first implementation commit: `docs/superpowers/plans/2026-09-09-person-dossier-repository-commands.md`
- Create: `Sources/LinkLoomCore/Models/PersonDossierRepository.swift`
- Modify: `Sources/LinkLoomCore/Models/PersonDossierSnapshot.swift`
- Create: `Tests/LinkLoomCoreTests/PersonDossierRepositoryDomainTests.swift`

- [ ] **Step 1: Write failing construction and identity tests**

Add `@Suite("Person dossier repository domain")` with focused tests proving:

- a current document, snapshot, and contained primary-role finding produce a selection whose support includes every document/input/DNA/finding field;
- `.authorizedPerson`, a non-person finding, a finding not contained in the snapshot, a document/snapshot ID mismatch, and a document/content-hash mismatch are rejected;
- `PersonDossierSummary.id` delegates to the dossier ID and the typed enums compare by value;
- an authoritative manual member selects its manual confirmation as `commandSupport` even when relationship support is also present;
- an automatic member selects its first already-canonical exact-primary support;
- a relationship-only member selects the exact `.confirmedPayment` wrapping `preferredPaymentSupport`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```sh
swift test --filter 'Person dossier repository domain'
```

Expected: compilation fails because the new boundary values and `commandSupport` do not exist.

- [ ] **Step 3: Implement the minimal validated public values**

Implement the interfaces above. Keep output-value memberwise initializers internal. Build selection support through `CurrentDocumentDNA` and `PersonDossierFindingSupportIdentity` so validation is defined once. Implement command-support precedence without changing stored fields or projection-token construction.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```sh
swift test --filter 'Person dossier repository domain'
```

Expected: all domain tests pass.

- [ ] **Step 5: Commit the boundary unit**

```sh
git add docs/superpowers/plans/2026-09-09-person-dossier-repository-commands.md Sources/LinkLoomCore/Models/PersonDossierRepository.swift Sources/LinkLoomCore/Models/PersonDossierSnapshot.swift Tests/LinkLoomCoreTests/PersonDossierRepositoryDomainTests.swift
git diff --cached --check
git commit -m "feat(dossier): define person repository commands"
```

---

### Task 2: Add exact person-anchor and dossier read primitives

**Files:**
- Modify: `Sources/LinkLoomCore/Persistence/PersonDossierAnchorStore.swift`
- Modify: `Sources/LinkLoomCore/Persistence/DossierStore.swift`
- Modify: `Tests/LinkLoomCoreTests/PersonDossierAnchorStoreTests.swift`
- Modify: `Tests/LinkLoomCoreTests/DossierStoreTests.swift`

- [ ] **Step 1: Write failing store tests**

Add tests for these internal operations:

```swift
PersonDossierAnchorStore.record(
    in: db,
    originDocumentID: UUID,
    primaryRole: PersonDossierRole,
    normalizedName: String
) throws -> PersonDossierAnchor?

PersonDossierAnchorStore.records(
    in: db,
    normalizedName: String
) throws -> [PersonDossierAnchor]

DossierStore.personDossier(
    in: db,
    personAnchorID: UUID
) throws -> DossierRecord?
```

Prove binary-exact normalized-name matching, role-sensitive stable-origin matching, deterministic `(createdAt, id)` order, empty results, malformed-row mapping, and correct typed dossier lookup. Install a GRDB statement trace and assert the normalized-name query contains `INDEXED BY person_dossier_anchor_normalized_name` using the actual v8 index name; do not fall back to `DossierStore.all` for create/open matching.

- [ ] **Step 2: Run the focused store suites and verify RED**

```sh
swift test --filter 'Person dossier anchor store'
swift test --filter 'Dossier store'
```

Expected: the new lookup methods are missing.

- [ ] **Step 3: Implement bounded store reads**

Select only the scalar anchor columns required by `decodeAnchor`, use the normalized-name index explicitly, and reuse strict evidence decoding. Add the direct person-anchor dossier query and reuse `decodeDossier`. Return `nil` only for absence; malformed or duplicate logical state remains `invalidStoredState`.

- [ ] **Step 4: Run focused store suites and verify GREEN**

```sh
swift test --filter 'Person dossier anchor store'
swift test --filter 'Dossier store'
```

Expected: all store tests pass, including existing costs/person persistence regressions.

- [ ] **Step 5: Commit the read primitives**

```sh
git add Sources/LinkLoomCore/Persistence/PersonDossierAnchorStore.swift Sources/LinkLoomCore/Persistence/DossierStore.swift Tests/LinkLoomCoreTests/PersonDossierAnchorStoreTests.swift Tests/LinkLoomCoreTests/DossierStoreTests.swift
git diff --cached --check
git commit -m "feat(dossier): add person anchor repository reads"
```

---

### Task 3: Assemble one complete person snapshot inside one transaction

**Files:**
- Create: `Sources/LinkLoomCore/Persistence/PersonDossierProjectionReader.swift`
- Create: `Tests/LinkLoomCoreTests/PersonDossierRepositoryTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift`

- [ ] **Step 1: Extend the synthetic fixture for persisted repository scenarios**

Add deterministic helpers to the existing PR 2 fixture for inserting source roots, documents, extractions, current DNA, person anchors/dossiers, relationship decisions, confirmations, and exclusions. Add deterministic UUID sequencing and dates so creation and correction revisions can be asserted exactly. Keep pure-projector and 10,000-document helpers unchanged.

- [ ] **Step 2: Write the failing baseline repository projection tests**

Create `@Suite("Person dossier repository")` and test the reader through `personDossierSnapshot(id:)`, which is introduced in this task. The persisted scenario must contain:

- current origin plus another exact-primary direct document;
- an exact secondary-role suggestion;
- one directly included invoice and one content-current confirmed payment;
- one unrelated same-reference cohort member that the resolver rejects;
- a manual confirmation whose original candidate is no longer current;
- an exclusion correction;
- multiple sources with deterministic display names.

Assert the returned `PersonDossierSnapshot` equals a snapshot produced from the same values by the existing pure projector, including origin, all sections, support identities, corrections, and token.

Trace SQL and assert:

- exactly one indexed person cohort read uses `document_dna_finding_kind_value`;
- reference-cohort reads equal the distinct normalized references of included current invoices only;
- no reference lookup is issued for an unrelated or excluded invoice;
- complete DNA reconstruction occurs only for exact person matches, correction documents that still have current DNA, and relationship endpoints;
- exact relationship decision keys, not the whole decision table, are loaded.

- [ ] **Step 3: Run the new suite and verify RED**

```sh
swift test --filter 'Person dossier repository'
```

Expected: compilation fails because `PersonDossierProjectionReader` and the person repository reads are absent.

- [ ] **Step 4: Implement `PersonDossierProjectionReader`**

Give the reader the existing analysis target and `InvoicePaymentCandidateProjector`. Its `snapshot(in:dossier:)` must perform these operations inside the caller's single `Database` closure:

1. require `.personMatter` with a typed person anchor;
2. load the optional origin row and its optional target-current DNA;
3. load the indexed exact normalized-name person cohort;
4. load confirmations and exclusions, require no document to have both, and load their document rows plus current DNA when available;
5. build `documentsByID` and `currentDocumentsByID`, then run the pure projector with no relationship candidates to freeze direct/manual membership;
6. take only current `.invoice` members from that frozen projection, deduplicate their normalized references, and call the existing indexed reference lookup once per distinct value;
7. project and deduplicate `InvoicePaymentCandidate` values only from those included invoices and their bounded cohorts;
8. load `InvoicePaymentDecisionRepository.currentRecords` for exactly those candidate keys;
9. add relationship endpoints, batch or bounded-load required source display names, and run the final pure projection;
10. call `Task.checkCancellation()` before expensive cohort assembly and before returning.

Also add `snapshot(in:dossierID:)` and `summary(in:dossier:)`. A missing ID is `.dossierNotFound`; a costs dossier passed to this reader is `.invalidStoredState`. Do not modify `PersonDossierProjector` behavior or duplicate its classification rules.

- [ ] **Step 5: Inject the reader and expose typed read methods**

Initialize a private nonisolated `personProjectionReader` beside the existing costs reader. Add `personDossierSummaries()` and `personDossierSnapshot(id:)`, each using exactly one `dbWriter.read` closure and the shared error mapper. Summaries must survive origin-document deletion because they carry the durable person anchor, not a required `DocumentRecord`.

- [ ] **Step 6: Run focused and adjacent projection tests and verify GREEN**

```sh
swift test --filter 'Person dossier repository'
swift test --filter 'Person dossier projector'
swift test --filter 'Person dossier candidate lookup'
swift test --filter 'Invoice payment candidate lookup'
```

Expected: the repository baseline and all PR 2 projection/index regressions pass.

- [ ] **Step 7: Commit the transactional reader**

```sh
git add Sources/LinkLoomCore/Persistence/PersonDossierProjectionReader.swift Sources/LinkLoomCore/Persistence/DossierRepository.swift Tests/LinkLoomCoreTests/PersonDossierRepositoryTests.swift Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift
git diff --cached --check
git commit -m "feat(dossier): load person snapshots transactionally"
```

---

### Task 4: Implement current-support create, open, and explicit choice

**Files:**
- Modify: `Sources/LinkLoomCore/Persistence/DossierRepository.swift`
- Modify: `Sources/LinkLoomCore/Persistence/PersonDossierProjectionReader.swift`
- Modify: `Tests/LinkLoomCoreTests/PersonDossierRepositoryTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift`

- [ ] **Step 1: Write failing current-selection tests**

Test that disposition and both write operations reject without mutation when:

- the document row or target-current DNA is missing (`invalidAnchor`);
- role, normalized name, content hash, extraction version, DNA target, analysis timestamp, exact finding, or evidence differs from the selected support (`staleInput`);
- the selected finding has ceased to be one of the current snapshot's exact findings.

Also prove a valid current selection does not become invalid merely because `DocumentAvailability` is `.unavailable` or `.missing`; current stored evidence and openability are separate concerns.

- [ ] **Step 2: Write failing create/open/choice behavior tests**

Cover all authoritative outcomes:

- no stable-origin or same-name anchor: `.create`, then one transaction inserts anchor+dossier and returns the first complete snapshot;
- creation uses exactly `Meine Mutter im Pflegeheim`, copies every selected support field, and captures birth date only under the one-primary-person/one-birth-date rule;
- multiple primary people, zero birth dates, or multiple birth dates result in `birthDate == nil`;
- repeated creation and concurrent creation through two repository actors sharing one database open one winning stable-origin dossier and leave one anchor/dossier;
- existing stable-origin tuple opens directly, even if other homonym anchors exist;
- any same-name non-identical anchor returns all deterministic `.choose` summaries and writes nothing, including the single-match case;
- `.existing` opens only a dossier still in the current choice set;
- stale/foreign/missing `.existing` choice returns `staleInput` without writes;
- explicit `.new` creates a distinct homonym dossier;
- an orphaned stable person anchor or wrong-kind dossier association is `invalidStoredState`;
- a costs dossier remains invisible to all person summaries and choices.

For atomic creation failure, install a test-only SQLite trigger that aborts dossier insertion. Assert the thrown `DatabaseError` is preserved and both proposed anchor and dossier roll back.

- [ ] **Step 3: Run focused create/open tests and verify RED**

```sh
swift test --filter 'Person dossier repository'
```

Expected: create/open/choice tests fail because the dispatcher methods are missing.

- [ ] **Step 4: Implement one transaction-local selection validator**

Add an internal helper that loads `DocumentDNARepository.currentSnapshot(in:documentID:target:)`, finds the exact selected person finding, reconstructs `PersonDossierFindingSupportIdentity`, and compares the complete value. Reuse it in disposition, create/open, and choose/create; do not trust caller display values or reconstruct from partial fields.

- [ ] **Step 5: Implement disposition and creation orchestration**

Use the stable-origin and indexed normalized-name store helpers. Generate proposed UUIDs/timestamp before the write closure, but persist them only after current selection and choice validation. Build the anchor from the database-current support and conservative birth-date capture. Insert/fetch anchor, insert/fetch its dossier, then call `personProjectionReader.snapshot` before commit.

`personDossierEntryDisposition` uses one read transaction. `createOrOpenPersonDossier` and `chooseOrCreatePersonDossier` use one write transaction each, including no-write open/choice outcomes, so support cannot change between validation and result.

- [ ] **Step 6: Run focused and costs regression tests and verify GREEN**

```sh
swift test --filter 'Person dossier repository'
swift test --filter 'Dossier repository'
```

Expected: all person creation tests and every existing costs repository test pass.

- [ ] **Step 7: Commit create/open/choice**

```sh
git add Sources/LinkLoomCore/Persistence/DossierRepository.swift Sources/LinkLoomCore/Persistence/PersonDossierProjectionReader.swift Tests/LinkLoomCoreTests/PersonDossierRepositoryTests.swift Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift
git diff --cached --check
git commit -m "feat(dossier): create and open person dossiers"
```

---

### Task 5: Accept and reject exact current suggestions

**Files:**
- Modify: `Sources/LinkLoomCore/Persistence/DossierRepository.swift`
- Modify: `Tests/LinkLoomCoreTests/PersonDossierRepositoryTests.swift`

- [ ] **Step 1: Write failing accept tests**

From a persisted current secondary-role suggestion and a birth-date-conflict suggestion, assert acceptance:

- requires exact dossier ID, document ID, `suggestion.commandSupport`, and snapshot token;
- inserts one confirmation with the injected revision/time and every accepted identity field copied exactly;
- removes the suggestion, adds one authoritative manual member, adds a confirmation correction, and returns a changed deterministic token;
- is isolated to the selected dossier and leaves Document DNA, exclusions, and invoice-payment decisions untouched.

Exercise stale token, support from another suggestion, changed candidate analysis, wrong document ID, already-accepted, missing dossier, and costs-dossier inputs. Each must throw the specified `staleInput`, `dossierNotFound`, or `invalidStoredState` error and insert no confirmation.

- [ ] **Step 2: Run focused acceptance tests and verify RED**

```sh
swift test --filter 'Person dossier repository'
```

Expected: acceptance tests fail because `acceptPersonSuggestion` is absent.

- [ ] **Step 3: Implement accept in one write transaction**

Reproject, compare `snapshot.token`, locate the exact suggestion by document ID, compare `commandSupport`, construct `DossierMembershipConfirmation` from that support plus injected revision/time, insert, and return a second complete projection. Map only competing primary-key/unique insertion to `staleInput`; let the enclosing transaction roll back every other failure.

- [ ] **Step 4: Write failing reject tests**

Prove exact support/token rejection inserts one exclusion, removes the suggestion, exposes an exclusion correction, and does not insert a confirmation. Repeat the stale-token, stale-support, wrong-document, already-corrected, missing/wrong-kind dossier, and cross-dossier isolation cases.

- [ ] **Step 5: Run rejection tests and verify RED, then implement reject**

```sh
swift test --filter 'Person dossier repository'
```

Implement the same preprojection and exact guards, insert one exclusion with the injected revision/time, then reproject before commit.

- [ ] **Step 6: Run focused tests and verify GREEN**

```sh
swift test --filter 'Person dossier repository'
swift test --filter 'Dossier store'
```

Expected: accept/reject and persistence regressions pass.

- [ ] **Step 7: Commit suggestion commands**

```sh
git add Sources/LinkLoomCore/Persistence/DossierRepository.swift Tests/LinkLoomCoreTests/PersonDossierRepositoryTests.swift
git diff --cached --check
git commit -m "feat(dossier): accept and reject person suggestions"
```

---

### Task 6: Remove members and reset exact correction revisions

**Files:**
- Modify: `Sources/LinkLoomCore/Persistence/DossierRepository.swift`
- Modify: `Tests/LinkLoomCoreTests/PersonDossierRepositoryTests.swift`

- [ ] **Step 1: Write failing automatic and relationship-member removal tests**

For an exact-primary direct member and a relationship-only payment member, assert that the exact current `commandSupport` plus token inserts one exclusion, suppresses all automatic supports for that document, returns an exclusion correction, and changes the token. For a multiply supported payment, only the canonical preferred payment support is accepted as the command identity.

Reject stale tokens, non-command supports, support from another member, wrong document ID, already removed members, missing dossiers, costs dossiers, and attempts to remove the durable person anchor as a document member. Assert no row changes on every failure.

- [ ] **Step 2: Write failing manual-member replacement tests**

Accept a suggestion, then remove the resulting authoritative member. Assert one transaction deletes the exact confirmation revision, inserts a new exclusion revision, and returns only the exclusion correction. Add an `AFTER INSERT` test trigger that creates conflicting correction state so final projection fails; assert the whole transaction rolls back and the original confirmation remains while no exclusion survives.

- [ ] **Step 3: Run member-removal tests and verify RED**

```sh
swift test --filter 'Person dossier repository'
```

Expected: removal tests fail because `removePersonMember` is absent.

- [ ] **Step 4: Implement exact member removal**

Reproject and validate token, obtain the member from either section by document ID, calculate its throwing `commandSupport`, and compare exactly. For manual support, delete only `confirmation.revisionID` before inserting the exclusion. For automatic/relationship support, insert the exclusion directly. Reproject before commit.

- [ ] **Step 5: Write failing reset tests**

Cover both correction cases:

- resetting an exact confirmation deletes it and returns the document to a suggestion only when current candidate evidence still exists;
- resetting an exact exclusion reprojects the document as member, suggestion, or hidden according to current evidence;
- resetting an exclusion that replaced a manual confirmation never restores that old confirmation;
- stale token, replaced revision, mismatched full decision, wrong document/dossier, missing dossier, and wrong-kind dossier return without deletion;
- reset in one dossier never changes the same document's correction in another dossier.

- [ ] **Step 6: Run reset tests and verify RED, then implement reset**

```sh
swift test --filter 'Person dossier repository'
```

Locate the exact current correction, compare its full `decision`, dispatch to `deleteConfirmation` or `deleteExclusion` with the embedded revision ID, require exactly one deleted row, and return a same-transaction reprojection. A lost delete race is `staleInput`.

- [ ] **Step 7: Run focused tests and verify GREEN**

```sh
swift test --filter 'Person dossier repository'
swift test --filter 'Person dossier projector'
swift test --filter 'Dossier store'
```

Expected: all remove/reset semantics and adjacent projector/store tests pass.

- [ ] **Step 8: Commit correction commands**

```sh
git add Sources/LinkLoomCore/Persistence/DossierRepository.swift Tests/LinkLoomCoreTests/PersonDossierRepositoryTests.swift
git diff --cached --check
git commit -m "feat(dossier): remove and reset person members"
```

---

### Task 7: Prove reanalysis, lifecycle, cancellation, and atomic failure behavior

**Files:**
- Modify: `Tests/LinkLoomCoreTests/PersonDossierRepositoryTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift`
- Modify only if a test exposes a defect: `Sources/LinkLoomCore/Persistence/PersonDossierProjectionReader.swift`
- Modify only if a test exposes a defect: `Sources/LinkLoomCore/Persistence/DossierRepository.swift`

- [ ] **Step 1: Add failing reanalysis and exact-content-return tests**

Persist automatic membership, manual confirmation, exclusion, and a confirmed invoice-payment decision. Then test, one state change at a time:

- changed person content removes unsupported automatic membership but retains manual confirmation and exclusion while rows exist;
- exact earlier person content reactivates automatic membership, with exclusion still winning;
- a changed invoice or payment content hash makes the old relationship decision unable to support membership;
- a new content-current confirmed decision restores the one-hop payment;
- an accepted suggestion whose exact candidate is stale remains a manual member without presenting stale current-candidate evidence;
- every old token and support submitted after reanalysis is `staleInput` and writes nothing.

Each assertion reloads explicitly through `personDossierSnapshot(id:)`. Automatic observation of analysis-completion events and publication into active workspace state belong to PR 4, not this repository PR.

- [ ] **Step 2: Add failing path, source, and availability lifecycle tests**

Update only synthetic catalog rows and assert:

- relative-path and source-root moves with stable document IDs preserve confirmations/exclusions and refresh summary/member source presentation plus token;
- `.unavailable` and `.missing` member records remain visible with their stored availability;
- origin evidence validity remains `current` or `stale` independently from `DocumentAvailability` while its row exists;
- removing a non-origin source deletes its documents and cascades their confirmations/exclusions while the dossier remains;
- removing the origin source deletes origin/candidate rows and document-bound decisions but preserves the person anchor and dossier, yields `.unavailable` origin, and returns no removed-source members;
- `personDossierSummaries()` still returns the surviving dossier after origin loss;
- existing costs-dossier cascade behavior remains unchanged.

- [ ] **Step 3: Add failing cancellation and rollback tests**

Use pre-cancelled tasks for create, accept, reject, remove, and reset. Assert `CancellationError` is preserved and table snapshots before/after are identical. Add deterministic abort/conflict triggers for one creation and one correction mutation so a failure after an attempted write rolls back the complete transaction and returns no snapshot.

Before and after each successful command family, compare persisted rows from `documentDNA`, `documentDNAFinding`, `documentDNAEvidence`, and `invoicePaymentUserDecision`; only dossier, person-anchor, confirmation, and exclusion tables may change as authorized.

- [ ] **Step 4: Run lifecycle tests and verify RED where coverage exposes missing behavior**

```sh
swift test --filter 'Person dossier repository'
```

Expected: new lifecycle tests initially fail at any missing cancellation checkpoint, error mapping, bounded load, or rollback guarantee.

- [ ] **Step 5: Make the minimum repository fixes**

Add cancellation checkpoints at transaction-safe boundaries, complete known-error mapping for `PersonDossierAnchorStoreError` and `PersonDossierProjectionError`, and correct only repository/reader behavior exposed by the tests. Do not move AppModel's publication/generation responsibilities into Core.

- [ ] **Step 6: Run focused and complete tests**

```sh
swift test --filter 'Person dossier repository'
swift test --filter 'Dossier repository'
swift test --filter 'Person dossier projector'
swift test
```

Expected: all tests pass. The opt-in 10,000-document acceptance fixture is neither changed nor required for this PR because its indexed lookup/projector scale contract was completed in PR 2.

- [ ] **Step 7: Commit lifecycle guarantees**

```sh
git add Sources/LinkLoomCore/Persistence/DossierRepository.swift Sources/LinkLoomCore/Persistence/PersonDossierProjectionReader.swift Tests/LinkLoomCoreTests/PersonDossierRepositoryTests.swift Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift
git diff --cached --check
git commit -m "test(dossier): cover person repository lifecycle"
```

---

### Task 8: Final scope audit, verification, and local handoff

**Files:**
- Review all PR 3 changes
- Do not add unrelated files

- [ ] **Step 1: Audit the diff against PR 3 boundaries**

Run:

```sh
git diff --stat origin/main...HEAD
git diff --name-only origin/main...HEAD
git diff origin/main...HEAD -- Sources/LinkLoomAppFeature Sources/LinkLoomApp Package.swift Tests/LinkLoomCoreTests/Fixtures/PersonDossier Tests/LinkLoomCoreTests/PersonDossierMetricTests.swift Tests/LinkLoomCoreTests/PersonDossierAcceptanceTests.swift
```

Expected: the final command is empty. Confirm there are no migrations, generated artifacts, dependency changes, AppModel, composition, UI, Golden, metric, or scale-fixture edits.

- [ ] **Step 2: Run required verification**

```sh
swift test
swift build -c release
git diff --check
git diff --cached --check
git status --short
```

Expected: all tests and release build pass; diff checks are silent; status contains only intended tracked PR 3 changes and no `.build`, local database, `.superpowers`, secret, or personal-data artifact.

- [ ] **Step 3: Inspect the complete diff and commit any final test-driven correction**

Read every changed production and test file. Verify exact support/token guards, transaction boundaries, deterministic ordering, error privacy, source-removal survival, costs compatibility, and absence of broad cleanup. If a correction is required, add or tighten a failing regression test first, implement the minimum fix, rerun focused plus complete verification, and commit with a scoped Conventional Commit subject.

- [ ] **Step 4: Perform the required two-stage self-review**

Use `superpowers:requesting-code-review` after implementation. First review strict spec/plan compliance; fix and re-review any gap. Then review code quality, transaction safety, concurrency/cancellation, query bounds, tests, and maintainability; fix and re-review every material finding. Since LinkLoom is solo-maintained, do not wait for hypothetical external comments.

- [ ] **Step 5: Prepare—but do not perform—GitHub actions without authorization**

Report the branch, commits, exact commands/results, residual risks, and proposed PR title:

```text
feat(dossier): add atomic person repository commands
```

Do not push, create the pull request, merge, or delete any branch until the user explicitly authorizes each next Git/GitHub action required by repository policy.

## Plan Self-Review Checklist

- [ ] Every PR 3 requirement is mapped to a task: typed reads; create/open/choose-or-create; complete snapshot assembly; accept/reject/remove/reset; exact current-support, token, and revision guards; reanalysis; path/source/availability lifecycle; source removal/origin loss; cancellation; atomic failure; and no mutation of DNA or relationship decisions.
- [ ] Every behavior change begins with a named failing test and an explicit RED command before implementation.
- [ ] Public types used by future AppModel code are constructible without exposing internal database types or partial identity.
- [ ] Every method and helper signature is consistent across the interface, tasks, tests, and transaction contract.
- [ ] No step changes AppModel, ports, composition, UI, migrations, Golden fixtures, metrics, opt-in scale fixtures, dependencies, remote configuration, or source files.
- [ ] No placeholder language, omitted implementation decision, personal data, or privacy-unsafe diagnostic is present.
