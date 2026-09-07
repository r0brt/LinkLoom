# Person-Dossier Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist validated typed dossier anchors, durable person-anchor evidence, and dossier-local positive membership confirmations without exposing any person-dossier workflow yet.

**Architecture:** Extend the existing dossier domain instead of creating a parallel subsystem. Migration `v8_person_anchored_dossiers` rebuilds the v7 dossier tables transactionally, preserves all costs-and-payments rows, and introduces person anchors whose origin document identifier is deliberately not a foreign key; internal GRDB stores expose only transaction-local primitives for later repository composition.

**Tech Stack:** Swift 6.2, macOS 15, Foundation, Swift Testing, GRDB 7.10.0, SQLite.

**Spec:** `docs/superpowers/specs/2026-09-06-person-anchored-main-dossier-design.md`

## Global Constraints

- Work in `/Users/robert/Documents/ChatGPT/LinkLoom`; do not create a Codex worktree.
- Start from the then-current `origin/main` on branch `codex/feat/person-dossier-persistence`.
- This plan implements only specification section 18, PR 1: typed anchors, person-anchor values, migration v8, positive membership confirmations, storage primitives, and migration coverage.
- Do not add person candidate lookup, conflict classification, person projection, Golden fixtures, metric evaluation, repository create/open/mutation commands, AppModel state, production composition, or UI.
- Do not make a person dossier visible through the existing costs-and-payments summary APIs; PR 3 and PR 4 introduce typed repository and application-facing results.
- Preserve every current costs-and-payments domain, repository, projection, AppModel, composition, presentation, and UI-smoke behavior.
- Keep `LinkLoomCore` independent of `LinkLoomAppFeature` and `LinkLoomApp`.
- Do not add dependencies, network calls, external AI, telemetry, remote configuration, or generated artifacts.
- Never rename, move, delete, or modify selected source documents. All tests use in-memory SQLite and synthetic values.
- `PersonDossierAnchor.originDocumentID` is durable UUID text without a `document` foreign key. Deleting a catalog document must not delete its person anchor or dossier.
- Names are not identities. Enforce uniqueness only for `(originDocumentID, primaryRole, normalizedName)`; allow separate anchors with the same normalized name.
- A loaded `DossierRecord` has exactly one typed anchor: `.document(UUID)` for `.costsAndPayments` or `.person(PersonDossierAnchor)` for `.personMatter`.
- Confirmation and exclusion mutual exclusivity is a PR 3 repository invariant, not a schema trigger in this PR. The v8 schema permits detection of malformed pre-existing state by later projection validation.
- Keep all processing and diagnostics free of person names, exact evidence text, absolute paths, hashes, and bookmark data.
- For every behavior change, write the failing test first, run it and observe the expected failure, implement the minimum behavior, then rerun the focused test.
- Before each implementation commit run `git diff --check`, stage only the named files, run `git diff --cached --check`, and inspect `git status --short`.
- Before PR handoff run all focused tests, `swift test`, `swift build -c release`, and a complete branch self-review. Stop before push, PR creation, merge, remote-branch deletion, or GitHub changes unless the user explicitly authorizes that action.

---

## File Structure

- Create `Sources/LinkLoomCore/Models/PersonDossierPersistence.swift`: person roles, persisted birth-date signal, person anchor, confirmation candidate kind, and positive confirmation validation.
- Modify `Sources/LinkLoomCore/Models/Dossier.swift`: add `.personMatter`, `DossierAnchor`, typed `DossierRecord.anchor`, and a costs-only convenience initializer.
- Modify `Sources/LinkLoomCore/Dossiers/CostsAndPaymentsDossierProjector.swift`: require `.document` explicitly instead of reading an untyped document property.
- Modify `Sources/LinkLoomCore/Persistence/DossierProjectionReader.swift`: reject non-document anchors at the existing costs-only boundary.
- Modify `Sources/LinkLoomCore/Persistence/DossierRepository.swift`: keep current public APIs costs-only and ignore stored person dossiers until the typed repository work in PR 3.
- Modify `Sources/LinkLoomCore/Persistence/AppDatabase.swift`: add the forward-only v8 tables and transactional v7 table rebuild.
- Create `Sources/LinkLoomCore/Persistence/PersonDossierAnchorStore.swift`: transaction-local idempotent anchor/evidence insertion and validated decoding.
- Modify `Sources/LinkLoomCore/Persistence/DossierStore.swift`: encode/decode typed dossier anchors and store positive confirmations.
- Modify `Tests/LinkLoomCoreTests/DossierDomainTests.swift`: typed-anchor and persisted person-value validation.
- Modify `Tests/LinkLoomCoreTests/AppDatabaseTests.swift`: fresh schema, populated upgrade, constraints, indexes, cascades, preservation, malformed-state rollback, and no-backfill coverage.
- Create `Tests/LinkLoomCoreTests/PersonDossierAnchorStoreTests.swift`: idempotency, homonyms, evidence order, and malformed-row decoding.
- Modify `Tests/LinkLoomCoreTests/DossierStoreTests.swift`: typed record and confirmation storage plus existing cost/exclusion regressions.
- Modify `Tests/LinkLoomCoreTests/DossierRepositoryTests.swift`: prove that current costs-only public repository results remain unchanged when a persisted person dossier exists.
- Modify `Tests/LinkLoomCoreTests/Support/DossierFixture.swift`: use typed document-anchor access in existing costs tests and add only the direct-store setup needed by the compatibility regression.
- Modify `Tests/LinkLoomCoreTests/DossierProjectorTests.swift`, `Tests/LinkLoomAppFeatureTests/AppModelTests.swift`, and `Tests/LinkLoomAppTests/AppCompositionTests.swift`: replace direct reads of the removed untyped anchor property with explicit document-anchor extraction.

No README, application source, SwiftUI source, Xcode project, fixture corpus, or package dependency changes belong in this PR.

---

### Task 1: Add validated typed-anchor domain values without changing costs behavior

**Files:**
- Create: `Sources/LinkLoomCore/Models/PersonDossierPersistence.swift`
- Modify: `Sources/LinkLoomCore/Models/Dossier.swift`
- Modify: `Sources/LinkLoomCore/Dossiers/CostsAndPaymentsDossierProjector.swift`
- Modify: `Sources/LinkLoomCore/Persistence/DossierProjectionReader.swift`
- Modify: `Sources/LinkLoomCore/Persistence/DossierRepository.swift`
- Modify: `Tests/LinkLoomCoreTests/DossierDomainTests.swift`
- Modify: `Tests/LinkLoomCoreTests/DossierProjectorTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/DossierFixture.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/AppModelTests.swift`
- Modify: `Tests/LinkLoomAppTests/AppCompositionTests.swift`

