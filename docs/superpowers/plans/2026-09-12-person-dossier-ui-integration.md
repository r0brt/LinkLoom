# Person Dossier UI Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the already implemented person-anchored main dossier through the production macOS app with per-finding entry actions, typed sidebar/workspace routing, explainable and correctable person-dossier UI, deterministic focus/accessibility behavior, operator guidance, and one complete process-level source-integrity smoke workflow.

**Architecture:** Keep `DossierRepository` as the single Core authority and adapt its person APIs through one thin production service beside the existing costs service. Keep all SwiftUI-only formatting, accessibility labels, focus destinations, and German copy in `LinkLoomAppFeature`; `AppModel` remains the sole owner of asynchronous state and commands from PR 4. Extend the existing XCUITest harness with a separate synthetic person-dossier fixture and read-only SQLite evidence so the new workflow does not weaken or replace the existing costs-and-payments smoke.

**Tech Stack:** Swift 6.2, macOS 15, SwiftUI, Combine, AppKit accessibility notifications, Swift Testing, GRDB 7.10.0, XCTest/XCUIAutomation, SQLite3, CoreGraphics, CoreText, PDFKit, CryptoKit, Xcode 26.3.

**Spec:** `docs/superpowers/specs/2026-09-06-person-anchored-main-dossier-design.md`

## Global Constraints

- Start implementation from the then-current `origin/main`; at plan-writing time local `main`, `origin/main`, and their merge-base are all `a22789269e85074072d06334f2107f62207d8694`.
- Create no branch while writing this plan. At implementation time use one short-lived branch such as `codex/feat/person-dossier-ui-integration`; do not push, merge, change GitHub settings, or delete a remote branch without explicit authorization.
- Keep `docs/superpowers/plans/2026-09-10-person-dossier-app-model-orchestration.md` byte-for-byte unchanged, untracked, and excluded from every commit. Before every commit, stage only the exact paths named in that task and prove with `git diff --cached --name-only` that this file is absent.
- Do not rename, move, delete, or intentionally modify any selected source document. UI smoke fixtures live under one test-owned temporary root and are the only source documents used by the process test.
- Keep all processing local. Add no network call, external AI, telemetry, package dependency, project generator, or new remote configuration.
- Preserve dependency direction: `LinkLoomCore` knows nothing about `LinkLoomAppFeature` or SwiftUI; `LinkLoomAppFeature` depends only on Core; `LinkLoomApp` is the concrete composition root.
- Reuse the Core person repository commands and PR 4 `AppModel` methods exactly. Do not duplicate projection, stale-input validation, correction persistence, cancellation, generation, token, or ABA logic in a view or adapter.
- Preserve all costs-and-payments titles, behavior, selection semantics, accessibility identifiers, process-smoke coverage, and compatibility accessors.
- The default persisted person dossier title remains exactly `Meine Mutter im Pflegeheim`. Never interpolate a person name into the dossier title.
- Entry actions exist only for current `.person` findings in the primary roles `resident`, `insuredPerson`, `accountHolder`, `invoiceRecipient`, and `grantor`. `authorizedPerson` never receives an entry action.
- A stable same-origin selection is an `Öffnen` action. Equal normalized names from other origins remain an `Erstellen` action that can lead to explicit existing-dossier choices plus `Neues Hauptdossier erstellen`.
- Every visible reason is derived from the complete current snapshot. Never display raw support identities, UUIDs, hashes, timestamps, bookmark data, absolute paths, or copied diagnostic evidence in labels or logs.
- Visible actions are native buttons, usable by keyboard, and never available only from context menus. Text uses scalable native styles and wraps rather than truncates.
- Successful create/open moves VoiceOver focus to the person workspace heading. Accept, reject, remove, and reset move focus to the resulting row or containing section and post one privacy-safe German announcement.
- The process smoke uses condition-based waits, never fixed sleeps. Durable database counts/state evidence is read-only and collected only after the launched app has terminated; while the app is running, the existing read-only probe may retrieve only persisted UUIDs needed to address dynamic accessibility identifiers after the corresponding UI row is stable.
- For every behavior change: write the behavioral test first, run it and observe the intended failure, implement the minimum change, then rerun focused tests.
- If any unexpected failure appears during implementation, stop and apply `superpowers:systematic-debugging` before editing production code.
- Final verification for this production/UI pull request is: focused suites, `swift test`, `swift build -c release`, the exact README `xcodebuild` UI-smoke command, `git diff --check`, `git diff --cached --check`, and `git status --short`.

---

## Verified Starting Point

- `main`, `origin/main`, and merge-base: `a227892` (`feat(dossier): orchestrate person workspace in AppModel (#49)`).
- Working tree at plan creation: only `?? docs/superpowers/plans/2026-09-10-person-dossier-app-model-orchestration.md`.
- PR 1 through PR 4 are present: typed person anchors, indexed candidates/projector, atomic repository commands, typed workspace state, guarded create/choose/load/navigation/mutation APIs, reanalysis refresh, and source-removal lifecycle.
- Production currently builds only `CurrentDossierService`; `AppModel` receives neither `personDossierLoader` nor `personDossierMutator`, so the person feature is intentionally unreachable.
- `ContentView` routes every `.dossier` selection to `CostsAndPaymentsDossierView`; `WorkspaceSidebar` renders only `model.dossiers`; `DocumentDNAInspector` exposes only the costs entry action.
- There is no `PersonDossierView`, person presentation layer, accessibility focus state, or person-specific XCUITest workflow.
- The existing UI smoke already proves costs-dossier creation/correction, restart, DNA retry, source removal, and exact filesystem snapshots. It must remain green as an independent regression test.

## File Responsibility Map

- Modify `Sources/LinkLoomApp/LinkLoomApp.swift`: add `CurrentPersonDossierService`, construct one shared `DossierRepository`, inject both person ports, and keep UI-test dynamic-type overrides compile-time isolated.
- Modify `Tests/LinkLoomAppTests/AppCompositionTests.swift`: prove exact forwarding, error propagation, and pre-mutation cancellation for every person adapter method.
- Create `Sources/LinkLoomAppFeature/PersonDossierPresentation.swift`: own entry eligibility/titles, sidebar item projection, role/origin/availability copy, member/suggestion/correction reasons, deterministic IDs, focus destinations, and announcements.
- Create `Tests/LinkLoomAppFeatureTests/PersonDossierPresentationTests.swift`: exhaustively lock presentation and focus behavior without requiring SwiftUI view introspection.
- Modify `Sources/LinkLoomAppFeature/ScanDashboard.swift` and `Tests/LinkLoomAppFeatureTests/ScanDashboardTests.swift`: retain each displayed fact's original deterministic finding index so its entry action stays attached to the exact person finding.
- Modify `Sources/LinkLoomAppFeature/DocumentDNAInspector.swift`: render one entry action per eligible person finding and the same-name choice UI.
- Modify `Sources/LinkLoomAppFeature/WorkspaceSidebar.swift`: render mixed costs/person rows in one `Dossiers` section.
- Modify `Sources/LinkLoomAppFeature/ContentView.swift`: dispatch the typed snapshot or known summary kind to the correct dossier view while retaining the shared inspector.
- Create `Sources/LinkLoomAppFeature/PersonDossierView.swift`: render anchor, direct documents, costs/payments, suggestions, corrections, navigation, mutations, retry, focus, and announcements.
- Modify `Sources/LinkLoomAppFeature/UITestLaunchConfiguration.swift` and `Tests/LinkLoomAppFeatureTests/UITestLaunchConfigurationTests.swift`: add a compile-time UI-test-only accessibility text-size switch.
- Modify `LinkLoomUITests/Support/SmokeFixture.swift`: add a separate person-dossier corpus plus hidden entries and a symbolic link under the temporary source.
- Modify `LinkLoomUITests/Support/SQLiteProbe.swift`: add person-dossier IDs and relational persistence/cascade evidence without exposing source content in diagnostics.
- Modify `LinkLoomUITests/LinkLoomUISmokeTests.swift`: add the full person create/decide/navigate/restart/reanalyze/reset/remove/integrity workflow while retaining the existing smoke unchanged.
- Modify `README.md`: document the visible main-dossier workflow, correction semantics, unavailable-origin behavior, local-only guarantees, and authoritative smoke command.

