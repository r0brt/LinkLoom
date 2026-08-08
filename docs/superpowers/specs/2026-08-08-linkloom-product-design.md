# LinkLoom Product Design

**Status:** Approved design for the personal functional prototype

**Date:** 2026-08-08

**Primary user:** Private document power user

**Golden use case:** “Meine Mutter im Pflegeheim”

## 1. Product thesis

LinkLoom is a local-first semantic layer over files that already exist on a Mac, in mounted cloud folders, or on mounted network storage. It does not import documents into a proprietary archive and does not rename, move, or reorganize original files.

The product extracts a structured **Document DNA** from each supported document and uses it to identify meaningful relationships across locations. These relationships form persistent virtual contexts. A document may belong to several contexts without being duplicated.

The core promise is:

> Deine Dateien bleiben, wo sie sind. LinkLoom versteht, was sie bedeuten und wie sie zusammengehören.

The prototype’s primary aha moment is not semantic search by itself. It is the automatic creation of an explainable, correctable dossier from documents that are distributed across folders and storage locations.

## 2. Prototype objective

The prototype proves one product assumption end to end:

> Starting with one minimal anchor, LinkLoom can discover, explain, and organize the documents belonging to a real personal matter without requiring the user to move, tag, or manually link those documents.

The first milestone is a personal functional prototype for one user on one Mac. It is not a commercial beta or public version 1.0.

## 3. Target user and archive

The target user is a private power user who has accumulated a large personal document archive distributed across local folders, iCloud Drive, another mounted cloud drive such as Infomaniak Drive, and mounted NAS directories.

The supported archive size is up to 10,000 documents. This is both a product boundary and a required performance-test boundary.

## 4. Golden use case

The reference dossier is **“Meine Mutter im Pflegeheim.”** It is deliberately broad and sensitive enough to exercise the central product capabilities. Relevant documents may include:

- care-home contracts and tariff changes;
- invoices and matching bank payments;
- health-insurance statements and reimbursements;
- medical or care-related documents;
- powers of attorney and advance-care documents;
- correspondence with institutions and authorities.

LinkLoom begins with one explicit anchor: either the mother’s name or an unambiguous document. It then searches all selected sources and creates the dossier automatically. The user does not manually assign the remaining documents.

The application may create subcontexts such as:

- Heimvertrag;
- Kosten und Zahlungen;
- Krankenkasse;
- medizinische Versorgung;
- Vollmachten und Behörden;
- Korrespondenz.

These names are initial system proposals. The user may rename, merge, or correct them without changing the original files.

## 5. Scope

### 5.1 Included

- native macOS application experience;
- one user on one Mac;
- user-selected local or mounted filesystem folders;
- local folders, iCloud Drive, Infomaniak Drive, and NAS through their normal filesystem mounts;
- PDF, JPG, PNG, and HEIC;
- OCR for image scans and image-based PDF pages;
- local Document DNA extraction;
- local entity resolution and relationship detection;
- persistent virtual contexts and subcontexts;
- confidence-aware automatic inclusion and suggestions;
- visible reasons for every automatic relationship;
- user confirmation, removal, renaming, and merging;
- semantic search within the resulting dossier;
- incremental detection of new, changed, moved, unavailable, and deleted files;
- an offline-capable core workflow;
- an optional external AI quality tier behind explicit user approval.

### 5.2 Excluded

- Office documents, email, webpages, and notes;
- Windows or mobile applications;
- multiple users or shared household workspaces;
- multiple-Mac synchronization;
- native cloud-provider API integrations;
- task management and reminder workflows;
- legal, medical, or financial advice;
- licensing, accounts, billing, telemetry, public onboarding, support, and other commercial-release capabilities.

## 6. Non-negotiable file behavior

LinkLoom treats the existing filesystem as the source of truth.

- It never moves or renames an original document.
- It never changes original document contents or metadata intentionally.
- It never requires a LinkLoom-owned archive folder.
- It stores references and rebuildable derived knowledge, not replacement copies of the source documents.
- Opening or revealing a document always leads back to the original file.
- A document can participate in any number of contexts without duplication.

Locally cached thumbnails or temporary OCR renderings are allowed only as rebuildable implementation artifacts. They must not become an alternative document archive and must be removable without losing original files.

## 7. Information model

The model separates source identity, extracted knowledge, canonical entities, relationships, and presentation contexts.

### 7.1 Source document

A source-document record identifies the original file and its current availability. It includes:

- current path and source root;
- content fingerprint;
- filesystem identity where available;
- media type, size, and modification time;
- page count and extraction state;
- availability and last-seen state.

A path is not the sole identity. Content fingerprints and filesystem metadata allow LinkLoom to recognize moves, duplicates, and replacements without treating every path change as a new document.

### 7.2 Document DNA

