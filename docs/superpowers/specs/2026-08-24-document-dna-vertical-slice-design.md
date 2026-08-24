# Document DNA Vertical Slice Design

**Status:** Proposed for review

**Date:** 2026-08-24

**Scope:** First fully local, persisted Document DNA slice

**Builds on:** the product, ingestion-hardening, and P0 reliability designs in
this directory, dated 2026-08-08, 2026-08-12, and 2026-08-16 respectively.

## 1. Objective

This slice turns an existing, successfully persisted text extraction into a
versioned and queryable Document DNA snapshot. It classifies the document and
extracts people, organizations, civil dates, monetary amounts, and reference
numbers. Every non-unknown result points to its exact page and text span.

The slice proves the local pipeline from stored extracted pages through typed
analysis and forward-only SQLite persistence. It does not yet resolve mentions
to canonical entities, infer relationships, build dossiers, or add UI.

The implementation must remain useful without a network connection and must
not add network calls, external AI, telemetry, or a new package dependency.

## 2. Current State and Reused Contracts

The current `LinkLoomCore` implementation already provides the input boundary:

- `IngestionPipeline` persists one `documentExtraction` and ordered
  `extractedPage` rows per ready document;
- each page retains its zero-based `pageIndex`, extracted text, and Vision OCR
  regions when OCR produced the page;
- `documentExtraction.analysisVersion` identifies the text-extraction logic;
- a changed text-analysis version selects ready documents for replacement;
- extraction replacement, FTS replacement, and transition to `.ready` are one
  transaction guarded by the current content hash;
- a content change resets the document to `.discovered`, while a move or
  temporary source unavailability preserves derived data.

Document DNA does not exist in code or schema. The next database migration is
therefore additive and follows `v4_remove_redundant_document_index`.

The DNA stage consumes persisted extraction data. It never opens an original
file and therefore does not start or extend a security-scoped access session.

## 3. Chosen Approach

### 3.1 Decision

Add a separate `DocumentDNAAnalyzing` boundary, a deterministic local rules
implementation, a `DocumentDNARepository`, and a source-scoped
`DocumentDNAAnalysisPipeline` inside `LinkLoomCore`. Persist completed snapshots
as a header plus normalized findings and evidence rows. Keep scheduling state
separate from the last completed snapshot.

The pipeline is wired after text ingestion in the executable composition root.
The existing `LinkLoomAppFeature` protocols do not need a DNA-specific UI or
repository dependency in this slice.

### 3.2 Alternatives not selected

1. **One Codable JSON blob per document.** This is smaller initially, but makes
   normalized fact lookup, provenance integrity, selective indexes, and schema
   migration opaque. It is not selected.
2. **Canonical entities and graph edges in the same slice.** This would produce
   more visible product behavior, but it combines extraction, resolution,
   confidence calibration, user decisions, and relationship persistence in one
   review. It is deferred.
3. **An external or embedded generative model.** An external model violates the
   offline baseline. Selecting and packaging an embedded model is a separate
   product and distribution decision. Neither is needed for this deterministic
   first slice.

## 4. Scope

### 4.1 Included

- a versioned Swift domain schema for one completed Document DNA snapshot;
- one document classification per snapshot;
- person and organization mentions, without cross-document resolution;
- civil dates and optional semantic roles;
- decimal monetary amounts and explicit currencies;
- labelled contract, invoice, policy, claim, customer, and payment references;
- exact page and UTF-16 text-span evidence, plus intersecting OCR region indexes;
- an additive GRDB migration and forward-migration tests;
- atomic persistence and stale-input rejection;
- same-version no-op behavior and controlled reanalysis on version changes;
- recoverable, per-document analysis failure state;
- privacy-safe synthetic golden fixtures for the care-home use case;
- composition after text ingestion for manual and watcher-triggered processing.

### 4.2 Excluded

- language detection, summaries, topics, addresses, places, accounts, or
  semantic embeddings;
- canonical entity creation, alias merging, or conflict resolution;
- document relationships, invoice-payment matching, contexts, or dossier UI;
- user corrections and preservation of user decisions, because this slice
  produces no relationship or canonical-entity decisions;
