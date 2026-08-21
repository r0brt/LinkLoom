# LinkLoom Hermetic XCUITest Smoke Test Design

**Date:** 2026-08-21

**Status:** Approved architecture; revised after the in-process SwiftUI
accessibility approach was disproved on the SwiftPM test runner

## 1. Purpose

This design adds a repeatable product-readiness smoke test for LinkLoom's
current ingestion workflow. The test launches a real macOS application bundle
in a separate process, drives the production SwiftUI through XCUIAutomation,
uses only generated temporary documents and a temporary database, and verifies
startup, source management, scanning, extraction, restart persistence, error
presentation, source removal, and source-file integrity.

The repository remains SwiftPM-first. A thin committed Xcode project exists
only to provide the application bundle and UI-test runner that SwiftPM cannot
produce. It compiles the existing LinkLoom composition root and links the local
package products instead of introducing a second implementation of the app.

## 2. Evidence Behind the Revision

The earlier design proposed hosting `NSHostingView` in an in-process
`NSWindow`. A focused red test proved that this runner exposes the hosting view
only as a childless `AXGroup`; SwiftUI controls and their identifiers are not
addressable through `NSAccessibilityProtocol`. Neither unignored-descendant
APIs nor a real AppKit event cycle produced the virtual control tree.

Starting and stopping `NSApplication.run()` inside the Swift Testing process
also interfered with the test runner's exit status. The experiment was removed
without committing its test files. Directly invoking `AppModel` after the UI
action failed was rejected because it would not be a UI test.

The process-level approach uses XCTest and XCUIAutomation as intended: an
Xcode UI-test bundle launches, monitors, and terminates a separate application
process and operates on its accessibility tree.

## 3. Decision and Constraints

The implementation adds a thin Xcode UI-test boundary while preserving these
constraints:

- macOS 15 or later and Swift 6.2 or later;
- Xcode 26.3 is the authoritative UI-test toolchain in CI;
- SwiftPM remains canonical for package structure, unit tests, integration
  tests, and release builds;
- no package generator, third-party UI-test dependency, network call,
  telemetry, or external AI;
- no use of the user's real LinkLoom Application Support directory;
- no use of personal or repository-resident source documents;
- no rename, move, delete, or intentional modification of selected source
  documents;
- no production behavior change beyond a deterministic folder-picker seam,
  stable accessibility metadata, and compile-time-isolated UI-test launch
  configuration;
- no UI-test launch configuration in SwiftPM or Release builds;
- no claim that the smoke test verifies distribution signing, notarization,
  Launch Services installation, or App Store packaging.

## 4. Project Topology

### 4.1 Swift package

`Package.swift` adds `LinkLoomAppFeature` as a public library product. Its target
and dependencies do not change. Existing products and test targets remain
unchanged.

The package dependency direction stays:

- `LinkLoomCore` has no app-layer dependency;
- `LinkLoomAppFeature` depends on `LinkLoomCore`;
- the executable composition root depends on both library targets.

### 4.2 Xcode project

The repository adds `LinkLoom.xcodeproj` with:

- a macOS application target named `LinkLoomUIHost` whose product is
  `LinkLoom.app`;
- a UI-test bundle target named `LinkLoomUITests`;
- a shared scheme named `LinkLoomUISmoke`;
- a local Swift-package reference to the repository root;
- product dependencies on `LinkLoomCore` and `LinkLoomAppFeature`;
- the existing `Sources/LinkLoomApp/LinkLoomApp.swift` as the app target's
  source file;
- `LinkLoomUITests` configured with `LinkLoomUIHost` as its target application.

The Xcode project does not duplicate Core, feature, or composition-root source.
It is not a replacement release workflow.

### 4.3 Build configurations

The UI-test scheme's Test action uses Debug. Only the Xcode app target's Debug
configuration defines `LINKLOOM_UI_TESTING`. Release and every SwiftPM build do
not define it.

The test host uses a test-only bundle identifier and automatic local signing
settings suitable for `xcodebuild test` on the GitHub-hosted macOS runner. It
does not add production entitlements or sandbox exceptions.

## 5. Test-Only Launch Boundary

`Sources/LinkLoomAppFeature/UITestLaunchConfiguration.swift` contains a pure,
side-effect-free parser exposed only through Swift's `UITesting` SPI. Keeping
the parser in the feature target lets SwiftPM test malformed and duplicate
arguments without launching AppKit. Merely compiling the parser does not
activate a test path.