**Interfaces:**
- Produces `PersonDossierRole`, `PersonDossierBirthDate`, `PersonDossierAnchor`, `PersonDossierCandidateKind`, and `DossierMembershipConfirmation`.
- Produces `DossierAnchor.document(UUID)` and `DossierAnchor.person(PersonDossierAnchor)`.
- `DossierRecord.init(id:kind:displayName:anchor:createdAt:updatedAt:)` validates the kind/anchor pair.
- Retains `DossierRecord.init(id:kind:displayName:anchorDocumentID:createdAt:updatedAt:)` as a costs-only source-compatibility convenience initializer.
- Produces optional read-only accessors `documentAnchorID` and `personAnchor`; callers must branch explicitly.
- Existing public `DossierRepository` methods remain costs-and-payments-only.

- [ ] **Step 1: Write failing domain tests for roles, evidence, typed anchors, and confirmations**

Add these helpers and tests to `DossierDomainTests.swift`:

```swift
private let personEvidence = try! DocumentDNAEvidence(
    pageIndex: 0,
    startUTF16: 12,
    lengthUTF16: 12,
    exactText: "Elise Muster",
    ocrRegionIndexes: [1, 2]
)

private func personAnchor(
    id: UUID = UUID(),
    originDocumentID: UUID = UUID(),
    normalizedName: String = "elise muster",
    role: PersonDossierRole = .resident,
    birthDate: PersonDossierBirthDate? = nil
) throws -> PersonDossierAnchor {
    try PersonDossierAnchor(
        id: id,
        displayName: "Elise Muster",
        normalizedName: normalizedName,
        primaryRole: role,
        originDocumentID: originDocumentID,
        originContentHash: "hash-origin",
        originExtractionVersion: "text-v1",
        originDNASchemaVersion: 1,
        originDNAAnalyzerIdentifier: "local-rules",
        originDNAAnalyzerVersion: "2",
        originDNAAnalyzedAt: Date(timeIntervalSince1970: 100),
        personEvidence: [personEvidence],
        birthDate: birthDate,
        createdAt: Date(timeIntervalSince1970: 110),
        updatedAt: Date(timeIntervalSince1970: 110)
    )
}

@Test func personAnchorAcceptsEveryPrimaryRoleAndRejectsSecondaryRole() throws {
    for role in PersonDossierRole.allCases where role.isPrimary {
        #expect(try personAnchor(role: role).primaryRole == role)
    }
    #expect(throws: DossierValidationError.invalidRecord) {
        try personAnchor(role: .authorizedPerson)
    }
}

@Test func personAnchorRequiresNonBlankIdentityAndEvidenceAndMonotonicDates() {
    #expect(throws: DossierValidationError.invalidRecord) {
        try PersonDossierAnchor(
            id: UUID(), displayName: " ", normalizedName: "elise muster",
            primaryRole: .resident, originDocumentID: UUID(),
            originContentHash: "hash", originExtractionVersion: "text-v1",
            originDNASchemaVersion: 1, originDNAAnalyzerIdentifier: "local-rules",
            originDNAAnalyzerVersion: "2", originDNAAnalyzedAt: .distantPast,
            personEvidence: [personEvidence], birthDate: nil,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
    #expect(throws: DossierValidationError.invalidRecord) {
        try PersonDossierAnchor(
            id: UUID(), displayName: "Elise Muster", normalizedName: " ",
            primaryRole: .resident, originDocumentID: UUID(),
            originContentHash: "hash", originExtractionVersion: "text-v1",
            originDNASchemaVersion: 1, originDNAAnalyzerIdentifier: "local-rules",
            originDNAAnalyzerVersion: "2", originDNAAnalyzedAt: .distantPast,
            personEvidence: [], birthDate: nil,
            createdAt: .distantPast, updatedAt: .distantPast
        )
    }
}

@Test func birthDateRequiresOneCivilDateAndEvidence() throws {
    let evidence = try DocumentDNAEvidence(
        pageIndex: 0, startUTF16: 30, lengthUTF16: 10,
        exactText: "03.04.1940", ocrRegionIndexes: []
    )
    let birthDate = try PersonDossierBirthDate(
        displayValue: "03.04.1940",
        normalizedValue: "1940-04-03",
        evidence: [evidence]
    )
    #expect(birthDate.normalizedValue == "1940-04-03")
    #expect(throws: DossierValidationError.invalidRecord) {
        try PersonDossierBirthDate(
            displayValue: "31.02.1940",
            normalizedValue: "1940-02-31",
            evidence: [evidence]
        )
    }
}

@Test func dossierRequiresAnchorMatchingItsKind() throws {
    let anchor = try personAnchor()
    let timestamp = Date(timeIntervalSince1970: 200)
    let person = try DossierRecord(
        id: UUID(), kind: .personMatter,
        displayName: "Meine Mutter im Pflegeheim",
        anchor: .person(anchor), createdAt: timestamp, updatedAt: timestamp
    )
    #expect(person.personAnchor == anchor)
    #expect(person.documentAnchorID == nil)
    #expect(throws: DossierValidationError.invalidRecord) {
        try DossierRecord(
            id: UUID(), kind: .costsAndPayments,
            displayName: "Kosten und Zahlungen",
            anchor: .person(anchor), createdAt: timestamp, updatedAt: timestamp
        )
    }
}

@Test func confirmationRequiresCandidateKindAndRoleToAgree() throws {
    let valid = try DossierMembershipConfirmation(
        dossierID: UUID(), documentID: UUID(), revisionID: UUID(),
        confirmedAt: Date(timeIntervalSince1970: 300),
        candidateKind: .secondaryRole,
        acceptedContentHash: "hash-candidate",
        acceptedExtractionVersion: "text-v1",
        acceptedDNASchemaVersion: 1,
        acceptedDNAAnalyzerIdentifier: "local-rules",
        acceptedDNAAnalyzerVersion: "2",
        acceptedDNAAnalyzedAt: Date(timeIntervalSince1970: 290),
        acceptedRole: .authorizedPerson,
        acceptedNormalizedName: "elise muster"
    )
    #expect(valid.candidateKind == .secondaryRole)
    #expect(throws: DossierValidationError.invalidRecord) {
        try DossierMembershipConfirmation(
            dossierID: UUID(), documentID: UUID(), revisionID: UUID(),
            confirmedAt: Date(timeIntervalSince1970: 300),
            candidateKind: .birthDateConflict,
            acceptedContentHash: "hash-candidate",
            acceptedExtractionVersion: "text-v1",
            acceptedDNASchemaVersion: 1,
            acceptedDNAAnalyzerIdentifier: "local-rules",
            acceptedDNAAnalyzerVersion: "2",
            acceptedDNAAnalyzedAt: Date(timeIntervalSince1970: 290),
            acceptedRole: .authorizedPerson,
            acceptedNormalizedName: "elise muster"
        )
    }
}
```

