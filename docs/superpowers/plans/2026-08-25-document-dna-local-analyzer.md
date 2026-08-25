# Document DNA Local Analyzer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the versioned Document DNA value contract and a deterministic, fully local rules analyzer backed by eight synthetic care-home golden fixtures.

**Architecture:** Keep the slice pure inside `LinkLoomCore`: validated Codable domain values describe snapshots and provenance, while `LocalRulesDocumentDNAAnalyzer` consumes only a `StoredExtraction` plus explicit identity, hash, and clock values. SwiftPM test resources hold literal inputs and complete expected snapshots; persistence, orchestration, file access, UI, and networking remain outside this change.

**Tech Stack:** Swift 6.2, Foundation, CoreGraphics, Swift Testing, SwiftPM test resources

**Spec:** `docs/superpowers/specs/2026-08-24-document-dna-vertical-slice-design.md`

## Global Constraints

- Keep all analysis local; add no network call, external AI, telemetry, package dependency, or remote configuration.
- Do not open, rename, move, delete, or intentionally modify source documents; analyze only supplied persisted extraction values.
- Keep `LinkLoomCore` independent of `LinkLoomAppFeature` and `LinkLoomApp`.
- Include exactly document classification, people, organizations, civil dates, explicit-currency amounts, labelled reference numbers, and exact page/UTF-16/OCR-region provenance.
- Do not add persistence repositories, analysis scheduling, pipeline composition, entity resolution, relationships, contexts, or UI.
- Golden data must be entirely synthetic and use literal expected values independent of production normalization helpers.

---

### Task 1: Add the validated versioned domain contract

**Files:**

- Create: `Sources/LinkLoomCore/Models/DocumentDNA.swift`
- Create: `Tests/LinkLoomCoreTests/DocumentDNADomainTests.swift`

**Interfaces:**

- Consumes: Foundation `UUID`, `Date`, `Decimal`, and Codable.
- Produces: `DocumentDNA`, `DocumentDNAFinding`, `DocumentDNAEvidence`, `DocumentDNAFindingKind`, `DocumentType`, `DocumentDNADateRole`, `DocumentDNAReferenceNumberKind`, and `DocumentDNAValidationError`.

- [x] **Step 1: Write failing domain behavior tests**

  Add literal tests proving that:

  - one complete snapshot round-trips through Codable without losing values;
  - a snapshot rejects zero or multiple `documentType` findings;
  - `unknown` classification requires confidence `0`, empty display text, and no evidence;
  - every other finding requires evidence and confidence in `0...1`;
  - qualifiers are rejected when absent, present, or malformed for the wrong finding kind;
  - evidence rejects negative page/range/region indexes, empty excerpts, and non-distinct region indexes;
  - malformed ISO civil dates, decimal amounts, schema/input versions, and reference qualifiers are rejected during both direct initialization and decoding.

  Use the intended throwing initializers directly, for example:

  ```swift
  let evidence = try DocumentDNAEvidence(
      pageIndex: 0,
      startUTF16: 9,
      lengthUTF16: 12,
      exactText: "Elise Muster",
      ocrRegionIndexes: []
  )
  let finding = try DocumentDNAFinding(
      kind: .person,
      qualifier: "resident",
      displayValue: "Elise Muster",
      normalizedValue: "elise muster",
      secondaryNormalizedValue: nil,
      confidence: 1,
      evidence: [evidence]
  )
  ```

- [x] **Step 2: Run the focused test and verify RED**

  Run:

  ```sh
  swift test --disable-sandbox --enable-swift-testing \
    -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
    -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
    --filter DocumentDNADomainTests
  ```

  Expected: compilation fails because the Document DNA domain symbols do not exist.

- [x] **Step 3: Implement the minimum validated values**

  Define raw-string Codable enums with exactly these v1 values:

  ```swift
  public enum DocumentDNAFindingKind: String, Codable, CaseIterable, Sendable {
      case documentType, person, organization, date, monetaryAmount, referenceNumber
  }

  public enum DocumentType: String, Codable, CaseIterable, Sendable {
      case contract, invoice, paymentConfirmation, insuranceStatement
      case medicalOrCareDocument, powerOfAttorney, correspondence, unknown
  }

  public enum DocumentDNADateRole: String, Codable, CaseIterable, Sendable {
      case issueDate, dueDate, serviceDate, servicePeriod, bookingDate, birthDate, unknown
  }

  public enum DocumentDNAReferenceNumberKind: String, Codable, CaseIterable, Sendable {
      case contractNumber, invoiceNumber, policyNumber, claimNumber
      case customerNumber, paymentReference, other
  }
  ```

  Add public throwing initializers and manual Codable decoding that reuses the same validation. `DocumentDNA` requires positive `schemaVersion`, non-empty analyzer/input version fields, and exactly one classification. Findings enforce the kind-specific qualifier/value/evidence contract. Evidence enforces non-negative offsets, positive length, a non-empty excerpt, and sorted unique non-negative OCR region indexes.

