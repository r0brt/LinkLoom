# LinkLoom Hermetic XCUITest Smoke Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a process-level macOS XCUITest that drives LinkLoom's real SwiftUI workflow against generated temporary documents and proves startup recovery, source management, scan/extraction, persistence, removal, and exact source-file integrity.

**Architecture:** Keep SwiftPM canonical and add a thin committed Xcode project only for the app bundle and XCTest UI runner. The Xcode app target compiles the existing composition root, links local package products, and enables launch configuration only through the `LINKLOOM_UI_TESTING` Debug condition. XCTest owns all fixtures and verifies durable state read-only after terminating the app.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, XCTest/XCUIAutomation, Swift Testing, GRDB/SQLite, CoreGraphics, CoreText, ImageIO, PDFKit, Vision, CryptoKit, Xcode 26.3, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-08-21-hermetic-ui-smoke-test-design.md`

## Global Constraints

- Work only in `/Users/robert/Documents/ChatGPT/LinkLoom` on `codex/test/hermetic-ui-smoke-test`.
- macOS 15 and Swift 6.2 are the minimums; CI uses Xcode 26.3.
- SwiftPM remains canonical for package targets, unit/integration tests, and release builds.
- Do not add a project generator, package dependency, external UI-test library, telemetry, network call, or external AI.
- Generate every source document and database under one test-owned temporary root.
- Never rename, move, delete, or intentionally modify a source document.
- UI-test launch arguments may be applied only inside `#if LINKLOOM_UI_TESTING`; SwiftPM and Release app behavior must remain production-only.
- Add, Scan, Retry, restart, and Remove must be driven through `XCUIApplication`; never substitute a model call or database mutation.
- Database evidence is read-only and collected only after the app terminates.
- Use condition-based waits, not fixed sleeps.
- The local Command Line Tools host cannot run `xcodebuild`; Xcode project and process-level evidence must be verified by the authorized pull-request CI.
- When a test or CI check fails unexpectedly, apply `superpowers:systematic-debugging` before changing code.
- Do not merge, change required checks, or delete the remote branch.

---

## Task 1: Add a Testable Launch-Argument Contract

**Files:**

- Modify: `Package.swift`
- Create: `Sources/LinkLoomAppFeature/UITestLaunchConfiguration.swift`
- Create: `Tests/LinkLoomAppFeatureTests/UITestLaunchConfigurationTests.swift`

**Interfaces:**

- Produces: `@_spi(UITesting) public struct UITestLaunchConfiguration: Sendable, Equatable`
- Produces: `@_spi(UITesting) public enum UITestLaunchConfigurationError: Error, Sendable, Equatable`
- Consumed later by: `LinkLoomApp` only under `LINKLOOM_UI_TESTING`

- [ ] **Step 1: Write the failing parser tests**

Use `@_spi(UITesting) import LinkLoomAppFeature`. Add literal expectations for:

```swift
let configuration = try UITestLaunchConfiguration(arguments: [
    "LinkLoom",
    "--linkloom-ui-test-database", "/tmp/LinkLoomSmoke/linkloom.sqlite",
    "--linkloom-ui-test-source", "/tmp/LinkLoomSmoke/source",
    "--linkloom-ui-test-disable-watcher",
    "--linkloom-ui-test-fail-startup-once",
    "-ApplePersistenceIgnoreState", "YES",
])

#expect(configuration.databaseURL?.path == "/tmp/LinkLoomSmoke/linkloom.sqlite")
#expect(configuration.sourceURL?.path == "/tmp/LinkLoomSmoke/source")
#expect(configuration.disablesWatcher)
#expect(configuration.failsStartupOnce)
```

Add separate tests requiring:

- no recognized arguments produces nil URLs and false flags;
- missing database/source values throw `.missingValue(argument)`;
- relative database/source values throw `.nonAbsolutePath(argument)`;
- a repeated valued argument throws `.duplicateArgument(argument)`;
- unknown Xcode arguments and their values are ignored.

The production mutation each test catches is a wrong argument branch, wrong URL, or accidentally permissive invalid path.

- [ ] **Step 2: Run the focused suite and verify red**