- [ ] **Step 2: Run the focused domain test and observe the missing-type failure**

Run: `swift test --filter DossierDomainTests`

Expected: compilation fails because the new persisted person types and `DossierAnchor` do not exist.

- [ ] **Step 3: Add the persisted person-domain implementation**

Create `PersonDossierPersistence.swift` with these declarations and validation rules:

```swift
import Foundation

public enum PersonDossierRole: String, CaseIterable, Sendable, Equatable {
    case resident
    case insuredPerson
    case accountHolder
    case invoiceRecipient
    case grantor
    case authorizedPerson

    public var isPrimary: Bool {
        self != .authorizedPerson
    }
}

public enum PersonDossierCandidateKind: String, CaseIterable, Sendable, Equatable {
    case secondaryRole
    case birthDateConflict
}

public struct PersonDossierBirthDate: Sendable, Equatable {
    public let displayValue: String
    public let normalizedValue: String
    public let evidence: [DocumentDNAEvidence]

    public init(
        displayValue: String,
        normalizedValue: String,
        evidence: [DocumentDNAEvidence]
    ) throws {
        guard !evidence.isEmpty else {
            throw DossierValidationError.invalidRecord
        }
        do {
            _ = try DocumentDNAFinding(
                kind: .date,
                qualifier: DocumentDNADateRole.birthDate.rawValue,
                displayValue: displayValue,
                normalizedValue: normalizedValue,
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: evidence
            )
        } catch {
            throw DossierValidationError.invalidRecord
        }
        self.displayValue = displayValue
        self.normalizedValue = normalizedValue
        self.evidence = evidence
    }
}

public struct PersonDossierAnchor: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let normalizedName: String
    public let primaryRole: PersonDossierRole
    public let originDocumentID: UUID
    public let originContentHash: String
    public let originExtractionVersion: String
    public let originDNASchemaVersion: Int
    public let originDNAAnalyzerIdentifier: String
    public let originDNAAnalyzerVersion: String
    public let originDNAAnalyzedAt: Date
    public let personEvidence: [DocumentDNAEvidence]
    public let birthDate: PersonDossierBirthDate?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        displayName: String,
        normalizedName: String,
        primaryRole: PersonDossierRole,
        originDocumentID: UUID,
        originContentHash: String,
        originExtractionVersion: String,
        originDNASchemaVersion: Int,
        originDNAAnalyzerIdentifier: String,
        originDNAAnalyzerVersion: String,
        originDNAAnalyzedAt: Date,
        personEvidence: [DocumentDNAEvidence],
        birthDate: PersonDossierBirthDate?,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let nonBlank = [
            displayName, normalizedName, originContentHash,
            originExtractionVersion, originDNAAnalyzerIdentifier,
            originDNAAnalyzerVersion,
        ].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard nonBlank,
              primaryRole.isPrimary,
              originDNASchemaVersion > 0,
              !personEvidence.isEmpty,
              updatedAt >= createdAt else {
            throw DossierValidationError.invalidRecord
        }
        self.id = id
        self.displayName = displayName
        self.normalizedName = normalizedName
        self.primaryRole = primaryRole
        self.originDocumentID = originDocumentID
        self.originContentHash = originContentHash
        self.originExtractionVersion = originExtractionVersion
        self.originDNASchemaVersion = originDNASchemaVersion
        self.originDNAAnalyzerIdentifier = originDNAAnalyzerIdentifier
        self.originDNAAnalyzerVersion = originDNAAnalyzerVersion
        self.originDNAAnalyzedAt = originDNAAnalyzedAt
        self.personEvidence = personEvidence
        self.birthDate = birthDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DossierMembershipConfirmation: Sendable, Equatable {
    public let dossierID: UUID
    public let documentID: UUID
    public let revisionID: UUID
    public let confirmedAt: Date
    public let candidateKind: PersonDossierCandidateKind
    public let acceptedContentHash: String
    public let acceptedExtractionVersion: String
    public let acceptedDNASchemaVersion: Int
    public let acceptedDNAAnalyzerIdentifier: String
    public let acceptedDNAAnalyzerVersion: String
    public let acceptedDNAAnalyzedAt: Date
    public let acceptedRole: PersonDossierRole
    public let acceptedNormalizedName: String

    public init(
        dossierID: UUID,
        documentID: UUID,
        revisionID: UUID,
        confirmedAt: Date,
        candidateKind: PersonDossierCandidateKind,
        acceptedContentHash: String,
        acceptedExtractionVersion: String,
        acceptedDNASchemaVersion: Int,
        acceptedDNAAnalyzerIdentifier: String,
        acceptedDNAAnalyzerVersion: String,
        acceptedDNAAnalyzedAt: Date,
        acceptedRole: PersonDossierRole,
        acceptedNormalizedName: String
    ) throws {
        let nonBlank = [
            acceptedContentHash, acceptedExtractionVersion,
            acceptedDNAAnalyzerIdentifier, acceptedDNAAnalyzerVersion,
            acceptedNormalizedName,
        ].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let roleMatchesKind = candidateKind == .secondaryRole
            ? acceptedRole == .authorizedPerson
            : acceptedRole.isPrimary
        guard nonBlank, acceptedDNASchemaVersion > 0, roleMatchesKind else {
            throw DossierValidationError.invalidRecord
        }
        self.dossierID = dossierID
        self.documentID = documentID
        self.revisionID = revisionID
        self.confirmedAt = confirmedAt
        self.candidateKind = candidateKind
        self.acceptedContentHash = acceptedContentHash
        self.acceptedExtractionVersion = acceptedExtractionVersion
        self.acceptedDNASchemaVersion = acceptedDNASchemaVersion
        self.acceptedDNAAnalyzerIdentifier = acceptedDNAAnalyzerIdentifier
        self.acceptedDNAAnalyzerVersion = acceptedDNAAnalyzerVersion
        self.acceptedDNAAnalyzedAt = acceptedDNAAnalyzedAt
        self.acceptedRole = acceptedRole
        self.acceptedNormalizedName = acceptedNormalizedName
    }
}
```

- [ ] **Step 4: Replace the untyped dossier anchor with a closed enum**

In `Dossier.swift`, add `.personMatter`, define the enum below, store `anchor` on `DossierRecord`, validate the pair, and keep the document convenience initializer:

```swift
public enum DossierKind: String, CaseIterable, Sendable, Equatable {
    case costsAndPayments
    case personMatter
}

public enum DossierAnchor: Sendable, Equatable {
    case document(UUID)
    case person(PersonDossierAnchor)
}

public struct DossierRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: DossierKind
    public let displayName: String
    public let anchor: DossierAnchor
    public let createdAt: Date
    public let updatedAt: Date

    public var documentAnchorID: UUID? {
        guard case let .document(id) = anchor else { return nil }
        return id
    }

    public var personAnchor: PersonDossierAnchor? {
        guard case let .person(anchor) = anchor else { return nil }
        return anchor
    }

    public init(
        id: UUID, kind: DossierKind, displayName: String,
        anchor: DossierAnchor, createdAt: Date, updatedAt: Date
    ) throws {
        let validAnchor = switch (kind, anchor) {
        case (.costsAndPayments, .document(_)),
             (.personMatter, .person(_)):
            true
        default: false
        }
        guard validAnchor,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              updatedAt >= createdAt else {
            throw DossierValidationError.invalidRecord
        }
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.anchor = anchor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(
        id: UUID, kind: DossierKind, displayName: String,
        anchorDocumentID: UUID, createdAt: Date, updatedAt: Date
    ) throws {
        try self.init(
            id: id,
            kind: kind,
            displayName: displayName,
            anchor: .document(anchorDocumentID),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
```

- [ ] **Step 5: Make every existing costs-only consumer branch on `.document`**

Use `guard case let .document(anchorDocumentID) = dossier.anchor` in `CostsAndPaymentsDossierProjector` and both `DossierProjectionReader.summary` and `snapshot`. Throw the boundary's existing `invalidStoredState` error when the anchor is not a document.

In `DossierRepository`, filter `DossierStore.all(in:)` to `.costsAndPayments` before producing current `DossierSummary` values or matching document membership. Compare against `documentAnchorID` only after unwrapping it. Do not create a public person API or a typed summary in this task.

Update the named tests and fixtures to use either `dossier.documentAnchorID` with `#require`, or switch over `dossier.anchor`. Do not add force unwraps to production source.

- [ ] **Step 6: Run focused regressions and verify the typed domain passes**

Run:

```bash
swift test --filter 'DossierDomainTests|DossierProjectorTests|DossierRepositoryTests|AppCompositionTests'
```

Expected: the new domain tests and all existing costs-and-payments regressions pass.

- [ ] **Step 7: Check and commit the typed-domain unit**

```bash
git diff --check
git add Sources/LinkLoomCore/Models/PersonDossierPersistence.swift Sources/LinkLoomCore/Models/Dossier.swift Sources/LinkLoomCore/Dossiers/CostsAndPaymentsDossierProjector.swift Sources/LinkLoomCore/Persistence/DossierProjectionReader.swift Sources/LinkLoomCore/Persistence/DossierRepository.swift Tests/LinkLoomCoreTests/DossierDomainTests.swift Tests/LinkLoomCoreTests/DossierProjectorTests.swift Tests/LinkLoomCoreTests/Support/DossierFixture.swift Tests/LinkLoomAppFeatureTests/AppModelTests.swift Tests/LinkLoomAppTests/AppCompositionTests.swift
git diff --cached --check
git status --short
git commit -m "feat(dossier): add typed person anchors"
```

### Task 2: Add the transactional v8 persistence migration

**Files:**
- Modify: `Sources/LinkLoomCore/Persistence/AppDatabase.swift`
- Modify: `Tests/LinkLoomCoreTests/AppDatabaseTests.swift`

**Interfaces:**
- Migration name: `v8_person_anchored_dossiers`.
- Creates `personDossierAnchor`, `personDossierAnchorEvidence`, and `dossierMembershipConfirmation`.
- Rebuilds `dossier` with nullable `anchorDocumentID`, nullable `personAnchorID`, and a kind-specific exactly-one-anchor check.
- Rebuilds `dossierMembershipExclusion` only to retarget its foreign key to the rebuilt dossier table.
- Copies every v7 dossier and exclusion scalar unchanged and creates no person anchor, person dossier, or confirmation during upgrade.

- [ ] **Step 1: Add failing exact-schema and no-backfill tests**

Add `personDossierMigrationCreatesConstrainedSchema()` and assert these exact column lists:

```swift
#expect(try connection.columns(in: "personDossierAnchor").map(\.name) == [
    "id", "displayName", "normalizedName", "primaryRole",
    "originDocumentID", "originContentHash", "originExtractionVersion",
    "originDNASchemaVersion", "originDNAAnalyzerIdentifier",
    "originDNAAnalyzerVersion", "originDNAAnalyzedAt",
    "birthDateDisplayValue", "birthDateNormalizedValue",
    "createdAt", "updatedAt",
])
#expect(try connection.columns(in: "personDossierAnchorEvidence").map(\.name) == [
    "personAnchorID", "subject", "evidenceOrder", "pageIndex",
    "startUTF16", "lengthUTF16", "exactText", "ocrRegionIndexesJSON",
])
#expect(try connection.columns(in: "dossier").map(\.name) == [
    "id", "kind", "displayName", "anchorDocumentID", "personAnchorID",
    "createdAt", "updatedAt",
])
#expect(try connection.columns(in: "dossierMembershipConfirmation").map(\.name) == [
    "dossierID", "documentID", "revisionID", "confirmedAt",
    "candidateKind", "acceptedContentHash", "acceptedExtractionVersion",
    "acceptedDNASchemaVersion", "acceptedDNAAnalyzerIdentifier",
    "acceptedDNAAnalyzerVersion", "acceptedDNAAnalyzedAt",
    "acceptedRole", "acceptedNormalizedName",
])
```

Assert the unique person-origin index columns, non-unique normalized-name index, evidence primary key, both dossier anchor unique constraints, confirmation primary key, and unique confirmation revision. Assert `PRAGMA foreign_key_check` is empty.

Add `personDossierMigrationPreservesPopulatedV7RowsWithoutBackfill()`: migrate only through v7, insert one costs dossier and two exclusions with distinct UUIDs and timestamps, capture ordered rows, run `AppDatabase.migrate`, then assert the rows' values are identical, `personAnchorID` is `NULL`, and all three new person tables are empty.

- [ ] **Step 2: Add failing constraint, cascade, and rollback tests**

Add these tests with direct SQL fixtures:

```swift
@Test func personDossierMigrationAllowsHomonymsButRejectsDuplicateOrigin() throws
@Test func personDossierMigrationRejectsMismatchedTypedAnchors() throws
@Test func deletingOriginDocumentPreservesPersonAnchorAndDossier() throws
@Test func deletingPersonAnchorCascadesDossierEvidenceCorrectionsAndConfirmations() throws
@Test func v8MigrationFailureRollsBackTheCompleteV7Rebuild() throws
```

