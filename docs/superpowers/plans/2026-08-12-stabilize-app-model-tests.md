# Stabilize App Model Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent the `AppModelTests` suite from intermittently starving Swift's cooperative executor and timing out in CI.

**Architecture:** Keep production behavior unchanged. Serialize the existing Main-Actor lifecycle suite so its synchronous blocking test doubles cannot occupy multiple cooperative-executor threads concurrently, while retaining the full suite as the regression check.

**Tech Stack:** Swift 6.2, Swift Testing, Swift Package Manager, GitHub Actions on macOS 15 with Xcode 26.3.

## Global Constraints

- Work directly in `/Users/robert/Documents/ChatGPT/LinkLoom`.
- Do not create a Codex worktree.
- Keep the fix limited to test scheduling; do not change production behavior.
- Merge PR #4 only after all required checks pass.

---

### Task 1: Serialize the App Model Lifecycle Suite

**Files:**
- Modify: `Tests/LinkLoomAppFeatureTests/AppModelTests.swift:7`
- Test: `Tests/LinkLoomAppFeatureTests/AppModelTests.swift`

**Interfaces:**
- Consumes: Swift Testing's `SuiteTrait.serialized` trait.
- Produces: The same `AppModelTests` cases, executed one at a time.

- [ ] **Step 1: Verify the regression is red**

Use GitHub Actions runs `31631427927` attempts 1 and 2 as the failing regression evidence. Both execute `swift test`, complete many assertions, then leave `swiftpm-testing` alive until the job's 20-minute timeout.

- [ ] **Step 2: Apply the minimal scheduling fix**

```swift
@Suite("Diagnostic app model", .serialized)
struct AppModelTests {
```

- [ ] **Step 3: Verify source-level correctness locally**

Run:

```bash
git diff --check
swift build -c release
```

Expected: both commands exit successfully. The local Command Line Tools installation lacks the `Testing` module, so the Xcode 26.3 test execution must be verified by GitHub Actions.

- [ ] **Step 4: Commit and push the focused fix**

```bash
git add Tests/LinkLoomAppFeatureTests/AppModelTests.swift docs/superpowers/plans/2026-08-12-stabilize-app-model-tests.md
git commit -m "test: serialize app model lifecycle suite"
git push
```

- [ ] **Step 5: Verify CI and merge**

Run:

```bash
gh pr checks 4 --repo r0brt/LinkLoom --watch
gh pr merge 4 --repo r0brt/LinkLoom --squash
```

Expected: `Policy / validate`, `Swift / test`, and `Swift / release-build` pass before the squash merge succeeds.