---

### Task 1: Wire the Person Repository into Production Composition

**Files:**

- Modify: `Sources/LinkLoomApp/LinkLoomApp.swift`
- Modify: `Tests/LinkLoomAppTests/AppCompositionTests.swift`

**Interfaces:**

- Consumes: the exact `DossierRepository` methods declared in `Sources/LinkLoomCore/Persistence/DossierRepository.swift`: `personDossierSummaries()`, `personDossierSnapshot(id:)`, `createOrOpenPersonDossier(from:)`, `chooseOrCreatePersonDossier(from:choice:)`, and the four dossier/document/support-or-decision/token mutation methods.
- Produces: `CurrentPersonDossierService: PersonDossierLoading, PersonDossierMutating`.
- Produces: one shared `DossierRepository` instance injected through both costs and person adapters into `AppModel`.

- [ ] **Step 1: Write failing adapter-forwarding tests**

Add a `PersonDossierServiceRecorder` actor and a local deterministic `PersonCompositionValues` fixture to `AppCompositionTests.swift`. The fixture exposes one valid `selection`, `summary`, `snapshot`, `suggestion`, `member`, and `correction`; build them with the same public/Core-internal constructors used in `Tests/LinkLoomAppFeatureTests/PersonDossierAppModelTestSupport.swift`, but keep the fixture local to the app test target.

Add these exact behavioral tests:

```swift
@Test func personDossierServiceForwardsReadsExactlyOnce() async throws {
    let values = try PersonCompositionValues.make()
    let recorder = PersonDossierServiceRecorder()
    let service = personDossierService(
        summaries: {
            await recorder.recordSummaries()
            return [values.summary]
        },
        snapshot: { id in
            await recorder.recordSnapshot(id)
            return values.snapshot
        }
    )

    #expect(try await service.personDossierSummaries() == [values.summary])
    #expect(try await service.personDossierSnapshot(id: values.summary.id) == values.snapshot)
    #expect(await recorder.summaryCalls == 1)
    #expect(await recorder.snapshotIDs == [values.summary.id])
}

@Test func personDossierServiceForwardsEveryExactMutationInput() async throws {
    let values = try PersonCompositionValues.make()
    let recorder = PersonDossierServiceRecorder()
    let service = personDossierService(recorder: recorder, returning: values.snapshot)

    _ = try await service.createOrOpenPersonDossier(from: values.selection)
    _ = try await service.chooseOrCreatePersonDossier(
        from: values.selection,
        choice: .new
    )
    _ = try await service.acceptPersonSuggestion(
        dossierID: values.snapshot.dossier.id,
        documentID: values.suggestion.id,
        expectedSupport: values.suggestion.commandSupport,
        expectedToken: values.snapshot.token
    )
    _ = try await service.rejectPersonSuggestion(
        dossierID: values.snapshot.dossier.id,
        documentID: values.suggestion.id,
        expectedSupport: values.suggestion.commandSupport,
        expectedToken: values.snapshot.token
    )
    _ = try await service.removePersonMember(
        dossierID: values.snapshot.dossier.id,
        documentID: values.member.id,
        expectedSupport: try values.member.commandSupport,
        expectedToken: values.snapshot.token
    )
    _ = try await service.resetPersonCorrection(
        dossierID: values.snapshot.dossier.id,
        documentID: values.correction.id,
        expectedDecision: values.correction.decision,
        expectedToken: values.snapshot.token
    )

    #expect(await recorder.openSelections == [values.selection])
    #expect(await recorder.choices == [.new])
    #expect(await recorder.acceptedSupports == [values.suggestion.commandSupport])
    #expect(await recorder.rejectedSupports == [values.suggestion.commandSupport])
    #expect(await recorder.removedSupports == [try values.member.commandSupport])
    #expect(await recorder.resetDecisions == [values.correction.decision])
    #expect(await recorder.tokens == Array(repeating: values.snapshot.token, count: 4))
}
```

Also add one table-driven cancellation test that starts each of the six mutation methods in an already-cancelled `Task`, expects `CancellationError`, and asserts that no mutation closure ran. Add one failure test proving an injected repository error is propagated unchanged by a read and by a mutation.

Define the two local test constructors in this task with these exact signatures so no later task depends on app-test fixtures:

```swift
private struct PersonCompositionValues {
    let selection: PersonDossierAnchorSelection
    let summary: PersonDossierSummary
    let snapshot: PersonDossierSnapshot
    let suggestion: PersonDossierSuggestion
    let member: PersonDossierMember
    let correction: PersonDossierCorrection

    static func make() throws -> Self
}

private func personDossierService(
    recorder: PersonDossierServiceRecorder,
    returning snapshot: PersonDossierSnapshot
) -> CurrentPersonDossierService
```

The closure-based `CurrentPersonDossierService` initializer used by this helper has the same eight closure parameters and argument order as the stored properties in Step 3.

- [ ] **Step 2: Run the app composition suite and verify RED**

Run:

```sh
swift test --filter AppCompositionTests
```

Expected: compilation fails because `CurrentPersonDossierService` and the test helper `personDossierService(recorder:returning:)` do not exist.

- [ ] **Step 3: Implement the minimal person adapter**

Add this concrete shape beside `CurrentDossierService` in `LinkLoomApp.swift`:

```swift
struct CurrentPersonDossierService: PersonDossierLoading, PersonDossierMutating {
    private let loadSummaries: @Sendable () async throws -> [PersonDossierSummary]
    private let loadSnapshot: @Sendable (UUID) async throws -> PersonDossierSnapshot
    private let open: @Sendable (PersonDossierAnchorSelection) async throws
        -> PersonDossierOpenResult
    private let choose: @Sendable (
        PersonDossierAnchorSelection, PersonDossierCreationChoice
    ) async throws -> PersonDossierSnapshot
    private let accept: @Sendable (
        UUID, UUID, PersonDossierCandidateSupportIdentity, PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot
    private let reject: @Sendable (
        UUID, UUID, PersonDossierCandidateSupportIdentity, PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot
    private let remove: @Sendable (
        UUID, UUID, PersonDossierMembershipSupport, PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot
    private let reset: @Sendable (
        UUID, UUID, PersonDossierCorrectionDecision, PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot
}
```

Provide one `init(repository: DossierRepository)` that forwards all eight repository calls and one closure initializer with the same parameter order for tests. Reads forward directly. Every mutation starts with `try Task.checkCancellation()` and then invokes exactly one stored closure. Do not map errors or reconstruct support/token values.

In `makeModel`, replace the separate inline repository construction with:

```swift
let dossierRepository = DossierRepository(dbWriter: database, target: dnaTarget)
let dossierService = CurrentDossierService(repository: dossierRepository)
let personDossierService = CurrentPersonDossierService(repository: dossierRepository)
```

Pass `personDossierLoader: personDossierService` and `personDossierMutator: personDossierService` to `AppModel` without changing any other dependency.

- [ ] **Step 4: Run focused GREEN and production regression tests**

Run:

```sh
swift test --filter AppCompositionTests
swift test --filter 'PersonDossierAppModelTests|AppModelTests|DossierAppStateTests'
```

Expected: all tests pass; production composition now loads person summaries and supports commands, but no visible person entry point exists yet.

- [ ] **Step 5: Commit only the adapter and its tests**

```sh
git add Sources/LinkLoomApp/LinkLoomApp.swift Tests/LinkLoomAppTests/AppCompositionTests.swift
git diff --cached --name-only
git commit -m "feat(app): compose person dossier service"
```

The staged-name output must contain exactly the two paths above.

---

### Task 2: Prepare the Hermetic Person-Smoke Fixture and Accessibility Test Mode

**Files:**

- Modify: `Sources/LinkLoomAppFeature/UITestLaunchConfiguration.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/UITestLaunchConfigurationTests.swift`
- Modify: `Sources/LinkLoomApp/LinkLoomApp.swift`
- Modify: `LinkLoomUITests/Support/SmokeFixture.swift`
- Modify: `LinkLoomUITests/Support/SQLiteProbe.swift`
- Modify: `LinkLoomUITests/LinkLoomUISmokeTests.swift`

**Interfaces:**

- Produces: `UITestLaunchConfiguration.usesAccessibilityTextSize` from the valueless `--linkloom-ui-test-accessibility-text` argument.
- Produces: `SmokeFixture.personDossier()` with one source containing the exact synthetic files listed below plus hidden entries and a symbolic link.
- Produces: `SQLiteProbe.personDossierEvidence()` and kind-specific dossier/document ID queries.
- Produces: compile-green fixture/probe contracts that the incrementally extended `testPersonDossierWorkflowPersistsAndPreservesSourceFiles()` consumes in Tasks 3–5.

- [ ] **Step 1: Write the failing launch-configuration tests**

Add assertions that the new flag is false by default, true when present once, and throws `.duplicateArgument("--linkloom-ui-test-accessibility-text")` when repeated:

```swift
let configuration = try UITestLaunchConfiguration(arguments: [
    "LinkLoom", "--linkloom-ui-test-accessibility-text",
])
#expect(configuration.usesAccessibilityTextSize)
```

Run `swift test --filter UITestLaunchConfigurationTests` and verify RED because the property is absent.

- [ ] **Step 2: Implement the compile-time-isolated text-size switch**

Extend the parser with:

```swift
public let usesAccessibilityTextSize: Bool
```

Parse the flag with the existing duplicate-argument rules. Under `#if LINKLOOM_UI_TESTING`, retain the parsed configuration on `LinkLoomApp` and apply this only to the ready `ContentView`:

```swift
.environment(
    \.dynamicTypeSize,
    configuration?.usesAccessibilityTextSize == true ? .accessibility5 : .large
)
```

The non-UI-test build must not read this flag or force a dynamic type size. Rerun `UITestLaunchConfigurationTests` and `swift build -c release`; both must pass.

- [ ] **Step 3: Add the dedicated person smoke fixture**

Keep `SmokeFixture()` and `prepareDefaultSource` unchanged for the existing costs smoke. Add `static func personDossier() throws -> SmokeFixture` backed by a named preparation closure that creates these fictional documents:

| Relative path | Exact labelled content and purpose |
| --- | --- |
| `anchor-care.pdf` | `Pflegebericht`, `Bewohnerin: Elise Muster`, `Geburtsdatum: 14.03.1942`; selected anchor and exact evidence |
| `invoices/care-home-invoice.pdf` | `Rechnung`, `Rechnungsnummer: PFLEGE-2026-001`, `CHF 1250`, `Ausstellerin: Pflegeheim Sonnengarten`, `Rechnung an: Elise Muster`; automatic financial member |
| `payments/payment-confirmation.pdf` | `Zahlungsbestätigung`, `Zahlungsreferenz: PFLEGE-2026-001`, `CHF 1250`, `Zahlungsempfängerin: Pflegeheim Sonnengarten`; one-hop confirmed payment |
| `insurance.pdf` | `Leistungsabrechnung`, `Versicherte Person: Elise Muster`; removable/resettable automatic member |
| `power-of-attorney.pdf` | `Vollmacht`, `Bevollmächtigte: Elise Muster`; secondary-role suggestion to accept |
| `conflicting-insurance.pdf` | `Leistungsabrechnung`, `Versicherte Person: Elise Muster`, `Geburtsdatum: 02.01.1950`; hard-conflict suggestion to reject |
| `scan.png` | high-contrast `Bewohnerin: Elise Muster`; OCR-backed direct member and text-layout coverage |
| `corrupt.pdf` | malformed PDF bytes; ingestion failure regression |

Also create `.hidden-evidence`, an empty `.hidden-directory`, and `anchor-link` as a relative symbolic link to `anchor-care.pdf`. Their names avoid supported extensions so catalog counts remain deterministic, while the integrity snapshot necessarily covers hidden files, hidden directories, link kind, and destination.

Use the existing PDF/image writers. Validate every generated PDF with `PDFDocument`, except `corrupt.pdf`. Do not copy fixture files into the database or application bundle.

- [ ] **Step 4: Add relational SQLite evidence for the person workflow**

Keep `SmokeDatabaseEvidence` unchanged for the old test. Add:

```swift
struct PersonDossierSmokeEvidence: CustomStringConvertible {
    let sourceCount: Int
    let documentCount: Int
    let personAnchorCount: Int
    let personAnchorEvidenceCount: Int
    let personDossierCount: Int
    let costsDossierCount: Int
    let confirmationCount: Int
    let exclusionCount: Int
    let confirmedRelationshipCount: Int
    let originDocumentStillCatalogued: Int
}
```

`personDossierEvidence()` must use joins and exact kinds, not total dossier assumptions:

```sql
SELECT COUNT(*) FROM dossier WHERE kind = 'personMatter';
SELECT COUNT(*) FROM dossier WHERE kind = 'costsAndPayments';
SELECT COUNT(*) FROM personDossierAnchor;
SELECT COUNT(*) FROM personDossierAnchorEvidence;
SELECT COUNT(*) FROM dossierMembershipConfirmation;
SELECT COUNT(*) FROM dossierMembershipExclusion;
SELECT COUNT(*) FROM invoicePaymentUserDecision
 WHERE relationshipType = 'paymentSettlesInvoice' AND decision = 'confirmed';
```

Add `documentID(relativePath: String)`, `onlyDossierID(kind: String)`, and `personAnchorOriginDocumentID()` queries. After the pre-removal workflow, evidence must prove one person dossier, one costs dossier, one accepted confirmation, one rejected-suggestion exclusion, no leftover exclusion for the reset automatic member, one confirmed relationship, and the origin document still catalogued. After source removal, it must prove zero sources/documents/Document-DNA/relationship decisions/costs dossiers/confirmations/exclusions, but exactly one person anchor, its two copied evidence rows, and one person dossier whose origin document ID equals the saved pre-removal ID.