Document DNA is the structured, versioned result of document analysis. It includes:

- document type;
- language;
- people and organizations;
- dates and date ranges;
- monetary amounts and currencies;
- addresses and places;
- account, contract, invoice, claim, and reference identifiers;
- topics and objects;
- extracted summary suitable for local retrieval;
- model, extractor, and schema versions used to create the DNA.

Every extracted fact retains provenance: page number and text span or OCR region. An extracted value without traceable evidence cannot be promoted to a trusted fact.

### 7.3 Entity

An entity is a canonical representation of a real-world person, organization, place, account, contract, or other identifiable object. It retains aliases and source-specific forms rather than discarding them.

Entity resolution is confidence-aware. Similar names alone are insufficient for a high-confidence merge when stronger conflicting identifiers exist.

### 7.4 Relationship

A relationship is a typed, evidence-backed statement connecting documents, entities, facts, or contexts. Examples include:

- document concerns person;
- invoice issued by organization;
- payment settles invoice;
- document refers to contract;
- person resides at care home;
- document belongs to context.

Each relationship stores its type, supporting evidence, confidence, analysis version, and user decision state. It is more than a raw semantic-similarity score.

### 7.5 Context

A context is a persistent virtual view over documents, entities, relationships, and other contexts. It has a name, explanation, membership evidence, and optional parent context. It is not a folder or exclusive tag.

Context membership is itself a relationship. This makes multiple membership natural and keeps every inclusion explainable.

### 7.6 User decision and correction knowledge

User decisions are stored separately from model output. They include confirmations, exclusions, entity merges or splits, context renames, and context merges.

Reanalysis must preserve these decisions. A removed relationship becomes a negative constraint so that the same unsupported relationship is not recreated automatically after every scan.

## 8. Confidence and explainability

Relationship candidates are handled in three bands:

1. **High confidence:** automatically included in the dossier.
2. **Medium confidence:** shown as a suggestion requiring review.
3. **Low confidence:** not shown in the main dossier, but retained as diagnostic candidate data when useful.

Exact thresholds are calibrated against the golden reference dossier rather than fixed prematurely. High-confidence auto-inclusion is optimized for precision because false inclusion damages trust more than a visible suggestion does.

Every visible relationship explains its strongest reasons in plain language, such as matching person identifiers, institution, address, contract number, period, amount, or payment reference. The user can navigate from a reason to the exact source location.

## 9. User experience

### 9.1 First-run flow

1. The user selects one or more source folders.
2. The application explains that originals remain untouched and analysis remains local.
3. The user supplies the mother’s name or selects an unambiguous anchor document.
4. LinkLoom scans and analyzes the selected sources while showing progress, discovered-document count, and recoverable errors.
5. The application opens the generated dossier rather than presenting a generic dashboard.

### 9.2 Dossier workspace

The approved baseline is **UX Variant 1A**, a high-information three-column workspace:

- the left column navigates dossiers, suggestions, documents, and sources;
- the center column shows the selected dossier and its subcontexts with representative documents;
- the right inspector explains why the current document or relationship belongs to the context and offers confirmation or removal.

The final visual treatment must preserve the information available at a glance while increasing whitespace between cards, sections, and columns. Closely related facts remain compact; distinct functional regions receive stronger spatial separation.

When horizontal space is limited, the interface progressively collapses secondary regions. It must not merely compress all three columns until labels and cards become crowded. The inspector is the first region that may become an on-demand panel.

### 9.3 Supporting views

- semantic search retrieves documents by meaning and can be scoped to a dossier or subcontext;
- a suggestion view collects medium-confidence candidates;
- a document detail view shows Document DNA, evidence, relationships, and the original-file action;
- a source view shows indexing status and unavailable mounts without becoming a replacement file manager.

A context map or timeline may become an optional view later. Neither is required for the first functional prototype.

## 10. Local architecture

The application is composed of bounded local components with explicit inputs and outputs.

### 10.1 File catalog

The file catalog monitors selected roots and records additions, changes, moves, temporary unavailability, and deletion. It schedules only the work required by the changed state.

### 10.2 Extraction pipeline

The extraction pipeline reads embedded PDF text where available and performs OCR when required. It produces normalized text plus page and region provenance. Extraction failure is isolated to the affected file.

### 10.3 Document DNA engine

The DNA engine classifies documents and extracts typed facts. Its output follows a versioned schema so that a model or extractor upgrade can trigger controlled reanalysis.

### 10.4 Graph engine

The graph engine canonicalizes entities, retrieves plausible relationship candidates, scores them, and stores evidence-backed edges. Candidate retrieval narrows comparisons so that relationship detection does not require comparing every document with every other document.

### 10.5 Context engine

The context engine starts from the explicit anchor and expands through high-confidence relationships. It proposes subcontexts and routes medium-confidence membership to suggestions.

