# Person-Dossier Candidate Retrieval and Projection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retrieve the small exact-name person candidate set through the existing DNA index and deterministically project an explainable person dossier with conservative conflict handling, dossier-local corrections, and one-hop confirmed payments.

**Architecture:** Add read-only candidate retrieval and pure projection components to `LinkLoomCore`. The lookup reuses the existing `(kind, normalizedValue)` index and reconstructs complete current DNA only for matching documents. A pure classifier and projector consume immutable inputs, apply exclusions and confirmations, and expand only from already included invoices through current confirmed invoice-payment candidates. PR 3 will compose these primitives inside repository transactions; this PR adds no repository dispatcher or mutation command.

**Tech Stack:** Swift 6.2, macOS 15, Foundation, Swift Testing, GRDB 7.10.0, SQLite, SwiftPM test resources.

**Spec:** `docs/superpowers/specs/2026-09-06-person-anchored-main-dossier-design.md`, sections 6.1–8, 11.1, 14, 15, 16, 17.2, 17.5, and 18 / PR 2.

## Global Constraints

- Work in `/Users/robert/Documents/ChatGPT/LinkLoom`; do not create a Codex worktree.
- Start implementation from the then-current `origin/main` on branch `codex/feat/person-dossier-candidate-projection`.
- This plan implements only specification section 18, PR 2: indexed current-person lookup, conservative conflict classification, pure person projection, confirmed one-hop payment expansion, versioned Golden fixtures, metric evaluation, and the opt-in 10,000-document acceptance test.
- Do not add or modify `DossierRepository` public commands, create/open/choose-or-create behavior, accept/reject/remove/reset mutation commands, transaction dispatch, AppModel ports or state, production composition, SwiftUI, accessibility UI, process-level UI smoke tests, or README operator guidance. Those belong to PRs 3–5.
- Existing `DossierStore` confirmation/exclusion write helpers may be used only to arrange tests. Do not add a new persistence mutation API in production code.
- Do not expose person dossiers through the existing costs-and-payments repository APIs. `PersonDossierProjector` is pure; PR 3 will perform the single-transaction assembly described by specification section 11.1.
- Keep `DossierSnapshot` and `CostsAndPaymentsDossierProjector` free of person-specific optional fields. New person output types live in `PersonDossierSnapshot.swift`.
- Reuse the existing `document_dna_finding_kind_value` index. Do not add a migration or a second person-name index.
- Exact normalized-name equality means Swift `String` equality on the already normalized DNA value. Do not normalize again, fold accents, compare case-insensitively, or add fuzzy/partial/initial/OCR similarity.
- Only `resident`, `insuredPerson`, `accountHolder`, `invoiceRecipient`, `grantor`, and `authorizedPerson` participate in retrieval. Unsupported or absent qualifiers stay hidden and must not cause complete DNA reconstruction.
- Treat a birth-date conflict as hard only when the anchor has a captured birth date and the candidate snapshot has exactly one supported primary-role person finding and exactly one `birthDate` finding, and their normalized civil dates differ. Missing or ambiguous birth dates never create a conflict.
- An exclusion wins over automatic person support, manual confirmation, and confirmed relationship support. A confirmation and exclusion for the same dossier/document pair is invalid stored input and must make projection fail without a partial value.
- A manual confirmation remains authoritative while its document row exists, even if the accepted candidate provenance is stale. Stale accepted evidence must not be emitted as current evidence.
- Expand only from invoices already included by direct exact-person support or manual confirmation. Follow only a current `InvoicePaymentCandidate` whose exact content-bound key has a `.confirmed` record. Stop at the payment.
- Undecided, `.excluded`, content-stale, unrelated, second-hop, and inferred-payment relationship paths produce neither membership nor a person suggestion.
- Preserve all independent confirmed paths as ordered visible supports, deduplicate documents by UUID, and use existing invoice/payment strength and canonical tie-break behavior to select the command support identity.
- Keep diagnostics and test output free of person names, exact evidence text, absolute source paths, content hashes, and bookmark data. Synthetic fixture contents may contain only the fictional data committed with the tests.
- Add no dependencies, network calls, external AI, telemetry, remote configuration, generated app artifacts, or source-file mutations.
- For every behavior change, write a failing behavioral test first, run it and observe the expected failure, add only the minimum production behavior, and rerun the focused test.
- After each task, run its focused tests plus the named adjacent regression tests, inspect the diff, and commit only that task during implementation. The current planning request itself creates only this uncommitted Markdown file.
- When implementation is separately authorized, carry this approved plan onto the feature branch and include it in the first implementation commit so it becomes the durable execution record.
- Before each future implementation commit run `git diff --check`, stage only the named files, run `git diff --cached --check`, and inspect `git status --short`.
- Before future PR handoff run all focused tests, `swift test`, `swift build -c release`, the opt-in 10,000-document test, and a complete branch self-review. Stop before push, PR creation, merge, remote-branch deletion, or GitHub changes unless separately authorized.

---

## Current `main` Baseline

The plan is based on `main` at `f26baa6763007956c9273e25d76865db6043407f` (`feat(dossier): persist person anchors (#46)`). Recheck this section before implementation if `main` advances.

- `PersonDossierPersistence.swift` already defines the six supported roles, primary-role classification, `PersonDossierCandidateKind`, durable `PersonDossierAnchor`, optional captured birth date, and content-bound `DossierMembershipConfirmation`.
- `DossierRecord` already has typed `.document` and `.person` anchors. The current public `DossierRepository` intentionally filters out person dossiers.
- `DossierStore` already provides transaction-local confirmation and exclusion reads. PR 1 deliberately permits both records to coexist in the schema so projection/repository validation can detect malformed state.
- `DocumentDNARepository.currentFindings(kind:normalizedValue:target:)` and `currentSnapshotsMatchingReference(_:target:)` already force `INDEXED BY document_dna_finding_kind_value` and reject stale DNA through the current document/content/extraction/target join.
- `DocumentDNARepository.currentSnapshot(in:documentID:target:)` and `snapshot(in:documentID:)` already provide transaction-local complete reconstruction primitives.
- `InvoicePaymentCandidateProjector`, `InvoicePaymentCandidateStrength`, `InvoicePaymentDecisionKey(candidate:)`, and `DossierCandidateTieBreakKey` already encode reference-cohort lookup, ambiguity handling, content-bound decision identity, strength ordering, signal canonicalization, and stable tie breaks.
- `CostsAndPaymentsDossierProjector` already demonstrates pure projection, exclusion precedence, deduplication, stable presentation ordering, and deterministic projection tokens. Its output types remain unchanged.
- `InvoicePaymentCandidateLookupTests` demonstrates GRDB statement tracing for bounded indexed reads. `DocumentDNAGoldenTests` demonstrates versioned resource decoding and UTF-16/OCR evidence validation. `IngestionAcceptanceTests` uses `LINKLOOM_PERF_TEST=1` for the existing opt-in 10,000-file test.

