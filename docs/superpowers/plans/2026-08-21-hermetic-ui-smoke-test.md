# LinkLoom Hermetic UI Smoke Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic macOS UI smoke suite that drives LinkLoom's real SwiftUI controls against generated temporary documents, the real catalog/extraction pipeline, and a temporary SQLite database, then proves restart persistence, error presentation, source removal, and byte-for-byte source integrity.

**Architecture:** Keep the package SwiftPM-only. Move the existing startup presentation into `LinkLoomAppFeature`, add narrowly scoped dependency-injection and accessibility seams, and host the production views in a test-owned `NSWindow`. Test helpers locate and invoke AppKit accessibility elements while durable assertions query the real repositories and temporary database.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Swift Testing, GRDB/SQLite, PDFKit, CoreGraphics, CoreText, ImageIO, Vision through `CompositeTextExtractor`, CryptoKit

**Spec:** `docs/superpowers/specs/2026-08-21-hermetic-ui-smoke-test-design.md`

## Global Constraints

- Work only on `codex/test/hermetic-ui-smoke-test` in `/Users/robert/Documents/ChatGPT/LinkLoom`.
- Generate every source document and database below `FileManager.default.temporaryDirectory`; never point the test at personal or repository-resident documents.
- Do not set or repurpose `HOME`, add network access, add a package, or introduce an Xcode project.
- Every add, scan, retry, and remove operation covered as UI behavior must be invoked through the hosted SwiftUI accessibility tree. A failed UI action is a failed test, not permission to call `AppModel` directly.
- Use deadline-based polling while pumping the main run loop. Do not use fixed sleeps as synchronization.
- Before any production correction prompted by an unexpected failure, reproduce it in a focused test and apply the `superpowers:systematic-debugging` skill.
- Keep commits small and conventional, with subjects at most 72 characters.

---

## Task 1: Add a Deterministic Folder-Picker Seam

**Files:**

- Create: `Tests/LinkLoomAppFeatureTests/FolderPickerTests.swift`
- Modify: `Sources/LinkLoomAppFeature/FolderPicker.swift`

- [ ] **Step 1: Write the failing selection-injection test**

```swift
import Foundation
import LinkLoomAppFeature
import Testing

@Suite("Folder picker")
struct FolderPickerTests {
    @Test @MainActor func injectedSelectionReturnsSpecifiedURLs() {
        let expected = [
            URL(fileURLWithPath: "/tmp/linkloom-source-a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/linkloom-source-b", isDirectory: true),
        ]
        let picker = FolderPicker(selectFolders: { expected })

        #expect(picker.selectFolders() == expected)
    }
}
```

- [ ] **Step 2: Run the focused test and confirm the expected compile failure**

Run:

```sh
swift test --filter FolderPickerTests
```

Expected: compilation fails because `FolderPicker` has no `selectFolders:` initializer.

- [ ] **Step 3: Store the injected operation and preserve production `NSOpenPanel` behavior**

Implement this shape in `FolderPicker.swift`:

```swift
@MainActor
public struct FolderPicker {
    private let selection: @MainActor () -> [URL]

    public init() {
        selection = {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.canDownloadUbiquitousContents = false
            return panel.runModal() == .OK ? panel.urls : []
        }
    }

    public init(
        selectFolders: @escaping @MainActor () -> [URL]
    ) {
        selection = selectFolders
    }

    public func selectFolders() -> [URL] {
        selection()
    }
}
```

- [ ] **Step 4: Run the focused test and the existing app-feature tests**

Run:

```sh
swift test --filter FolderPickerTests
swift test --filter AppModelTests
```

Expected: both commands pass.

- [ ] **Step 5: Commit the seam**

```sh
git add Sources/LinkLoomAppFeature/FolderPicker.swift Tests/LinkLoomAppFeatureTests/FolderPickerTests.swift
git commit -m "refactor(ui): make folder selection injectable"
```

---

## Task 2: Build the In-Process Accessibility Driver

**Files:**

- Create: `Tests/LinkLoomAppFeatureTests/AccessibilityViewHostTests.swift`
- Create: `Tests/LinkLoomAppFeatureTests/Support/AccessibilityViewHost.swift`

- [ ] **Step 1: Write a failing test for lookup and press**