For the homonym test, insert two anchors with normalized name `elise muster` but different origin document IDs and require success; a third insert repeating the first `(originDocumentID, primaryRole, normalizedName)` must throw `DatabaseError`.

For the typed-anchor test, require valid cost/document and person/person pairs, then require these four malformed rows to fail: both anchor IDs null, both non-null, `.costsAndPayments` with only `personAnchorID`, and `.personMatter` with only `anchorDocumentID`.

For the origin-deletion test, insert a real origin `document`, a person anchor containing its UUID as plain text, and a person dossier. Delete the document and assert the anchor and dossier counts remain one.

For cascade coverage, attach evidence, an exclusion, and a confirmation to one person dossier; delete only `personDossierAnchor`, then assert all five owned rows are gone while the confirmed document remains.

For rollback, create a v7 database, enable `PRAGMA ignore_check_constraints = TRUE`, insert a v7 dossier with kind `unsupported`, execute `PRAGMA ignore_check_constraints = FALSE`, and call `AppDatabase.migrate`. Require a thrown `DatabaseError`, the original six-column v7 dossier table and malformed row still present, the original exclusion table name intact, no v8 person tables, and `SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v8_person_anchored_dossiers'` to return zero.

- [ ] **Step 3: Run the database suite and observe v8 failures**

Run: `swift test --filter AppDatabaseTests`

Expected: the new tests fail because v8 tables and rebuilt columns are absent.

- [ ] **Step 4: Register `v8_person_anchored_dossiers`**

Append one migration after v7. Repeat the v6 Unicode whitespace scalar set locally so persisted nonblank checks match `CharacterSet.whitespacesAndNewlines`; do not normalize names in SQL. The migration body follows this exact order so foreign keys always point at the intended parent:

```swift
migrator.registerMigration("v8_person_anchored_dossiers") { db in
    let foundationWhitespaceSQL = """
        char(9) || char(10) || char(11) || char(12) || char(13) ||
        char(32) || char(133) || char(160) || char(5760) ||
        char(8192) || char(8193) || char(8194) || char(8195) ||
        char(8196) || char(8197) || char(8198) || char(8199) ||
        char(8200) || char(8201) || char(8202) || char(8232) ||
        char(8233) || char(8239) || char(8287) || char(12288)
        """
    try db.create(table: "personDossierAnchor") { table in
        table.column("id", .text).primaryKey()
        table.column("displayName", .text).notNull()
            .check(sql: "length(trim(displayName, \(foundationWhitespaceSQL))) > 0")
        table.column("normalizedName", .text).notNull()
            .check(sql: "length(trim(normalizedName, \(foundationWhitespaceSQL))) > 0")
        table.column("primaryRole", .text).notNull().check(sql: """
            primaryRole IN (
                'resident', 'insuredPerson', 'accountHolder',
                'invoiceRecipient', 'grantor'
            )
            """)
        table.column("originDocumentID", .text).notNull()
        table.column("originContentHash", .text).notNull()
            .check(sql: "length(trim(originContentHash, \(foundationWhitespaceSQL))) > 0")
        table.column("originExtractionVersion", .text).notNull()
            .check(sql: "length(trim(originExtractionVersion, \(foundationWhitespaceSQL))) > 0")
        table.column("originDNASchemaVersion", .integer).notNull()
            .check(sql: "originDNASchemaVersion > 0")
        table.column("originDNAAnalyzerIdentifier", .text).notNull()
            .check(sql: "length(trim(originDNAAnalyzerIdentifier, \(foundationWhitespaceSQL))) > 0")
        table.column("originDNAAnalyzerVersion", .text).notNull()
            .check(sql: "length(trim(originDNAAnalyzerVersion, \(foundationWhitespaceSQL))) > 0")
        table.column("originDNAAnalyzedAt", .datetime).notNull()
        table.column("birthDateDisplayValue", .text)
        table.column("birthDateNormalizedValue", .text)
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.uniqueKey(["originDocumentID", "primaryRole", "normalizedName"])
        table.check(sql: "updatedAt >= createdAt")
        table.check(sql: """
            (birthDateDisplayValue IS NULL AND birthDateNormalizedValue IS NULL)
            OR (
                birthDateDisplayValue IS NOT NULL
                AND length(birthDateDisplayValue) > 0
                AND birthDateNormalizedValue IS NOT NULL
                AND length(trim(
                    birthDateNormalizedValue,
                    \(foundationWhitespaceSQL)
                )) > 0
            )
            """)
    }
    try db.create(
        index: "person_dossier_anchor_normalized_name",
        on: "personDossierAnchor",
        columns: ["normalizedName"]
    )
    try db.create(table: "personDossierAnchorEvidence") { table in
        table.column("personAnchorID", .text).notNull()
            .references("personDossierAnchor", onDelete: .cascade)
        table.column("subject", .text).notNull()
            .check(sql: "subject IN ('person', 'birthDate')")
        table.column("evidenceOrder", .integer).notNull()
            .check(sql: "evidenceOrder >= 0")
        table.column("pageIndex", .integer).notNull()
            .check(sql: "pageIndex >= 0")
        table.column("startUTF16", .integer).notNull()
            .check(sql: "startUTF16 >= 0")
        table.column("lengthUTF16", .integer).notNull()
            .check(sql: "lengthUTF16 > 0")
        table.column("exactText", .text).notNull()
            .check(sql: "length(exactText) > 0")
        table.column("ocrRegionIndexesJSON", .blob).notNull()
        table.primaryKey(["personAnchorID", "subject", "evidenceOrder"])
    }

    try db.execute(sql: """
        ALTER TABLE dossierMembershipExclusion
        RENAME TO dossierMembershipExclusionV7
        """)
    try db.execute(sql: "ALTER TABLE dossier RENAME TO dossierV7")
    try db.execute(sql: "DROP INDEX dossier_anchor_document")

    try db.create(table: "dossier") { table in
        table.column("id", .text).primaryKey()
        table.column("kind", .text).notNull()
            .check(sql: "kind IN ('costsAndPayments', 'personMatter')")
        table.column("displayName", .text).notNull()
            .check(sql: "length(trim(displayName, \(foundationWhitespaceSQL))) > 0")
        table.column("anchorDocumentID", .text)
            .references("document", onDelete: .cascade)
        table.column("personAnchorID", .text)
            .references("personDossierAnchor", onDelete: .cascade)
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.uniqueKey(["anchorDocumentID"])
        table.uniqueKey(["personAnchorID"])
        table.check(sql: "updatedAt >= createdAt")
        table.check(sql: """
            (kind = 'costsAndPayments'
                AND anchorDocumentID IS NOT NULL
                AND personAnchorID IS NULL)
            OR
            (kind = 'personMatter'
                AND anchorDocumentID IS NULL
                AND personAnchorID IS NOT NULL)
            """)
    }
    try db.create(
        index: "dossier_anchor_document",
        on: "dossier",
        columns: ["anchorDocumentID"]
    )
    try db.create(
        index: "dossier_person_anchor",
        on: "dossier",
        columns: ["personAnchorID"]
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
    try db.execute(sql: """
        INSERT INTO dossier (
            id, kind, displayName, anchorDocumentID, personAnchorID,
            createdAt, updatedAt
        )
        SELECT id, kind, displayName, anchorDocumentID, NULL,
               createdAt, updatedAt
        FROM dossierV7
        """)
    try db.execute(sql: """
        INSERT INTO dossierMembershipExclusion (
            dossierID, documentID, revisionID, excludedAt
        )
        SELECT dossierID, documentID, revisionID, excludedAt
        FROM dossierMembershipExclusionV7
        """)
    try db.drop(table: "dossierMembershipExclusionV7")
    try db.drop(table: "dossierV7")

    try db.create(table: "dossierMembershipConfirmation") { table in
        table.column("dossierID", .text).notNull()
            .references("dossier", onDelete: .cascade)
        table.column("documentID", .text).notNull()
            .references("document", onDelete: .cascade)
        table.column("revisionID", .text).notNull().unique()
        table.column("confirmedAt", .datetime).notNull()
        table.column("candidateKind", .text).notNull()
            .check(sql: "candidateKind IN ('secondaryRole', 'birthDateConflict')")
        table.column("acceptedContentHash", .text).notNull()
            .check(sql: "length(trim(acceptedContentHash, \(foundationWhitespaceSQL))) > 0")
        table.column("acceptedExtractionVersion", .text).notNull()
            .check(sql: "length(trim(acceptedExtractionVersion, \(foundationWhitespaceSQL))) > 0")
        table.column("acceptedDNASchemaVersion", .integer).notNull()
            .check(sql: "acceptedDNASchemaVersion > 0")
        table.column("acceptedDNAAnalyzerIdentifier", .text).notNull()
            .check(sql: "length(trim(acceptedDNAAnalyzerIdentifier, \(foundationWhitespaceSQL))) > 0")
        table.column("acceptedDNAAnalyzerVersion", .text).notNull()
            .check(sql: "length(trim(acceptedDNAAnalyzerVersion, \(foundationWhitespaceSQL))) > 0")
        table.column("acceptedDNAAnalyzedAt", .datetime).notNull()
        table.column("acceptedRole", .text).notNull().check(sql: """
            acceptedRole IN (
                'resident', 'insuredPerson', 'accountHolder',
                'invoiceRecipient', 'grantor', 'authorizedPerson'
            )
            """)
        table.column("acceptedNormalizedName", .text).notNull()
            .check(sql: "length(trim(acceptedNormalizedName, \(foundationWhitespaceSQL))) > 0")
        table.primaryKey(["dossierID", "documentID"])
        table.check(sql: """
            (candidateKind = 'secondaryRole' AND acceptedRole = 'authorizedPerson')
            OR
            (candidateKind = 'birthDateConflict' AND acceptedRole <> 'authorizedPerson')
            """)
    }
}
```