- background model downloads, remote configuration, or optional external AI;
- changes to supported source formats, OCR, FTS, or source-document status;
- retrospective backfill during application startup or database migration.

These exclusions make the result one reviewable prerequisite for the later
entity and graph slices rather than a partial implementation of them.

## 5. Versioned Domain Model

### 5.1 Snapshot envelope

`DocumentDNA` is a `Sendable`, `Equatable`, `Codable` value with:

- `documentID: UUID`;
- `schemaVersion: Int`, initially `1`;
- `analyzerIdentifier: String`, initially `local-rules`;
- `analyzerVersion: String`, initially `1`;
- `inputContentHash: String`;
- `inputExtractionVersion: String`;
- `findings: [DocumentDNAFinding]` in deterministic order;
- `analyzedAt: Date`, supplied by the pipeline's injected clock.

`schemaVersion` describes the public DNA value contract. `analyzerIdentifier`
and `analyzerVersion` describe how values were produced. The input fields bind
the snapshot to both the source bytes and the exact text-extraction contract.
Changing any of these four version/input values makes the snapshot non-current.

### 5.2 Findings

`DocumentDNAFinding` contains:

- `kind: DocumentDNAFindingKind`;
- `qualifier: String?` validated according to `kind`;
- `displayValue: String`, preserving the extracted spelling;
- `normalizedValue: String`, using the rules below;
- `secondaryNormalizedValue: String?` for a range end when applicable;
- `confidence: Double` in the closed range `0...1`;
- `evidence: [DocumentDNAEvidence]` in source order.

The initial finding kinds are:

| Kind | Meaning | Qualifier | Normalized value |
| --- | --- | --- | --- |
| `documentType` | One classification | none | `DocumentType` raw value |
| `person` | A person mention | optional local role | normalized name |
| `organization` | An organization mention | optional local role | normalized name |
| `date` | A civil date or range | optional `DateRole` | ISO `YYYY-MM-DD` |
| `monetaryAmount` | A decimal amount | ISO 4217 currency or `unknown` | canonical decimal string |
| `referenceNumber` | A labelled identifier | `ReferenceNumberKind` | canonical identifier |

The v1 `DocumentType` cases are `contract`, `invoice`,
`paymentConfirmation`, `insuranceStatement`, `medicalOrCareDocument`,
`powerOfAttorney`, `correspondence`, and `unknown`.

The v1 date roles are `issueDate`, `dueDate`, `serviceDate`,
`servicePeriod`, `bookingDate`, `birthDate`, and `unknown`.

The v1 reference kinds are `contractNumber`, `invoiceNumber`,
`policyNumber`, `claimNumber`, `customerNumber`, `paymentReference`, and
`other`.

Exactly one `documentType` finding is required. `unknown` has confidence `0`
and no evidence because it represents the absence of a supported
classification. Every other finding, including every non-unknown
classification, has at least one validated evidence span.

### 5.3 Normalization

Normalization is deterministic and does not perform entity resolution:

- names use Unicode canonical composition, trimmed and collapsed whitespace,
  and locale-stable lowercase comparison form while retaining `displayValue`;
- civil dates remain calendar values and never become timezone-dependent
  timestamps;
- monetary values use `Decimal`, never binary floating point, and persist a
  plain decimal representation without grouping separators;
- currencies are recorded only when a currency marker is present; the analyzer
  does not infer CHF merely from German text;
- reference numbers remove label punctuation and insignificant whitespace but
  retain meaningful letters, digits, and check digits;
- findings with the same kind, qualifier, and normalized value are collapsed
  into one finding with all distinct evidence occurrences.

## 6. Provenance Contract

`DocumentDNAEvidence` contains:

- `pageIndex: Int`, using the extraction layer's zero-based page index;
- `startUTF16: Int` and `lengthUTF16: Int` in that page's persisted text;
- `exactText: String`;
- `ocrRegionIndexes: [Int]`, empty for embedded text or when no region applies.

UTF-16 offsets are chosen because Foundation regular expressions and
`NSRange` use the same coordinate system. They remain unambiguous across Swift
`String` index lifetimes and can be checked against the stored SQLite text.
The presentation layer will display `pageIndex + 1` to users.