- [x] **Step 4: Run the focused test and verify GREEN**

  Re-run the Step 2 command. Expected: every `DocumentDNADomainTests` case passes without warnings.

- [x] **Step 5: Commit the domain unit**

  ```sh
  git add Sources/LinkLoomCore/Models/DocumentDNA.swift \
    Tests/LinkLoomCoreTests/DocumentDNADomainTests.swift \
    docs/superpowers/plans/2026-08-25-document-dna-local-analyzer.md
  git commit -m "feat(dna): add versioned domain model"
  ```

---

### Task 2: Add deterministic local rule analysis

**Files:**

- Create: `Sources/LinkLoomCore/Analysis/DocumentDNAAnalyzing.swift`
- Create: `Sources/LinkLoomCore/Analysis/LocalRulesDocumentDNAAnalyzer.swift`
- Create: `Tests/LinkLoomCoreTests/LocalRulesDocumentDNAAnalyzerTests.swift`

**Interfaces:**

- Consumes: `StoredExtraction`, `ExtractedPage`, and the Task 1 domain values.
- Produces:

  ```swift
  public protocol DocumentDNAAnalyzing: Sendable {
      func analyze(
          documentID: UUID,
          contentHash: String,
          extraction: StoredExtraction,
          analyzedAt: Date
      ) throws -> DocumentDNA
  }
  ```

  `LocalRulesDocumentDNAAnalyzer` publishes `schemaVersion = 1`, `analyzerIdentifier = "local-rules"`, and `analyzerVersion = "1"`.

- [x] **Step 1: Write failing analyzer behavior tests**

  Add independent literal tests for:

  - each of the eight document types plus the below-threshold and tied-score `unknown` paths;
  - supported labelled people and organizations, including Unicode canonical composition, whitespace collapse, and locale-stable lowercase normalization;
  - labelled and unlabelled ISO/dotted civil dates, date ranges, and rejection of invalid dates and bare years;
  - `CHF`, `Fr.`, and `EUR` amounts with Swiss/standard grouping and rejection without a currency marker;
  - every supported reference label and rejection of unlabelled phone numbers, postal codes, and long digit sequences;
  - equivalent-finding collapse with multiple distinct evidence occurrences;
  - UTF-16 offsets for non-ASCII text and OCR-region intersection for newline-joined regions;
  - stable output ordering across multiple pages.

  Each assertion uses literal normalized values, offsets, excerpts, confidence values, and region indexes. The production change each test catches is a missing/wrong matching, normalization, provenance, collapse, or sorting rule.

- [x] **Step 2: Run the focused test and verify RED**

  Run the fallback test command from Task 1 with `--filter LocalRulesDocumentDNAAnalyzerTests`.

  Expected: compilation fails because the analyzer protocol and implementation do not exist.

- [x] **Step 3: Implement the pure analyzer**

  Implement page-local Foundation regular-expression rules with these boundaries:

  - classification uses explicit weighted markers, minimum score `2`, and returns `unknown` on a top-score tie;
  - people require supported labels such as `Bewohnerin`, `Versicherte Person`, `Kontoinhaberin`, `Rechnung an`, `Vollmachtgeberin`, or `Bevollmächtigte`;
  - organizations require supported issuer/provider/insurer/payee/authority labels or a complete line ending in `AG`, `GmbH`, or `Stiftung`;
  - dates accept only real Gregorian `YYYY-MM-DD` or `dd.MM.yyyy` values and supported labelled ranges;
  - amounts require adjacent `CHF`, `Fr.`, or `EUR`, parse through `Decimal`, and persist an ungrouped canonical decimal string;
  - references require a supported contract, invoice, policy, claim, customer, payment, or generic reference label;
  - evidence ranges use Foundation `NSRange` UTF-16 coordinates; OCR indexes are reconstructed from newline-separated ordered regions;
  - candidates sort by page, span, kind, qualifier, and normalized value before equal kind/qualifier/normalized/range-end findings collapse.

  The implementation performs no file, database, network, application-layer, locale-model, or `NaturalLanguage` work.

