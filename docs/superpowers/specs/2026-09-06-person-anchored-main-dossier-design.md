# Person-Anchored Main Dossier Vertical Slice Design

**Status:** Approved

**Date:** 2026-09-06

**Scope:** First person-anchored main dossier for “Meine Mutter im Pflegeheim”

**Builds on:** the product design dated 2026-08-08, the Document DNA designs
dated 2026-08-24 and 2026-08-25, and the anchor-to-dossier design dated
2026-09-01. The implementation baseline is `main` commit `a9988da`, which
contains the costs-and-payments vertical UI slice merged through pull request
44.

## 1. Objective

This slice proves the primary LinkLoom product promise for the golden use case.
Starting from one explicitly selected, evidence-backed person finding, LinkLoom
creates a persistent main dossier named `Meine Mutter im Pflegeheim`, discovers
related documents across selected sources, explains every visible assignment,
and lets the user correct the result without changing any source document.

The dossier is anchored by a durable user selection, not by a claim that
LinkLoom has resolved a canonical real-world person. It remains available when
the document that supplied the original finding later becomes stale,
unavailable, or is removed from the catalog.

The slice reuses the confirmed invoice-payment relationship from the existing
`Kosten und Zahlungen` architecture. A person-associated invoice may bring its
confirmed payment into one derived costs subcontext. No other transitive graph
expansion is allowed.

## 2. Verified Baseline

### 2.1 Current `main`

The design was checked against a clean local `main` synchronized with
`origin/main` at `a9988da` (`feat(app): integrate dossier vertical UI (#44)`).
The complete baseline suite passed with 531 tests in 35 suites.

The dependency direction remains:

- `LinkLoomCore` owns analysis, persistence, candidate lookup, relationship
  decisions, and dossier projection;
- `LinkLoomAppFeature` owns `AppModel`, presentation state, and SwiftUI views;
- `LinkLoomApp` composes concrete Core services into AppFeature ports.

This slice must preserve that direction.

### 2.2 Current Document DNA person findings

Document DNA schema version 1 represents a person mention as a
`DocumentDNAFinding` with an optional local role, display value, normalized
name, confidence, and exact page/text/OCR evidence. The local rules analyzer is
currently version 2 and extracts people only from supported labelled fields.

The implemented roles relevant to this design are:

| Source label | Stored qualifier | Policy in this slice |
| --- | --- | --- |
| `Bewohnerin` | `resident` | primary |
| `Versicherte Person` | `insuredPerson` | primary |
| `Kontoinhaberin` | `accountHolder` | primary |
| `Rechnung an` | `invoiceRecipient` | primary |
| `Vollmachtgeberin` | `grantor` | primary |
| `Bevollmächtigte` | `authorizedPerson` | secondary |

Name normalization performs canonical Unicode composition, collapses
whitespace, and applies POSIX lowercasing. It does not remove accents, infer
aliases, or resolve two mentions to a canonical person.

The current golden corpus already proves exact evidence and roles for the
fictional people `Elise Muster` and `Nora Muster`. It does not prove dossier
membership, homonym handling, person-level corrections, or person-anchored
lifecycle behavior.

### 2.3 Costs-and-payments architecture through PR 44

The merged architecture has one `DossierKind`, `costsAndPayments`. A dossier is
anchored by an invoice or payment document. Its non-anchor membership is
derived, not persisted: only a direct, current invoice-payment candidate with
an exact content-valid `.confirmed` decision may become a member. A
dossier-local exclusion suppresses an inferred member without modifying that
relationship decision.

Core loads all projection inputs in one GRDB transaction and publishes one
immutable `DossierSnapshot`. Mutations reproject, validate an expected support
or correction revision, write atomically, and return a complete replacement
snapshot. `AppModel` protects loads and mutations with generations, projection
tokens, cancellation, and ABA guards. The UI supplies create/open/choose,
cross-source member navigation, reversible corrections, deterministic
accessibility identifiers, and a process-level source-integrity smoke test.

Those semantics are the starting architecture, not functionality to duplicate
in a parallel person-dossier subsystem.

## 3. Considered Approaches

### 3.1 Chosen: typed person anchor in the existing dossier architecture