Before persistence, the repository validates every evidence range against the
corresponding `extractedPage.text` and requires that the substring equals
`exactText`. For OCR pages, it reconstructs the newline-separated offsets of
the ordered `TextRegion` values and stores every intersecting region index.
An invalid page, range, excerpt, or region index rejects the whole candidate
snapshot. No untraceable partial finding is persisted.

This slice records exact text and OCR-region provenance. It does not fabricate
bounding boxes for embedded PDF text, because the current extractor does not
provide them.

## 7. Local Analysis Rules

`LocalRulesDocumentDNAAnalyzer` is a pure, injected implementation of
`DocumentDNAAnalyzing`. It receives a document ID, content hash, and
`StoredExtraction`; it has no file, database, network, or application-layer
dependency.

The v1 rules target high precision in German and Swiss care-administration
documents:

- classification assigns weighted evidence to explicit markers such as
  `Vertrag`, `Rechnung`, `Zahlungsbestätigung`, `Leistungsabrechnung`,
  `Pflegedokumentation`, and `Vollmacht`; a unique score below the documented
  minimum, or a tied top score, yields `unknown`;
- people are extracted only from supported labelled fields such as
  `Bewohnerin`, `Versicherte Person`, `Kontoinhaberin`, `Rechnung an`, and
  `Vollmachtgeberin`;
- organizations are extracted from supported labelled issuer, provider,
  insurer, and payee fields, and from complete names with recognized legal
  forms such as `AG`, `GmbH`, or `Stiftung`;
- dates support ISO dates and unambiguous dotted day-month-year dates, with a
  semantic role only when a nearby supported label supplies it;
- monetary amounts require a numeric value adjacent to an explicit `CHF`,
  `Fr.`, or `EUR` marker and support Swiss and standard grouping conventions;
- reference numbers require a supported label. Unlabelled phone numbers,
  postal codes, years, and arbitrary long digit sequences are not references.

Rule definitions and thresholds are versioned with the analyzer. Rule matching
is page-local so a finding never crosses a page boundary. Output is sorted by
page, span, kind, qualifier, and normalized value before equivalent findings
are collapsed. This guarantees stable golden results.

Foundation APIs used by the implementation must operate entirely on-device.
`NaturalLanguage` name tagging is not part of v1 because OS-dependent model
changes would make the first golden contract less reproducible.

## 8. Persistence Schema

Migration `v5_document_dna` adds four tables without changing existing rows.

### 8.1 `documentDNA`

| Column | Contract |
| --- | --- |
| `documentID` | text primary key, FK to `document(id)` with cascade delete |
| `schemaVersion` | positive integer |
| `analyzerIdentifier` | non-empty text |
| `analyzerVersion` | non-empty text |
| `inputContentHash` | non-empty text |
| `inputExtractionVersion` | non-empty text |
| `analyzedAt` | datetime |

This table contains only a completed snapshot. It is never used as an
in-progress marker.

### 8.2 `documentDNAFinding`

| Column | Contract |
| --- | --- |
| `id` | integer primary key |
| `documentID` | required FK to `documentDNA(documentID)`, cascade delete |
| `kind` | finding-kind raw value |
| `qualifier` | nullable validated qualifier |
| `displayValue` | non-empty text except for `unknown` classification |
| `normalizedValue` | required canonical value |
| `secondaryNormalizedValue` | optional canonical range end |
| `confidence` | real constrained to `0...1` |
| `sortOrder` | non-negative integer, unique per document |

Indexes support `(kind, normalizedValue)` and `(documentID, kind)`. A partial
unique index on `documentID` where `kind = 'documentType'` prevents multiple
classifications; repository validation requires exactly one.

### 8.3 `documentDNAEvidence`

| Column | Contract |
| --- | --- |
| `findingID` | required FK to `documentDNAFinding(id)`, cascade delete |
| `evidenceOrder` | non-negative integer |
| `pageIndex` | non-negative integer |
| `startUTF16` | non-negative integer |
| `lengthUTF16` | positive integer |
| `exactText` | non-empty text |
| `ocrRegionIndexesJSON` | non-null encoded integer array |

The primary key is `(findingID, evidenceOrder)`.

### 8.4 `documentDNAAnalysisState`