## File Structure

### Production files

- Create `Sources/LinkLoomCore/Matching/PersonDossierCandidateLookup.swift`: public read-only lookup wrapper over the exact-name repository primitive.
- Create `Sources/LinkLoomCore/Matching/PersonDossierCandidateClassifier.swift`: internal pure exact-role and conservative birth-date classifier.
- Modify `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift`: add public actor and transaction-local static complete-snapshot lookup for exact supported person findings.
- Create `Sources/LinkLoomCore/Models/PersonDossierSnapshot.swift`: person-only origin, member, support, suggestion, correction, section, and token values.
- Create `Sources/LinkLoomCore/Dossiers/PersonDossierProjector.swift`: internal pure direct projection, correction application, one-hop relationship expansion, deduplication, ordering, and token construction.
- Modify `Sources/LinkLoomCore/Dossiers/CostsAndPaymentsDossierProjector.swift`: make only the existing canonical invoice/payment tie-break helper and signal canonicalizer module-internal so the person projector reuses exactly the same ranking; do not change costs projection behavior.

### Test files and resources

- Create `Tests/LinkLoomCoreTests/PersonDossierCandidateLookupTests.swift`.
- Create `Tests/LinkLoomCoreTests/PersonDossierCandidateClassifierTests.swift`.
- Create `Tests/LinkLoomCoreTests/PersonDossierProjectorTests.swift`.
- Create `Tests/LinkLoomCoreTests/PersonDossierGoldenTests.swift`.
- Create `Tests/LinkLoomCoreTests/PersonDossierMetricTests.swift`.
- Create `Tests/LinkLoomCoreTests/PersonDossierAcceptanceTests.swift`.
- Create `Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift`: deterministic domain and database builders shared by focused and acceptance tests.
- Create `Tests/LinkLoomCoreTests/Support/PersonDossierGoldenFixture.swift`: versioned manifest decoder, input construction, expected-snapshot construction, overlay application, and evidence validation.
- Create `Tests/LinkLoomCoreTests/Support/PersonDossierMetricEvaluator.swift`: test-only aggregate evaluator for synthetic and optional local reference manifests.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/manifest.json`: the coherent 15-document fictional baseline plus decision/lifecycle overlay definitions and complete expected states.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/baseline-snapshot.json`.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/accepted-secondary-snapshot.json`.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/rejected-secondary-snapshot.json`.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/corrected-snapshot.json`.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/removed-primary-snapshot.json`.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/reset-corrections-snapshot.json`.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/reanalysis-snapshot.json`.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/origin-stale-snapshot.json`.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/origin-unavailable-snapshot.json`.
- Create `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/member-availability-snapshot.json`.

No `AppDatabase.swift`, schema migration, `DossierRepository.swift`, `DossierStore.swift`, `DossierSnapshot.swift`, `LinkLoomAppFeature`, `LinkLoomApp`, `Package.swift`, README, Xcode project, or existing DNA Golden fixture change belongs in this PR.

---

## Required Domain Interfaces

Implement these public person-only output shapes in `PersonDossierSnapshot.swift`. Initializers must validate their invariants; they must be `Sendable` and `Equatable`. Keep initializers `internal` unless PR 3 needs public construction from outside `LinkLoomCore`.

```swift
public enum PersonDossierOriginEvidenceValidity: String, Sendable, Equatable {
    case current
    case stale
    case unavailable
}

public enum PersonDossierSection: String, Sendable, Equatable {
    case directDocuments
    case costsAndPayments
}

public struct PersonDossierOriginState: Sendable, Equatable {
    public let validity: PersonDossierOriginEvidenceValidity
    public let document: DocumentRecord?
    public let sourceDisplayName: String?
}

public struct PersonDossierFindingSupportIdentity: Sendable, Equatable {
    public let documentID: UUID
    public let contentHash: String
    public let extractionVersion: String
    public let dnaSchemaVersion: Int
    public let dnaAnalyzerIdentifier: String
    public let dnaAnalyzerVersion: String
    public let dnaAnalyzedAt: Date
    public let role: PersonDossierRole
    public let normalizedName: String
    public let finding: DocumentDNAFinding
}

public enum PersonDossierInvoiceMembershipBasis: Sendable, Equatable {
    case exactPerson([PersonDossierFindingSupportIdentity])
    case manualConfirmation(revisionID: UUID)
}

public struct PersonDossierPaymentSupportIdentity: Sendable, Equatable {
    public let invoiceDocumentID: UUID
    public let invoiceMembershipBasis: PersonDossierInvoiceMembershipBasis
    public let relationship: DossierMembershipSupportIdentity
    public let signals: [InvoicePaymentCandidateSignal]
}

public enum PersonDossierMembershipSupport: Sendable, Equatable {
    case exactPrimary(PersonDossierFindingSupportIdentity)
    case manualConfirmation(
        confirmation: DossierMembershipConfirmation,
        currentCandidate: PersonDossierCandidateSupportIdentity?
    )
    case confirmedPayment(PersonDossierPaymentSupportIdentity)
}

public enum PersonDossierConflictState: Sendable, Equatable {
    case none
    case hardBirthDateConflict(
        anchor: PersonDossierBirthDate,
        candidate: DocumentDNAFinding
    )
}

public struct PersonDossierCandidateSupportIdentity: Sendable, Equatable {
    public let kind: PersonDossierCandidateKind
    public let person: PersonDossierFindingSupportIdentity
    public let conflict: PersonDossierConflictState
}

public struct PersonDossierMember: Identifiable, Sendable, Equatable {
    public var id: UUID { document.id }
    public let document: DocumentRecord
    public let sourceDisplayName: String
    public let documentType: DocumentType?
    public let section: PersonDossierSection
    public let supports: [PersonDossierMembershipSupport]
    public let isConfirmationAuthoritative: Bool
    public let preferredPaymentSupport: PersonDossierPaymentSupportIdentity?
}

public struct PersonDossierSuggestion: Identifiable, Sendable, Equatable {
    public var id: UUID { document.id }
    public let document: DocumentRecord
    public let sourceDisplayName: String
    public let documentType: DocumentType?
    public let section: PersonDossierSection
    public let kind: PersonDossierCandidateKind
    public let conflict: PersonDossierConflictState
    public let currentSupports: [PersonDossierCandidateSupportIdentity]
    public let commandSupport: PersonDossierCandidateSupportIdentity
}

public enum PersonDossierCorrectionDecision: Sendable, Equatable {
    case confirmation(DossierMembershipConfirmation)
    case exclusion(DossierMembershipExclusion)
}

public struct PersonDossierCorrection: Identifiable, Sendable, Equatable {
    public var id: UUID { document.id }
    public let document: DocumentRecord
    public let sourceDisplayName: String
    public let documentType: DocumentType?
    public let decision: PersonDossierCorrectionDecision
}

public struct PersonDossierDocumentProjectionIdentity: Sendable, Equatable {
    public let documentID: UUID
    public let sourceRootID: UUID
    public let relativePath: String
    public let contentHash: String
    public let availability: DocumentAvailability
    public let dnaAnalyzedAt: Date?
}

public struct PersonDossierProjectionToken: Sendable, Equatable {
    public let dossierUpdatedAt: Date
    public let anchorUpdatedAt: Date
    public let originValidity: PersonDossierOriginEvidenceValidity
    public let documents: [PersonDossierDocumentProjectionIdentity]
    public let memberSupports: [[PersonDossierMembershipSupport]]
    public let suggestionSupports: [PersonDossierCandidateSupportIdentity]
    public let confirmationRevisionIDs: [UUID]
    public let exclusionRevisionIDs: [UUID]
}

public struct PersonDossierSnapshot: Sendable, Equatable {
    public let dossier: DossierRecord
    public let anchor: PersonDossierAnchor
    public let origin: PersonDossierOriginState
    public let directMembers: [PersonDossierMember]
    public let costsAndPayments: [PersonDossierMember]
    public let suggestions: [PersonDossierSuggestion]
    public let corrections: [PersonDossierCorrection]
    public let token: PersonDossierProjectionToken
}
```