Extend the dossier domain with a typed person anchor and add a dedicated pure
person-dossier projector. Reuse the existing transactional repository,
snapshot, AppModel, correction, and workspace patterns. Keep the current
costs-and-payments projector behavior unchanged and expose both snapshot shapes
through a typed workspace snapshot.

This is the smallest approach that preserves a single dossier architecture,
survives loss of the originating document, and leaves a clean route toward
later entity resolution without pretending that a normalized name already is
an entity.

### 3.2 Not chosen: parallel standalone person dossier

A separate person-dossier store would avoid rebuilding the existing `dossier`
table, but it would duplicate identity, corrections, AppModel state,
navigation, and UI composition. The short-term migration convenience does not
justify two competing dossier architectures.

### 3.3 Not chosen: generic entity and relationship graph now

Canonical people, alias resolution, entity merge/split, global corrections,
and arbitrary graph traversal are part of the broader product design. Building
them before this vertical proof would multiply scope and make it harder to
measure whether the person-anchored dossier itself is useful and trustworthy.

## 4. Scope

### 4.1 Included

- create or open a main dossier from a current evidence-backed person finding
  in a supported primary role;
- persist a person anchor independently of the originating document row;
- automatically include exact normalized-name matches in primary roles;
- demote exact secondary-role matches and supported identity conflicts to
  suggestions;
- include a confirmed payment one relationship step from a person-associated
  invoice;
- present complete, plain-language reasons with navigable source evidence;
- accept or reject suggestions, remove automatic members, and reset every
  dossier-local decision;
- preserve user decisions across reanalysis and path or source moves that keep
  document identity;
- keep the person dossier after loss or catalog removal of the original anchor
  document;
- provide typed failure, cancellation, unavailable-source, accessibility, and
  source-integrity behavior;
- verify quality with versioned synthetic goldens and a local-only personal
  reference set.

### 4.2 Excluded

- free-form name entry and alias management;
- fuzzy names, accent folding, initials, partial names, and OCR similarity;
- canonical person entities or global identity merge/split decisions;
- person-wide corrections outside one dossier;
- automatic traversal beyond one confirmed invoice-payment edge;
- generic nested dossier or context hierarchies;
- dossier rename or merge;
- semantic search;
- new Document DNA finding kinds or analyzer rules;
- network calls, external AI, telemetry, or package dependencies.

## 5. User Flow and Create-or-Open Semantics

1. The user scans selected sources and opens an analyzed document.
2. Every current person finding in a supported primary role presents its own
   `Hauptdossier erstellen` or `Hauptdossier öffnen` action.
3. The action sends the complete selected finding support, including document
   identity, input identity, role, normalized value, and evidence, to one
   authoritative repository operation.
4. If a person anchor already has the same origin document ID, selected role,
   and normalized name, the existing dossier opens.
5. Otherwise, an existing person dossier with the same normalized name is only
   a possible match, not proof of identity. The UI offers the matching
   dossiers and an explicit `Neues Hauptdossier erstellen` choice. No storage
   changes until the user chooses.
6. Creation stores a new person anchor and dossier in one write transaction and
   returns its first complete projection.
7. Only after that snapshot succeeds does `AppModel` select and display the new
   workspace.

There is no uniqueness constraint on normalized name. Homonyms may have
separate person anchors. There is a uniqueness constraint on the stable origin
selection `(originDocumentID, primaryRole, normalizedName)` to make retry and
concurrent creation idempotent.

The default dossier display name is exactly `Meine Mutter im Pflegeheim`. The
selected person's display name appears as the sidebar subtitle and workspace
anchor label; it is not interpolated into the persisted dossier title.

## 6. Domain Model

### 6.1 Typed anchors

`DossierKind` gains `personMatter`. A loaded dossier has exactly one typed
anchor:

- `.document(UUID)` for `costsAndPayments`;
- `.person(PersonDossierAnchor)` for `personMatter`.

`PersonDossierAnchor` is a durable user decision with:

- `id`;
- `displayName` and `normalizedName` copied from the selected finding;
- `primaryRole`;
- `originDocumentID` as a stable value, deliberately not a foreign key;
- original content hash, DNA schema/analyzer identity, and analysis timestamp;
- complete selected person-finding evidence;
- an optional unambiguous `birthDate` identity signal with evidence;
- `createdAt` and `updatedAt`.