Run the documented Command Line Tools-compatible command with:

```sh
--filter UITestLaunchConfigurationTests
```

Expected: compilation fails because `UITestLaunchConfiguration` does not exist.

- [ ] **Step 3: Add the feature library product**

Add exactly this product without changing targets:

```swift
.library(name: "LinkLoomAppFeature", targets: ["LinkLoomAppFeature"]),
```

- [ ] **Step 4: Implement the minimal pure parser**

Use these exact public SPI declarations:

```swift
@_spi(UITesting)
public enum UITestLaunchConfigurationError: Error, Sendable, Equatable {
    case missingValue(String)
    case nonAbsolutePath(String)
    case duplicateArgument(String)
}

@_spi(UITesting)
public struct UITestLaunchConfiguration: Sendable, Equatable {
    public let databaseURL: URL?
    public let sourceURL: URL?
    public let disablesWatcher: Bool
    public let failsStartupOnce: Bool

    public init(arguments: [String]) throws
}
```

Parse only the four spec arguments. Require exactly one following value for each valued argument, use `NSString.isAbsolutePath`, reject a second occurrence, and ignore unknown tokens. Construct file URLs with the correct `isDirectory` value. Do not read `ProcessInfo` inside this type.

- [ ] **Step 5: Run focused tests green**

Run:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/linkloom-ui-smoke-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/linkloom-ui-smoke-swiftpm-cache \
  swift test --disable-sandbox --enable-swift-testing \
  --filter UITestLaunchConfigurationTests \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
env CLANG_MODULE_CACHE_PATH=/tmp/linkloom-ui-smoke-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/linkloom-ui-smoke-swiftpm-cache \
  swift test --disable-sandbox --enable-swift-testing \
  --filter FolderPickerTests \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: parser and existing picker seam pass.

- [ ] **Step 6: Run the feature regression suites**

Run:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/linkloom-ui-smoke-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/linkloom-ui-smoke-swiftpm-cache \
  swift test --disable-sandbox --enable-swift-testing \
  --filter AppStartupControllerTests \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
env CLANG_MODULE_CACHE_PATH=/tmp/linkloom-ui-smoke-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/linkloom-ui-smoke-swiftpm-cache \
  swift test --disable-sandbox --enable-swift-testing \
  --filter AppModelTests \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: all pass.

- [ ] **Step 7: Commit**

```sh
git add Package.swift Sources/LinkLoomAppFeature/UITestLaunchConfiguration.swift Tests/LinkLoomAppFeatureTests/UITestLaunchConfigurationTests.swift
git commit -m "test(app): define UI test launch configuration"
```

---

## Task 2: Apply Launch Configuration Only in the Xcode UI-Test Build

**Files:**

- Modify: `Sources/LinkLoomApp/LinkLoomApp.swift`
- Create: `Tests/LinkLoomAppFeatureTests/UITestStartupFailureGateTests.swift`
- Create: `Sources/LinkLoomAppFeature/UITestStartupFailureGate.swift`

**Interfaces:**

- Consumes: `UITestLaunchConfiguration(arguments:)`
- Produces: `@_spi(UITesting) @MainActor public final class UITestStartupFailureGate`
- Produces: compile-time-only app composition overrides for database URL, picker, watcher, and first startup attempt

- [ ] **Step 1: Write the failing one-shot gate test**

```swift
@Test @MainActor func enabledGateFailsOnlyFirstAttempt() {
    let gate = UITestStartupFailureGate(enabled: true)
    #expect(gate.consumeFailure())
    #expect(!gate.consumeFailure())
}

@Test @MainActor func disabledGateNeverFails() {
    let gate = UITestStartupFailureGate(enabled: false)
    #expect(!gate.consumeFailure())
    #expect(!gate.consumeFailure())
}
```

Expected mutation: a retry that keeps failing or a disabled gate that fails makes this test red.

- [ ] **Step 2: Run the focused test and verify red**

Expected: compilation fails because the gate is absent.

- [ ] **Step 3: Implement the minimal SPI gate**