The parser accepts only these exact launch arguments:

| Argument | Value | Effect |
| --- | --- | --- |
| `--linkloom-ui-test-database` | absolute file path | use an explicit temporary SQLite URL |
| `--linkloom-ui-test-source` | absolute directory path | injected folder picker returns this one source |
| `--linkloom-ui-test-disable-watcher` | none | omit the filesystem watcher for manual deterministic scans |
| `--linkloom-ui-test-fail-startup-once` | none | first model factory call throws a deterministic local error |

Missing values, non-absolute paths, or duplicate valued arguments make the
test configuration invalid and surface through the existing recoverable
startup failure. Unknown arguments are ignored because Xcode supplies its own
launch arguments.

Only code enclosed by `#if LINKLOOM_UI_TESTING` in `LinkLoomApp.swift` reads
process arguments. It parses them once during initialization and applies the
result to:

- the database URL passed to `AppDatabase.makeQueue(at:)`;
- the already-approved injected `FolderPicker` selection operation;
- watcher construction;
- a process-local startup-failure gate consumed by the first factory call.

Without the compilation condition, no production code reads the UI-test SPI or
its arguments. The current production database URL, `NSOpenPanel`, watcher,
startup behavior, and logging remain in effect.

## 6. Accessibility Contract

The production views expose these stable identifiers:

| Identifier | Element |
| --- | --- |
| `startup.progress` | startup progress presentation |
| `startup.failure` | recoverable startup error container |
| `startup.retry` | retry button |
| `source.add` | add-folder button |
| `source.row.<UUID>` | source row |
| `scan.start` | analyze button |
| `scan.error` | operation-level runtime error message |
| `status.discovered` | discovered count card |
| `status.extracting` | extracting count card |
| `status.ready` | ready count card |
| `status.failed` | failed count card |
| `documents.table` | document table |

Each status card exposes a deterministic accessibility label in the form
`<German title>: <integer>`, derived from the same count displayed visually.

Source removal continues to use the existing context menu. The XCUITest
right-clicks the identified source row and invokes the visible `Quelle
entfernen` menu item. No UI-only removal API is added.

## 7. Hermetic Fixture and Integrity Snapshot

`LinkLoomUITests` creates one unique temporary root per test. The root owns:

- a `source` directory;
- `linkloom.sqlite` and its SQLite sidecars;
- generated test state and attachments.

The source contains exactly:

- `selectable.pdf`, a one-page PDF containing `Selectable LinkLoom smoke text`;
- `scan.png`, a high-contrast image containing `Scanned LinkLoom smoke 2026`;
- `corrupt.pdf`, invalid PDF bytes beginning with a PDF header;
- `unsupported.txt`, an unsupported UTF-8 document.

Fixture generation uses only system frameworks: CoreGraphics, CoreText,
ImageIO, AppKit, and PDFKit. The test never copies repository or user files.

Before the app launches and after all UI operations, the test snapshots each
source file's:

- relative path;
- CryptoKit SHA-256;
- byte count;
- exact content-modification date;
- POSIX mode.

The sorted before and after arrays must be exactly equal.

## 8. Primary UI Workflow

The serialized `testProductWorkflowPersistsAndPreservesSourceFiles` performs:

1. Create the fixture and initial source snapshot.
2. Launch `XCUIApplication` with the temporary database/source arguments and
   watcher disabled.
3. Wait for `source.add` and click it.
4. Wait for one identifier matching `source.row.*` and for `scan.start`.
5. Click `scan.start` and wait for terminal visible counts:
   `Entdeckt: 0`, `Extraktion: 0`, `Bereit: 2`, `Fehler: 1`.
6. Require `documents.table`, `selectable.pdf`, `scan.png`, `corrupt.pdf`,
   failed status, and `unreadableDocument` to be visible. Require
   `unsupported.txt` to be absent.
7. Terminate the app cleanly.
8. Open the temporary database read-only with SQLite and require:
   - three document rows;
   - two ready and one failed status;
   - two extraction headers and two FTS rows;
   - selectable extraction text contains `Selectable LinkLoom smoke text`;
   - OCR extraction text contains `LinkLoom` and `2026`;
   - the corrupt document has failure code `unreadableDocument`;
   - no row references `unsupported.txt`.
9. Relaunch with the same database and source arguments without clicking Add
   or Scan.
10. Require the source row, persisted counts, table, paths, and failure code to
    reappear.