The optional birth date is captured only when the origin snapshot contains
exactly one primary-role person and exactly one `birthDate` finding. It remains
an evidence-backed anchor signal, not a generally resolved relationship
between arbitrary people and dates.

Origin evidence validity is projected independently from source availability:

- `current` when the document and exact current finding/input identity still
  match;
- `stale` when the document exists but the selected input or finding no longer
  matches;
- `unavailable` when the document row no longer exists.

When the document row remains, its separate `DocumentAvailability` reports
`available`, `unavailable`, or `missing`. A temporarily unmounted source can
therefore have current stored anchor evidence while the original itself is not
currently openable.

### 6.2 Person workspace snapshot

The person projection produces a `PersonDossierSnapshot` containing:

- the dossier and person anchor;
- origin evidence validity and source availability;
- current members, each appearing once;
- one derived `Kosten und Zahlungen` section;
- suggestions;
- reversible correction records;
- a deterministic projection token.

A member records its document, source display name, availability, current
document type, ordered membership supports, and whether user confirmation is
authoritative. Initial support kinds are:

- exact primary-role person finding;
- dossier-local manual confirmation;
- confirmed payment-to-invoice relationship whose invoice belongs to this
  person dossier.

Suggestions record the document, candidate kind, conflict state, current
evidence, and exact support identity required by accept or reject commands.

The application-facing workspace snapshot is a closed enum with a
costs-and-payments case carrying the existing snapshot and a person-matter case
carrying `PersonDossierSnapshot`. The existing costs snapshot and projector do
not acquire person-specific optional fields.

## 7. Membership Projection

### 7.1 Direct automatic membership

A current document is automatically associated with the person when all of
these conditions hold:

1. its current target-version DNA has a `person` finding whose
   `normalizedValue` exactly equals the anchor's normalized name;
2. the finding qualifier is one of `resident`, `insuredPerson`,
   `accountHolder`, `invoiceRecipient`, or `grantor`;
3. no supported hard identity conflict exists;
4. no dossier exclusion suppresses the document.

Document type is not an eligibility condition. A correctly labelled person
fact remains useful even when classification is `unknown`.

A hard birth-date conflict exists only when both sides have an unambiguous
birth date under the conservative single-primary-person/single-birth-date rule
and the normalized civil dates differ. Such a document becomes a warning
suggestion rather than an automatic member.

### 7.2 Suggestions and hidden candidates

The first version exposes exactly two suggestion classes:

- an exact normalized-name match found only in the secondary
  `authorizedPerson` role;
- an otherwise automatic primary-role match with a hard birth-date conflict.

The following are outside candidate retrieval and remain hidden:

- accent or spelling variants with a different normalized value;
- initials, abbreviations, partial names, and fuzzy similarity;
- unlabelled text occurrences;
- unsupported or absent person qualifiers;
- directory, filename, organization, or reference-number similarities.

Hidden candidates create no persisted rows. Golden tests make the boundary
behavior explicit, and any ground-truth-relevant document hidden by those
rules counts as a false negative in reference-set reporting rather than being
disguised by a confidence score.

### 7.3 Costs-and-payments expansion

Documents appear only once in the person workspace. Invoices and payments are
grouped into the derived `Kosten und Zahlungen` section; other direct members
appear under direct documents.

For each direct or manually confirmed invoice in the dossier, projection may
follow one current invoice-payment candidate when the exact relationship key
has a content-valid `.confirmed` decision. The counterpart payment is included
unless excluded from this person dossier. Undecided or excluded relationship
decisions produce neither membership nor a duplicate person-dossier
suggestion.

Expansion stops at that payment. It never continues from an inferred payment,
another invoice, a shared organization, or a reference. Removing the only
supporting invoice therefore removes its derived payment on the next complete
projection unless the payment has another included confirmed path or a manual
dossier confirmation.

When multiple current paths support one document, projection retains all
independent visible reasons in deterministic order but uses the existing
candidate strength and canonical tie-break rules to select one command support
identity. Documents are sorted by section, source display name, relative path,
and UUID.

## 8. Explainability

Every automatic member and suggestion has at least one current evidence-backed
reason. The UI presents reason codes as plain German sentences, for example:

- `Der Name ‹Elise Muster› stimmt exakt mit dem Personenanker überein. Rolle:
  Rechnungsempfängerin.`