| Column | Contract |
| --- | --- |
| `documentID` | text primary key, FK to `document(id)` with cascade delete |
| `targetSchemaVersion` | positive integer |
| `targetAnalyzerIdentifier` | non-empty text |
| `targetAnalyzerVersion` | non-empty text |
| `inputContentHash` | non-empty text |
| `inputExtractionVersion` | non-empty text |
| `status` | `analyzing`, `ready`, or `failed` |
| `failureCode` | null except for `failed` |
| `updatedAt` | datetime |

Scheduling state is separate so a failed upgrade can retain the previous
completed snapshot for diagnostics. Repository reads return a snapshot as
current only when its input and versions match the current document,
extraction, and configured analyzer. Stale snapshots are not promoted as
current facts.

## 9. Forward Migration

`v5_document_dna` is additive:

1. create the four DNA tables, constraints, and indexes;
2. do not scan documents or backfill DNA inside the migration;
3. leave all catalog, extraction, page, and FTS rows byte-for-byte unchanged;
4. let the normal pending query discover ready extractions with no current DNA;
5. rely on document cascade deletion so removing a source removes DNA and
   analysis state without a separate trigger.

Migration tests start from `v4_remove_redundant_document_index`, insert a ready
document with page and FTS data, migrate forward, and prove both preservation
of old data and creation of the new constraints. A clean-database test proves
the same final schema. A cascade test proves source removal deletes all four
DNA tables.

No reverse migration is provided. The SQLite catalog is rebuildable, while
source documents remain authoritative and untouched.

## 10. Analysis Pipeline and Atomicity

`DocumentDNAAnalysisPipeline` processes only available, `.ready` documents
with a persisted extraction. Its pending query selects a document when:

- no completed DNA snapshot exists; or
- schema or analyzer identity/version differs; or
- the snapshot's input content hash differs from `document.contentHash`; or
- the snapshot's input extraction version differs from
  `documentExtraction.analysisVersion`.

A `failed` state for the exact same target and input is not selected again. A
manual retry repository API deletes that attempt state. Any input or target
version change is automatically eligible.

The pipeline follows the existing ingestion reliability shape:

1. serialize runs per source root while allowing different sources to proceed;
2. delete orphaned `analyzing` attempts to make them eligible at run start;
3. load a bounded batch of stored extractions;
4. analyze documents concurrently with a small fixed limit;
5. validate domain invariants and provenance;
6. in one transaction, verify the expected current content hash and extraction
   version, replace header/findings/evidence, and mark analysis state `ready`;
7. reject a stale completion without deleting the previous good snapshot.

On a same-version rerun over unchanged inputs, the pending query returns no
rows and the analyzer is not called. On an analyzer or schema version change,
each eligible document is analyzed once and its complete child row set is
replaced, never appended. Repeating that run is again a no-op.

DNA analysis does not change `document.status`; that status continues to
describe catalog/text-ingestion state. DNA failure is isolated in
`documentDNAAnalysisState` and cannot make successfully extracted text
unsearchable.

## 11. Failure and Cancellation Behavior

- a deterministic analyzer or validation failure marks only that document
  `failed` for the exact target/input and records a privacy-safe stable code;
- failure codes are `analysisFailure`, `invalidFinding`, and
  `invalidProvenance`; raw extracted text is never written to logs or codes;
- persistence, pending-query, and stale-input failures use a typed run-level
  error with the completed/failed partial report;
- cancellation before commit leaves the previous completed snapshot intact and
  restores the attempt to eligible work;
- startup recovery converts orphaned `analyzing` attempts to eligible work;
- a content change during analysis causes stale-input rejection; the new text
  extraction must complete before DNA is attempted again;
- source unavailability preserves completed DNA and schedules no file access;
- source or document deletion cascades all rebuildable DNA data.

The composition root invokes DNA only after successful text ingestion. A DNA
run-level failure prevents a watcher rescan completion from being announced,
matching the existing rescan reliability contract.

## 12. Synthetic Golden Fixtures

Version-controlled fixtures live under
`Tests/LinkLoomCoreTests/Fixtures/DocumentDNA/v1/`. They contain synthetic page
text, optional OCR regions, and the complete expected sorted DNA value,
including UTF-16 offsets and exact excerpts. They never contain real personal
documents or identifiers.