The test must host a miniature SwiftUI button, find it by identifier, invoke its accessibility press action, and observe the state change only through the button closure:

```swift
import SwiftUI
import Testing

@Suite("Accessibility view host")
struct AccessibilityViewHostTests {
    @Test @MainActor func findsAndPressesIdentifiedButton() throws {
        var pressed = false
        let host = AccessibilityViewHost {
            Button("Test") { pressed = true }
                .accessibilityIdentifier("fixture.button")
        }

        try host.performPress(identifier: "fixture.button")

        #expect(pressed)
    }
}
```

- [ ] **Step 2: Run the focused test and confirm the missing-host failure**

Run:

```sh
swift test --filter AccessibilityViewHostTests
```

Expected: compilation fails because `AccessibilityViewHost` does not exist.

- [ ] **Step 3: Implement the test-only host**

In `Support/AccessibilityViewHost.swift`:

- create an `NSWindow` with an `NSHostingView` content view;
- make the window key and order it front for the duration of the test;
- recursively traverse `accessibilityChildren()` from the hosting view, including unignored descendants;
- match `accessibilityIdentifier()` exactly;
- expose `performPress(identifier:)`, requiring `accessibilityPerformPress()` to return `true`;
- expose `performCustomAction(named:identifier:)`, finding the matching `NSAccessibilityCustomAction` and requiring its handler to return `true`;
- expose an element snapshot containing identifier, label, value, and role for assertions without leaking raw AppKit objects outside `@MainActor`;
- expose `waitUntil(description:timeout:condition:)` that runs the main run loop in short slices until the condition succeeds or throws a diagnostic timeout;
- close the window in `deinit` and in an explicit `close()` used before model restart.

Use a small local error enum with cases for missing element, unsupported press, missing custom action, rejected custom action, and timeout. Do not add production code or global Accessibility permission checks.

- [ ] **Step 4: Add a named-action fixture test**

Extend `AccessibilityViewHostTests` with a SwiftUI label that has:

```swift
.accessibilityAction(named: Text("Fixture action")) {
    actionPerformed = true
}
```

Invoke it through `performCustomAction(named:identifier:)` and require the closure to run.

- [ ] **Step 5: Run the host tests repeatedly**

Run:

```sh
swift test --filter AccessibilityViewHostTests
swift test --filter AccessibilityViewHostTests
```

Expected: both runs pass without Accessibility permission prompts.

- [ ] **Step 6: Commit the driver**

```sh
git add Tests/LinkLoomAppFeatureTests/AccessibilityViewHostTests.swift Tests/LinkLoomAppFeatureTests/Support/AccessibilityViewHost.swift
git commit -m "test(ui): add in-process accessibility driver"
```

---

## Task 3: Add Hermetic Documents, Database Composition, and Integrity Probes

**Files:**

- Modify: `Package.swift`
- Create: `Tests/LinkLoomAppFeatureTests/UISmokeFixtureTests.swift`
- Create: `Tests/LinkLoomAppFeatureTests/Support/UISmokeFixture.swift`

- [ ] **Step 1: Write the failing fixture contract test**

The test constructs `UISmokeFixture` and requires:

- `selectable.pdf`, `scan.png`, `corrupt.pdf`, and `unsupported.txt` exist below its temporary source directory;
- the database URL is outside the source directory but inside the same temporary root;
- the initial snapshot contains exactly those four relative paths;
- changing one fixture byte changes the snapshot, proving that integrity comparison is sensitive;
- constructing the real model does not touch the source snapshot before a UI operation.

Expected production composition returned by the fixture:

```swift
struct SmokeComposition {
    let model: AppModel
    let sources: SourceRootRepository
    let documents: DocumentRepository
    let extractions: ExtractionRepository
    let databaseProbe: SmokeDatabaseProbe
}
```

- [ ] **Step 2: Run the focused test and confirm the missing-fixture failure**

Run:

```sh
swift test --filter UISmokeFixtureTests
```

Expected: compilation fails because `UISmokeFixture` does not exist.

- [ ] **Step 3: Give the app-feature test target direct access to the existing GRDB product**

Change only the existing test target dependency list in `Package.swift`:

```swift
.testTarget(
    name: "LinkLoomAppFeatureTests",
    dependencies: [
        "LinkLoomAppFeature",
        "LinkLoomCore",
        .product(name: "GRDB", package: "GRDB.swift"),
    ]
),
```

This is a test-only direct dependency on the already pinned package, not a new package or production dependency.

- [ ] **Step 4: Implement fixture generation entirely below a unique temporary root**

`UISmokeFixture` must:

- create and own one unique temporary root, source directory, and explicit database URL;
- render a one-page selectable PDF containing `Selectable LinkLoom smoke text`;
- render a high-contrast PNG containing `Scanned LinkLoom smoke 2026` at a Vision-friendly size;
- write a corrupt `%PDF` fixture and an unsupported UTF-8 text file;
- remove the whole temporary root in `deinit` only after windows/models have been released;
- never read a document from the repository or user directories.

Reuse the proven CoreGraphics/CoreText/ImageIO construction approach from `Tests/LinkLoomCoreTests/Support/FixtureFactory.swift`, but keep the smoke target self-contained rather than changing target boundaries.

- [ ] **Step 5: Implement exact source snapshots**

Represent each file with an equatable value containing:

```swift
struct SourceFileSnapshot: Equatable {
    let relativePath: String
    let sha256: String
    let byteCount: UInt64
    let modifiedAt: Date
    let posixMode: UInt16
}
```

Enumerate regular files deterministically, hash their bytes with CryptoKit SHA-256, and compare the sorted arrays before add/scan and after remove. Do not normalize dates or permissions.

- [ ] **Step 6: Implement the real temporary composition**

Build a fresh `AppDatabase.makeQueue(at:)`, repositories, `CatalogService`, `IngestionPipeline`, and `AppModel` each time `makeComposition()` is called. Use:

- a test-only path-bookmark `SourceAccessing` implementation that scopes access to the temporary source without macOS user authorization UI;
- `DefaultFileEnumerator`, `SHA256FileFingerprinter`, and `CompositeTextExtractor` unchanged;
- tiny test-only `CatalogScanning` and `PendingIngesting` adapters equivalent to the executable's private adapters;
- no watcher, because the smoke explicitly invokes scanning.

Keep the database queue in `SmokeDatabaseProbe`. Add read-only methods that count `sourceRoot`, `document`, `documentExtraction`, `extractedPage`, and `extractionFTS` rows. These methods are evidence probes only and never mutate state.

- [ ] **Step 7: Run fixture and existing source-integrity tests**

Run:

```sh
swift test --filter UISmokeFixtureTests
swift test --filter IngestionAcceptanceTests.ingestionLeavesEverySourceFileUnchanged
```

Expected: both suites pass.

- [ ] **Step 8: Commit the hermetic fixture**

```sh
git add Package.swift Tests/LinkLoomAppFeatureTests/UISmokeFixtureTests.swift Tests/LinkLoomAppFeatureTests/Support/UISmokeFixture.swift
git commit -m "test(ui): add hermetic smoke fixtures"
```

---

## Task 4: Move the Startup Presentation into the Feature Module

**Files:**

- Create: `Tests/LinkLoomAppFeatureTests/AppStartupViewTests.swift`
- Create: `Sources/LinkLoomAppFeature/AppStartupView.swift`
- Modify: `Sources/LinkLoomApp/LinkLoomApp.swift`

- [ ] **Step 1: Write the failing startup-failure and retry test**

Construct one controller whose model factory throws a deterministic error on its first call and returns `fixture.makeComposition().model` on its second call. Host the not-yet-existing production view with an injected empty picker and a registration closure.

The test must:

- wait for `startup.failure`;
- require `startup.retry` to be present;
- invoke retry using `performPress(identifier: "startup.retry")`;
- wait for `source.add`, proving the ready workspace replaced the failure presentation;
- assert the registration closure received the ready model.

- [ ] **Step 2: Run the focused test and confirm the missing-view failure**

Run:

```sh
swift test --filter AppStartupViewTests
```

Expected: compilation fails because `AppStartupView` does not exist.

- [ ] **Step 3: Extract the exact startup UI into `LinkLoomAppFeature`**

Create a public `AppStartupView` with:

```swift
public init(
    startup: AppStartupController,
    folderPicker: FolderPicker = FolderPicker(),
    registerModel: @escaping @MainActor (AppModel) -> Void = { _ in }
)
```

It must observe the controller, render the current German copy unchanged, call `startIfNeeded` from `.task`, and call `retry` from the retry button. Add:

- `startup.progress` to the progress presentation;
- `startup.failure` to the failure container;
- `startup.retry` to the retry button.

The ready phase must render `ContentView(model:folderPicker:)`.

- [ ] **Step 4: Make the executable use `AppStartupView`**

Replace `startupContent` and the surrounding `.task` in `LinkLoomApp.swift` with:

```swift
AppStartupView(startup: startup) { model in
    appDelegate.configure(model: model)
}
```

Delete only the now-duplicated private startup presentation. Keep model construction, logging, the app delegate, and termination behavior in the executable.

- [ ] **Step 5: Run startup view/controller tests and build the executable**

Run:

```sh
swift test --filter AppStartupViewTests
swift test --filter AppStartupControllerTests
swift build
```

Expected: all pass; startup text and phases are unchanged.

- [ ] **Step 6: Commit the extraction**

```sh
git add Sources/LinkLoomAppFeature/AppStartupView.swift Sources/LinkLoomApp/LinkLoomApp.swift Tests/LinkLoomAppFeatureTests/AppStartupViewTests.swift
git commit -m "refactor(ui): expose the startup presentation"
```

---

## Task 5: Drive the Full Workspace Workflow and Add Its Accessibility Contract

**Files:**

- Create: `Tests/LinkLoomAppFeatureTests/LinkLoomUISmokeTests.swift`
- Modify: `Sources/LinkLoomAppFeature/SourceSidebar.swift`
- Modify: `Sources/LinkLoomAppFeature/ScanDashboard.swift`

- [ ] **Step 1: Write the failing real workflow test before adding identifiers**

Add `workspacePersistsAcrossRestartAndPreservesSourceFiles()` under a serial, `@MainActor` `LinkLoomUISmokeTests` suite. Its exact flow is:

1. construct `UISmokeFixture`, capture `beforeSnapshot`, and make the first real composition;
2. host `AppStartupView` whose injected picker returns only `fixture.sourceURL`;
3. wait for `source.add` and press it;
4. wait until the source repository contains one source and locate `source.row.<UUID>`;
5. wait for `scan.start`, press it, and wait until `model.scanState == .idle` with three persisted supported documents in terminal states;
6. require UI elements `status.discovered`, `status.extracting`, `status.ready`, `status.failed`, and `documents.table`;
7. require repository state of two ready documents and one failed corrupt PDF, with no `unsupported.txt` record;
8. require stored extraction text for the selectable PDF and OCR fixture, and the stable `unreadableDocument` failure code for the corrupt PDF;
9. close the first window and release the first model;
10. build a fresh composition and startup view against the same database;
11. require the same source, three documents, status counts, and table to reappear without adding or scanning again;
12. invoke the source row's named `Quelle entfernen` action;
13. wait for all five database table/FTS counts to become zero;
14. capture `afterSnapshot` and require exact equality with `beforeSnapshot`.

The UI count assertions must read the accessibility snapshot label/value associated with each status identifier. Repository counts alone do not satisfy the visible-status requirement.

- [ ] **Step 2: Run the focused workflow and confirm the intended red state**

Run:

```sh
swift test --filter LinkLoomUISmokeTests.workspacePersistsAcrossRestartAndPreservesSourceFiles
```

Expected: the hosted ready workspace appears, but the test fails because `source.add` is absent from the accessibility contract. If it fails earlier, fix only the test harness/fixture until the first missing production identifier is the failure.

- [ ] **Step 3: Add stable source identifiers and the named removal action**

In `SourceSidebar.swift`:

- attach `source.add` to the add-folder button;
- attach `source.row.<UUID>` to each source row;
- keep the context-menu removal command unchanged;
- when and only when `model.scanState == .idle`, attach a custom accessibility action named `Quelle entfernen` that starts the same `model.removeSource(source)` operation;
- factor a small private row builder if needed to conditionally attach the action without exposing it while scanning.

Do not replace the context menu or change selection behavior.

- [ ] **Step 4: Add stable dashboard identifiers and explicit count labels**