```swift
@_spi(UITesting)
@MainActor
public final class UITestStartupFailureGate {
    private var shouldFail: Bool

    public init(enabled: Bool) { shouldFail = enabled }

    public func consumeFailure() -> Bool {
        guard shouldFail else { return false }
        shouldFail = false
        return true
    }
}
```

- [ ] **Step 4: Run the gate tests green**

Run the focused gate and startup-controller suites. Expected: pass.

- [ ] **Step 5: Add conditional SPI import and composition**

In `LinkLoomApp.swift`, replace the unconditional feature import with:

```swift
#if LINKLOOM_UI_TESTING
@_spi(UITesting) import LinkLoomAppFeature
#else
import LinkLoomAppFeature
#endif
```

Add `private let folderPicker: FolderPicker`. In the `LINKLOOM_UI_TESTING`
branch of `init()`:

1. parse `ProcessInfo.processInfo.arguments` into a `Result`;
2. build an injected picker returning the configured source or an empty list;
3. create a one-shot gate from `failsStartupOnce`;
4. make the startup controller factory first retrieve the configuration, then
   throw a private deterministic error when the gate consumes its failure, then
   call the configured model factory.

The non-UI-test branch must instantiate `FolderPicker()` and the existing
startup controller without reading arguments.

- [ ] **Step 6: Apply database and watcher overrides**

Factor the existing model builder so its UI-test branch can pass:

```swift
databaseURL: configuration.databaseURL
disableWatcher: configuration.disablesWatcher
```

When the watcher is disabled, construct `AppModel` with its public initializer
and `watchScheduler: nil`; otherwise keep the current `RescanScheduler`. In the
ready phase render:

```swift
ContentView(model: model, folderPicker: folderPicker)
```

Do not add startup accessibility identifiers yet; the remote UI tests in Task
3 must demonstrate their absence.

- [ ] **Step 7: Verify production builds cannot activate the hook**

Run focused parser/gate tests, the complete Swift suite, and:

```sh
swift build -c release --disable-sandbox
```

Expected: all pass without defining `LINKLOOM_UI_TESTING`.

- [ ] **Step 8: Commit**

```sh
git add Sources/LinkLoomApp/LinkLoomApp.swift Sources/LinkLoomAppFeature/UITestStartupFailureGate.swift Tests/LinkLoomAppFeatureTests/UITestStartupFailureGateTests.swift
git commit -m "test(app): isolate UI test composition"
```

---

## Task 3: Add the Xcode UI-Test Harness and Establish Remote Red

**Files:**

- Create: `LinkLoom.xcodeproj/project.pbxproj`
- Create: `LinkLoom.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- Create: `LinkLoom.xcodeproj/xcshareddata/xcschemes/LinkLoomUISmoke.xcscheme`
- Create: `LinkLoomUITests/LinkLoomUISmokeTests.swift`
- Create: `LinkLoomUITests/Support/SmokeFixture.swift`
- Create: `LinkLoomUITests/Support/SQLiteProbe.swift`
- Modify: `.github/workflows/swift.yml`

**Interfaces:**

- Consumes: app launch arguments and production UI specified above
- Produces: targets `LinkLoomUIHost`, `LinkLoomUITests`, scheme `LinkLoomUISmoke`
- Produces: CI job `ui-smoke` with display name `Swift / UI smoke`

- [ ] **Step 1: Create the exact Xcode object graph**

Author an Xcode 26-compatible `project.pbxproj` with object version 77 and:

- project deployment target 15.0 and Swift 6;
- local package reference with `relativePath = .`;
- package products `LinkLoomCore` and `LinkLoomAppFeature` linked to the app;
- app source reference `Sources/LinkLoomApp/LinkLoomApp.swift`;
- UI-test source group `LinkLoomUITests` with the three files above;
- app product `LinkLoom.app`, bundle ID `local.linkloom.uitesthost`, generated
  Info.plist, `ENABLE_APP_SANDBOX = NO`, and Debug condition
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG LINKLOOM_UI_TESTING"`;
- UI-test product `LinkLoomUITests.xctest`, bundle ID
  `local.linkloom.uitests`, generated Info.plist, `TEST_TARGET_NAME =
  LinkLoomUIHost`, and `libsqlite3.tbd` linked;
