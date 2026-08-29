# Document DNA Reference Normalization v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make labelled reference-number separator and whitespace variants produce one deterministic `normalizedValue`, trigger controlled reanalysis through `local-rules` analyzer version `2`, and make invoice/payment references jointly discoverable through `currentFindings`.

**Architecture:** Keep the Document DNA schema at version `1` and implement the changed canonicalization only inside `LocalRulesDocumentDNAAnalyzer`. The analyzer accepts the existing ASCII identifier alphabet, removes an explicit Unicode whitespace/separator set, preserves every digit and check digit, and rejects all other characters instead of compatibility-folding them. Existing target-version scheduling, atomic replacement, and exact current-finding lookup remain the persistence and query authorities.

**Tech Stack:** Swift 6.2, Foundation Unicode scalars, Swift Testing, GRDB 7.10.0, SQLite, existing synthetic JSON golden fixtures

**Spec:** `docs/superpowers/specs/2026-08-24-document-dna-vertical-slice-design.md` Sections 5.1-5.3, 8, 10, 12, and 13, refined by the approved bounded v2 design from 2026-08-29; reanalysis behavior remains governed by `docs/superpowers/specs/2026-08-25-document-dna-analysis-pipeline-design.md` Sections 10-12.

## Global Constraints

- Work from current `origin/main` in `/Users/robert/Documents/ChatGPT/LinkLoom`; do not use a path under `/Users/robert/.codex/worktrees/`.
- Keep `schemaVersion = 1` and `analyzerIdentifier = "local-rules"`; set only `analyzerVersion = "2"`.
- Add no SQLite migration, table, column, index, package dependency, network call, external AI, telemetry, or remote configuration.
- Never open, rename, move, delete, or intentionally modify a selected source document; tests use only synthetic persisted text and in-memory SQLite databases.
- Preserve `displayValue`, exact UTF-16 evidence, OCR-region evidence, finding order, and every ASCII digit including leading zeros and check digits.
- Treat only ASCII letters and ASCII digits as significant identifier characters. Accept lowercase ASCII and canonicalize it to uppercase ASCII.
- Remove Unicode `White_Space` scalars and only the explicit dot, slash, and dash scalar set defined in Task 1. Reject underscores, other punctuation, controls, format characters, non-ASCII letters, and non-ASCII digits.
- Do not use NFKC, width folding, diacritic folding, transliteration, confusable mapping, numeric parsing, or check-digit validation.
- Keep qualifiers out of `normalizedValue` and catalog-wide lookup identity. Preserve qualifiers in the analyzer collapse key and returned findings.
- A matching normalized reference is candidate-retrieval evidence, not by itself authorization to infer or persist a document relationship.
- Preserve cancellation, source-scoped coordination, stale-input rejection, prior-snapshot retention, and atomic replacement behavior.
- Every production behavior change begins with a focused failing behavioral test and an observed failure caused by the old normalization/version contract.

---

## File Map

- `Sources/LinkLoomCore/Analysis/LocalRulesDocumentDNAAnalyzer.swift` — owns the explicit v2 reference grammar, scalar normalization, and analyzer version constant.
- `Tests/LinkLoomCoreTests/LocalRulesDocumentDNAAnalyzerTests.swift` — proves equivalence, rejected Unicode/characters, check-digit preservation, collision behavior, and qualifier-aware in-snapshot collapse.
- `Tests/LinkLoomCoreTests/DocumentDNAGoldenTests.swift` — continues to compare every complete schema-v1 fixture snapshot against the current local-rules analyzer.
- `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/*.json` — retain synthetic source/evidence literals while changing only the analyzer-version and affected canonical-reference expectations.
- `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/README.md` — clarifies that `v1` names the Document DNA schema fixture family rather than the analyzer implementation version.
- `Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift` — proves the production v2 snapshot, catalog-wide invoice/payment lookup, and unchanged pipeline composition.
- `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift` and `Sources/LinkLoomCore/Persistence/AppDatabase.swift` — inspected and regression-tested but not modified; exact currentness and `(kind, normalizedValue)` lookup remain sufficient.

---

### Task 1: Specify and implement the local-rules v2 reference contract

**Files:**