Generalize the existing test mutator to `makeDocumentDNAFailureRetryable(databaseURL:relativePath:)`, bind the relative path as a SQLite parameter in both the delete and update, and require exactly one changed row per statement. Keep `makeSelectableDocumentDNAFailureRetryable(databaseURL:)` as a compatibility wrapper passing `selectable.pdf`, so the old costs smoke remains unchanged.

- [ ] **Step 5: Add fixture-level tests before launching the app**

Add `testPersonDossierFixtureIntegritySnapshotIncludesEveryEntryKind()` beside the current snapshot helper tests. Assert the person fixture snapshot includes all eight regular files, `invoices`, `payments`, `.hidden-evidence`, `.hidden-directory`, and `anchor-link`; assert the link's kind/destination, both hidden kinds, and non-nil SHA-256/byte count/modification date/POSIX mode for every regular file. Create a second snapshot without changing the fixture and assert exact equality.

This test is RED before `SmokeFixture.personDossier()` exists and GREEN after Step 3. Do not launch `XCUIApplication` yet; the feature workflow starts in Task 3 so this task can end with all tests green.

- [ ] **Step 6: Run fixture, parser, release, and existing-smoke GREEN**

Run:

```sh
swift test --filter UITestLaunchConfigurationTests
swift build -c release
xcodebuild test \
  -project LinkLoom.xcodeproj \
  -scheme LinkLoomUISmoke \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/LinkLoomDerivedData \
  -resultBundlePath /tmp/LinkLoomPersonFixture.xcresult \
  -only-testing:LinkLoomUITests/LinkLoomUISmokeTests/testPersonDossierFixtureIntegritySnapshotIncludesEveryEntryKind
```

Expected: all commands exit 0. Run the existing costs product-smoke test once as a regression because the launch helper and composition root changed.

- [ ] **Step 7: Commit the green test infrastructure**

```sh
git add Sources/LinkLoomAppFeature/UITestLaunchConfiguration.swift Tests/LinkLoomAppFeatureTests/UITestLaunchConfigurationTests.swift Sources/LinkLoomApp/LinkLoomApp.swift LinkLoomUITests/Support/SmokeFixture.swift LinkLoomUITests/Support/SQLiteProbe.swift LinkLoomUITests/LinkLoomUISmokeTests.swift
git diff --cached --name-only
git commit -m "test(ui): add person dossier smoke fixture"
```

The protected 2026-09-10 plan must not appear in the staged-name output.

---

### Task 3: Add Per-Person Entry Actions and Same-Name Choices

**Files:**

- Create: `Sources/LinkLoomAppFeature/PersonDossierPresentation.swift`
- Create: `Tests/LinkLoomAppFeatureTests/PersonDossierPresentationTests.swift`
- Modify: `Sources/LinkLoomAppFeature/ScanDashboard.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/ScanDashboardTests.swift`
- Modify: `Sources/LinkLoomAppFeature/DocumentDNAInspector.swift`
- Modify: `LinkLoomUITests/LinkLoomUISmokeTests.swift`

**Interfaces:**

- Produces: `PersonDossierEntryPresentation.entries(document:snapshot:summaries:)`.
- Produces: deterministic zero-based eligible-person ordinals and `document-dna.person-dossier.<ordinal>` identifiers.
- Consumes: `AppModel.openOrCreatePersonDossier(from:)`, `choosePersonDossier(id:)`, `createNewPersonDossier()`, `personDossierChoices`, and `dossierMutationState`.

- [ ] **Step 1: Write failing entry-presentation tests**

Create `PersonDossierPresentationTests.swift` and cover all six roles plus invalid/current-input boundaries. Use a snapshot whose finding order interleaves document type, organization, primary people, `authorizedPerson`, and dates. Assert:

```swift
let entries = PersonDossierEntryPresentation.entries(
    document: document,
    snapshot: dna,
    summaries: summaries
)

#expect(entries.map(\.ordinal) == [0, 1, 2, 3, 4])
#expect(entries.map(\.findingIndex) == [1, 3, 5, 6, 8])
#expect(entries.map(\.actionTitle) == [
    "Hauptdossier öffnen",
    "Hauptdossier erstellen",
    "Hauptdossier erstellen",
    "Hauptdossier erstellen",
    "Hauptdossier erstellen",
])
#expect(entries.map(\.accessibilityIdentifier) == [
    "document-dna.person-dossier.0",
    "document-dna.person-dossier.1",
    "document-dna.person-dossier.2",
    "document-dna.person-dossier.3",
    "document-dna.person-dossier.4",
])
#expect(entries.allSatisfy { $0.selection.support.documentID == document.id })
```

Also assert that `authorizedPerson`, unsupported/missing qualifiers, empty evidence, stale content hash, and a snapshot for another document produce no entry. An exact same-origin triple `(originDocumentID, primaryRole, normalizedName)` yields `Öffnen`; same normalized name from another origin yields `Erstellen`.

In `LinkLoomUISmokeTests.swift`, start `testPersonDossierWorkflowPersistsAndPreservesSourceFiles()` with the person fixture and initial integrity snapshot. Drive source add/scan, select the invoice, confirm the payment candidate, create the existing costs dossier, return to the source, select `anchor-care.pdf`, and require `document-dna.person-dossier.0` with an accessibility label containing `Elise Muster` and `Bewohnerin`. Click it, retrieve only the newly persisted person dossier UUID through `onlyDossierID(kind: "personMatter")`, and require its existing `dossier.row.<uuid>` sidebar row. Return to the invoice finding from the other origin, require its action title to remain `Hauptdossier erstellen`, click it, require the offered existing dossier plus the visible `Neues Hauptdossier erstellen` alternative, choose the existing dossier, and assert the database still has exactly one person anchor/dossier. Terminate and compare the filesystem snapshot exactly. Do not add later workspace assertions yet.

- [ ] **Step 2: Run the presentation test and verify RED**

Run:

```sh
swift test --filter PersonDossierPresentationTests
xcodebuild test \
  -project LinkLoom.xcodeproj \
  -scheme LinkLoomUISmoke \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/LinkLoomDerivedData \
  -resultBundlePath /tmp/LinkLoomPersonEntryRed.xcresult \
  -only-testing:LinkLoomUITests/LinkLoomUISmokeTests/testPersonDossierWorkflowPersistsAndPreservesSourceFiles
```

Expected: the Swift test fails to compile because `PersonDossierEntryPresentation` is absent. Independently, the Xcode process test reaches scan/costs creation and fails specifically on the absent `document-dna.person-dossier.0`. Fix fixture or harness failures before production work.

- [ ] **Step 3: Implement the minimal entry projection**

Use this shape:

```swift
struct PersonDossierEntryPresentation: Identifiable, Equatable {
    var id: Int { ordinal }
    let ordinal: Int
    let findingIndex: Int
    let displayName: String
    let roleTitle: String
    let actionTitle: String
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let selection: PersonDossierAnchorSelection

    static func entries(
        document: DocumentRecord,
        snapshot: DocumentDNA,
        summaries: [PersonDossierSummary]
    ) -> [Self]
}
```

Enumerate only eligible `.person` findings in their deterministic snapshot order, retain each finding's original `snapshot.findings` index, and assign ordinals after filtering. Build each `PersonDossierAnchorSelection`; discard construction failures. Determine `Öffnen` only by the stable origin triple, never by display/normalized name alone. Map primary roles to `Bewohnerin`, `Versicherte Person`, `Kontoinhaberin`, `Rechnungsempfängerin`, and `Vollmachtgeberin`. The accessibility label concatenates the computed action title, `für`, the finding display value, `Rolle`, and the mapped role title.