The initial fictional corpus uses names such as `Elise Muster` and
`Pflegezentrum Sonnenrain AG` and includes:

1. a care-home contract with resident, provider, signature date, monthly CHF
   amount, and contract number;
2. a care-home invoice with issue date, due date, invoice number, recipient,
   issuer, and total;
3. a bank payment confirmation sharing the invoice reference and amount;
4. a health-insurance statement with insured person, insurer, statement date,
   reimbursement, policy number, and claim number;
5. a power of attorney with two people, an authority organization, and date;
6. an OCR-derived invoice whose findings map to exact OCR region indexes;
7. a misleading-name negative fixture containing a phone number, postal code,
   bare year, and unrelated person that must not become labelled facts;
8. an ambiguous correspondence fixture that must classify as `unknown` while
   retaining any independently supported labelled facts.

Golden tests compare the entire decoded output, not selected fields. A helper
also re-slices every expected UTF-16 range from its input page and checks the
excerpt before the analyzer result is compared. Fixture ordering is stable and
reviewable in source control, and the runner supplies a fixed `analyzedAt`.

## 13. Verification Strategy

### 13.1 Unit tests

- every classification rule and the tie/below-threshold path;
- labelled person and organization extraction and normalization;
- supported and rejected date, amount, and reference formats;
- finding collapse with multiple evidence spans;
- Unicode UTF-16 offsets and embedded-text provenance;
- OCR region intersection;
- schema validation and rejection of invalid qualifiers or evidence.

### 13.2 Repository and migration tests

- clean migration and `v4` to `v5` forward migration;
- preservation of existing extraction and FTS rows;
- atomic snapshot replacement and rollback on an injected failure;
- stale content-hash and extraction-version rejection;
- current-versus-stale read behavior;
- source deletion cascade.

### 13.3 Pipeline tests

- first analysis persists the complete snapshot;
- unchanged same-version rerun makes zero analyzer calls;
- analyzer-version and schema-version changes each cause exactly one
  replacement per ready document;
- replacement retains exactly one classification and no duplicate findings;
- a failed document does not block another document;
- exact failed target/input does not spin or retry indefinitely;
- cancellation restores retryability and keeps the prior snapshot;
- concurrent runs are serialized per source and isolated across sources;
- a text/content change during analysis rejects stale output.

### 13.4 Golden and acceptance tests

- all eight v1 golden fixtures match their complete expected DNA;
- an in-memory database test seeds persisted extracted pages, runs the real
  local analyzer and pipeline, reloads DNA through the repository, and compares
  it with the golden output;
- a composition-level test proves catalog/text ingestion is followed by DNA
  analysis without network or original-file mutation;
- source-integrity checks compare synthetic source bytes and metadata before
  and after the integrated workflow.

Because this slice does not change catalog fingerprinting or the 10,000-file
acceptance boundary, it does not require the opt-in 10,000-document benchmark.
The complete Swift suite and release build remain required.

## 14. Acceptance Criteria

The slice is complete when:

- the v1 schema represents exactly the included finding kinds and rejects
  malformed values;
- every non-unknown classification and every extracted fact has validated page
  and exact text-span provenance;
- the application can produce and persist DNA using only local code and stored
  extraction data;
- `v4` databases migrate forward without changing existing catalog,
  extraction, page, or FTS content;
- unchanged same-version inputs perform no analyzer work and create no rows;
- analyzer, schema, content, or extraction-version changes trigger controlled
  atomic replacement without duplicate findings;
- failed or cancelled reanalysis never exposes a partial new snapshot;
- the synthetic care-home golden corpus passes in full;
- no source file is renamed, moved, deleted, or intentionally modified;
- no network capability, external AI, telemetry, package dependency, entity
  resolution, relationship, context, or UI change enters the review.

## 15. First Implementation Boundary

Implementation should begin with the persistence contract only: add failing
tests for the clean and `v4`-to-`v5` migrations, including preservation and
cascade behavior, then implement only `v5_document_dna`. Domain analysis and
pipeline work start in later TDD tasks after the storage boundary is green.