- Modify: `Tests/LinkLoomCoreTests/LocalRulesDocumentDNAAnalyzerTests.swift:145-225`
- Modify: `Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift:458-586`
- Modify: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/README.md`
- Modify: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/ambiguous-correspondence.json`
- Modify: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/care-home-contract.json`
- Modify: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/care-home-invoice.json`
- Modify: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/insurance-statement.json`
- Modify: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/misleading-negative.json`
- Modify: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/ocr-invoice.json`
- Modify: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/payment-confirmation.json`
- Modify: `Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/power-of-attorney.json`
- Modify: `Sources/LinkLoomCore/Analysis/LocalRulesDocumentDNAAnalyzer.swift:3-7,301-332,425-439`

**Interfaces:**

- Consumes: page-local supported reference labels, `DocumentDNAReferenceNumberKind`, and exact `DocumentDNAEvidence` creation.
- Produces: `LocalRulesDocumentDNAAnalyzer.analyzerVersion == "2"` and a private `normalizeReference(_ value: String) -> String?` whose non-nil output matches `^[A-Z0-9]+$`.
- Preserves: `CandidateKey(kind, qualifier, normalizedValue, secondaryNormalizedValue)` so only same-qualifier findings collapse inside one snapshot.

- [x] **Step 1: Add the failing separator/whitespace equivalence test**

Add this behavior test beside `extractsEverySupportedLabelledReferenceKind`:

```swift
@Test func normalizesEquivalentReferenceSeparatorsAndUnicodeWhitespace() throws {
    let nonBreakingHyphen = "\u{2011}"
    let nonBreakingSpace = "\u{00A0}"
    let narrowNoBreakSpace = "\u{202F}"
    let fullwidthSlash = "\u{FF0F}"
    let fullwidthFullStop = "\u{FF0E}"
    let text = """
        Rechnung
        Rechnungsnummer: inv-2026-0042
        Rechnungsnummer: INV 2026 0042
        Rechnungsnummer: INV/2026.0042
        Rechnungsnummer: INV\(nonBreakingHyphen)2026\(nonBreakingHyphen)0042
        Rechnungsnummer: INV\(nonBreakingSpace)2026\(narrowNoBreakSpace)0042
        Rechnungsnummer: INV\(fullwidthSlash)2026\(fullwidthFullStop)0042
        """

    let references = try analyze(text).findings.filter {
        $0.kind == .referenceNumber
    }

    #expect(references.count == 1)
    #expect(references[0].qualifier == "invoiceNumber")
    #expect(references[0].normalizedValue == "INV20260042")
    #expect(references[0].displayValue == "inv-2026-0042")
    #expect(references[0].evidence.count == 6)
}
```

This test must retain all six distinct evidence ranges while collapsing the six separator-only variants.

Add this real analyzer/pipeline/repository regression beside the existing
real-local-analyzer integration test in the same RED step:

```swift
@Test func realAnalyzerJointlyFindsInvoiceAndPaymentReferenceVariants() async throws {
    let db = try TestDatabase.make()
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let source = SourceRootRecord(
        id: UUID(uuidString: "51000000-0000-0000-0000-000000000001")!,
        displayName: "Reference matching",
        pathHint: "/synthetic/reference-matching",
        bookmarkData: Data("bookmark-reference-matching".utf8),
        createdAt: date
    )
    let inputs: [(UUID, String, String, String)] = [
        (
            UUID(uuidString: "51000000-0000-0000-0000-000000000002")!,
            "invoice.pdf",
            "hash-invoice",
            "Rechnung\nRechnungsnummer: inv-2026-0042"
        ),
        (
            UUID(uuidString: "51000000-0000-0000-0000-000000000003")!,
            "payment.pdf",
            "hash-payment",
            "Zahlungsbestätigung\nZahlungsreferenz: inv 2026 0042"
        ),
    ]
    try await db.write { database in
        try source.insert(database)
    }
    let extractions = ExtractionRepository(dbWriter: db)
    for (documentID, relativePath, contentHash, text) in inputs {
        let document = DocumentRecord(
            id: documentID,
            sourceRootID: source.id,
            relativePath: relativePath,
            contentHash: contentHash,
            byteCount: 64,
            modifiedAt: date,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: date,
            lastFingerprintAt: date
        )
        try await db.write { database in
            try document.insert(database)
        }
        try await extractions.replace(
            documentID: documentID,
            analysisVersion: "text-v1",
            extraction: ExtractedDocument(
                method: .embeddedPDFText,
                pages: [ExtractedPage(pageIndex: 0, text: text, regions: [])]
            ),
            at: date
        )
    }
    let target = try DocumentDNAAnalysisTarget(
        schemaVersion: LocalRulesDocumentDNAAnalyzer.schemaVersion,
        analyzerIdentifier: LocalRulesDocumentDNAAnalyzer.analyzerIdentifier,
        analyzerVersion: LocalRulesDocumentDNAAnalyzer.analyzerVersion
    )
    let repository = DocumentDNARepository(dbWriter: db)
    let pipeline = DocumentDNAAnalysisPipeline(
        repository: repository,
        analyzer: LocalRulesDocumentDNAAnalyzer(),
        target: target,
        now: { date }
    )

    #expect(try await pipeline.processPending(
        sourceRootID: source.id,
        limit: 2
    ) == DocumentDNAAnalysisReport(completed: 2, failed: 0))

    let matches = try await repository.currentFindings(
        kind: .referenceNumber,
        normalizedValue: "INV20260042",
        target: target
    )

    #expect(matches.map(\.document.relativePath) == [
        "invoice.pdf",
        "payment.pdf",
    ])
    #expect(matches.map(\.finding.qualifier) == [
        "invoiceNumber",
        "paymentReference",
    ])
    #expect(matches.map(\.finding.displayValue) == [
        "inv-2026-0042",
        "inv 2026 0042",
    ])
    #expect(matches.allSatisfy {
        $0.finding.normalizedValue == "INV20260042"
            && $0.finding.evidence.count == 1
    })
    #expect(try await pipeline.processPending(
        sourceRootID: source.id,
        limit: 2
    ) == DocumentDNAAnalysisReport(completed: 0, failed: 0))
}
```