- `Der Name stimmt, aber dieses Dokument nennt ein anderes Geburtsdatum.`
- `Von dir aus einem Vorschlag aufgenommen.`
- `Diese Zahlung wurde aufgenommen, weil sie als Gegenstück zu Rechnung X
  bestätigt wurde. Rechnung X gehört über ihren Personenbefund zum Dossier.`

The user can navigate from a person reason to its exact page/text/OCR evidence
through the existing document inspector. Relationship reasons expose the
invoice and payment evidence already used by the invoice-payment candidate
flow and retain the existing `Gegenstück anzeigen` navigation.

The support identity binds visible reasoning to document IDs, content hashes,
DNA analysis timestamps, findings, relationship-decision timestamps, and
resolver versions. It is used for stale-command validation and never appears
as raw diagnostic text.

A manual confirmation survives loss of its original candidate. While the
accepted candidate is still current, its evidence remains visible. If it is no
longer current, the member remains labelled `Von dir aufgenommen`; the UI says
that the original suggestion evidence is no longer current and does not
present stale evidence as current fact.

## 9. Corrections and Command Preconditions

Corrections remain local to one dossier and never rewrite Document DNA,
canonicalize a person, or change an invoice-payment decision.

- Removing an automatic direct or relationship-derived member creates a
  `dossierMembershipExclusion`.
- Accepting a current suggestion creates a
  `dossierMembershipConfirmation`.
- Rejecting a current suggestion creates an exclusion.
- Resetting a confirmation deletes only the expected current confirmation
  revision. The document returns to a suggestion only if current candidate
  evidence still supports it.
- Resetting an exclusion deletes only the expected current exclusion revision.
  Reprojection then returns the document as a member, suggestion, or neither.
- Removing a manually confirmed member atomically replaces its confirmation
  with an exclusion. Resetting that exclusion does not silently restore the
  old confirmation; current rules determine the next state.

Confirmation and exclusion for the same `(dossierID, documentID)` are mutually
exclusive. Repository validation treats both being present as invalid stored
state.

Every command supplies the dossier ID, document ID, and exact expected
candidate, membership, confirmation, or exclusion identity from the displayed
snapshot. One write transaction reprojects, validates that expected state,
performs the mutation, and returns a complete new snapshot. A mismatch returns
`staleInput` and writes nothing.

An exclusion suppresses every current automatic support for that document in
this dossier. It does not suppress another document or another dossier. The
person anchor itself is not a document member and cannot be excluded.

## 10. Persistence and Migration

Migration `v8_person_anchored_dossiers` is forward-only. It introduces no
automatic dossier backfill.

### 10.1 Person anchor storage

`personDossierAnchor` stores the validated scalar anchor fields. Its
`originDocumentID` is non-null UUID text without a document foreign key so
source removal cannot cascade the user-created main dossier.

Ordered `personDossierAnchorEvidence` rows identify their subject as `person`
or `birthDate` and store a subject-local order plus the same page index, UTF-16
range, exact text, and OCR region contract as Document DNA. Deleting a person
anchor cascades its copied evidence.

The table enforces a unique
`(originDocumentID, primaryRole, normalizedName)` key. Normalized name alone is
indexed for create/open candidate lookup but is not unique.

### 10.2 Typed dossier anchor

The `dossier` table is rebuilt transactionally so that:

- `kind` accepts `costsAndPayments` and `personMatter`;
- `anchorDocumentID` becomes nullable and retains its document foreign key;
- `personAnchorID` is a nullable foreign key to `personDossierAnchor`;
- a kind-specific check requires exactly the appropriate anchor column;
- document-anchor uniqueness and person-anchor uniqueness are enforced;
- deleting a cost anchor still cascades its costs dossier;
- deleting a person anchor cascades its person dossier.

All existing v7 dossier IDs, names, document anchors, and timestamps are copied
unchanged. `dossierMembershipExclusion` is rebuilt only as required to retain
its foreign key to the rebuilt dossier table; every row, revision, and
timestamp is preserved.

Migration tests cover fresh databases, populated v7 upgrades, constraints,
indexes, cascades, malformed state, and rollback on injected failure.

### 10.3 Positive confirmation

`dossierMembershipConfirmation` contains:

- dossier and document foreign keys with cascade delete;
- unique revision UUID;
- confirmation timestamp;
- accepted candidate kind;
- accepted document content hash, extraction version, DNA schema/analyzer
  identity, and analysis timestamp;
- accepted person qualifier and normalized value.

Its primary key is `(dossierID, documentID)`. Positive confirmations are valid
only for `personMatter`; this cross-table rule and mutual exclusion with
`dossierMembershipExclusion` are enforced in repository transactions and
validated on every projection.

## 11. Transactional Data Flow and Lifecycle

### 11.1 Projection

Within one GRDB read or write transaction, the repository:

1. loads the dossier and typed anchor;
2. performs an indexed current-finding lookup for the exact normalized person
   name;
3. loads complete current snapshots only for matched documents;
4. loads confirmations and exclusions;
5. projects direct members and suggestions;
6. retrieves invoice-payment candidates only for included invoices;
7. loads exact current relationship decisions;
8. runs the pure person projector and returns one immutable snapshot.

The query must use the existing `(kind, normalizedValue)` DNA finding index and
must not load every DNA snapshot in the catalog. Relationship expansion is
bounded by included invoices, not by all invoices or payments.

### 11.2 Reanalysis and source lifecycle

- Path changes and moves between sources preserve membership decisions when
  document identity remains stable.
- Content changes re-evaluate automatic membership and relationship support.
  Positive confirmations and exclusions remain authoritative while the
  document row exists.
- Exact earlier content may reactivate automatic or invoice-payment support;
  a dossier exclusion still wins.
- A content-stale invoice-payment decision cannot support a payment.
- Temporarily unavailable or missing originals remain visible while their
  document rows remain, with explicit availability state.
- Successful target-version analysis completion triggers reprojection of an
  active person dossier because a match may live in another source.
- Removing a source deletes its documents and document-bound decisions. Cost
  dossiers anchored in that source cascade as before. The person anchor and
  main dossier survive, with origin support marked unavailable.

Reprojection publishes one complete snapshot. A repository load failure keeps
the last complete snapshot and exposes a retryable diagnostic. Cancellation
publishes nothing and is not shown as a failure.

`AppModel` applies the existing request generation, selected dossier, expected
projection token, and mutation identity guards to the new snapshot case. A
late completion cannot replace a newer source, document, or dossier selection,
including A-B-A cycles.

## 12. Application and UI Design

### 12.1 Entry and sidebar

Each eligible person fact in the shared Document DNA inspector has its own
create/open action. Multiple people therefore cannot be confused by one
document-level button.

The existing `Dossiers` sidebar remains the single navigation surface. A person
dossier row shows `Meine Mutter im Pflegeheim` with the selected display name
as subtitle. Existing costs-and-payments rows keep their current titles,
document-anchor subtitles, selection behavior, and accessibility identifiers.

`ContentView` dispatches the typed workspace snapshot to the existing
`CostsAndPaymentsDossierView` or a new `PersonDossierView`. It continues to use
the shared inspector for document selection.

### 12.2 Person dossier workspace

The person workspace shows, in order:

1. dossier title, person display name, selected role, origin evidence validity,
   and source availability;
2. direct non-financial documents;
3. the derived `Kosten und Zahlungen` section;
4. suggestions with `Aufnehmen` and `Ablehnen`;
5. corrections with an action appropriate to confirmation or exclusion.

Every document row shows source, relative path, document type, availability,
membership role, and concise reasons. Member selection delegates to the
existing atomic source/document loading flow, including cross-source
navigation. The dossier remains the workspace selection while its document is
inspected.

There is no persisted generic parent-child dossier relation in this slice. The
costs section is part of the person snapshot. If an existing persistent costs
dossier covers one of its documents, normal document and dossier navigation
remain available, but that dossier is not duplicated or reparented.

## 13. Accessibility

The visible workflow is operable with keyboard and VoiceOver. Actions are
visible buttons, not available only through context menus. Native scalable text
styles wrap vertically; reasons and paths are not truncated at the supported
minimum window and inspector widths. Status is never conveyed by color or icon
alone.

VoiceOver labels include the person, role, availability, reason class, and
action outcome without reading automation UUIDs. Heading and focus order
follows the visual order. Successful creation moves accessibility focus to the
person workspace heading. Accept, reject, remove, and reset move focus to the
resulting member, suggestion, correction, or containing section and announce
the state change.