- no UI-test compilation condition in Release.

The shared scheme builds both targets, uses Debug for Test, sets the UI-test
bundle as the only testable, and launches `LinkLoomUIHost` when run manually.

- [ ] **Step 2: Add the hermetic fixture support**

Implement `SmokeFixture` with unique temporary root/source/database URLs,
generated selectable PDF, high-contrast PNG, corrupt PDF, unsupported text,
and exact `SourceFileSnapshot` values. Reuse only system frameworks. The helper
must expose:

```swift
let rootURL: URL
let sourceURL: URL
let databaseURL: URL
func snapshot() throws -> [SourceFileSnapshot]
func remove() throws
```

`remove()` validates that `rootURL` is a direct child of
`FileManager.default.temporaryDirectory` before deletion.

- [ ] **Step 3: Add the read-only SQLite probe**

Using `import SQLite3`, open with `SQLITE_OPEN_READONLY`. Expose scalar/string
queries and a `SmokeDatabaseEvidence` containing counts for `sourceRoot`,
`document`, `documentExtraction`, `extractedPage`, `extractionFTS`, ready,
failed, unsupported, selectable text match, OCR token matches, and corrupt
failure-code match. Final removal evidence requires every table count to be
zero.

- [ ] **Step 4: Write both UI tests before production identifiers**

Implement an `XCTestCase` with `continueAfterFailure = false`, app termination
and fixture cleanup in teardown, and failure screenshot/UI-hierarchy
attachments. Use `XCTContext.runActivity` for each spec phase.

`testProductWorkflowPersistsAndPreservesSourceFiles` must execute all 14 spec
steps. `testStartupFailureCanRetry` must require `startup.failure`,
`startup.retry`, the German error copy, and `source.add` after clicking Retry.

Element helpers must query identifiers exactly, use `waitForExistence` or
predicate expectations, and contain no `sleep` call.

- [ ] **Step 5: Add the CI job**

Append `ui-smoke` to `.github/workflows/swift.yml` without changing existing
jobs. Use Xcode 26.3, the exact `xcodebuild test` command from the spec, and
upload `$RUNNER_TEMP/LinkLoomUISmoke.xcresult` with the pinned upload-artifact
SHA, seven-day retention, and `if: always()`.

- [ ] **Step 6: Validate locally available structure**

Run:

```sh
plutil -lint LinkLoom.xcodeproj/project.pbxproj
plutil -lint LinkLoom.xcodeproj/project.xcworkspace/contents.xcworkspacedata
plutil -lint LinkLoom.xcodeproj/xcshareddata/xcschemes/LinkLoomUISmoke.xcscheme
rg -n "LINKLOOM_UI_TESTING|LinkLoomUIHost|LinkLoomUITests|LinkLoomUISmoke" LinkLoom.xcodeproj .github/workflows/swift.yml
git diff --check
```

Expected: plist/project syntax passes and all expected object names exist.

- [ ] **Step 7: Commit the harness**

```sh
git add LinkLoom.xcodeproj LinkLoomUITests .github/workflows/swift.yml
git commit -m "test(ui): add process-level smoke harness"
```

- [ ] **Step 8: Publish a draft pull request for authoritative red**

Read and use the `github:github` skill. Push the branch, create a draft PR titled
`test(ui): add hermetic product smoke test`, and wait for CI.

Expected UI-smoke state after infrastructure issues are resolved: the app
builds and launches with temporary paths, but the UI tests fail at the first
missing stable identifier (`startup.failure` or `source.add`). Existing Swift
jobs must remain green. Do not change production UI until this intended red is
observed.

---

## Task 4: Add the Accessibility Contract and Turn Remote UI Smoke Green

**Files:**

- Modify: `Sources/LinkLoomApp/LinkLoomApp.swift`
- Modify: `Sources/LinkLoomAppFeature/SourceSidebar.swift`
- Modify: `Sources/LinkLoomAppFeature/ScanDashboard.swift`

**Interfaces:**

- Consumes: identifiers asserted by `LinkLoomUISmokeTests`
- Produces: exact accessibility contract in spec section 6

- [ ] **Step 1: Add startup identifiers only**