The stored `DocumentRecord.availability` remains authoritative; do not duplicate an independently mutable availability field on members. `origin.document?.availability` supplies source availability while the row exists. `origin.document == nil` is the only `.unavailable` origin-evidence case.

Use this internal pure input; the future PR 3 reader must load it in one transaction without changing the projector:

```swift
struct PersonDossierProjectionInput: Sendable {
    let dossier: DossierRecord
    let originDocument: DocumentRecord?
    let currentOrigin: CurrentDocumentDNA?
    let documentsByID: [UUID: DocumentRecord]
    let currentDocumentsByID: [UUID: CurrentDocumentDNA]
    let personCandidates: [CurrentDocumentDNA]
    let relationshipCandidates: [InvoicePaymentCandidate]
    let relationshipDecisionsByKey:
        [InvoicePaymentDecisionKey: InvoicePaymentDecisionRecord]
    let sourceDisplayNames: [UUID: String]
    let confirmations: [DossierMembershipConfirmation]
    let exclusions: [DossierMembershipExclusion]
}
```

`currentDocumentsByID` contains current DNA for origin/corrections/confirmed documents when available and for every relationship endpoint. `personCandidates` is exactly the bounded result of the indexed lookup. `relationshipCandidates` is preloaded only for invoices that the caller expects may be included; the projector still defensively rejects expansion from any invoice that is not a direct or manually confirmed member.

---

### Task 1: Add bounded indexed exact-person retrieval

**Files:**
- Add approved plan to first implementation commit: `docs/superpowers/plans/2026-09-08-person-dossier-candidate-projection.md`
- Create: `Sources/LinkLoomCore/Matching/PersonDossierCandidateLookup.swift`
- Modify: `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift`
- Create: `Tests/LinkLoomCoreTests/PersonDossierCandidateLookupTests.swift`
- Create: `Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift`

**Interfaces:**

```swift
public struct PersonDossierCandidateLookup: Sendable {
    public init(repository: DocumentDNARepository, target: DocumentDNAAnalysisTarget)
    public func currentDocuments(matchingNormalizedName: String) async throws
        -> [CurrentDocumentDNA]
}

extension DocumentDNARepository {
    public func currentSnapshotsMatchingPerson(
        _ normalizedName: String,
        target: DocumentDNAAnalysisTarget
    ) async throws -> [CurrentDocumentDNA]

    static func currentSnapshotsMatchingPerson(
        in db: Database,
        normalizedName: String,
        target: DocumentDNAAnalysisTarget
    ) throws -> [CurrentDocumentDNA]
}
```

- [ ] **Step 1: Write the failing lookup behavior tests**

Add these exact test cases:

- `lookupReturnsCompleteCurrentSnapshotsForAllSixSupportedRoles()` inserts one exact-name snapshot per `PersonDossierRole`, calls the lookup once, and compares complete `CurrentDocumentDNA` values in `(sourceRootID, relativePath, UUID)` order.
- `lookupExcludesDifferentNormalizedNamesWithoutAccentFolding()` proves `"elise müster"`, `"e. muster"`, and `"elise"` are not returned for `"elise muster"`.
- `lookupDoesNotReconstructUnsupportedOrUnqualifiedPersonSnapshots()` inserts exact-name `person` findings with `qualifier == nil` and `qualifier == "beneficiary"`; neither result may be returned.
- `lookupExcludesStaleContentExtractionAndAnalysisTargets()` changes content hash, extraction version, schema version, analyzer identifier, and analyzer version in five separate documents and expects only the current control document.
- `lookupDeduplicatesDocumentsWithRepeatedSupportedExactFindings()` inserts two exact supported person findings in one snapshot and expects one complete document.
- `lookupUsesOneIndexedCohortReadAndOnlyReconstructsMatches()` attaches a GRDB statement trace, expects exactly one statement containing `INDEXED BY document_dna_finding_kind_value`, and expects complete-snapshot header reads only for the returned document count.
- `lookupRejectsBlankNormalizedNameWithoutReadingDNA()` expects `[]` and zero traced DNA statements for an empty or whitespace-only value.

- [ ] **Step 2: Run the focused tests and observe the missing API failure**

Run: `swift test --filter PersonDossierCandidateLookupTests`

Expected: compilation fails because `PersonDossierCandidateLookup` and `currentSnapshotsMatchingPerson` do not exist.

- [ ] **Step 3: Implement the exact indexed query**

The static repository query must use this shape:

```sql
SELECT DISTINCT document.*
FROM documentDNAFinding AS finding
    INDEXED BY document_dna_finding_kind_value
JOIN documentDNA
    ON documentDNA.documentID = finding.documentID
JOIN document
    ON document.id = documentDNA.documentID
JOIN documentExtraction
    ON documentExtraction.documentID = document.id
WHERE finding.kind = 'person'
    AND finding.normalizedValue = ?
    AND finding.qualifier IN (
        'resident', 'insuredPerson', 'accountHolder',
        'invoiceRecipient', 'grantor', 'authorizedPerson'
    )
    AND documentDNA.schemaVersion = ?
    AND documentDNA.analyzerIdentifier = ?
    AND documentDNA.analyzerVersion = ?
    AND documentDNA.inputContentHash = document.contentHash
    AND documentDNA.inputExtractionVersion = documentExtraction.analysisVersion
ORDER BY document.sourceRootID, document.relativePath, document.id
```