### 10.6 Application layer

The application layer presents dossiers, search, suggestions, explanations, corrections, and source status. It reads original files only through the source-document references.

### 10.7 Local stores

The prototype uses local, rebuildable stores for:

- catalog state, Document DNA, provenance, user decisions, entities, relationships, and contexts;
- full-text search;
- local vector representations and nearest-neighbor candidate retrieval;
- optional thumbnails and transient processing artifacts.

A relational embedded database such as SQLite is the default store for catalog, DNA, graph edges, and user decisions. Full-text and vector indexing may use embedded extensions or rebuildable sidecar indexes, provided the entire core remains local.

## 11. Data flow

1. The user grants access to selected filesystem roots.
2. The catalog fingerprints supported files and identifies changed work.
3. The extraction pipeline produces text, OCR output, and provenance.
4. The DNA engine produces versioned structured facts.
5. The graph engine resolves entities and generates relationship candidates.
6. Confidence scoring separates automatic relationships from suggestions.
7. The context engine expands from the user’s anchor and builds the dossier and subcontexts.
8. The application presents membership reasons and correction actions.
9. User decisions become durable constraints.
10. Later filesystem changes rerun only affected pipeline stages and dependent relationships.

The pipeline is idempotent: rerunning the same analysis version over unchanged inputs must not duplicate facts, edges, or contexts.

## 12. Privacy boundary and optional external AI

OCR, Document DNA, semantic search, entity resolution, relationship detection, and context creation must produce a useful result without an internet connection.

External AI is an optional enhancement, not a hidden dependency. Before any external request, the application must show what will be sent and require explicit approval. Approval for one action does not silently enable unrestricted future processing.

Original files, extracted text, DNA, embeddings, relationships, and user corrections remain stored locally. The external path must be replaceable without changing the local information model.

## 13. Failure handling

Each document advances independently through explicit processing states such as discovered, extracting, analyzed, linked, failed, and unavailable.

- A corrupt or unsupported file does not stop the archive scan.
- Password-protected documents are reported without repeated failed processing.
- Low-confidence OCR reduces downstream confidence and remains visible in evidence details.
- A temporarily unavailable mounted source preserves known derived data while clearly marking the original as unavailable.
- Confirmed deletion is distinct from temporary unavailability.
- Duplicate content is identified without deleting either original path.
- Interrupted processing resumes from durable stage state.
- Model or schema changes trigger controlled reanalysis while retaining user decisions.

No inferred medical, legal, or financial interpretation is presented as professional advice.

## 14. Quality targets

Against a manually reviewed reference set for “Meine Mutter im Pflegeheim,” the prototype targets:

- at least 90% precision among automatically included documents;
- at least 80% recall of all relevant documents;
- at least one inspectable source-backed reason for every automatic inclusion;
- clear separation of uncertain suggestions from automatic membership;
- successful incremental updating after additions, edits, moves, unavailability, and deletions;
- a complete core workflow without network access;
- reliable operation on a corpus of up to 10,000 supported documents.

Precision and recall are measured on document membership in the golden dossier. Subcontext quality is reviewed separately because meaningful grouping may have more than one acceptable structure.

## 15. Verification strategy

### 15.1 Unit verification

- file identity and change classification;
- text normalization and provenance mapping;
- Document DNA schema validation;
- entity matching and conflict rules;
- confidence-band assignment;
- preservation of negative constraints and other user decisions.

### 15.2 Golden fixtures

A privacy-safe synthetic fixture set covers contracts, invoices, payments, insurance statements, OCR scans, duplicates, misleading name matches, and conflicting identifiers. Expected DNA, relationships, and context membership are version controlled.

The real personal archive remains local and outside version control. Its manually reviewed membership list is stored locally and used for prototype evaluation without committing document contents.

### 15.3 Integration verification

- scan selected roots and process mixed supported formats;
- match invoices with payments using multiple independent signals;
- rebuild affected relationships after a document change;
- recognize a moved file without duplicating its knowledge;
- preserve dossier state while a mounted source is unavailable;
- resume interrupted processing;
- verify that optional external processing never occurs without approval.

### 15.4 End-to-end acceptance

Starting from a clean local database, the user selects sources, supplies the anchor, waits for local analysis, opens the generated dossier, inspects a relationship reason, removes one false relationship, and confirms that the correction survives reanalysis.

Automated acceptance checks compare source paths, names, content hashes, and relevant metadata before and after the workflow to verify that originals remain unchanged.

## 16. Design decisions and deferred choices

The product scope, local-first boundary, golden use case, information model, architecture, baseline UX, robustness behavior, and quality targets are approved.

Implementation-language choices, concrete local models, OCR libraries, embedding models, vector-index technology, and macOS framework selection are intentionally deferred to the implementation plan. Those choices must satisfy this design rather than redefine it.