Stable automation identifiers are:

| Identifier | Element |
| --- | --- |
| `document-dna.person-dossier.<ordinal>` | action for a deterministic person-finding ordinal |
| `dossier.person.workspace` | person workspace |
| `dossier.person.anchor` | person anchor and origin status |
| `dossier.person.direct-members` | direct-document section |
| `dossier.person.costs` | costs-and-payments section |
| `dossier.person.member.<UUID>` | current document member |
| `dossier.person.member.remove.<UUID>` | remove action |
| `dossier.person.suggestions` | suggestion section |
| `dossier.person.suggestion.<UUID>` | suggestion row |
| `dossier.person.suggestion.accept.<UUID>` | accept action |
| `dossier.person.suggestion.reject.<UUID>` | reject action |
| `dossier.person.corrections` | correction section |
| `dossier.person.correction.<UUID>` | correction row |
| `dossier.person.correction.reset.<UUID>` | exact reset action |
| `dossier.person.error` | retryable diagnostic |

Persisted UUIDs use the existing lowercase database representation. The entry
ordinal is stable within deterministic Document DNA finding order and contains
no personal value. Existing `dossier.row.<UUID>`, `dossier.sidebar`, source,
Document DNA, and invoice-payment identifiers remain unchanged.

At narrow widths, the inspector becomes an on-demand panel before primary
workspace content is compressed. Tests cover keyboard reachability, focus
transitions, VoiceOver labels, multiline layout, and the largest supported app
text setting.

## 14. Errors, Privacy, and Source Integrity

### 14.1 Error contract

Core adds or reuses typed boundary errors for:

- invalid or no-longer-current person anchor input;
- dossier not found;
- stale candidate, member, confirmation, or correction input;
- invalid stored state.

Create/open failure preserves the current workspace. Load and mutation failure
preserve the last complete displayed state. Retry starts a new generation.
Cancellation is silent. A stale or unavailable origin is normal projected
state, not an error.

Errors and logs contain no person names, exact text, absolute paths, content
hashes, bookmark data, or copied evidence. All processing remains local; this
slice adds no network-capable dependency or external processing path.

### 14.2 Source integrity

Candidate retrieval and dossier projection read only the local database.
Opening a source or navigating to evidence uses the existing security-scoped
access boundary, with every started scope balanced on all success, failure,
and cancellation paths.

The process-level UI smoke test compares an integrity snapshot before and after
creation, decisions, navigation, reanalysis, restart, reset, and catalog source
removal. The snapshot covers:

- relative path and entry kind;
- SHA-256 and byte count for regular files;
- modification date and POSIX mode;
- hidden files and directories;
- symbolic links and their destinations.

Removing a source through LinkLoom removes catalog-derived rows but not the
filesystem content. The existing costs dossier anchored in that source is
expected to cascade. The person dossier remains, has no current documents from
the removed source, and reports `Ursprungsnachweis nicht verfügbar`. Original
files are never renamed, moved, deleted, or intentionally modified.

## 15. Golden Fixtures

A new privacy-safe, versioned corpus lives under
`Tests/LinkLoomCoreTests/Fixtures/PersonDossier/v1/`. It does not modify or
weaken the existing Document DNA goldens.

The corpus manifest records for every synthetic document:

- ground-truth relevance;
- expected initial class: `automatic`, `suggestion`, or `hidden`;
- expected workspace section;
- expected ordered reason codes and evidence;
- invoice-payment decision state when applicable;
- expected states after accept, reject, remove, and exact-revision reset.

Required cases are:

1. the selected `resident` finding used as anchor;
2. exact `resident`, `insuredPerson`, `accountHolder`, `invoiceRecipient`, and
   `grantor` positives;
3. an OCR-backed exact primary-role positive;
4. a payment without a person finding reached through a confirmed invoice;
5. the same relationship shape with undecided and excluded decisions;
6. an exact match found only as `authorizedPerson`;
7. an exact primary-role homonym with a conflicting unambiguous birth date;
8. ground-truth-irrelevant boundary negatives containing an accent variation,
   abbreviated name, partial name, or unlabelled name that must remain hidden;