Return early for a blank name. Reconstruct each returned document with the existing private `snapshot(in:documentID:)`; if a selected header disappears inside the same read transaction, map it to `DocumentDNARepositoryError.invalidStoredState`. Do not scan, fetch, or decode unrelated snapshots.

- [ ] **Step 4: Rerun lookup and adjacent index regressions**

Run:

```sh
swift test --filter PersonDossierCandidateLookupTests
swift test --filter InvoicePaymentCandidateLookupTests
swift test --filter DocumentDNARepositoryTests
swift test --filter AppDatabaseTests
```

Expected: all pass; no migration or index definition changed.

- [ ] **Step 5: Review and commit Task 1 during implementation**

Verify the query contains no interpolated person value and the public wrapper only reads. Commit message: `feat(dossier): retrieve exact person candidates`.

---

### Task 2: Add conservative person candidate classification

**Files:**
- Create: `Sources/LinkLoomCore/Matching/PersonDossierCandidateClassifier.swift`
- Create: `Tests/LinkLoomCoreTests/PersonDossierCandidateClassifierTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift`

**Internal interface:**

```swift
enum PersonDossierCandidateClassification: Sendable, Equatable {
    case automatic([PersonDossierFindingSupportIdentity])
    case suggestion(
        kind: PersonDossierCandidateKind,
        conflict: PersonDossierConflictState,
        supports: [PersonDossierCandidateSupportIdentity],
        commandSupport: PersonDossierCandidateSupportIdentity
    )
    case hidden
}

struct PersonDossierCandidateClassifier: Sendable {
    func classify(
        _ current: CurrentDocumentDNA,
        for anchor: PersonDossierAnchor
    ) -> PersonDossierCandidateClassification
}
```

Use role order `resident`, `insuredPerson`, `accountHolder`, `invoiceRecipient`, `grantor`, `authorizedPerson`; break ties within one role by the finding's existing snapshot order. The classifier must not mutate or normalize input.

- [ ] **Step 1: Write the failing classifier matrix**

Add these exact tests:

- `everyExactPrimaryRoleIsAutomaticRegardlessOfDocumentType()` loops over five primary roles and all `DocumentType` values, including `.unknown`.
- `exactAuthorizedPersonIsASecondaryRoleSuggestion()` expects `.suggestion(kind: .secondaryRole, conflict: .none, ...)` with complete current finding provenance.
- `differentNormalizedNameUnsupportedQualifierAndUnlabelledTextAreHidden()` covers accent, abbreviation, partial, absent qualifier, unsupported qualifier, organization/reference values, relative path, and plain extracted text without a person finding.
- `oneDifferentUnambiguousBirthDateDemotesPrimaryMatch()` gives the anchor `1940-02-01`, one primary person, and one candidate birth date `1941-03-02`; expect `.birthDateConflict` and both person and date evidence.
- `matchingMissingOrAmbiguousBirthDatesDoNotConflict()` covers no anchor date, no candidate date, same date, two primary persons, and two birth-date findings; every exact primary control stays automatic.
- `automaticPrimarySupportOutranksAnAdditionalSecondaryFinding()` expects one automatic document, all primary supports retained in role/snapshot order, and no duplicate suggestion for the additional secondary finding.
- `classifierPreservesExactUnicodeSemantics()` proves canonically different already-normalized strings are not folded by the classifier.
- `supportIdentityIncludesCompleteInputAndEvidence()` compares every content hash, extraction version, DNA target field, analysis timestamp, role, normalized name, finding, and evidence field.

- [ ] **Step 2: Run RED**

Run: `swift test --filter PersonDossierCandidateClassifierTests`

Expected: compilation fails because classifier and projection support types do not exist.

- [ ] **Step 3: Add only the support/conflict domain types and classifier**

Create `PersonDossierSnapshot.swift` initially with the origin, finding-support, conflict, and candidate-support declarations needed by the classifier. Implement the hard-conflict predicate literally:

```swift
guard let anchorBirthDate = anchor.birthDate else { return nil }
let primaryPeople = snapshot.findings.filter { finding in
    finding.kind == .person
        && finding.qualifier.flatMap(PersonDossierRole.init(rawValue:))?.isPrimary == true
}
let birthDates = snapshot.findings.filter {
    $0.kind == .date && $0.qualifier == DocumentDNADateRole.birthDate.rawValue
}
guard primaryPeople.count == 1,
      primaryPeople[0].normalizedValue == anchor.normalizedName,
      birthDates.count == 1,
      birthDates[0].normalizedValue != anchorBirthDate.normalizedValue
else { return nil }
return .hardBirthDateConflict(anchor: anchorBirthDate, candidate: birthDates[0])
```

If any non-conflicting exact primary finding exists, classify the document as automatic. Otherwise prefer `.birthDateConflict` over `.secondaryRole`; select the command support by role order then snapshot order. Never emit a support without current evidence.

- [ ] **Step 4: Run GREEN and lookup regression**

Run:

```sh
swift test --filter PersonDossierCandidateClassifierTests
swift test --filter PersonDossierCandidateLookupTests
swift test --filter DossierDomainTests
```

Expected: all pass.

- [ ] **Step 5: Review and commit Task 2 during implementation**

Confirm there is no `localizedCaseInsensitiveCompare`, folding, regex similarity, edit distance, or inference from filenames/references/organizations. Commit message: `feat(dossier): classify person candidates conservatively`.

---

### Task 3: Project origin, direct members, suggestions, and corrections purely

**Files:**
- Modify: `Sources/LinkLoomCore/Models/PersonDossierSnapshot.swift`
- Create: `Sources/LinkLoomCore/Dossiers/PersonDossierProjector.swift`
- Create: `Tests/LinkLoomCoreTests/PersonDossierProjectorTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift`

**Pure interface:**

```swift
enum PersonDossierProjectionError: Error, Sendable, Equatable {
    case invalidStoredState
}

struct PersonDossierProjector: Sendable {
    func project(_ input: PersonDossierProjectionInput) throws
        -> PersonDossierSnapshot
}
```

- [ ] **Step 1: Write failing origin and input-validation tests**

Add:

- `projectsCurrentOriginOnlyForExactPersistedInputAndFindingIdentity()` expects `.current` only when document ID/content hash, extraction version, schema/analyzer identity, analyzed timestamp, role, display/normalized value, and complete person evidence equal the copied anchor support.
- `projectsStaleOriginSeparatelyFromDocumentAvailability()` varies the current input/finding identity while retaining an `.available`, `.unavailable`, or `.missing` document row; validity remains `.stale` and availability stays on the document.
- `projectsUnavailableOriginOnlyWhenDocumentRowIsGone()` supplies neither origin row nor current origin and expects `.unavailable` with no source display name.
- `rejectsWrongDossierKindOrAnchor()` rejects costs dossiers and mismatched person anchors.
- `rejectsForeignDuplicateAndContradictoryCorrections()` rejects confirmation/exclusion records for another dossier, duplicate records for a document, and simultaneous confirmation plus exclusion.
- `rejectsConfirmationOrExclusionWithoutItsDocumentRow()` rejects a correction whose FK-bound document is absent from `documentsByID`.

- [ ] **Step 2: Run the focused test and observe missing projector failures**

Run: `swift test --filter PersonDossierProjectorTests`

Expected: compilation fails because the full snapshot and projector are absent.

- [ ] **Step 3: Implement validated origin and immutable output construction**

Finish the required domain interfaces above. `PersonDossierProjector` must validate all input before building output so no partially valid snapshot can escape. Source display fallback is the lowercase UUID string, matching existing dossier behavior without exposing an absolute path.

- [ ] **Step 4: Write failing direct-membership and correction tests**

Add:

- `projectsEachAutomaticDocumentOnceWithAllOrderedExactSupports()` feeds duplicate exact primary findings and duplicate candidate input rows; expect one member and all distinct supports.
- `placesInvoicesAndPaymentsInCostsAndPaymentsAndEverythingElseDirect()` covers all document types; only `.invoice` and `.paymentConfirmation` enter the derived section.
- `projectsSecondaryAndConflictCandidatesAsSuggestions()` compares complete kind, conflict, current support, command support, evidence, document, source, type, and section values.
- `exclusionSuppressesAutomaticSuggestionConfirmationAndRelationshipSupport()` exercises each source of membership against one exclusion and expects only an exclusion correction.
- `confirmationCreatesAnAuthoritativeMemberAndCorrection()` expects the document as a member plus a confirmation correction.
- `currentAcceptedCandidateAddsCurrentEvidenceToManualSupport()` matches the full accepted content/extraction/DNA/role/name identity.
- `staleAcceptedCandidateKeepsOnlyManualSupport()` changes each accepted provenance component separately and proves no stale person evidence is emitted.
- `reanalysisAndPathOrSourceMoveKeepConfirmationAndExclusionAuthoritative()` changes current DNA, relative path, and source root while preserving document UUID.
- `ordersEachSectionAndSuggestionsBySourceNamePathUUID()` supplies reverse input order and duplicate source/path values.
- `projectionIsInputOrderIndependent()` permutes person candidates, dictionaries, confirmations, exclusions, and source name insertion order and compares the complete snapshots.

- [ ] **Step 5: Run RED for direct projection**

Run: `swift test --filter PersonDossierProjectorTests`

Expected: the new tests compile but fail because the projector has not applied classification/corrections.

- [ ] **Step 6: Implement direct projection and correction precedence**

Build candidate classifications by document UUID. Apply this precedence exactly:

1. exclusion → no member/suggestion, one exclusion correction;
2. confirmation → authoritative member, one confirmation correction, plus current accepted support only when exact accepted identity still matches;
3. automatic primary classification → non-authoritative member;
4. secondary or birth-date-conflict classification → suggestion;
5. hidden → no output.

Deduplicate equal supports, preserve distinct role findings, and canonicalize before sorting. A confirmation can keep a document as a member without current DNA; its `documentType` is then `nil` and its section is `.directDocuments` because a stale type must not be invented. A current confirmed invoice remains eligible for Task 4 expansion.

- [ ] **Step 7: Run GREEN plus costs regressions**

Run:

```sh
swift test --filter PersonDossierProjectorTests
swift test --filter PersonDossierCandidateClassifierTests
swift test --filter DossierProjectorTests
swift test --filter DossierStoreTests
```

Expected: all pass and `DossierSnapshot` remains unchanged.

- [ ] **Step 8: Review and commit Task 3 during implementation**

Confirm the projector imports Foundation only, performs no database/file/network access, and never changes its input. Commit message: `feat(dossier): project person dossier candidates`.

---

### Task 4: Expand one confirmed invoice-payment hop with complete supports

**Files:**
- Modify: `Sources/LinkLoomCore/Dossiers/PersonDossierProjector.swift`
- Modify: `Sources/LinkLoomCore/Dossiers/CostsAndPaymentsDossierProjector.swift`
- Modify: `Tests/LinkLoomCoreTests/PersonDossierProjectorTests.swift`
- Modify: `Tests/LinkLoomCoreTests/DossierProjectorTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift`

- [ ] **Step 1: Write the failing one-hop matrix**

Add:

- `confirmedCurrentCandidateAddsPaymentFromDirectInvoice()` expects a payment member with the exact decision key/timestamp, invoice/payment DNA timestamps, resolver version, canonical signals, and invoice person-membership basis.
- `confirmedCurrentCandidateAddsPaymentFromManuallyConfirmedInvoice()` proves manual invoice confirmation is a valid starting point.
- `undecidedExcludedAndContentStaleRelationshipsAddNothing()` covers absent decision, `.excluded`, and decisions keyed to old invoice or payment content.
- `personExclusionSuppressesOtherwiseConfirmedPayment()` expects only its exclusion correction.
- `doesNotExpandFromSuggestionExcludedInvoiceOrInferredPayment()` covers all three invalid starting points.
- `stopsAfterPaymentAndNeverAddsSecondInvoice()` supplies a confirmed payment→other-invoice-shaped candidate after the first hop and expects no second hop.
- `removingSoleInvoiceRemovesDerivedPayment()` excludes the only supporting invoice; neither invoice nor payment remains unless payment has direct/manual support.
- `keepsPaymentWithIndependentDirectManualOrSecondInvoiceSupport()` removes one path at a time and compares all remaining supports.
- `deduplicatesPaymentAndRetainsAllConfirmedPaths()` supplies two included invoices pointing to one payment; expect one member and two visible relationship supports.
- `selectsPreferredPaymentCommandSupportByExistingRanking()` varies disposition, signal count, resolver identity, analyzed timestamps, document types, and canonical signals in both input orders.
- `ordersRelationshipSignalsAndSupportsDeterministically()` expects reference, amount, organization signal order and stable invoice/path/UUID ordering across independent paths.
- `relationshipOnlyPaymentNeverBecomesPersonSuggestion()` proves undecided/excluded relationship candidates are absent from suggestions.

- [ ] **Step 2: Run RED**

Run: `swift test --filter PersonDossierProjectorTests`

Expected: relationship tests fail because no one-hop expansion exists.

- [ ] **Step 3: Share, do not duplicate, the existing candidate ranking**

