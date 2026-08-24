# Document DNA v5 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the forward-only SQLite storage boundary for the first Document DNA slice without implementing analysis or pipeline behavior.

**Architecture:** Extend the existing GRDB `DatabaseMigrator` with one additive `v5_document_dna` migration. The migration creates completed-snapshot, finding, evidence, and analysis-state tables with database-enforced invariants and cascade deletion from the authoritative `document` row.

**Tech Stack:** Swift 6.2, GRDB 7.10.0, SQLite, Swift Testing

**Spec:** `docs/superpowers/specs/2026-08-24-document-dna-vertical-slice-design.md`

## Global Constraints

- Keep all processing and persisted derived data local; add no network call, external AI, telemetry, or package dependency.
- Do not rename, move, delete, or intentionally modify selected source documents.
- Preserve the dependency direction: `LinkLoomCore` remains independent of `LinkLoomAppFeature` and `LinkLoomApp`.
- Make the migration additive and forward-only; do not backfill DNA during migration.
- Preserve existing catalog, extraction, page, and FTS rows exactly.
- Implement no Document DNA domain models, analyzer, repository, pipeline, composition, or UI in this task.

---

### Task 1: Add and verify `v5_document_dna`

**Files:**

- Modify: `Tests/LinkLoomCoreTests/AppDatabaseTests.swift`
- Modify: `Sources/LinkLoomCore/Persistence/AppDatabase.swift`

**Interfaces:**

- Consumes: `AppDatabase.makeMigrator()`, existing migrations through `v4_remove_redundant_document_index`, and GRDB's schema APIs.
- Produces: migration identifier `v5_document_dna` and tables `documentDNA`, `documentDNAFinding`, `documentDNAEvidence`, and `documentDNAAnalysisState`.

- [x] **Step 1: Write failing migration behavior tests**

Add three tests to `AppDatabaseTests`:

1. `documentDNAMigrationCreatesVersionedSchema` creates a current in-memory database and asserts that all four tables exist, the finding table has named indexes `document_dna_finding_kind_value`, `document_dna_finding_document_kind`, and `document_dna_one_classification`, and the state table has the exact version/input/status columns from the design.
2. `documentDNAMigrationPreservesV4ExtractionData` migrates only through `v4_remove_redundant_document_index`, inserts one source, ready document, extraction header, extracted page, and FTS row with hand-written literal values, migrates to current, and asserts that each pre-existing value and row count is unchanged.
3. `removingSourceCascadesDocumentDNAData` creates a current database, inserts one source and document plus representative rows in all four DNA tables, deletes the source row, and asserts zero rows remain in every DNA table.

The tests exercise the real migrator and database. They use literal expected table/index/column names and literal stored values rather than deriving expectations from production helpers.

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```sh
swift test --disable-sandbox --enable-swift-testing \
  -Xswiftc -I -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter AppDatabaseTests
```

Expected: the three new tests fail because `v5_document_dna` and its four tables do not exist. Existing database tests remain green.

- [x] **Step 3: Implement the minimal forward migration**

Register `v5_document_dna` after v4 in `AppDatabase.makeMigrator()` and create:

```swift
documentDNA(
    documentID TEXT PRIMARY KEY REFERENCES document(id) ON DELETE CASCADE,
    schemaVersion INTEGER NOT NULL CHECK (schemaVersion > 0),
    analyzerIdentifier TEXT NOT NULL CHECK (length(analyzerIdentifier) > 0),
    analyzerVersion TEXT NOT NULL CHECK (length(analyzerVersion) > 0),
    inputContentHash TEXT NOT NULL CHECK (length(inputContentHash) > 0),
    inputExtractionVersion TEXT NOT NULL CHECK (length(inputExtractionVersion) > 0),
    analyzedAt DATETIME NOT NULL
)
```

```swift
documentDNAFinding(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    documentID TEXT NOT NULL REFERENCES documentDNA(documentID) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (length(kind) > 0),
    qualifier TEXT,
    displayValue TEXT NOT NULL,
    normalizedValue TEXT NOT NULL CHECK (length(normalizedValue) > 0),
    secondaryNormalizedValue TEXT,
    confidence REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    sortOrder INTEGER NOT NULL CHECK (sortOrder >= 0),
    UNIQUE(documentID, sortOrder)
)
```

```swift
documentDNAEvidence(
    findingID INTEGER NOT NULL REFERENCES documentDNAFinding(id) ON DELETE CASCADE,
    evidenceOrder INTEGER NOT NULL CHECK (evidenceOrder >= 0),
    pageIndex INTEGER NOT NULL CHECK (pageIndex >= 0),
    startUTF16 INTEGER NOT NULL CHECK (startUTF16 >= 0),
    lengthUTF16 INTEGER NOT NULL CHECK (lengthUTF16 > 0),
    exactText TEXT NOT NULL CHECK (length(exactText) > 0),
    ocrRegionIndexesJSON BLOB NOT NULL,
    PRIMARY KEY(findingID, evidenceOrder)
)
```

```swift
documentDNAAnalysisState(
    documentID TEXT PRIMARY KEY REFERENCES document(id) ON DELETE CASCADE,
    targetSchemaVersion INTEGER NOT NULL CHECK (targetSchemaVersion > 0),
    targetAnalyzerIdentifier TEXT NOT NULL CHECK (length(targetAnalyzerIdentifier) > 0),
    targetAnalyzerVersion TEXT NOT NULL CHECK (length(targetAnalyzerVersion) > 0),
    inputContentHash TEXT NOT NULL CHECK (length(inputContentHash) > 0),
    inputExtractionVersion TEXT NOT NULL CHECK (length(inputExtractionVersion) > 0),
    status TEXT NOT NULL CHECK (status IN ('analyzing', 'ready', 'failed')),
    failureCode TEXT,
    updatedAt DATETIME NOT NULL,
    CHECK ((status = 'failed' AND failureCode IS NOT NULL AND length(failureCode) > 0)
        OR (status <> 'failed' AND failureCode IS NULL))
)
```

Add these indexes:

```sql
CREATE INDEX document_dna_finding_kind_value
    ON documentDNAFinding(kind, normalizedValue);
CREATE INDEX document_dna_finding_document_kind
    ON documentDNAFinding(documentID, kind);
CREATE UNIQUE INDEX document_dna_one_classification
    ON documentDNAFinding(documentID)
    WHERE kind = 'documentType';
```

Use GRDB schema builders and `Column.check(sql:)`/`TableDefinition.check(sql:)`; do not add repositories or model types.

- [x] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command again.

Expected: all `AppDatabaseTests` pass with no warning or failure.

- [x] **Step 5: Run complete verification**

Run the complete fallback suite:

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

Expected: all non-opt-in tests and the release build pass, both diff checks are silent, and status contains only the plan, migration test, and migration implementation files.

- [x] **Step 6: Commit the focused storage boundary**

```sh
git add docs/superpowers/plans/2026-08-24-document-dna-v5-migration.md \
  Tests/LinkLoomCoreTests/AppDatabaseTests.swift \
  Sources/LinkLoomCore/Persistence/AppDatabase.swift
git commit -m "feat(db): add document DNA schema"
```