- [ ] **Step 5: Run the database suite and verify all migration paths pass**

Run: `swift test --filter AppDatabaseTests`

Expected: fresh v1-to-v8 databases, populated v7 upgrades, constraints, cascades, and rollback tests all pass.

- [ ] **Step 6: Check and commit the migration unit**

```bash
git diff --check
git add Sources/LinkLoomCore/Persistence/AppDatabase.swift Tests/LinkLoomCoreTests/AppDatabaseTests.swift
git diff --cached --check
git status --short
git commit -m "feat(dossier): add person persistence migration"
```

### Task 3: Add transaction-local person-anchor storage

**Files:**
- Create: `Sources/LinkLoomCore/Persistence/PersonDossierAnchorStore.swift`
- Create: `Tests/LinkLoomCoreTests/PersonDossierAnchorStoreTests.swift`

**Interfaces:**

```swift
enum PersonDossierAnchorStoreError: Error, Equatable {
    case invalidStoredState
}

enum PersonDossierAnchorStore {
    static func record(in db: Database, id: UUID) throws -> PersonDossierAnchor?
    static func insertOrFetch(
        in db: Database,
        proposed: PersonDossierAnchor
    ) throws -> PersonDossierAnchor
}
```

`insertOrFetch` is synchronous and accepts an existing `Database` transaction. It inserts scalar and evidence rows only when the stable origin tuple is new, then returns the stored record selected by `(originDocumentID, primaryRole, normalizedName)`.

- [ ] **Step 1: Write failing anchor-store behavior tests**

Create the suite with deterministic UUIDs, one in-memory migrated database, and these tests:

```swift
@Suite("Person dossier anchor store")
struct PersonDossierAnchorStoreTests {
    @Test func insertOrFetchIsIdempotentForStableOriginIdentity() throws
    @Test func sameNormalizedNameFromDifferentOriginsCreatesDistinctAnchors() throws
    @Test func recordRoundTripsPersonAndBirthDateEvidenceInOrder() throws
    @Test func recordRejectsMalformedUUIDRoleDateAndEvidenceJSON() throws
    @Test func recordRejectsMissingOrUnexpectedEvidenceSubjects() throws
}
```

In the idempotency test, propose two anchors with different IDs and display names but the same origin tuple. Require both calls to return the first full value and require one anchor row plus exactly its evidence rows.

In the homonym test, hold `normalizedName` constant while changing `originDocumentID`; require two distinct stored anchors.

In the ordering test, persist two person evidence values and one birth-date evidence value in deliberately non-lexical page order; require exact array order after decoding.

For malformed decoding, insert raw values after selectively enabling `PRAGMA ignore_check_constraints = TRUE`, or corrupt the evidence JSON after insertion. Each `record` call must throw `PersonDossierAnchorStoreError.invalidStoredState`, never leak `DatabaseError`, `DecodingError`, or `DossierValidationError`.

- [ ] **Step 2: Run the suite and observe the missing-store failure**

Run: `swift test --filter PersonDossierAnchorStoreTests`

Expected: compilation fails because `PersonDossierAnchorStore` does not exist.

- [ ] **Step 3: Implement idempotent scalar and evidence insertion**

Use a private `EvidenceSubject` raw enum with `person` and `birthDate`. Execute this scalar insert first:

```swift
try db.execute(
    sql: """
        INSERT INTO personDossierAnchor (
            id, displayName, normalizedName, primaryRole,
            originDocumentID, originContentHash, originExtractionVersion,
            originDNASchemaVersion, originDNAAnalyzerIdentifier,
            originDNAAnalyzerVersion, originDNAAnalyzedAt,
            birthDateDisplayValue, birthDateNormalizedValue,
            createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(originDocumentID, primaryRole, normalizedName) DO NOTHING
        """,
    arguments: [
        proposed.id, proposed.displayName, proposed.normalizedName,
        proposed.primaryRole.rawValue, proposed.originDocumentID,
        proposed.originContentHash, proposed.originExtractionVersion,
        proposed.originDNASchemaVersion, proposed.originDNAAnalyzerIdentifier,
        proposed.originDNAAnalyzerVersion, proposed.originDNAAnalyzedAt,
        proposed.birthDate?.displayValue, proposed.birthDate?.normalizedValue,
        proposed.createdAt, proposed.updatedAt,
    ]
)
let inserted = db.changesCount == 1
```

When `inserted` is true, enumerate `personEvidence` and optional birth-date evidence separately from zero and insert each `DocumentDNAEvidence` using:

```swift
private static func insertEvidence(
    _ values: [DocumentDNAEvidence],
    subject: EvidenceSubject,
    personAnchorID: UUID,
    in db: Database
) throws {
    for (order, evidence) in values.enumerated() {
        let regionData = try JSONEncoder().encode(evidence.ocrRegionIndexes)
        try db.execute(
            sql: """
                INSERT INTO personDossierAnchorEvidence (
                    personAnchorID, subject, evidenceOrder, pageIndex,
                    startUTF16, lengthUTF16, exactText, ocrRegionIndexesJSON
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                personAnchorID, subject.rawValue, order, evidence.pageIndex,
                evidence.startUTF16, evidence.lengthUTF16,
                evidence.exactText, regionData,
            ]
        )
    }
}
```

Fetch the stable tuple after insertion. Throw `invalidStoredState` if the row is absent. Because callers provide an outer transaction, any evidence insert failure rolls back the scalar insert.

- [ ] **Step 4: Implement strict validated decoding**

Fetch evidence ordered by `subject, evidenceOrder`, partition only the two known subjects, decode `[Int]` with `JSONDecoder`, and reconstruct every `DocumentDNAEvidence` through its throwing initializer. Reject gaps in each subject-local order, absent person evidence, birth-date evidence without scalar birth-date fields, scalar birth-date fields without evidence, and every unknown enum or malformed UUID/date.

Wrap the complete row/evidence decode in one `do/catch` and map every error to `PersonDossierAnchorStoreError.invalidStoredState`. Do not include row values in the error.

- [ ] **Step 5: Run the anchor-store suite and migration rollback regression**

Run:

```bash
swift test --filter 'PersonDossierAnchorStoreTests|v8MigrationFailureRollsBackTheCompleteV7Rebuild'
```

Expected: all person-anchor store and rollback tests pass.

- [ ] **Step 6: Check and commit the anchor-store unit**

```bash
git diff --check
git add Sources/LinkLoomCore/Persistence/PersonDossierAnchorStore.swift Tests/LinkLoomCoreTests/PersonDossierAnchorStoreTests.swift
git diff --cached --check
git status --short
git commit -m "feat(dossier): persist person anchor evidence"
```

### Task 4: Store typed dossiers and positive confirmations

**Files:**
- Modify: `Sources/LinkLoomCore/Persistence/DossierStore.swift`
- Modify: `Tests/LinkLoomCoreTests/DossierStoreTests.swift`
- Modify: `Tests/LinkLoomCoreTests/DossierRepositoryTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/DossierFixture.swift`

**Interfaces:**
- Keeps all existing exclusion methods and exact-revision semantics.
- Keeps `all(in:)`, `record(in:id:)`, and `insertOrFetchAnchored(in:proposed:)`, but makes them typed-anchor aware.
- Adds these transaction-local methods:

```swift
static func confirmations(
    in db: Database,
    dossierID: UUID
) throws -> [DossierMembershipConfirmation]

static func insertConfirmation(
    in db: Database,
    confirmation: DossierMembershipConfirmation
) throws

static func deleteConfirmation(
    in db: Database,
    dossierID: UUID,
    documentID: UUID,
    expectedRevisionID: UUID
) throws -> Bool
```

- `DossierStore` does not create person anchors. Callers first use `PersonDossierAnchorStore.insertOrFetch` in the same outer write transaction, construct the dossier with that returned anchor, and then call `insertOrFetchAnchored`.
- Confirmation rows order by `confirmedAt, documentID` and exact-revision deletion returns `true` only for one deleted row.

- [ ] **Step 1: Add failing typed-dossier store tests**

Extend `DossierStoreFixture` with one persisted person anchor and add:

```swift
@Test func allAndRecordRoundTripDocumentAndPersonAnchors() throws
@Test func insertOrFetchPersonDossierIsIdempotentByPersonAnchor() throws
@Test func personDossierRequiresPreviouslyStoredPersonAnchor() throws
@Test func malformedTypedDossierRowsMapToInvalidStoredState() throws
```

The mixed round-trip test must insert one costs dossier and one person dossier, then require complete equality including copied person and birth-date evidence. The idempotency test proposes two dossier IDs for one stored person anchor and requires the first stored dossier to win. The foreign-key test proposes a person dossier whose anchor was never stored and requires `DatabaseError` from insertion. The malformed test corrupts kind/anchor pairs with check constraints ignored and requires `DossierStoreError.invalidStoredState` from reads.

- [ ] **Step 2: Add failing confirmation store tests**

Add:

```swift
@Test func confirmationsRoundTripInConfirmedAtThenDocumentOrder() throws
@Test func duplicateConfirmationMembershipIsRejected() throws
@Test func deleteConfirmationRequiresExactRevision() throws
@Test func malformedConfirmationMapsToInvalidStoredState() throws
```

Use two different documents and confirmation timestamps. Require exact full-value equality, primary-key rejection for duplicate `(dossierID, documentID)`, no deletion for a stale revision, one deletion for the exact revision, and privacy-safe invalid-state mapping for malformed UUID, enum, date, role/kind combination, or nonblank fields.

- [ ] **Step 3: Run the store suite and observe the typed-column failures**

Run: `swift test --filter DossierStoreTests`

Expected: the new tests fail because `DossierStore` still selects the v7 column shape and has no confirmation methods.

- [ ] **Step 4: Encode and decode typed dossier rows**

Select both anchor columns in all dossier queries:

```sql
SELECT id, kind, displayName, anchorDocumentID, personAnchorID,
       createdAt, updatedAt
FROM dossier
```