Attach:

```swift
.accessibilityIdentifier("startup.progress")
.accessibilityIdentifier("startup.failure")
.accessibilityIdentifier("startup.retry")
```

to the corresponding existing presentation/container/button without changing
German copy or controller behavior.

- [ ] **Step 2: Add source identifiers**

Attach `source.add` to the add button and `source.row.\(source.id.uuidString)`
to the row label. Keep selection and the existing context-menu remove action
unchanged.

- [ ] **Step 3: Add dashboard identifiers and labels**

Attach `scan.start`, `scan.error`, and `documents.table`. Change
`statusCard(_:status:)` to accept an identifier, compute the count once, and
attach both the identifier and accessibility label `"\(title): \(count)"` to
the card. Pass the four exact status identifiers.

- [ ] **Step 4: Run local regression verification**

Run FolderPicker, parser, gate, startup-controller, and AppModel focused tests,
then the complete Swift suite and release build. Expected: all green.

- [ ] **Step 5: Commit and push the accessibility contract**

```sh
git add Sources/LinkLoomApp/LinkLoomApp.swift Sources/LinkLoomAppFeature/SourceSidebar.swift Sources/LinkLoomAppFeature/ScanDashboard.swift
git commit -m "test(ui): expose product workflow identifiers"
git push
```

- [ ] **Step 6: Diagnose CI task-by-task until the real smoke passes**

Wait for `Swift / UI smoke`. For any failure:

1. read the `.xcresult` summary/logs and identify whether it is project build,
   launch configuration, element lookup, persistence, OCR, removal, or cleanup;
2. reproduce locally where possible with Swift tests or structural checks;
3. form one hypothesis and make one minimal change;
4. add or tighten the smallest automated assertion that would catch the same
   regression;
5. rerun local checks, commit, push, and wait again.

Do not weaken expected counts/text/integrity or replace UI actions. Completion
requires `Swift / UI smoke`, `Swift / test`, and `Swift / release-build` green.

---

## Task 5: Document and Complete the Readiness Gate

**Files:**

- Modify: `README.md`
- Modify: `CONTRIBUTING.md`
- Verify: all changed files

**Interfaces:**

- Consumes: final scheme and CI job names
- Produces: durable operator/contributor commands and final evidence

- [ ] **Step 1: Update durable documentation**

In `README.md`, keep Command Line Tools sufficient for normal SwiftPM work and
add a focused subsection stating that the process-level UI smoke requires full
Xcode 26.3 and runs with the exact `xcodebuild` command from the spec.

In `CONTRIBUTING.md`, add `Swift / UI smoke` to the required-check inventory and
state that it must first run reliably before an administrator makes it required.
Do not claim the ruleset was changed.

- [ ] **Step 2: Commit documentation**

```sh
git add README.md CONTRIBUTING.md
git commit -m "docs: document the UI smoke gate"
git push
```

- [ ] **Step 3: Run final local verification**

Run the focused parser/gate/picker/startup/model suites, complete Swift suite,
source-integrity acceptance test, release build, project/scheme lint, workflow
syntax inspection, `git diff --check`, `git diff --cached --check`, and
`git status --short`.

- [ ] **Step 4: Wait for final PR verification**

Require `Policy / validate`, `Swift / test`, `Swift / release-build`, and
`Swift / UI smoke` to pass on the tested HEAD. Record exact run URLs and commit
SHA. Keep the PR draft unless the user separately asks to mark it ready.

- [ ] **Step 5: Review final diff and PR scope**

Inspect `git diff origin/main...HEAD`, tracked files, and PR body. Confirm no
fixture, database, SQLite sidecar, DerivedData, `.xcresult`, secret, personal
data, or unrelated change is present. Explain why the PR exceeds 500 changed
lines: the committed Xcode object graph plus hermetic UI fixture/test code are
one inseparable process-level test boundary.

- [ ] **Step 6: Report readiness**

Report branch, commit, PR, local commands, all CI outcomes, UI workflow
evidence, exact source-integrity evidence, absence/presence of independently
confirmed product defects, the XCUITest boundary, one Go/No-Go decision, and
exactly one recommended next task.