- [ ] **Step 4: Render the action beside its exact person fact**

In `ScanDashboard.swift`, add `sourceFindingIndex: Int` to `DocumentDNAFactPresentation` and build `facts` with `snapshot.findings.enumerated().compactMap`, retaining the original index while continuing to omit `.documentType`. Update `ScanDashboardTests` to assert the source indexes. In `DocumentDNAInspector`, derive entries from the currently displayed `document` and `.available(snapshot)`, then match `entry.findingIndex` to `fact.sourceFindingIndex`. Render each action immediately after the matching eligible person fact, not once at document level. Keep the existing finding/evidence order and costs entry content unchanged.

Add local state:

```swift
@State private var pendingPersonSelection: PersonDossierAnchorSelection?
```

On click, set the pending selection, await `model.openOrCreatePersonDossier(from:)`, then retain it only when `model.personDossierChoices` is non-empty. While `.openingPerson(documentID:)`, disable every person entry button and show `Hauptdossier wird geöffnet …` for the selected entry.

Below that selected entry only, render the offered matching dossiers with title plus anchor display name, each calling `choosePersonDossier(id:)`, and a visible `Neues Hauptdossier erstellen` button calling `createNewPersonDossier()`. Clear local pending selection on document ID or DNA input-identity change. Do not persist anything from the view.

- [ ] **Step 5: Run focused GREEN and advance the process smoke**

Run:

```sh
swift test --filter 'PersonDossierPresentationTests|DossierPresentationTests|ScanDashboardTests'
xcodebuild test \
  -project LinkLoom.xcodeproj \
  -scheme LinkLoomUISmoke \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/LinkLoomDerivedData \
  -resultBundlePath /tmp/LinkLoomPersonEntry.xcresult \
  -only-testing:LinkLoomUITests/LinkLoomUISmokeTests/testPersonDossierWorkflowPersistsAndPreservesSourceFiles
```

Expected: Swift tests and the bounded process workflow pass. The click persists one person anchor/dossier and adds the person sidebar summary, while the test intentionally makes no person-workspace rendering claim yet.

- [ ] **Step 6: Commit the entry slice**

```sh
git add Sources/LinkLoomAppFeature/PersonDossierPresentation.swift Tests/LinkLoomAppFeatureTests/PersonDossierPresentationTests.swift Sources/LinkLoomAppFeature/ScanDashboard.swift Sources/LinkLoomAppFeature/DocumentDNAInspector.swift Tests/LinkLoomAppFeatureTests/ScanDashboardTests.swift LinkLoomUITests/LinkLoomUISmokeTests.swift
git diff --cached --name-only
git commit -m "feat(dossier): add person finding entry actions"
```

---

### Task 4: Route Person Dossiers and Render the Anchor and Members

**Files:**

- Modify: `Sources/LinkLoomAppFeature/PersonDossierPresentation.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/PersonDossierPresentationTests.swift`
- Modify: `Sources/LinkLoomAppFeature/WorkspaceSidebar.swift`
- Modify: `Sources/LinkLoomAppFeature/ContentView.swift`
- Create: `Sources/LinkLoomAppFeature/PersonDossierView.swift`
- Modify: `LinkLoomUITests/LinkLoomUISmokeTests.swift`

**Interfaces:**

- Produces: `WorkspaceDossierSidebarItem`, `DossierWorkspaceViewKind`, `PersonDossierAnchorPresentation`, `PersonDossierMemberPresentation`, and `PersonDossierAccessibilityIdentifier`.
- Consumes: typed `DossierWorkspaceSnapshot`, costs/person summaries, and `AppModel.selectPersonDossierDocument(documentID:)`.

- [ ] **Step 1: Write failing sidebar, routing, anchor, member, and ID tests**

Add tests that prove:

- mixed costs and person summaries sort by dossier `createdAt`, then lowercase UUID, while costs subtitle remains the anchor relative path and person subtitle is `anchor.displayName`;
- `DossierWorkspaceViewKind` returns `.personMatter` from a person snapshot or known person summary ID even during initial loading/failure, and `.costsAndPayments` for existing costs behavior;
- current/stale/unavailable origin maps exactly to `Ursprungsnachweis aktuell`, `Ursprungsnachweis veraltet`, and `Ursprungsnachweis nicht verfügbar`;
- available/unavailable/missing maps to `Verfügbar`, `Vorübergehend nicht verfügbar`, and `Fehlt`;
- member location is relative path for the selected source and `source · relative/path` cross-source;
- direct, manual, and confirmed-payment supports produce all ordered reasons, with no UUID/hash/timestamp text;
- every person identifier uses lowercase persisted UUID strings.

Lock these identifiers:

```swift
dossier.person.workspace
dossier.person.anchor
dossier.person.direct-members
dossier.person.costs
dossier.person.member.<uuid>
dossier.person.member.remove.<uuid>
dossier.person.member.<uuid>.counterpart
dossier.person.member.<uuid>.reason.<ordinal>
```

Extend the existing person process test after the entry click: require `dossier.person.workspace`, title `Meine Mutter im Pflegeheim`, `dossier.person.anchor`, both member sections, every expected direct/financial member ID, every reason ID/label, navigation from the OCR member to its exact person evidence, and the payment row's counterpart navigation back to the invoice. Keep the dossier workspace selected throughout and compare the source snapshot after both navigation paths.

Run `swift test --filter PersonDossierPresentationTests`; expected RED on missing presentation/routing types. Run the focused Xcode process command from Task 3; expected RED on missing `dossier.person.workspace`. These are the only accepted RED boundaries.

- [ ] **Step 2: Implement pure mixed-sidebar and workspace routing**

Define:

```swift
enum WorkspaceDossierSidebarItem: Identifiable, Equatable {
    case costs(DossierSummary)
    case person(PersonDossierSummary)

    var id: UUID { dossier.id }
    var dossier: DossierRecord {
        switch self {
        case .costs(let summary): summary.dossier
        case .person(let summary): summary.dossier
        }
    }
    var subtitle: String {
        switch self {
        case .costs(let summary): summary.anchor.relativePath
        case .person(let summary): summary.anchor.displayName
        }
    }
}

enum DossierWorkspaceViewKind: Equatable {
    case costsAndPayments
    case personMatter

    init(
        selection: AppWorkspaceSelection?,
        detail: DossierDetailState,
        personSummaries: [PersonDossierSummary]
    )
}
```

Use an exhaustive switch rather than optional person fields. `WorkspaceSidebar` renders the mixed collection inside the existing `Dossiers` section, keeps `.tag(.dossier(id))`, and keeps `DossierAccessibilityIdentifier.row(id)` unchanged for both kinds. A person row shows the fixed dossier title and person subtitle; a costs row remains byte-for-byte equivalent in visible copy.

`ContentView` switches on `DossierWorkspaceViewKind` for dossier selections and instantiates `PersonDossierView(model:)` or `CostsAndPaymentsDossierView(model:)`. Source/nil selections still render `ScanDashboard`. Keep the one shared `.inspector` modifier at the top level rather than embedding an inspector in either workspace; this preserves the platform's on-demand inspector collapse before primary workspace content is compressed. In the process test, narrow the window to the declared 900-point minimum, open and close the inspector through document selection, and assert the workspace remains scrollable and expands again after dismissal.

- [ ] **Step 3: Implement anchor and member presentations**