In `ScanDashboard.swift`:

- attach `scan.start` to the analyze button;
- attach `scan.error` to the existing red runtime error text;
- attach `documents.table` to the table;
- pass an identifier into `statusCard` and attach `status.discovered`, `status.extracting`, `status.ready`, and `status.failed` respectively;
- give each status card a deterministic accessibility label such as `Bereit: 2`, derived from the same count rendered on screen.

Do not alter scan state, filtering, or error handling.

- [ ] **Step 5: Run the real workflow until green**

Run:

```sh
swift test --filter LinkLoomUISmokeTests.workspacePersistsAcrossRestartAndPreservesSourceFiles
```

Expected: pass with two ready, one failed, no unsupported document, a successful restart, zero related rows after UI removal, and identical source snapshots.

- [ ] **Step 6: Add and run the runtime-error presentation test**

Add `catalogFailureIsVisibleAndRecoverable()` to the same suite. Use the real temporary repositories but inject a `CatalogScanning` adapter that throws a deterministic test error. Drive add and scan through `source.add` and `scan.start`, then require:

- `scan.error` appears and its accessibility label starts with `Fehler:`;
- the model returns to `.idle`;
- the temporary source snapshot remains unchanged.

This focused case covers the dashboard's operation-level error presentation; the main workflow separately covers per-document failure presentation.

Run:

```sh
swift test --filter LinkLoomUISmokeTests.catalogFailureIsVisibleAndRecoverable
```

Expected: pass.

- [ ] **Step 7: Prove repeatability and source integrity**

Run:

```sh
swift test --filter LinkLoomUISmokeTests
swift test --filter LinkLoomUISmokeTests
swift test --filter IngestionAcceptanceTests.ingestionLeavesEverySourceFileUnchanged
```

Expected: all three commands pass; neither smoke run requires Accessibility permission or leaves a fixture behind.

- [ ] **Step 8: Commit the completed smoke suite**

```sh
git add Sources/LinkLoomAppFeature/SourceSidebar.swift Sources/LinkLoomAppFeature/ScanDashboard.swift Tests/LinkLoomAppFeatureTests/LinkLoomUISmokeTests.swift
git commit -m "test(ui): cover the hermetic product workflow"
```

---

## Task 6: Run Product-Readiness Verification

**Files:**

- Verify only; modify code solely if a reproducible defect is separately confirmed by a focused failing test.

- [ ] **Step 1: Run the focused smoke and startup suites with the repository's Command Line Tools compatibility flags if needed**

Run:

```sh
swift test --filter LinkLoomUISmokeTests
swift test --filter AppStartupViewTests
swift test --filter AccessibilityViewHostTests
```

Expected: all pass.

- [ ] **Step 2: Run the complete suite**

Run the standard command first:

```sh
swift test
```

If this host cannot import Swift Testing, rerun exactly the documented compatibility command from `AGENTS.md` with temporary module-cache paths. Expected: every test passes.

- [ ] **Step 3: Run the production release build**

```sh
swift build -c release
```

Expected: pass.

- [ ] **Step 4: Inspect diffs and repository hygiene**

Run:

```sh
git diff --check
git diff --cached --check
git status --short
git log --oneline origin/main..HEAD
```

Expected: no whitespace errors; only the approved spec, plan, production seams, accessibility metadata, and test files are present; no databases, generated documents, `.build`, `.superpowers`, secrets, or personal data are tracked.

- [ ] **Step 5: Review the final diff against the approved design**

Run:

```sh
git diff origin/main...HEAD -- Package.swift Sources Tests docs/superpowers/specs docs/superpowers/plans
```

Confirm every acceptance criterion in the approved spec has direct test evidence and there is no production behavior beyond the agreed seams.

- [ ] **Step 6: Record the evidence and decide Go/No-Go**

The final report must state:

- branch and tested commit SHA;
- exact focused/full/release commands and outcomes;
- verified startup, source management, scan, extraction, restart, error, removal, and file-integrity evidence;
- any defect found, its independent reproduction, and its minimal fix, or explicitly that no defect required a code correction;
- the in-process test boundary (no packaging/signing/notarization/inter-process claim);
- one Go/No-Go decision;
- exactly one recommended next task.