Before v2 implementation, the lookup returns only the payment document because
the invoice stores `INV-2026-0042`. After v2 implementation, it returns both
while preserving their distinct qualifiers, displays, and evidence.

- [x] **Step 2: Add rejected-Unicode, check-digit, and qualifier/collision tests**

Add these independent tests before changing production code:

```swift
@Test func rejectsCharactersOutsideTheV2ReferenceAlphabet() throws {
    let zeroWidthSpace = "\u{200B}"
    let text = """
        Rechnung
        Rechnungsnummer: INV_2026_0042
        Rechnungsnummer: INV+2026+0042
        Rechnungsnummer: INV\(zeroWidthSpace)20260042
        Rechnungsnummer: ＩＮＶ-2026-0042
        Rechnungsnummer: INV-２０２６-0042
        """

    #expect(try analyze(text).findings.filter {
        $0.kind == .referenceNumber
    }.isEmpty)
}

@Test func preservesLeadingZerosAndCheckDigitsWithoutValidation() throws {
    let text = """
        Zahlungsbestätigung
        Zahlungsreferenz: 21 00000 00003 13947 14300 09017
        Zahlungsreferenz: 21-00000-00003-13947-14300-09018
        """

    let references = try analyze(text).findings.filter {
        $0.kind == .referenceNumber
    }

    #expect(references.map(\.normalizedValue) == [
        "210000000003139471430009017",
        "210000000003139471430009018",
    ])
}

@Test func separatorCollisionCollapsesOnlyWithinTheSameQualifier() throws {
    let text = """
        Rechnung
        Rechnungsnummer: AB-12
        Rechnungsnummer: A-B12
        Kundennummer: AB-12
        """

    let references = try analyze(text).findings.filter {
        $0.kind == .referenceNumber
    }

    #expect(references.map(\.qualifier) == [
        "invoiceNumber",
        "customerNumber",
    ])
    #expect(references.map(\.normalizedValue) == ["AB12", "AB12"])
    #expect(references[0].evidence.count == 2)
    #expect(references[1].evidence.count == 1)
}
```

The rejection test is a guardrail against implementing the feature with broad punctuation deletion or compatibility folding. The collision test records that separator loss is intentional while qualifier semantics remain intact.

- [x] **Step 3: Update all literal v2 expectations before implementation**

Change `extractsEverySupportedLabelledReferenceKind` to expect:

```swift
#expect(references.map(\.normalizedValue) == [
    "VER202601",
    "INV0042",
    "POL7788",
    "CLM9",
    "KD123",
    "QRR000111",
    "SONST5",
])
```

Change `referenceEmbeddedISODateIsNotAnUnlabelledDate` to expect
`INV20260803`. In `sortsFindingsByPageThenSpanBeforeCollapsing`, change the
expected reference values from `A-1` and `B-2` to `A1` and `B2`. Keep their
display strings and evidence unchanged.