Add:

```swift
struct PersonDossierAnchorPresentation: Equatable {
    let displayName: String
    let roleTitle: String
    let evidenceValidityTitle: String
    let sourceAvailabilityTitle: String?
    let accessibilityLabel: String
}

struct PersonDossierMemberPresentation: Equatable {
    let documentID: UUID
    let location: String
    let documentTypeTitle: String
    let availabilityTitle: String
    let membershipRoleTitle: String
    let reasons: [String]
    let preferredCounterpartDocumentID: UUID?
    let accessibilityLabel: String
}
```

For `.exactPrimary`, format `Der Name ‹<display>› stimmt exakt mit dem Personenanker überein. Rolle: <role>.` from the current finding. For `.manualConfirmation`, show `Von dir aus einem Vorschlag aufgenommen.` and, when `currentCandidate == nil`, additionally `Der ursprüngliche Vorschlagsnachweis ist nicht mehr aktuell.` For `.confirmedPayment`, name the supporting invoice by its snapshot relative path, explain the invoice's person basis, and append existing signal titles/comparisons using `InvoicePaymentSignalPresentation`. Retain all supports in their snapshot order; do not collapse multiple independent reasons.

- [ ] **Step 4: Create the workspace shell and member navigation**

`PersonDossierView` uses a `ScrollView` containing, in exact order:

1. fixed dossier title and person anchor block;
2. `Direkte Dokumente` with identifier `dossier.person.direct-members`;
3. `Kosten und Zahlungen` with identifier `dossier.person.costs`;
4. suggestions;
5. corrections.

Render empty section copy rather than omitting the first two sections. Each member row shows source/path, document type, availability, membership role, and every concise reason with `.fixedSize(horizontal: false, vertical: true)`. The whole document summary is a plain `Button` calling `selectPersonDossierDocument(documentID:)`. For a preferred payment support, add `Gegenstück anzeigen`, calling the same AppModel method with the supporting invoice ID. Show `Aus Dossier entfernen` for every member except `snapshot.anchor.originDocumentID`; call `removePersonDossierMember(_:)` and disable while any dossier mutation is active.

The view reads the last complete person snapshot from `dossierDetailState.personSnapshot`; `.loading` overlays `Hauptdossier wird aktualisiert …`; `.failed` preserves the snapshot, shows the privacy-safe error under `dossier.person.error`, and provides `Erneut versuchen` calling `refreshSelectedDossier()`.

- [ ] **Step 5: Run focused GREEN and advance the smoke**

Run:

```sh
swift test --filter 'PersonDossierPresentationTests|DossierPresentationTests|DossierAppStateTests'
swift test --filter 'PersonDossierAppModelTests|AppModelTests'
```

Then rerun the complete `xcodebuild test` command shown in Task 3 Step 5, including its `-only-testing:LinkLoomUITests/LinkLoomUISmokeTests/testPersonDossierWorkflowPersistsAndPreservesSourceFiles` argument.

Expected: routing, sidebar, anchor, direct/costs sections, member navigation, counterpart navigation, and the bounded process workflow all pass. Suggestion/correction assertions are added only at the start of Task 5.

- [ ] **Step 6: Commit routing and read-only workspace UI**

```sh
git add Sources/LinkLoomAppFeature/PersonDossierPresentation.swift Tests/LinkLoomAppFeatureTests/PersonDossierPresentationTests.swift Sources/LinkLoomAppFeature/WorkspaceSidebar.swift Sources/LinkLoomAppFeature/ContentView.swift Sources/LinkLoomAppFeature/PersonDossierView.swift LinkLoomUITests/LinkLoomUISmokeTests.swift
git diff --cached --name-only
git commit -m "feat(dossier): present person workspace"
```

---

### Task 5: Add Suggestions, Corrections, Focus, and VoiceOver Announcements

**Files:**

- Modify: `Sources/LinkLoomAppFeature/PersonDossierPresentation.swift`
- Modify: `Tests/LinkLoomAppFeatureTests/PersonDossierPresentationTests.swift`
- Modify: `Sources/LinkLoomAppFeature/PersonDossierView.swift`
- Modify: `LinkLoomUITests/LinkLoomUISmokeTests.swift`

**Interfaces:**

- Produces: `PersonDossierSuggestionPresentation`, `PersonDossierCorrectionPresentation`, `PersonDossierFocusTarget`, and `PersonDossierMutationOutcome`.
- Consumes: PR 4 accept/reject/remove/reset AppModel commands and complete replacement snapshots.
- Produces: native accessibility focus changes plus `NSAccessibility.Notification.announcementRequested` after successful state changes.

- [ ] **Step 1: Write failing suggestion/correction/focus tests**

For secondary-role and birth-date-conflict suggestions, assert exact reason copy and labels. For confirmation and exclusion corrections, assert exact reset titles:

```swift
#expect(secondary.reason == "Der Name stimmt exakt, erscheint aber nur in der Rolle Bevollmächtigte.")
#expect(conflict.reason == "Der Name stimmt, aber dieses Dokument nennt ein anderes Geburtsdatum.")
#expect(confirmation.resetTitle == "Aufnahme zurücksetzen")
#expect(exclusion.resetTitle == "Ausschluss zurücksetzen")
```

Lock identifiers:

```swift
dossier.person.suggestions
dossier.person.suggestion.<uuid>
dossier.person.suggestion.accept.<uuid>
dossier.person.suggestion.reject.<uuid>
dossier.person.corrections
dossier.person.correction.<uuid>
dossier.person.correction.reset.<uuid>
dossier.person.error
```

Define and test outcome resolution against complete post-command snapshots:

```swift
#expect(PersonDossierMutationOutcome.accepted(id, in: accepted).focus == .member(id))
#expect(PersonDossierMutationOutcome.rejected(id, in: rejected).focus == .correction(id))
#expect(PersonDossierMutationOutcome.removed(id, in: removed).focus == .correction(id))
#expect(PersonDossierMutationOutcome.reset(id, in: automatic).focus == .member(id))
#expect(PersonDossierMutationOutcome.reset(id, in: suggested).focus == .suggestion(id))
#expect(PersonDossierMutationOutcome.reset(id, in: hidden).focus == .section(.corrections))
```

Also assert exact privacy-safe announcements: `Dokument aufgenommen.`, `Vorschlag abgelehnt.`, `Dokument aus dem Dossier entfernt.`, and `Korrektur zurückgesetzt.`

Extend `testPersonDossierWorkflowPersistsAndPreservesSourceFiles()` from its Task 4 stopping point through the complete accepted workflow:

1. accept `power-of-attorney.pdf` and require its suggestion row to become a member plus confirmation correction;
2. reject `conflicting-insurance.pdf` and require its suggestion row to become an exclusion correction;
3. remove `insurance.pdf`, require the member to become an exclusion correction, reset that exact correction, and require the automatic member to return while that correction disappears;
4. compare the fixture snapshot after every create/accept/reject/remove/reset/navigation phase;
5. terminate, assert one person dossier, one costs dossier, one confirmation, one exclusion, one confirmed relationship, and the original catalogued anchor; relaunch and verify both durable corrections and the restored member;
6. terminate, call `makeDocumentDNAFailureRetryable(databaseURL:relativePath:)` for `anchor-care.pdf`, confirm the source snapshot is unchanged, relaunch, invoke `Erneut analysieren`, and wait until the person workspace again shows one complete expected member/suggestion/correction set;
7. compare the source snapshot after restart and reanalysis;
8. remove the source through the visible source context menu, require the costs row to disappear, require the person row/workspace to remain, require `Ursprungsnachweis nicht verfügbar`, and require every document-bound member/suggestion/correction row to disappear;
9. terminate, assert zero catalog/document/DNA/relationship/costs/correction rows but one person anchor, its two copied evidence rows, and one person dossier retaining the saved origin UUID; compare the final source snapshot exactly;
10. attach screenshots after initial person projection, decisions, restart, and unavailable-origin projection.