Change only access control on `DossierCandidateTieBreakKey` and its `canonicalSignals(_:)` helper from `private` to module-internal. Reuse `InvoicePaymentCandidateStrength` as-is. Add a costs projector regression proving its complete result and token are unchanged for the same duplicate candidates before and after the access-control change.

- [ ] **Step 4: Implement bounded one-hop expansion**

Freeze the direct/manual member set before inspecting relationship candidates. For every candidate:

1. require its invoice UUID in that frozen set and its current type `.invoice`;
2. build `InvoicePaymentDecisionKey(candidate:)` and require an exact matching `.confirmed` record;
3. require the decision key to match both current content hashes;
4. reject a person-excluded payment;
5. add one `.confirmedPayment` support containing the canonical candidate signals and the invoice's current exact-person supports or confirmation revision;
6. do not feed the added payment back into expansion.

Merge the payment into an existing direct/manual member when applicable. Retain every distinct confirmed-path support, then select `preferredPaymentSupport` by `InvoicePaymentCandidateStrength` followed by `DossierCandidateTieBreakKey`. Never select by dictionary or input order.

- [ ] **Step 5: Build the deterministic projection token**

Populate the token from the already sorted output:

- dossier and anchor update timestamps;
- origin validity;
- every visible document's ID, source ID, relative path, content hash, availability, and current DNA timestamp;
- the complete ordered support list for each member;
- each suggestion command support;
- confirmation and exclusion revision UUIDs in correction presentation order.

The same logical input in any collection order must produce an equal token. Changes to current content, analysis, availability, path/source, relationship decision timestamp, support evidence, or correction revision must change it.

- [ ] **Step 6: Run GREEN and all relationship/dossier regressions**

Run:

```sh
swift test --filter PersonDossierProjectorTests
swift test --filter DossierProjectorTests
swift test --filter InvoicePaymentCandidateProjectorTests
swift test --filter InvoicePaymentCandidateLookupTests
swift test --filter InvoicePaymentDecisionRepositoryTests
```

Expected: all pass.

- [ ] **Step 7: Review and commit Task 4 during implementation**

Search the diff for loops over newly inferred members; there must be none. Commit message: `feat(dossier): expand confirmed person payments one hop`.

---

### Task 5: Add complete versioned Person-Dossier Golden fixtures

**Files:**
- Create: `Tests/LinkLoomCoreTests/Support/PersonDossierGoldenFixture.swift`
- Create: `Tests/LinkLoomCoreTests/PersonDossierGoldenTests.swift`
- Create: all files under `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/` listed above

**Fixture contract:**

`manifest.json` contains `schemaVersion: 1`, fictional source roots, anchor, documents, current DNA, relationship candidates/decisions, baseline confirmation/exclusion state, metric labels, and named overlays. Each document entry contains:

```json
{
  "id": "83000000-0000-0000-0000-000000000001",
  "relativePath": "wohnen/anker.pdf",
  "groundTruthRelevant": true,
  "membershipClass": "direct",
  "expectedInitialClass": "automatic",
  "expectedSection": "directDocuments",
  "expectedReasonCodes": ["exactPrimary"],
  "expectedEvidence": [{"pageIndex": 0, "startUTF16": 12, "lengthUTF16": 12}],
  "relationshipDecision": null,
  "expectedAfterAccept": "automatic",
  "expectedAfterReject": "excluded",
  "expectedAfterRemove": "excluded",
  "expectedAfterReset": "automatic"
}
```

Use test-only decoded enums for the string labels. Expected snapshot JSON files encode every public field of `PersonDossierSnapshot`, including document records, source names, document types, sections, complete supports/findings/evidence, conflict values, corrections, and token. Decode them into domain values and compare with `==`; do not compare selected fields or serialized debug descriptions.

- [ ] **Step 1: Write the failing fixture inventory test**

`manifestCoversEveryRequiredSpecificationCase()` must assert these deterministic baseline IDs and purposes:

| ID | Baseline purpose | Truth / initial class |
| --- | --- | --- |
| D01 | selected resident origin | relevant / automatic |
| D02 | insuredPerson | relevant / automatic |
| D03 | accountHolder | relevant / automatic |
| D04 | invoiceRecipient invoice A | relevant / automatic |
| D05 | grantor | relevant / automatic |
| D06 | OCR-backed resident invoice B | relevant / automatic |
| D07 | payment with no person finding, confirmed from D04 and D06 | relevant / automatic indirect |
| D08 | authorizedPerson only | relevant / suggestion |
| D09 | exact primary homonym with hard birth-date conflict | irrelevant / suggestion |
| D10 | accent variant | irrelevant / hidden |
| D11 | abbreviated name | irrelevant / hidden |
| D12 | partial name | irrelevant / hidden |
| D13 | unlabelled text occurrence | irrelevant / hidden |
| D14 | misleading organization/reference/filename/directory similarity | irrelevant / hidden |
| D15 | second-hop invoice/payment shape | irrelevant / hidden |

The five primary roles, OCR evidence, no-person payment, undecided/excluded relationship overlays, secondary role, conflict, all hidden boundaries, misleading metadata, second hop, multiple confirmed paths, reanalysis decisions, origin lifecycle, and member availability/deletion must all be asserted explicitly.

- [ ] **Step 2: Run RED for missing resources**

Run: `swift test --filter PersonDossierGoldenTests`

Expected: the test records missing `PersonDossier/v1` resources.

- [ ] **Step 3: Add the manifest and complete baseline expected snapshot**

Use deterministic UUIDs under `83000000-...`, fixed ISO-8601 timestamps, and only fictional Swiss-style names/organizations/references. The baseline has eight relevant documents: D01–D08. D01–D07 are automatic (D07 indirect); D08 is the one relevant suggestion. D09 is the one irrelevant visible conflict suggestion. D10–D15 are irrelevant hidden negatives.

- [ ] **Step 4: Validate every evidence range against synthetic input**

For each `DocumentDNAFinding.evidence` and copied anchor evidence:

- locate the declared page;
- assert `NSMaxRange` is inside the page's UTF-16 length;
- assert the substring equals `exactText`;
- assert every OCR region index exists;
- assert non-OCR findings use an empty OCR index list;
- assert D06 has at least one valid OCR region.

- [ ] **Step 5: Add behavioral overlay Goldens without changing the denominator**

The named overlays must construct inputs directly—never invoke future repository commands—and compare complete values:

- `relationship-undecided`: remove D07's confirmed decisions; D07 disappears.
- `relationship-excluded`: use `.excluded`; D07 disappears without a person suggestion.
- `accepted-secondary`: add a confirmation for D08; it becomes authoritative and remains in corrections.
- `rejected-secondary`: add an exclusion for D08; it disappears and projects an exclusion correction.
- `corrected`: confirm D08 and exclude D09 in one input; membership contains exactly the eight relevant documents used by the corrected-quality metric.
- `removed-primary`: exclude D02; it disappears and projects an exclusion correction.
- `reset-corrections`: omit the exact prior confirmation/exclusion revisions; current rules restore D08 as suggestion and D02 as automatic.
- `reanalysis`: change D08 accepted provenance and D02 automatic DNA while keeping their confirmation/exclusion records; confirmation/exclusion remain authoritative and stale accepted evidence is absent.
- `origin-stale`: keep D01's row but alter one origin identity component; origin is stale.
- `origin-unavailable`: omit D01's row/current DNA; the dossier survives and origin is unavailable.
- `member-availability`: project one current available, one temporarily unavailable, one missing, and one deleted candidate; deleted has no output unless a surviving relationship/current row supports it.

- [ ] **Step 6: Run Golden and existing DNA Golden tests**

Run:

```sh
swift test --filter PersonDossierGoldenTests
swift test --filter DocumentDNAGoldenTests
```

Expected: complete equality and all evidence validations pass; existing DNA fixtures are untouched.

- [ ] **Step 7: Review and commit Task 5 during implementation**

Search fixtures for real paths, names, accounts, hashes, or bookmarks before staging. Commit message: `test(dossier): add person projection goldens`.

---

### Task 6: Evaluate synthetic and optional local-reference metrics

**Files:**
- Create: `Tests/LinkLoomCoreTests/Support/PersonDossierMetricEvaluator.swift`
- Create: `Tests/LinkLoomCoreTests/PersonDossierMetricTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/PersonDossierGoldenFixture.swift`
- Modify: `Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/manifest.json`

Keep metric machinery test-only. It is verification infrastructure, not an application or repository API.

**Test-only interfaces:**

```swift
enum PersonDossierMetricMembershipClass: String, Decodable {
    case direct
    case indirectPayment
}

struct PersonDossierMetricLabel: Decodable, Equatable {
    let documentID: UUID
    let supportedFormat: Bool
    let relevant: Bool
    let membershipClass: PersonDossierMetricMembershipClass
    let role: PersonDossierRole?
    let candidateKind: PersonDossierCandidateKind?
}

struct PersonDossierQualitySlice: Equatable {
    let truePositive: Int
    let falsePositive: Int
    let falseNegative: Int
    let precision: Double
    let recall: Double
}

struct PersonDossierQualityReport: Equatable {
    let automatic: PersonDossierQualitySlice
    let discoverable: PersonDossierQualitySlice
    let corrected: PersonDossierQualitySlice
    let direct: PersonDossierQualitySlice
    let indirectPayment: PersonDossierQualitySlice
    let byRole: [PersonDossierRole: PersonDossierQualitySlice]
    let byCandidateKind: [PersonDossierCandidateKind: PersonDossierQualitySlice]
}

enum PersonDossierMetricEvaluator {
    static func evaluate(
        labels: [PersonDossierMetricLabel],
        baseline: PersonDossierSnapshot,
        corrected: PersonDossierSnapshot
    ) throws -> PersonDossierQualityReport
}
```

Denominator membership is exactly the set of manifest documents with `supportedFormat == true`; overlays never add denominator rows. Define zero-denominator precision/recall as `1.0` only when the corresponding predicted/relevant count is also zero; otherwise use the ordinary ratios.

- [ ] **Step 1: Write failing formula and denominator tests**

Add:

- `metricFormulasCountTrueFalsePositivesAndFalseNegatives()` with a small hand-built table.
- `unsupportedDocumentsAndOverlayStatesDoNotEnterDenominator()`.
- `discoverableIncludesAutomaticAndSuggestionsWithoutDoubleCounting()`.
- `correctedUsesFinalMembersAndNotCorrectionRowsAsMembership()`.
- `reportSplitsDirectIndirectRoleAndCandidateKind()`.
- `emptySliceUsesDefinedUnitQuality()`.

- [ ] **Step 2: Run RED**

Run: `swift test --filter PersonDossierMetricTests`

Expected: compilation fails because the evaluator is absent.

- [ ] **Step 3: Implement the evaluator and gate the synthetic corpus**

Use sets of document UUIDs. Throw a test-only fixture error for duplicate labels, missing labels for visible projected documents, or a projected document marked unsupported. The Golden baseline produces exact aggregate expectations:

- automatic: TP 7, FP 0, FN 1, precision `1.0`, recall `0.875`;
- discoverable: TP 8, FP 1, FN 0, precision `8.0 / 9.0`, recall `1.0`;
- corrected after accepting D08 and rejecting D09: TP 8, FP 0, FN 0, precision `1.0`, recall `1.0`.

The release gates assert automatic precision `== 1.0`, discoverable recall `== 1.0`, and corrected precision/recall `== 1.0`. Automatic recall is asserted and printed but is not a gate. Report and assert D07 in the indirect-payment slice and D01–D06/D08 in direct/role slices so aggregate success cannot hide a broken class.

- [ ] **Step 4: Add an optional local-only reference-set evaluator**

Add a test enabled only when `LINKLOOM_PERSON_REFERENCE_MANIFEST` is present. Decode that untracked local JSON through the same label/result DTOs, print only aggregate integer counts and ratios, and assert automatic precision `>= 0.90` and discoverable recall `>= 0.80`. Never print or commit document IDs, text, names, paths, memberships, or the environment variable value. If the variable is absent, the normal suite skips the test without failure.

- [ ] **Step 5: Run metrics and Golden regressions**

Run:

```sh
swift test --filter PersonDossierMetricTests
swift test --filter PersonDossierGoldenTests
```

Expected: synthetic gates pass; local reference test is skipped unless explicitly configured.

- [ ] **Step 6: Review and commit Task 6 during implementation**

Inspect captured test output to ensure it contains aggregates only. Commit message: `test(dossier): evaluate person projection quality`.

---

### Task 7: Prove bounded behavior with the opt-in 10,000-document acceptance test

**Files:**
- Create: `Tests/LinkLoomCoreTests/PersonDossierAcceptanceTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift`

Use the existing opt-in switch for consistency:

```swift
@Test(.enabled(if: ProcessInfo.processInfo.environment["LINKLOOM_PERF_TEST"] == "1"))
func indexedLookupAndProjectionStayBoundedAtTenThousandDocuments() async throws
```

- [ ] **Step 1: Write the disabled-by-default acceptance test**

In one in-memory database transaction, insert 10,000 supported document rows, current extraction rows, DNA headers, and findings with prepared GRDB statements. Exactly three documents use the anchor's normalized name: one direct invoice, one direct non-financial document, and one secondary-role suggestion. One current confirmed payment candidate is reachable from the invoice. The remaining 9,997 snapshots use distinct nonmatching names and references.