Decode with an explicit switch:

```swift
let documentAnchorID = try row.decodeIfPresent(
    UUID.self, forColumn: "anchorDocumentID"
)
let personAnchorID = try row.decodeIfPresent(
    UUID.self, forColumn: "personAnchorID"
)
let anchor: DossierAnchor
switch kind {
case .costsAndPayments:
    guard let documentAnchorID, personAnchorID == nil else {
        throw DossierStoreError.invalidStoredState
    }
    anchor = .document(documentAnchorID)
case .personMatter:
    guard documentAnchorID == nil,
          let personAnchorID,
          let personAnchor = try PersonDossierAnchorStore.record(
              in: db, id: personAnchorID
          ) else {
        throw DossierStoreError.invalidStoredState
    }
    anchor = .person(personAnchor)
}
```

Map `PersonDossierAnchorStoreError` to `DossierStoreError.invalidStoredState`. Insert nullable anchor arguments derived from the enum and use `ON CONFLICT DO NOTHING`; fetch the winner by the matching non-null unique anchor column. If insertion fails because only the proposed dossier ID conflicts and no anchor winner exists, throw `invalidStoredState`.

- [ ] **Step 5: Implement strict confirmation storage**

Insert every confirmation field explicitly. Fetch with this deterministic order:

```sql
SELECT dossierID, documentID, revisionID, confirmedAt,
       candidateKind, acceptedContentHash, acceptedExtractionVersion,
       acceptedDNASchemaVersion, acceptedDNAAnalyzerIdentifier,
       acceptedDNAAnalyzerVersion, acceptedDNAAnalyzedAt,
       acceptedRole, acceptedNormalizedName
FROM dossierMembershipConfirmation
WHERE dossierID = ?
ORDER BY confirmedAt, documentID
```

Decode both raw enums before calling the throwing `DossierMembershipConfirmation` initializer. Map malformed rows to `DossierStoreError.invalidStoredState`. Delete only with all three identity fields:

```swift
try db.execute(
    sql: """
        DELETE FROM dossierMembershipConfirmation
        WHERE dossierID = ? AND documentID = ? AND revisionID = ?
        """,
    arguments: [dossierID, documentID, expectedRevisionID]
)
return db.changesCount == 1
```

- [ ] **Step 6: Prove persisted person rows do not leak into current public costs APIs**

In `DossierRepositoryTests`, create one normal costs dossier through the public repository, then insert a person anchor and person dossier directly inside `fixture.db.write`. Require:

```swift
let summaries = try await fixture.repository.summaries()
#expect(summaries.count == 1)
#expect(summaries[0].dossier.kind == .costsAndPayments)
```

Also rerun existing create/open, summary order, projection, exclusion, and reset tests. Do not add a public person repository method in this PR.

- [ ] **Step 7: Run all dossier persistence and repository regressions**

Run:

```bash
swift test --filter 'DossierStoreTests|PersonDossierAnchorStoreTests|DossierRepositoryTests|DossierProjectorTests'
```

Expected: typed storage tests pass and every existing costs-and-payments test remains green.

- [ ] **Step 8: Check and commit the storage unit**

```bash
git diff --check
git add Sources/LinkLoomCore/Persistence/DossierStore.swift Tests/LinkLoomCoreTests/DossierStoreTests.swift Tests/LinkLoomCoreTests/DossierRepositoryTests.swift Tests/LinkLoomCoreTests/Support/DossierFixture.swift
git diff --cached --check
git status --short
git commit -m "feat(dossier): store typed dossiers and confirmations"
```

### Task 5: Run the PR 1 completion gate and perform self-review

**Files:**
- Verify only: all files changed by Tasks 1–4
- Do not modify: README, app UI, Xcode project, package dependencies, source documents, or later-PR fixtures

**Interfaces:**
- Produces one mergeable, non-visible persistence foundation for later PRs.
- Leaves current public runtime behavior unchanged.

- [ ] **Step 1: Run focused domain and persistence suites**

```bash
swift test --filter 'DossierDomainTests|AppDatabaseTests|PersonDossierAnchorStoreTests|DossierStoreTests|DossierRepositoryTests|DossierProjectorTests'
```

Expected: every selected test passes with zero failures.

- [ ] **Step 2: Run the complete test suite**

Run: `swift test`

Expected: all suites pass. The opt-in 10,000-document benchmark remains skipped because this PR changes neither catalog scale behavior nor person candidate lookup.

- [ ] **Step 3: Run the production release build**

Run: `swift build -c release`

Expected: release build exits successfully.

- [ ] **Step 4: Audit schema and source boundaries**

Run:

```bash
git diff origin/main...HEAD --check
git diff origin/main...HEAD --name-only
git status --short
! rg -n 'URLSession|Network|telemetry|PersonDossierView|PersonDossierSnapshot|currentSnapshotsMatchingPerson' Sources Tests README.md Package.swift
```

Expected: the diff is whitespace-clean; only the planned Core and test files appear; the status contains no local database, `.build`, `.superpowers`, secret, or source-document artifact; the negated scope scan succeeds with no output, proving there is no network, telemetry, UI, person projection, or person-candidate lookup addition.

- [ ] **Step 5: Review the complete branch against the specification**

Verify each item explicitly:

- both allowed dossier kind/anchor pairs decode and every mismatched pair is rejected;
- existing v7 costs dossiers, exclusion revisions, timestamps, and cascade behavior survive unchanged;
- origin document deletion cannot cascade a person anchor or person dossier;
- deleting a person anchor cascades its copied evidence, dossier, exclusions, and confirmations;
- same-origin retry is idempotent and same-name/different-origin anchors remain distinct;
- person and birth-date evidence round-trip in exact subject-local order;
- positive confirmations contain the complete accepted input identity and use exact-revision deletion;
- malformed UUID, enum, date, role/kind, evidence, and JSON rows map to typed privacy-safe invalid-state errors;
- no person dossier is exposed through current costs-only repository, AppModel, composition, or UI paths;
- no candidate, projection, Golden, metric, 10,000-document lookup, or source-file behavior from PR 2–5 entered the branch.

If any item lacks a passing test, add that test and its minimum implementation before continuing.

- [ ] **Step 6: Inspect staged state before handoff**

```bash
git diff --cached --check
git status --short
git log --oneline origin/main..HEAD
```

Expected: no unintended staged or untracked files and exactly the understandable Task 1–4 commits.

- [ ] **Step 7: Stop before remote actions**

Report exact test/build results, changed files, migration and rollback risks, privacy/source-integrity impact, and the recommended PR title `feat(dossier): persist person anchors`. Obtain separate explicit authorization before push or pull-request creation; merge authorization remains separate.