9. misleading organization, reference, filename, and directory similarities;
10. a second relationship hop that must not expand;
11. multiple confirmed paths to one deduplicated payment;
12. positive confirmation and exclusion surviving reanalysis;
13. stale and later unavailable origin support;
14. available, temporarily unavailable, missing, and deleted member behavior.

All names, organizations, dates, accounts, references, paths, and document
contents are fictional. Golden tests compare complete projected values, not
selected fields, and validate every expected evidence range against its
synthetic input.

The manifest designates one coherent baseline scenario for metric calculation.
Alternative decision, reanalysis, availability, and deletion states are
behavioral overlays on that corpus and do not simultaneously alter the metric
denominator. This prevents mutually exclusive states such as confirmed and
excluded versions of one relationship from being counted as separate archive
documents.

## 16. Precision and Recall

Ground truth is document membership in the synthetic manifest or the manually
reviewed local reference set. Only supported document formats inside selected
sources enter the denominator.

- **Automatic precision** = relevant automatically included documents divided
  by all automatically included documents.
- **Automatic recall** = relevant automatically included documents divided by
  all relevant documents.
- **Discoverable recall** = relevant automatic members plus relevant visible
  suggestions divided by all relevant documents.
- **Corrected quality** = precision and recall after the fixture's scripted
  user decisions.

Required gates are:

| Corpus | Automatic precision | Discoverable recall | Corrected quality |
| --- | ---: | ---: | ---: |
| Synthetic person-dossier goldens | 100% | 100% | 100% precision and recall |
| Local manually reviewed reference set | at least 90% | at least 80% | reported separately |

Automatic recall is always reported but is not an initial release gate. This
prevents the implementation from buying recall with unsupported fuzzy matches
that lower trust. The report also splits direct person membership from indirect
payment membership and reports every role and candidate class separately so a
large easy class cannot hide a failing rule.

The synthetic set contains at least one ground-truth-relevant secondary-role
suggestion, so automatic recall is meaningfully below discoverable recall. Its
hidden spelling and unlabelled cases are explicit irrelevant negatives; real
same-person variants outside the deterministic rules count as false negatives
in the local reference-set recall instead of being excluded from that metric.

The real personal archive, extracted text, person labels, and document-level
membership list remain local and outside version control. Only aggregate
counts and ratios may appear in a review report.

## 17. Verification Strategy

Behavior changes follow red-green-refactor in every implementation pull
request.

### 17.1 Domain and migration

- typed-anchor and person-anchor validation;
- same-origin idempotency and same-name non-identity;
- fresh migration and populated v7-to-v8 upgrade;
- byte-for-byte logical preservation of existing dossier and correction rows;
- kind-specific checks, uniqueness, indexes, foreign keys, and cascades;
- malformed UUID, enum, date, and evidence decoding;
- transaction rollback on injected migration or persistence failure.

### 17.2 Candidate and pure projection

- every primary and secondary role;
- exact Unicode normalization behavior without accent folding;
- conservative birth-date capture and conflict handling;
- hidden partial, fuzzy, and unlabelled cases;
- confirmed, undecided, excluded, stale, duplicate, and multi-hop payment
  relationships;
- exclusion precedence, confirmation persistence, deterministic order, and
  complete support identities;
- complete golden snapshots and metric calculation.

### 17.3 Repository and lifecycle

- atomic create/open/choose-or-create;
- one-transaction projection inputs;
- exact support and revision validation for every command;
- content change, exact-content return, path/source move, unavailable mount,
  missing file, source removal, and origin loss;
- cancellation and failure publishing no partial snapshot;
- active-dossier refresh after any relevant source analysis completion;
- no mutation of Document DNA or invoice-payment decisions.

### 17.4 AppModel and presentation

- typed workspace dispatch and sidebar summaries;
- creation, same-origin reopening, same-name choice, and explicit new dossier;
- document and counterpart navigation within and across sources;
- complete snapshot replacement and preservation on failure;
- duplicate-command suppression and late/ABA completion rejection;
- all German labels, reasons, availability states, disabled states,
  accessibility identifiers, focus transitions, and multiline layout.

### 17.5 Scale and end-to-end acceptance