11. Right-click the source row and click `Quelle entfernen`.
12. Wait until the source row and selected-source dashboard disappear, then
    terminate the app.
13. Require zero rows in `sourceRoot`, `document`, `documentExtraction`,
    `extractedPage`, and `extractionFTS`.
14. Capture the final source snapshot and require exact equality with the
    initial snapshot.

All database access by the UI-test process is read-only and occurs while the
app is terminated.

## 9. Recoverable Startup-Failure Workflow

The serialized `testStartupFailureCanRetry` uses a separate temporary root and
launches with `--linkloom-ui-test-fail-startup-once`.

It requires:

1. `startup.failure` and `startup.retry` appear;
2. the German recoverable-error copy remains visible;
3. clicking `startup.retry` consumes the one-shot failure gate;
4. `source.add` appears, proving the real model opened the temporary database;
5. the source snapshot remains unchanged.

This test covers startup error presentation. The corrupt PDF in the primary
workflow covers per-document failure presentation without turning an expected
document failure into an operation-level test failure.

## 10. Synchronization and Diagnostics

The test uses:

- `XCUIElement.waitForExistence(timeout:)` for elements;
- XCTest predicate expectations for label and disappearance conditions;
- read-only SQLite state after app termination for durable persistence checks.

After launch, the test activates the application and moves its window upward
through an XCUI title-bar drag. This keeps the sidebar action above the
screen-edge and Dock activation region on the 1024×768 CI desktop without
changing product layout or bypassing the UI.

It does not use fixed sleeps. Every timeout names the missing identifier,
expected label, or SQLite condition.

Each major workflow phase uses `XCTContext.runActivity`. On failure, the test
attaches an application screenshot and the relevant UI hierarchy description.
The CI job retains the complete `.xcresult` bundle.

If a required SwiftUI control is not accessible to XCUIAutomation, the test
fails at that control. It must not substitute a launch argument, database
mutation, or direct model call for the failed user interaction.

## 11. Isolation and Cleanup

The UI-test fixture owns all documents and database files. `tearDownWithError`
terminates the application before removing the unique temporary root. Cleanup
never targets a broad directory, the repository, Application Support, or a
user-selected path.

The test does not set or repurpose `HOME`. It passes explicit absolute paths
through compile-time-isolated launch arguments.

## 12. CI and Verification

The existing SwiftPM `test` and `release-build` jobs remain unchanged. A new
job named `Swift / UI smoke` runs on `macos-15` with:

```yaml
env:
  DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer
```

Its authoritative command is:

```sh
xcodebuild test \
  -project LinkLoom.xcodeproj \
  -scheme LinkLoomUISmoke \
  -destination 'platform=macOS' \
  -derivedDataPath "$RUNNER_TEMP/LinkLoomDerivedData" \
  -resultBundlePath "$RUNNER_TEMP/LinkLoomUISmoke.xcresult"
```

An `if: always()` step uploads the result bundle with the immutable
`actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02`
pin and seven-day retention.

The local Command Line Tools-only host cannot execute `xcodebuild`. Local
verification therefore covers:

- focused Swift tests for the SPI launch-argument parser and production seams;
- the complete Swift suite;
- `swift build -c release`;
- Xcode project-file syntax and shared-scheme presence checks;
- `git diff --check`, `git diff --cached --check`, and repository status.

The authorized branch push and pull request provide the required process-level
evidence on Xcode 26.3. Completion requires the UI-smoke CI job to pass; local
structural validation alone is insufficient.

## 13. Acceptance Criteria

The task is complete when:

- a committed macOS app target compiles the real LinkLoom composition root;
- a committed XCTest UI-test target launches and drives it in a separate
  process;
- test-only paths are unreachable in SwiftPM and Release builds;
- all inputs and the SQLite database are temporary and explicit;
- Add, Scan, Retry, restart, and Remove are exercised through XCUIAutomation;
- ready, failed, ignored, persisted, and removed states have visible and
  durable evidence;
- extracted selectable and OCR text is confirmed read-only in SQLite;
- all related relational and FTS rows disappear after UI removal;
- before and after source snapshots are exactly equal;
- the existing source-integrity acceptance test remains green;
- the complete Swift suite and release build pass;
- `Swift / UI smoke` passes on the pull request under Xcode 26.3;
- no generated fixture, database, DerivedData, `.xcresult`, secret, personal
  data, or unrelated change is committed.