Attach a thread-safe GRDB statement trace after fixture setup. Measure elapsed time with `ContinuousClock`, but only print a privacy-safe diagnostic containing total catalog count, match count, person cohort read count, reconstructed snapshot count, relationship cohort count, and elapsed milliseconds.

- [ ] **Step 2: Add structural boundedness assertions, not a wall-clock gate**

Assert:

- catalog document count is 10,000;
- exact person lookup returns the three expected UUIDs in stable order;
- exactly one candidate SQL statement contains `INDEXED BY document_dna_finding_kind_value`;
- complete snapshot header reconstruction runs exactly three times, never 10,000 times;
- invoice/payment reference lookup runs only for the one included direct invoice;
- projector result contains the expected direct member, invoice, confirmed payment, and secondary suggestion once each;
- no unrelated UUID is present in members, suggestions, corrections, supports, or token;
- repeating projection with reversed bounded input produces the same complete snapshot and token;
- there is no elapsed-time assertion.

- [ ] **Step 3: Run the test once without and once with opt-in**

Run:

```sh
swift test --filter PersonDossierAcceptanceTests
LINKLOOM_PERF_TEST=1 swift test --filter PersonDossierAcceptanceTests
```

Expected: first run reports the test disabled; second run passes and prints aggregate diagnostics only.

- [ ] **Step 4: Run focused PR 2 verification**

Run:

```sh
swift test --filter PersonDossierCandidateLookupTests
swift test --filter PersonDossierCandidateClassifierTests
swift test --filter PersonDossierProjectorTests
swift test --filter PersonDossierGoldenTests
swift test --filter PersonDossierMetricTests
LINKLOOM_PERF_TEST=1 swift test --filter PersonDossierAcceptanceTests
swift test --filter DossierProjectorTests
swift test --filter InvoicePaymentCandidateLookupTests
swift test --filter InvoicePaymentCandidateProjectorTests
swift test --filter InvoicePaymentDecisionRepositoryTests
swift test --filter DocumentDNAGoldenTests
```

Expected: all enabled tests pass.

- [ ] **Step 5: Review and commit Task 7 during implementation**

Confirm the acceptance setup writes only the in-memory test database and does not create 10,000 source files. Commit message: `test(dossier): verify person projection scale`.

---

### Task 8: Complete PR 2 verification and strict-scope self-review

**Files:**
- Modify only files already named in Tasks 1–7 if verification exposes an in-scope defect.

- [ ] **Step 1: Run complete tests and release build**

Run:

```sh
swift test
swift build -c release
```

Expected: both exit successfully.

- [ ] **Step 2: Run the opt-in scale acceptance test again from the final tree**

Run:

```sh
LINKLOOM_PERF_TEST=1 swift test --filter PersonDossierAcceptanceTests
```

Expected: pass with no wall-clock assertion and no private fixture output.

- [ ] **Step 3: Run mechanical diff checks**

Run:

```sh
git diff --check
git status --short
git diff --stat origin/main...HEAD
git diff origin/main...HEAD -- Sources/LinkLoomCore Tests/LinkLoomCoreTests
```

Expected: no whitespace errors, no `.build`, database, secret, local-reference manifest, or unrelated file; no modifications under app targets.

- [ ] **Step 4: Perform specification and boundary self-review**

Check every item explicitly:

- exact indexed retrieval and supported qualifiers only;
- no accent/fuzzy/partial/unlabelled inference;
- every primary role automatic, secondary role suggested;
- conservative single-person/single-date conflict rule;
- origin current/stale/unavailable separate from document availability;
- exclusion precedence and invalid contradictory state;
- confirmation persistence with no stale evidence presentation;
- documents deduplicated and sectioned deterministically;
- confirmed current relationship only, expansion frozen at one hop;
- all independent relationship reasons retained and preferred support ranked by existing rules;
- complete support identities and deterministic token;
- complete Golden equality and evidence bounds;
- exact synthetic quality gates and aggregate-only optional local metrics;
- 10,000-document structural boundedness without time gate;
- no repository mutation commands, application ports, AppModel, composition, UI, migration, dependency, network, telemetry, or selected-source mutation.

- [ ] **Step 5: Run staged checks before the final future implementation commit**

Run:

```sh
git add Sources/LinkLoomCore/Matching/PersonDossierCandidateLookup.swift \
  Sources/LinkLoomCore/Matching/PersonDossierCandidateClassifier.swift \
  Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift \
  Sources/LinkLoomCore/Models/PersonDossierSnapshot.swift \
  Sources/LinkLoomCore/Dossiers/PersonDossierProjector.swift \
  Sources/LinkLoomCore/Dossiers/CostsAndPaymentsDossierProjector.swift \
  Tests/LinkLoomCoreTests/PersonDossierCandidateLookupTests.swift \
  Tests/LinkLoomCoreTests/PersonDossierCandidateClassifierTests.swift \
  Tests/LinkLoomCoreTests/PersonDossierProjectorTests.swift \
  Tests/LinkLoomCoreTests/PersonDossierGoldenTests.swift \
  Tests/LinkLoomCoreTests/PersonDossierMetricTests.swift \
  Tests/LinkLoomCoreTests/PersonDossierAcceptanceTests.swift \
  Tests/LinkLoomCoreTests/DossierProjectorTests.swift \
  Tests/LinkLoomCoreTests/Support/PersonDossierFixture.swift \
  Tests/LinkLoomCoreTests/Support/PersonDossierGoldenFixture.swift \
  Tests/LinkLoomCoreTests/Support/PersonDossierMetricEvaluator.swift \
  Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1 \
  docs/superpowers/plans/2026-09-08-person-dossier-candidate-projection.md
git diff --cached --check
git status --short
```

Expected: only PR 2 files are staged. If task commits already contain these files and there is no final change, do not manufacture an empty commit.

- [ ] **Step 6: Stop at local completion**

Report exact test/build/acceptance results, commit IDs, aggregate metric results, and remaining PR 3 boundary. Do not push, create a pull request, merge, delete a branch, or change GitHub state without separate explicit authorization.

---

## Explicit PR 3 Handoff Boundary

PR 2 ends with pure, tested building blocks. PR 3—not this plan—will:

- load dossier, lookup results, corrections, relationship candidates, and decisions in one authoritative GRDB transaction;
- add public typed person-dossier repository reads and create/open/choose-or-create commands;
- add accept, reject, remove, and exact-revision reset mutations;
- validate displayed support/token identities against a reprojected current state;
- handle cancellation, reanalysis refresh, source removal, and atomic failure behavior.

No application-facing workspace enum, AppModel state, composition wiring, or visible UI appears until later PRs.