An opt-in 10,000-document acceptance fixture proves that indexed person lookup
returns the correct small match set, does not materialize unrelated DNA
snapshots, and projects the expected dossier without quadratic candidate
comparison. Runtime is recorded diagnostically rather than using a
machine-fragile wall-clock gate.

The process-level UI smoke test starts from a clean database and:

1. scans synthetic sources and selects an eligible person finding;
2. creates the main dossier;
3. observes direct and confirmed-payment membership with explanations;
4. accepts one suggestion and rejects another;
5. removes and resets one automatic member;
6. navigates to exact evidence and an invoice-payment counterpart;
7. restarts and verifies decisions and the person dossier persist;
8. triggers reanalysis and verifies one complete updated snapshot;
9. removes the catalog source and verifies the person dossier survives with an
   unavailable origin;
10. proves the source-integrity snapshot is exactly unchanged.

Every production-code pull request runs focused tests, `swift test`,
`swift build -c release`, diff checks, staged diff checks before commit, and
status inspection. The final visible-workflow pull request also runs the exact
UI smoke command documented in `README.md`.

## 18. Sequential Pull Request Decomposition

Each implementation pull request starts from the then-current `origin/main`,
has one reviewable outcome, follows TDD, and leaves the complete suite green.
No visible partial feature is exposed before PR 5.

### PR 1: Persist typed anchors

Add the typed dossier-anchor domain, person-anchor values, v8 migration,
positive membership confirmation, storage primitives, and exhaustive migration
tests. Preserve every current costs-and-payments behavior. Do not add candidate
lookup, projection, repository commands, AppModel state, composition, or UI.

### PR 2: Retrieve and project person candidates

Add indexed current-person lookup, conservative conflict classification, the
pure person projector, one-hop confirmed-payment expansion, golden fixtures,
metric evaluation, and the opt-in 10,000-document acceptance test. Do not add
application ports or visible UI.

### PR 3: Add atomic repository commands

Extend the repository dispatcher with person create/open/choose-or-create,
consistent snapshot loading, accept, reject, remove, and reset. Add
reanalysis, lifecycle, stale-input, cancellation, and source-removal tests. Do
not add AppModel or UI behavior.

### PR 4: Orchestrate the typed workspace in `AppModel`

Add person-dossier loading and mutation ports, typed workspace state,
selection, navigation, complete publication, failure preservation, generation
guards, cancellation, and ABA tests. Do not add the entry action, production
composition, or person workspace view.

### PR 5: Integrate UI, accessibility, and product smoke

Add the per-person Document DNA action, sidebar presentation,
`PersonDossierView`, suggestions, corrections, focus behavior, stable
accessibility contract, production composition, README guidance, and the full
process-level source-integrity smoke workflow. This is the first pull request
that exposes the feature to the user.

Each pull request reports migration, privacy, compatibility, rollback, and
source-integrity implications and completes the repository's required
self-review. This sequence does not authorize pushing, merging, remote branch
deletion, or GitHub setting changes.

## 19. Acceptance Criteria

The vertical slice is complete when all five implementation pull requests have
established that:

- one selected current primary-role finding creates or reopens the correct
  persistent person dossier without treating name equality as global identity;
- the dossier survives stale or unavailable origin evidence;
- exact primary-role matches enter automatically unless a supported conflict
  demotes them;
- secondary-role and conflict candidates appear separately as suggestions;
- only a current confirmed invoice-payment edge adds a payment, and expansion
  stops after that one edge;
- every visible automatic member and suggestion has a source-backed reason;
  exact evidence is navigable whenever its original is available, while
  unavailable originals are labelled without presenting stale evidence as
  current;
- manual confirmation and exclusion are dossier-local, durable, mutually
  exclusive, reversible, and protected against stale commands;
- reanalysis, moves, unavailable sources, deletion, failures, cancellation,
  and ABA races never publish mixed or unintended state;
- the synthetic quality gates and local-reference targets are measured exactly
  as defined;
- the 10,000-document acceptance fixture proves bounded indexed retrieval;
- keyboard, VoiceOver, focus, text scaling, and automation identifiers satisfy
  the accessibility contract;
- source bytes, metadata, directories, hidden entries, and symbolic links are
  unchanged through the full process workflow;
- focused tests, the complete suite, release build, applicable UI smoke, diff
  checks, status inspection, and self-review pass.