- [x] **Step 4: Run the focused test and verify GREEN**

  Re-run the Step 2 command. Expected: every analyzer unit case passes without warnings.

- [x] **Step 5: Commit the analyzer unit**

  ```sh
  git add Sources/LinkLoomCore/Analysis \
    Tests/LinkLoomCoreTests/LocalRulesDocumentDNAAnalyzerTests.swift
  git commit -m "feat(dna): add local rules analyzer"
  ```

---

### Task 3: Add the complete synthetic care-home golden corpus

**Files:**

- Modify: `Package.swift`
- Create: `Tests/LinkLoomCoreTests/DocumentDNAGoldenTests.swift`
- Create: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/care-home-contract.json`
- Create: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/care-home-invoice.json`
- Create: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/payment-confirmation.json`
- Create: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/insurance-statement.json`
- Create: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/power-of-attorney.json`
- Create: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/ocr-invoice.json`
- Create: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/misleading-negative.json`
- Create: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/ambiguous-correspondence.json`

**Interfaces:**

- Consumes: `LocalRulesDocumentDNAAnalyzer`, `Bundle.module`, and literal JSON.
- Produces: eight independently reviewable fixtures whose `expected` member decodes as the complete `DocumentDNA` snapshot.

- [x] **Step 1: Register fixtures and write the failing golden runner**

  Register `.process("Fixtures")` on `LinkLoomCoreTests`. Define a test-only Codable fixture envelope with:

  ```swift
  struct DocumentDNAGoldenFixture: Decodable {
      let name: String
      let documentID: UUID
      let contentHash: String
      let extractionVersion: String
      let extractionMethod: ExtractionMethod
      let pages: [GoldenPage]
      let analyzedAt: Date
      let expected: DocumentDNA
  }
  ```

  The runner loads all eight fixed filenames, reconstructs `StoredExtraction`, verifies every literal expected evidence range by slicing the fixture page text, runs the real analyzer, and compares the entire returned `DocumentDNA` value to `expected`.

- [x] **Step 2: Run the golden test and verify RED**

  Run the fallback test command with `--filter DocumentDNAGoldenTests`.

  Expected: the runner fails because the eight resources are absent.

- [x] **Step 3: Add eight literal JSON fixtures one at a time**

  Add the exact corpus listed in design section 12. Every file uses only fictional names and identifiers, includes literal UTF-16 offsets and exact excerpts, and contains a complete expected snapshot with fixed UUID, versions, content hash, and timestamp. After adding each fixture, rerun the focused golden test and confirm the failure count decreases for the expected missing or mismatching next fixture.

- [x] **Step 4: Verify the complete golden corpus GREEN**

  Run the Step 2 command. Expected: all eight complete snapshot comparisons and all expected evidence re-slices pass.

- [x] **Step 5: Commit the golden corpus**

  ```sh
  git add Package.swift Tests/LinkLoomCoreTests/DocumentDNAGoldenTests.swift \
    Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1
  git commit -m "test(dna): add synthetic care-home goldens"
  ```

---

### Task 4: Verify the focused slice and prepare review

**Files:**

- Modify only when verification exposes a defect in the files above.

**Interfaces:**

- Consumes: all Task 1-3 deliverables.
- Produces: a clean, reviewable branch with exact verification evidence.

- [x] **Step 1: Run focused tests**

  Run the fallback suite filtered separately to `DocumentDNADomainTests`, `LocalRulesDocumentDNAAnalyzerTests`, and `DocumentDNAGoldenTests`.

- [ ] **Step 2: Run complete verification**

  ```sh
  swift test --disable-sandbox --enable-swift-testing \
    -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
    -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
  swift build -c release
  git diff --check
  git diff --cached --check
  git status --short
  ```

  Expected: all non-opt-in tests and the release build pass; diff checks are silent; status contains only the planned analyzer/domain/golden files.

- [ ] **Step 3: Review scope and privacy**

  Inspect `git diff origin/main...HEAD` and confirm no persistence, pipeline, app, UI, network, dependency, source-file, real-personal-data, database, build-artifact, or generated-file change entered the branch.

- [ ] **Step 4: Request review and resolve findings**

  Review the branch against this plan and the design. Resolve all critical and important findings, rerun the relevant focused test after every behavior fix, then repeat Step 2.

- [ ] **Step 5: Push and open a focused pull request**

  Use a Conventional Commit PR title no longer than 72 characters. Report the exact tests/builds, the local-only privacy boundary, synthetic fixture status, absence of schema/pipeline/UI changes, compatibility considerations, and rollback risk. Do not merge until required checks pass.