In every JSON golden fixture, change `expected.analyzerVersion` from `"1"` to `"2"`. Change only these affected reference expectations:

| Fixture | v1 value | v2 value |
| --- | --- | --- |
| `ambiguous-correspondence.json` | `BRIEF-77` | `BRIEF77` |
| `care-home-contract.json` | `VER2026-001` | `VER2026001` |
| `care-home-invoice.json` | `INV-2026-0042` | `INV20260042` |
| `insurance-statement.json` claim | `CLM-2026-9` | `CLM20269` |
| `ocr-invoice.json` | `OCR-0043` | `OCR0043` |

Keep `POL7788` and the payment fixture's existing `INV20260042` unchanged. Fixtures without reference findings change only `analyzerVersion`.

In `realLocalAnalyzerPersistsLiteralSnapshotAndLeavesDocumentReady`, change the expected analyzer version to `"2"` and `RE-2026-0815`'s expected normalized value to `RE20260815`. Keep its `displayValue`, evidence offset, length, and `exactText` unchanged.

Replace the fixture README with this exact contract clarification:

```markdown
# Synthetic Document DNA schema-v1 fixtures

Every JSON file in this directory is fictional and exists only to verify the
schema-v1 local Document DNA contract against the current versioned analyzer.
The directory version names the persisted DNA schema, not the analyzer
implementation version. Do not copy real personal documents, names,
identifiers, or extracted text into these fixtures.
```

- [x] **Step 4: Run the focused tests and verify RED**

Run:

```sh
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter 'LocalRulesDocumentDNAAnalyzerTests|DocumentDNAGoldenTests|realLocalAnalyzerPersistsLiteralSnapshotAndLeavesDocumentReady|realAnalyzerJointlyFindsInvoiceAndPaymentReferenceVariants'
```

Expected: failures show that the current analyzer still reports version `1`, retains ASCII punctuation, does not accept the selected Unicode separator variants, and therefore does not collapse all equivalent references. Evidence re-slicing must continue to pass.

- [x] **Step 5: Implement the explicit scalar normalizer and analyzer version bump**

Change the analyzer constants and capture pattern to:

```swift
public static let schemaVersion = 1
public static let analyzerIdentifier = "local-rules"
public static let analyzerVersion = "2"
private static let labelledReferencePattern = #"(?mi)^(Vertragsnummer|Rechnungsnummer|Policennummer|Schadennummer|Kundennummer|Zahlungsreferenz|Referenz):[ \t]*([^\r\n]+?)[ \t]*$"#
private static let referenceSeparatorScalars: Set<UInt32> = [
    0x002D, 0x002E, 0x002F, // ASCII hyphen, full stop, slash
    0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, // dash family
    0x2044, 0x2212, 0x2215, // fraction slash, minus, division slash
    0x2024, 0xFE52, // one-dot leader, small full stop
    0xFE63, 0xFF0D, 0xFF0E, 0xFF0F, // small/fullwidth variants
]
```

Add this private helper immediately after `normalizeName`:

```swift
private func normalizeReference(_ value: String) -> String? {
    var normalized = ""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A:
            normalized.unicodeScalars.append(scalar)
        case 0x61...0x7A:
            normalized.unicodeScalars.append(
                Unicode.Scalar(scalar.value - 0x20)!
            )
        default:
            guard scalar.properties.isWhitespace
                    || Self.referenceSeparatorScalars.contains(scalar.value)
            else {
                return nil
            }
        }
    }
    return normalized.isEmpty ? nil : normalized
}
```

Replace the inline whitespace/uppercase expression in `references(in:)` with an exact guard:

```swift
let display = source.substring(with: valueRange)
guard let normalizedValue = normalizeReference(display) else {
    continue
}
candidates.append(Candidate(
    kind: .referenceNumber,
    qualifier: kinds[label]!.rawValue,
    displayValue: display,
    normalizedValue: normalizedValue,
    secondaryNormalizedValue: nil,
    confidence: 1,
    evidence: [try makeEvidence(page: page, range: valueRange)]
))
```

Do not change `CandidateKey`, finding sorting, evidence construction, domain validation, repository code, or schema code.

- [x] **Step 6: Run the focused tests and verify GREEN**

Re-run the Step 4 command.

Expected: every analyzer unit, complete golden snapshot, and real pipeline literal test passes. The six formatting variants collapse to one finding with six evidence values; disallowed Unicode remains absent; leading zeros/check digits are unchanged.