Run the presentation suite and the focused Xcode process test. Expected RED: the unit test reports missing suggestion/correction/focus types and the process test stops at `dossier.person.suggestion.<power-of-attorney-uuid>`. Fixture, entry, routing, membership, and navigation must already be green.

- [ ] **Step 2: Implement suggestion and correction presentations**

Use snapshot values only:

```swift
struct PersonDossierSuggestionPresentation: Equatable {
    let location: String
    let documentTypeTitle: String
    let availabilityTitle: String
    let roleTitle: String
    let reason: String
    let accessibilityLabel: String
}

struct PersonDossierCorrectionPresentation: Equatable {
    let location: String
    let documentTypeTitle: String
    let availabilityTitle: String
    let decisionTitle: String
    let resetTitle: String
    let accessibilityLabel: String
}
```

Suggestion rows are navigable document buttons and expose separate visible `Aufnehmen` and `Ablehnen` buttons. Correction rows are navigable document buttons and expose one decision-specific reset button. Disable all mutation buttons when `dossierMutationState != .idle`; show an inline progress label only on the row whose `(dossierID, documentID)` matches the active mutation case.

- [ ] **Step 3: Implement deterministic focus and announcements**

Define:

```swift
enum PersonDossierSectionFocus: Hashable { case suggestions, corrections }

enum PersonDossierFocusTarget: Hashable {
    case workspace
    case member(UUID)
    case suggestion(UUID)
    case correction(UUID)
    case section(PersonDossierSectionFocus)
}

struct PersonDossierMutationOutcome: Equatable {
    let focus: PersonDossierFocusTarget
    let announcement: String

    static func accepted(_ id: UUID, in snapshot: PersonDossierSnapshot) -> Self
    static func rejected(_ id: UUID, in snapshot: PersonDossierSnapshot) -> Self
    static func removed(_ id: UUID, in snapshot: PersonDossierSnapshot) -> Self
    static func reset(_ id: UUID, in snapshot: PersonDossierSnapshot) -> Self
}
```

In `PersonDossierView`, add:

```swift
@AccessibilityFocusState private var accessibilityFocus: PersonDossierFocusTarget?
```

Attach `.accessibilityFocused` to the workspace heading, every member/suggestion/correction row, and the two fallback section headings. Apply `.accessibilityDefaultFocus($accessibilityFocus, .workspace)` to the workspace heading so successful create/open and sidebar navigation focus it when the person view appears.

Each mutation button captures the current token, awaits exactly one AppModel command, and only when a different complete snapshot is published computes `PersonDossierMutationOutcome`, assigns its focus, and posts:

```swift
NSAccessibility.post(
    element: NSApp as Any,
    notification: .announcementRequested,
    userInfo: [
        .announcement: outcome.announcement,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
    ]
)
```

Do not announce cancellation/failure and do not move focus if the token is unchanged. Accessibility labels combine person/role, availability, reason class, and action outcome, but omit automation UUIDs. Keep heading/focus declaration order identical to visual order.

- [ ] **Step 4: Prove keyboard and layout behavior in the process test**

Add one `requireKeyboardReachable` helper that sends Tab with an upper bound equal to the current visible button count and waits on the macOS accessibility `hasKeyboardFocus == true` attribute; failure attaches the hierarchy. Use it for `Aufnehmen`, `Ablehnen`, `Aus Dossier entfernen`, reset, member navigation, and counterpart navigation.

Implementation acceptance amendment (2026-09-13, explicitly approved): the
visible-button bound is replaced by the current complete AX-button count.
Process evidence showed 16 hittable buttons but the visible confirmation
correction was reached at Tab 18 because five offscreen buttons remained in
AppKit's Tab order; the complete AX-button count was 23. Traversal remains
deterministically bounded, Tab-only, and checks `hasKeyboardFocus` directly after
XCTest's idle-synchronized key event. A short XCTest predicate expectation was
also replaced after a constant-true probe demonstrated that its initial polling
did not occur within 0.2 seconds. No production focus model is changed.

At the fixed minimum window width, assert every anchor/reason/path/action frame is contained in the window or its scroll viewport after scrolling. Require at least one long relationship reason frame to be taller than a single caption line under `.accessibility5`, proving wrapping instead of truncation. Do not infer accessibility from color or icon checks; assert the full labels.

- [ ] **Step 5: Run focused and process-level GREEN**

Run:

```sh
swift test --filter 'PersonDossierPresentationTests|DossierPresentationTests'
swift test --filter 'PersonDossierAppModelTests|AppModelTests|DossierAppStateTests'
xcodebuild test \
  -project LinkLoom.xcodeproj \
  -scheme LinkLoomUISmoke \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/LinkLoomDerivedData \
  -resultBundlePath /tmp/LinkLoomPersonDossierGreen.xcresult \
  -only-testing:LinkLoomUITests/LinkLoomUISmokeTests/testPersonDossierWorkflowPersistsAndPreservesSourceFiles
```

Expected: every command exits 0; the XCUITest completes create/open, decisions, navigation, restart, reanalysis, source removal, unavailable origin, database evidence, and exact filesystem equality.

- [ ] **Step 6: Commit interactive and accessible UI behavior**

```sh
git add Sources/LinkLoomAppFeature/PersonDossierPresentation.swift Tests/LinkLoomAppFeatureTests/PersonDossierPresentationTests.swift Sources/LinkLoomAppFeature/PersonDossierView.swift LinkLoomUITests/LinkLoomUISmokeTests.swift
git diff --cached --name-only
git commit -m "feat(dossier): add accessible person corrections"
```

---

### Task 6: Document the Product Workflow and Run the Complete Acceptance Gate

> Controller/user-approved acceptance amendment (2026-09-13): runtime acceptance
> identified two exact-evidence timestamp codecs requiring precise REAL writes
> and legacy TEXT reads in Core (person anchor analyzedAt and membership
> acceptedDNAAnalyzedAt); no schema migration or tolerance comparison was added.
> A rollback of visible PR5 UI must retain these Core fixes: old generic GRDB
> readers interpret numeric dates as Unix rather than reference-date seconds.
> The original no-Core-change/full-revert statements below are historical plan
> constraints superseded only by these explicitly approved bounded fixes.
> The 900pt layout gate requires a hidden sidebar while the Inspector is open,
> fully contained Inspector close/workspace controls and a scrollable workspace.
> After genuine close, the previously visible sidebar must return fully contained,
> preserve dossier selection, and leave more width for the workspace. This
> explicitly approved adaptive contract replaces simultaneous three-column
> containment: observed native widths148+450+380 exceed900. Below980 with an open
> Inspector, a structurally separate constant-detailOnly branch avoids writing
> forced visibility into the normal user's binding; wider/closed layouts retain
> normal visibility. Outer idealWidth900 (without max) prevents native deferred
> resizing to the former window width; the process test checks wide initial
> layout and stable900 geometry. The visible `Inspector schließen` button is the
> explicit dismissal action. No source, schema, copy-shortening or icon workaround.

