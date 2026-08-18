# LinkLoom Agent Guide

This file applies to the entire repository. It is an execution guide, not a
product specification. Verify current behavior in code and tests before making
changes.

## Start here

- Use [README.md](README.md) for prerequisites, setup, supported inputs, and operator guidance.
- Follow [CONTRIBUTING.md](CONTRIBUTING.md) for branches, commits, pull requests, required checks,
  and merge policy.
- Use [the product design](docs/superpowers/specs/2026-08-08-linkloom-product-design.md)
  for product boundaries and non-negotiable file behavior.
- Use
  [the ingestion hardening design](docs/superpowers/specs/2026-08-12-linkloom-ingestion-hardening-design.md)
  and
  [the P0 reliability design](docs/superpowers/specs/2026-08-16-p0-reliability-hardening-design.md)
  for accepted ingestion and failure-handling contracts.
- Treat files under `docs/superpowers/plans/` as historical execution records.
  Do not infer that planned behavior exists without checking code and tests.

## System map

- `LinkLoomCore` owns cataloging, source access, persistence, extraction,
  ingestion, and filesystem watching. It must remain independent of the app
  and SwiftUI layers.
- `LinkLoomAppFeature` owns `AppModel` and SwiftUI views. It depends on
  `LinkLoomCore`.
- `LinkLoomApp` is the executable composition root.
- GRDB/SQLite stores rebuildable catalog and extraction data. Source documents
  remain outside the database and are authoritative.
- Preserve the dependency direction: `LinkLoomApp` may depend on both
  `LinkLoomAppFeature` and `LinkLoomCore`; `LinkLoomAppFeature` may depend on
  `LinkLoomCore`; `LinkLoomCore` must not depend on either app target.

## Non-negotiable constraints

- Never rename, move, delete, or intentionally modify selected source
  documents. Use temporary fixtures for tests and manual verification.
- Keep document processing local. Do not add network calls, external AI, or
  telemetry without an explicitly approved requirement.
- Preserve security-scoped source access and balance every started access
  scope.
- Do not mark known documents missing after an incomplete scan.
- Preserve cancellation, actor isolation, and source-scoped coordination when
  changing asynchronous code.
- Persisted schema changes require a forward migration and migration tests.
- Do not add dependencies, remote configuration changes, broad cleanup, or
  generated artifacts unless they are part of the approved task.
- Do not push, merge, change GitHub settings, or delete remote branches without
  explicit user authorization.

## Workflow

1. Inspect the current implementation, adjacent tests, and relevant accepted
   design before proposing a change.
2. Keep one branch and pull request focused on one reviewable outcome.
3. For behavior changes, write a failing behavioral test first, verify the
   failure, implement the minimum change, and rerun the focused test.
4. Run the complete suite after focused tests pass. Run the opt-in 10,000-file
   acceptance test only when catalog, fingerprinting, or scale behavior changes.
5. Update durable documentation when a public contract, architecture boundary,
   setup command, or operator workflow changes.
6. Avoid unrelated formatting, refactoring, dependency updates, or cleanup.

## Commands

Standard commands from the repository root:

```sh
swift build
swift test
swift build -c release
swift run LinkLoomApp
```

If a Command Line Tools-only environment cannot import the Swift `Testing`
module, run the suite with:

```sh
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

There is currently no repository lint or formatting gate. Do not perform a
repository-wide automatic format as part of an unrelated task.

## Definition of done

- The requested outcome and explicit acceptance criteria are satisfied.
- Relevant focused tests and the complete suite pass for code changes.
- `swift build -c release` passes for production-code changes.
- Before committing, run `git diff --check` and `git diff --cached --check`,
  then inspect `git status --short` for unintended or untracked files.
- Source-integrity acceptance tests pass when file handling changes.
- No secrets, personal data, local databases, `.build/`, or `.superpowers/`
  artifacts are included.
- The pull request reports exact verification and follows
  [CONTRIBUTING.md](CONTRIBUTING.md).