- [x] **Step 7: Commit the analyzer-v2 contract**

```sh
git add Sources/LinkLoomCore/Analysis/LocalRulesDocumentDNAAnalyzer.swift \
  Tests/LinkLoomCoreTests/LocalRulesDocumentDNAAnalyzerTests.swift \
  Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift \
  Tests/LinkLoomCoreTests/DocumentDNAGoldenTests.swift \
  Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1 \
  docs/superpowers/plans/2026-08-29-document-dna-reference-normalization-v2.md
git diff --cached --check
git commit -m "fix(dna): normalize reference separators"
```

---

### Task 2: Prove catalog-wide invoice/payment matching and controlled reanalysis

**Files:**

- Modify: `Tests/LinkLoomCoreTests/DocumentDNAAnalysisPipelineTests.swift:458-586`
- Verify only: `Tests/LinkLoomCoreTests/DocumentDNARepositoryTests.swift:686-896`
- Verify only: `Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift:106-170,419-625`
- Verify only: `Sources/LinkLoomCore/Persistence/AppDatabase.swift:94-180`

**Interfaces:**

- Consumes: `LocalRulesDocumentDNAAnalyzer` v2, `DocumentDNAAnalysisPipeline.processPending`, and `DocumentDNARepository.currentFindings(kind:normalizedValue:target:)`.
- Produces: an end-to-end regression proving two differently formatted, differently qualified references share one catalog lookup without changing repository SQL or persistence schema.
- Reuses: existing generic analyzer-version replacement, stale/current visibility, rollback, one-statement query, and index regressions.

- [x] **Step 1: Confirm the catalog lookup test participated in Task 1 RED**

Task 1 Step 1 adds the following test beside the existing real-local-analyzer
integration test before any production change. Confirm its pre-implementation
failure was recorded as one payment match instead of the expected invoice and
payment pair:

```swift
@Test func realAnalyzerJointlyFindsInvoiceAndPaymentReferenceVariants() async throws {
    let db = try TestDatabase.make()
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let source = SourceRootRecord(
        id: UUID(uuidString: "51000000-0000-0000-0000-000000000001")!,
        displayName: "Reference matching",
        pathHint: "/synthetic/reference-matching",
        bookmarkData: Data("bookmark-reference-matching".utf8),
        createdAt: date
    )
    let inputs: [(UUID, String, String, String)] = [
        (
            UUID(uuidString: "51000000-0000-0000-0000-000000000002")!,
            "invoice.pdf",
            "hash-invoice",
            "Rechnung\nRechnungsnummer: inv-2026-0042"
        ),
        (
            UUID(uuidString: "51000000-0000-0000-0000-000000000003")!,
            "payment.pdf",
            "hash-payment",
            "Zahlungsbestätigung\nZahlungsreferenz: inv 2026 0042"
        ),
    ]
    try await db.write { database in
        try source.insert(database)
    }
    let extractions = ExtractionRepository(dbWriter: db)
    for (documentID, relativePath, contentHash, text) in inputs {
        let document = DocumentRecord(
            id: documentID,
            sourceRootID: source.id,
            relativePath: relativePath,
            contentHash: contentHash,
            byteCount: 64,
            modifiedAt: date,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: date,
            lastFingerprintAt: date
        )
        try await db.write { database in
            try document.insert(database)
        }
        try await extractions.replace(
            documentID: documentID,
            analysisVersion: "text-v1",
            extraction: ExtractedDocument(
                method: .embeddedPDFText,
                pages: [ExtractedPage(pageIndex: 0, text: text, regions: [])]
            ),
            at: date
        )
    }
    let target = try DocumentDNAAnalysisTarget(
        schemaVersion: LocalRulesDocumentDNAAnalyzer.schemaVersion,
        analyzerIdentifier: LocalRulesDocumentDNAAnalyzer.analyzerIdentifier,
        analyzerVersion: LocalRulesDocumentDNAAnalyzer.analyzerVersion
    )
    let repository = DocumentDNARepository(dbWriter: db)
    let pipeline = DocumentDNAAnalysisPipeline(
        repository: repository,
        analyzer: LocalRulesDocumentDNAAnalyzer(),
        target: target,
        now: { date }
    )

    #expect(try await pipeline.processPending(
        sourceRootID: source.id,
        limit: 2
    ) == DocumentDNAAnalysisReport(completed: 2, failed: 0))

    let matches = try await repository.currentFindings(
        kind: .referenceNumber,
        normalizedValue: "INV20260042",
        target: target
    )

    #expect(matches.map(\.document.relativePath) == [
        "invoice.pdf",
        "payment.pdf",
    ])
    #expect(matches.map(\.finding.qualifier) == [
        "invoiceNumber",
        "paymentReference",
    ])
    #expect(matches.map(\.finding.displayValue) == [
        "inv-2026-0042",
        "inv 2026 0042",
    ])
    #expect(matches.allSatisfy {
        $0.finding.normalizedValue == "INV20260042"
            && $0.finding.evidence.count == 1
    })
    #expect(try await pipeline.processPending(
        sourceRootID: source.id,
        limit: 2
    ) == DocumentDNAAnalysisReport(completed: 0, failed: 0))
}
```