**Files:**

- Modify: `README.md`
- Verify only: all files changed in Tasks 1–5

**Interfaces:**

- Produces: operator guidance for the visible person-anchored main dossier and the unchanged authoritative UI-smoke command.
- Produces: final evidence that PR 5 satisfies UI, accessibility, privacy, compatibility, rollback, and source-integrity scope.

- [ ] **Step 1: Write the README acceptance assertions first**

Use this explicit documentation review checklist as the pre-edit documentation gate:

```text
[ ] “Meine Mutter im Pflegeheim” is named exactly.
[ ] Entry begins at one supported primary person finding, not free-form input.
[ ] Same-name dossiers require an explicit existing/new choice.
[ ] Exact primary matches and one-hop confirmed payments are explained.
[ ] Suggestions can be accepted/rejected; removals and both correction kinds reset.
[ ] Stale/unavailable origin is normal state and the person dossier survives source removal.
[ ] Processing and decisions are local; originals are not renamed, moved, deleted, or rewritten.
[ ] The existing xcodebuild command remains the authoritative full UI smoke command.
```

Before the edit, confirm at least the first seven statements are absent or incomplete in `README.md`.

- [ ] **Step 2: Add concise German operator guidance**

After `## Kosten und Zahlungen`, add `## Meine Mutter im Pflegeheim` explaining the eight checklist points above. Tell the user to select an analyzed document, choose the action attached to the desired primary person finding, resolve any same-name choice explicitly, inspect both document sections and reasons, and use `Aufnehmen`, `Ablehnen`, `Aus Dossier entfernen`, and the decision-specific reset controls. State that unavailable origin evidence does not delete the person dossier.

Keep the existing `## Process-level UI smoke test` command text exactly executable; extend its prose to say the scheme now runs both the costs workflow and the complete person workflow with hidden entries, symbolic links, restart, reanalysis, catalog source removal, and exact metadata/content comparison.

- [ ] **Step 3: Run focused suites**

Run:

```sh
swift test --filter 'PersonDossierPresentationTests|DossierPresentationTests|AppCompositionTests|PersonDossierAppModelTests|AppModelTests|DossierAppStateTests|ScanDashboardTests|UITestLaunchConfigurationTests'
```

Expected: all focused tests pass with no skipped person tests.

- [ ] **Step 4: Run the complete Swift and release gates**

Run:

```sh
swift test
swift build -c release
```

If the Command Line Tools host cannot import `Testing`, use the complete framework-path fallback command from `AGENTS.md` without changing repository files. Expected: complete suite and release build exit 0.

- [ ] **Step 5: Run the complete authoritative UI smoke**

Run exactly the README command, without `-only-testing`:

```sh
xcodebuild test \
  -project LinkLoom.xcodeproj \
  -scheme LinkLoomUISmoke \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/LinkLoomDerivedData \
  -resultBundlePath /tmp/LinkLoomUISmoke.xcresult
```

Expected: existing costs smoke, new person smoke, startup recovery, and integrity-helper tests all pass. Retain the `.xcresult` path and the four person-workflow screenshot names for the pull-request report.

- [ ] **Step 6: Audit source integrity, privacy, compatibility, and rollback**

Inspect the complete branch diff and record:

- Source integrity: every person-smoke checkpoint equals the initial snapshot for relative path, entry kind, SHA-256, byte count, modification date, POSIX mode, hidden entries, and symbolic-link destination.
- Privacy/security: no person name, exact text, absolute path, content hash, bookmark, or evidence appears in logs/errors; no network/dependency change exists; every navigation still uses the existing security-scoped source boundary.
- Compatibility: costs UI, IDs, old process smoke, dossier rows, and costs composition all remain green.
- Migration: none in PR 5; schema v8 from PR 1 is only consumed.
- Rollback: reverting PR 5 removes visible entry/composition while leaving persisted v8 person rows readable by Core; no source data requires rollback.
- Scope: no Core projection/persistence changes, no generic hierarchy, rename/merge, alias/fuzzy matching, analyzer rule, or unrelated refactor entered the diff.

- [ ] **Step 7: Run diff and staging hygiene checks**

Run:

```sh
git diff --check
git status --short
```

Stage only the README, then run:

```sh
git add README.md
git diff --cached --check
git diff --cached --name-only
```

The protected untracked 2026-09-10 plan must remain absent from the index and unchanged on disk.

- [ ] **Step 8: Commit documentation and prepare the PR handoff**

```sh
git commit -m "docs: explain person dossier workflow"
git status --short
```

Prepare a PR titled `feat(dossier): integrate person dossier UI`. Report exact focused/full/release/UI commands and results, screenshots, no migration, local-only privacy posture, preserved costs compatibility, rollback behavior, and source-integrity evidence. Perform the repository-required self-review and inspect any already-existing bot/reviewer comments; do not wait for hypothetical external review and do not push or merge without explicit authorization.

---

## Plan Self-Review Result (performed 2026-09-12)

- [x] **Scope completeness:** Task 1 covers production composition; Task 3 covers the per-finding entry action and same-name choice; Task 4 covers typed dispatch, single sidebar, anchor, direct documents, costs/payments, explanations, evidence/counterpart navigation, and remove; Task 5 covers suggestions, corrections, focus, announcements, keyboard, VoiceOver labels, stable IDs, narrow layout, and largest supported text; Tasks 2–5 build the complete process smoke and Task 6 covers README guidance.
- [x] **Lifecycle completeness:** the process workflow proves creation, persisted decisions, restart, retry-driven reanalysis, reset, catalog source removal, surviving person anchor/dossier, unavailable origin, and disappearance of removed-source document rows.
- [x] **Source-integrity completeness:** the main person smoke fixture itself contains regular files, nested directories, hidden file/directory, and a symbolic link, and equality is checked after every material phase, not only at final teardown.
- [x] **RED–GREEN clarity:** every production unit has a named compile/behavior RED before implementation; Tasks 3–5 extend one process test only to the next boundary, observe a named missing UI contract, implement it, and end GREEN before committing. No planned commit intentionally leaves a required test red.
- [x] **Type consistency:** adapter method names/signatures match `PersonDossierLoading`, `PersonDossierMutating`, and `DossierRepository`; view calls match PR 4 `AppModel` APIs; focus outcomes consume only complete `PersonDossierSnapshot` values. The original finding index is explicitly retained from `DocumentDNADetailPresentation` to the per-finding action.
- [x] **Feasibility:** Xcode 26.6 and Swift 6.3.3 are available on the planning host; the repository requires only Xcode 26.3/Swift 6.2. The planned `AccessibilityFocusState`, `.accessibility5`, and AppKit announcement call were type-checked against the installed SDK.
- [x] **Boundary consistency:** Core owns eligibility authority, projection, support/token validation, persistence, and lifecycle; AppFeature owns formatting/focus/accessibility; App owns construction; XCUITest owns generated files, read-only runtime UUID lookup, and read-only post-process durable-state inspection.
- [x] **Backward compatibility:** no existing costs type gains person optionals, old IDs/copy are unchanged, and the existing costs smoke remains a separate required test.
- [x] **Placeholder scan:** the plan contains no deferred implementation marker, unnamed edge case, or undefined cross-task API.
- [x] **Commit hygiene:** every `git add` lists exact paths, every commit checks staged names, and the protected untracked 2026-09-10 plan is excluded throughout.