Before v2 implementation, the lookup returns only the payment document because the invoice stores `INV-2026-0042`. After v2 implementation, it returns both while preserving their distinct qualifiers, displays, and evidence.

- [x] **Step 2: Run the new integration test and verify GREEN after Task 1**

Run:

```sh
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter realAnalyzerJointlyFindsInvoiceAndPaymentReferenceVariants
```

Expected: one passing test; the first run completes exactly two documents and the unchanged rerun completes zero.

- [x] **Step 3: Re-run the existing controlled-version and persistence regressions**

Run:

```sh
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter 'analyzerAndSchemaChangesEachReplaceExactlyOnce|replacementIsVersionIdempotentAndDoesNotAppendChildren|failedChildWriteRollsBackCompleteReplacement|currentSnapshotRequiresMatchingTargetAndExtractionInput|currentFindingsReturnCompleteCatalogMatchesInStableOrder|currentFindingsUseOneIndexedStatementForAllMatches|currentFindingsRequireAnExactKindAndNormalizedValue'
```

Expected: every named regression passes and proves:

- target version `2` makes a version-`1` snapshot eligible exactly once;
- successful replacement leaves one header and one complete child set;
- failed child persistence retains the prior snapshot and state;
- a target-version mismatch hides the stored prior snapshot from current reads;
- `currentFindings` remains exact, target-current, read-only, stable, and one-statement indexed.

Do not change `DocumentDNARepository`, `AppDatabase`, `DocumentDNA`, or the `currentFindings` signature to make these tests pass.

- [x] **Step 4: Inspect the Task 1 commit boundary**

Run:

```sh
git show --stat --oneline HEAD
git show --format= --name-only HEAD
```

Expected: the analyzer-v2 commit contains the analyzer, focused analyzer and
pipeline tests, schema-v1 synthetic fixture expectations/README, and this plan.
It contains no repository, database, domain-model, package, app/UI, source-file,
network, telemetry, or dependency change.

---

### Task 3: Complete verification and review preparation

**Files:**

- Review: every changed file since the task's base SHA
- Modify only when a fresh failing regression demonstrates an in-scope defect.

**Interfaces:**

- Consumes: Tasks 1-2 and the repository definition of done.
- Produces: exact local verification evidence and a focused review-ready branch; no push, pull request, merge, remote setting, or remote branch change.

- [x] **Step 1: Run all focused Document DNA suites**

```sh
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter 'DocumentDNADomainTests|LocalRulesDocumentDNAAnalyzerTests|DocumentDNAGoldenTests|DocumentDNARepositoryTests|DocumentDNAAnalysisPipelineTests|AppCompositionTests'
```

Expected: every focused domain, analyzer, golden, repository, pipeline, and composition test passes. The production target must be `schemaVersion 1 / local-rules / analyzerVersion 2`.

- [x] **Step 2: Run the complete non-opt-in suite**

```sh
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: all non-opt-in tests pass. Do not run `catalogHandlesTenThousandDocumentsIdempotently`; reference normalization does not change catalog, fingerprinting, or scale behavior.

- [x] **Step 3: Run the production release build**

```sh
swift build -c release
```

Expected: exit status `0` with no warning attributable to this change.

- [x] **Step 4: Verify diff hygiene, schema scope, and repository index reuse**

```sh
git diff --check
git diff --cached --check
git status --short
git diff --stat origin/main...HEAD
git diff --name-status origin/main...HEAD
git diff origin/main...HEAD -- Sources/LinkLoomCore/Persistence/AppDatabase.swift Sources/LinkLoomCore/Persistence/DocumentDNARepository.swift Sources/LinkLoomCore/Models/DocumentDNA.swift Package.swift
```

Expected:

- both diff checks are silent;
- no database, `.build/`, `.superpowers/`, source-document, secret, or generated artifact is tracked;
- `AppDatabase.swift`, `DocumentDNARepository.swift`, `DocumentDNA.swift`, and `Package.swift` have no diff;
- the existing `document_dna_finding_kind_value` index remains the lookup path;
- changes are limited to the analyzer, focused tests, synthetic golden expectations/README, and this plan.

- [x] **Step 5: Inspect normalization and privacy invariants manually**

Review the complete diff and confirm all of the following:

- every removed scalar belongs to Unicode whitespace or the explicit separator set;
- no digit, including a leading zero or final check digit, is removed;
- rejected characters cause the complete reference candidate to be skipped rather than partially normalized;
- `displayValue`, `exactText`, UTF-16 ranges, and OCR indexes remain source-faithful;
- `CandidateKey` still contains `qualifier`;
- `currentFindings` still omits qualifier from its SQL identity and requires all five currentness fields;
- no normalization input, reference value, path, or personal data enters errors or logs;
- no source file is accessed or modified by DNA analysis.

- [x] **Step 6: Request independent read-only review**

Use `superpowers:requesting-code-review` with the task base SHA and current HEAD. Require review of:

- exact equivalence and rejection boundaries;
- separator-loss collision risk and qualifier semantics;
- check-digit and leading-zero preservation;
- Unicode whitespace/separator allowlist versus forbidden compatibility folding;
- analyzer-version/currentness behavior;
- atomic prior-snapshot retention and no-migration scope;
- golden literal independence and evidence integrity.

Resolve every Critical or Important finding through `superpowers:receiving-code-review`: reproduce it with a focused failing test, observe RED, apply the minimum in-scope fix, rerun the affected focused test, then repeat Tasks 3 Steps 1-5.

- [x] **Step 7: Record exact verification evidence in this plan and commit it**

Add a `## Verification Record` section containing literal test counts, suite counts, release-build result, diff/status result, independent-review verdict, and the tested commit SHA. Do not use placeholders or estimated counts.

```sh
git add docs/superpowers/plans/2026-08-29-document-dna-reference-normalization-v2.md
git diff --cached --check
git commit -m "docs: record reference normalization verification"
```

- [ ] **Step 8: Hand off without remote mutation**

Report the branch name, commits, exact focused/full/release verification, review verdict, schema/persistence compatibility, and remaining required GitHub checks. Do not push, create or merge a pull request, change GitHub settings, or delete a branch without a new explicit user authorization.

## Verification Record

- Tested implementation commit: `35cf660326367f0ea0456be9893979c16a9610be`
  (`fix(dna): normalize reference separators`).
- Focused Document DNA verification: 108 tests in 6 suites passed (exit 0).
- Complete non-opt-in verification: 320 tests in 25 suites passed (exit 0).
  `catalogHandlesTenThousandDocumentsIdempotently()` was skipped as the
  opt-in scale test, because this change does not affect cataloging,
  fingerprinting, or scale behavior.
- Production release build: `swift build -c release` exited 0 with no
  attributable compiler warnings. The complete test run emitted the
  non-failing, non-attributable CoreGraphics runtime line `CoreGraphics PDF
  has logged an error. Set environment variable "CG_PDF_VERBOSE" to learn
  more.`; all tests and suites still passed.
- Diff and status: `git diff --check`, `git diff --cached --check`, and the
  committed-range `git diff --check origin/main...HEAD` were clean; `git
  status --short` was empty before this record. The protected-path diff for
  `AppDatabase.swift`, `DocumentDNARepository.swift`, `DocumentDNA.swift`,
  and `Package.swift` was empty.
- Independent review: Ready to merge **Yes**; no Critical or Important
  findings; two non-blocking Minor test-hardenings (representative rather than
  exhaustive scalar-boundary cases, and no direct per-evidence range/exact-text
  assertions in the six-variant collapse test).
- Schema and persistence compatibility: schema version remains 1; analyzer
  identity remains `local-rules` with analyzer version 2; no migration,
  database, repository, domain-model, package, or index change was made. The
  existing `document_dna_finding_kind_value` index remains the lookup path,
  and currentness/atomic prior-snapshot behavior remains covered by the
  passing focused regressions.
