# LinkLoom Ingestion Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native, local macOS vertical slice that remembers user-selected folders, catalogs up to 10,000 supported documents without changing them, extracts page-scoped text from PDFs and image scans, and shows scan results in a SwiftUI application.

**Architecture:** A Swift Package contains a UI-independent `LinkLoomCore` library and a small SwiftUI executable, `LinkLoomApp`. Core services communicate through explicit protocols, store catalog and extraction state in local SQLite through GRDB, and treat original files as read-only inputs. Scans are idempotent, failures are isolated per document, and filesystem events trigger debounced incremental reconciliation.

**Tech Stack:** Swift 6.3 toolchain with Swift tools version 6.2, SwiftUI, AppKit, Foundation, UniformTypeIdentifiers, CryptoKit, PDFKit, Vision, Core Services FSEvents, Swift Testing, GRDB.swift 7.10.0, SQLite FTS5.

## Global Constraints

- The application is native macOS software for one user on one Mac.
- The first supported archive boundary is 10,000 documents.
- Sources are user-selected local or mounted filesystem folders, including mounted iCloud Drive, Infomaniak Drive, and NAS locations.
- Supported formats are PDF, JPG/JPEG, PNG, and HEIC.
- LinkLoom never moves, renames, writes, or intentionally changes metadata on an original document.
- LinkLoom stores references and rebuildable derived knowledge, not replacement copies of documents.
- PDF text and OCR output retain a zero-based page index; OCR output additionally retains normalized bounding boxes.
- The complete scan and extraction path works without network access.
- One corrupt, encrypted, unavailable, or unsupported file cannot stop other files from processing.
- User-selected source access is represented by persistent security-scoped bookmarks, even while the SwiftPM prototype runs outside an App Sandbox.
- Source paths may be shown in the local UI but must never be emitted in ordinary logs or test snapshots.
- GRDB is pinned to 7.10.0 for reproducible builds.
- The implementation target is macOS 15 or later; development is verified on the available macOS 26.4 / Swift 6.3 environment.

---

## Roadmap Boundary

The approved product design contains five independently reviewable implementation areas. This plan covers only the first and leaves the repository in a working, demonstrable state before the next plan begins.

1. **This plan — ingestion foundation:** source access, catalog, text extraction, incremental scanning, and a diagnostic SwiftUI interface.
2. **Document DNA plan:** versioned classification and typed fact extraction with evidence.
3. **Knowledge graph plan:** canonical entities, candidate retrieval, typed relationships, and confidence bands.
4. **Context plan:** anchor expansion, subcontexts, suggestions, and durable correction constraints.
5. **Dossier experience plan:** approved UX Variant 1A, semantic search, golden-dossier evaluation, and the 10,000-document acceptance run.

The current plan must not introduce cloud AI, embeddings, entity resolution, relationship scoring, or final dossier cards. Its output is the stable local substrate those later plans consume.

## File Structure

```text
Package.swift
README.md
Sources/
  LinkLoomCore/
    Models/
      SourceRootRecord.swift
      DocumentRecord.swift
      ExtractionModels.swift
    Persistence/
      AppDatabase.swift
      SourceRootRepository.swift
      DocumentRepository.swift
      ExtractionRepository.swift
    FileAccess/
      SourceAccess.swift
      DefaultSourceAccess.swift
    Catalog/
      FileEnumerator.swift
      FileFingerprinter.swift
      CatalogService.swift
    Extraction/
      DocumentTextExtractor.swift
      PDFEmbeddedTextExtractor.swift
      VisionOCRRecognizer.swift
      PDFPageRenderer.swift
      CompositeTextExtractor.swift
    Pipeline/
      IngestionPipeline.swift
    Watching/
      DirectoryWatcher.swift
      FSEventsDirectoryWatcher.swift
      RescanScheduler.swift
  LinkLoomApp/
    LinkLoomApp.swift
  LinkLoomAppFeature/
    AppModel.swift
    FolderPicker.swift
    ContentView.swift
    SourceSidebar.swift
    ScanDashboard.swift
Tests/
  LinkLoomCoreTests/
    Support/
      TemporaryDirectory.swift
      FixtureFactory.swift
      TestDatabase.swift
    AppDatabaseTests.swift
    SourceAccessTests.swift
    FileEnumeratorTests.swift
    FileFingerprinterTests.swift
    CatalogServiceTests.swift
    PDFEmbeddedTextExtractorTests.swift
    VisionOCRRecognizerTests.swift
    CompositeTextExtractorTests.swift
    IngestionPipelineTests.swift
    RescanSchedulerTests.swift
    IngestionAcceptanceTests.swift
  LinkLoomAppFeatureTests/
    AppModelTests.swift
```

Each production file has one responsibility. `LinkLoomCore` contains no SwiftUI types. The app target composes the core services and translates state into views.

### Task 1: Swift package, domain records, and initial database

**Files:**
- Create: `Package.swift`
- Create: `Sources/LinkLoomCore/Models/SourceRootRecord.swift`
- Create: `Sources/LinkLoomCore/Models/DocumentRecord.swift`
- Create: `Sources/LinkLoomCore/Persistence/AppDatabase.swift`
- Create: `Tests/LinkLoomCoreTests/Support/TestDatabase.swift`
- Test: `Tests/LinkLoomCoreTests/AppDatabaseTests.swift`

**Interfaces:**
- Produces: `SourceRootRecord`, `DocumentRecord`, `SupportedMediaType`, `DocumentStatus`, and `DocumentAvailability`.
- Produces: `AppDatabase.makeQueue(at:) -> DatabaseQueue` and `AppDatabase.migrate(_:)`.
- Consumes: no earlier application interfaces.

- [ ] **Step 1: Create the package manifest and a failing migration test**

Create `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LinkLoom",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LinkLoomCore", targets: ["LinkLoomCore"]),
        .executable(name: "LinkLoomApp", targets: ["LinkLoomApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
    ],
    targets: [
        .target(
            name: "LinkLoomCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "LinkLoomAppFeature", dependencies: ["LinkLoomCore"]),
        .executableTarget(
            name: "LinkLoomApp",
            dependencies: ["LinkLoomCore", "LinkLoomAppFeature"]
        ),
        .testTarget(
            name: "LinkLoomCoreTests",
            dependencies: ["LinkLoomCore"]
        ),
        .testTarget(
            name: "LinkLoomAppFeatureTests",
            dependencies: ["LinkLoomAppFeature", "LinkLoomCore"]
        ),
    ]
)
```

Create `Tests/LinkLoomCoreTests/Support/TestDatabase.swift`:

```swift
import GRDB
import LinkLoomCore

enum TestDatabase {
    static func make() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrate(queue)
        return queue
    }
}
```

Create `Tests/LinkLoomCoreTests/AppDatabaseTests.swift`:

```swift
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("App database")
struct AppDatabaseTests {
    @Test func initialMigrationCreatesCatalogTables() throws {
        let db = try TestDatabase.make()
        try db.read { connection in
            #expect(try connection.tableExists("sourceRoot"))
            #expect(try connection.tableExists("document"))
            #expect(try connection.indexes(on: "document").contains { $0.name == "document_source_relative_unique" })
        }
    }
}
```

- [ ] **Step 2: Run the test to verify the missing types fail compilation**

Run: `swift test --filter AppDatabaseTests`

Expected: FAIL with unresolved symbols for `AppDatabase` and the missing `LinkLoomCore` source target.

- [ ] **Step 3: Add records and the v1 migration**

Create `SourceRootRecord.swift`:

```swift
import Foundation
import GRDB

public struct SourceRootRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "sourceRoot"

    public var id: UUID
    public var displayName: String
    public var pathHint: String
    public var bookmarkData: Data
    public var createdAt: Date
    public var lastScanAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        pathHint: String,
        bookmarkData: Data,
        createdAt: Date = .now,
        lastScanAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.pathHint = pathHint
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.lastScanAt = lastScanAt
    }
}
```

Create `DocumentRecord.swift`:

```swift
import Foundation
import GRDB

public enum SupportedMediaType: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case pdf
    case jpeg
    case png
    case heic
}

public enum DocumentStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case discovered
    case extracting
    case ready
    case failed
}

public enum DocumentAvailability: String, Codable, DatabaseValueConvertible, Sendable {
    case available
    case unavailable
    case missing
}

public struct DocumentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "document"

    public var id: UUID
    public var sourceRootID: UUID
    public var relativePath: String
    public var contentHash: String
    public var byteCount: Int64
    public var modifiedAt: Date
    public var mediaType: SupportedMediaType
    public var status: DocumentStatus
    public var availability: DocumentAvailability
    public var pageCount: Int?
    public var failureCode: String?
    public var lastSeenAt: Date

    public init(
        id: UUID = UUID(),
        sourceRootID: UUID,
        relativePath: String,
        contentHash: String,
        byteCount: Int64,
        modifiedAt: Date,
        mediaType: SupportedMediaType,
        status: DocumentStatus = .discovered,
        availability: DocumentAvailability = .available,
        pageCount: Int? = nil,
        failureCode: String? = nil,
        lastSeenAt: Date = .now
    ) {
        self.id = id
        self.sourceRootID = sourceRootID
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.mediaType = mediaType
        self.status = status
        self.availability = availability
        self.pageCount = pageCount
        self.failureCode = failureCode
        self.lastSeenAt = lastSeenAt
    }
}
```

Create `AppDatabase.swift`:

```swift
import Foundation
import GRDB

public enum AppDatabase {
    public static func makeQueue(at url: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: url.path)
        try migrate(queue)
        return queue
    }

    public static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_catalog") { db in
            try db.create(table: "sourceRoot") { table in
                table.column("id", .text).primaryKey()
                table.column("displayName", .text).notNull()
                table.column("pathHint", .text).notNull()
                table.column("bookmarkData", .blob).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("lastScanAt", .datetime)
            }
            try db.create(table: "document") { table in
                table.column("id", .text).primaryKey()
                table.column("sourceRootID", .text).notNull()
                    .references("sourceRoot", onDelete: .cascade)
                table.column("relativePath", .text).notNull()
                table.column("contentHash", .text).notNull()
                table.column("byteCount", .integer).notNull()
                table.column("modifiedAt", .datetime).notNull()
                table.column("mediaType", .text).notNull()
                table.column("status", .text).notNull()
                table.column("availability", .text).notNull()
                table.column("pageCount", .integer)
                table.column("failureCode", .text)
                table.column("lastSeenAt", .datetime).notNull()
                table.uniqueKey(["sourceRootID", "relativePath"])
            }
            try db.create(
                index: "document_source_relative_unique",
                on: "document",
                columns: ["sourceRootID", "relativePath"],
                unique: true
            )
            try db.create(index: "document_content_hash", on: "document", columns: ["contentHash"])
            try db.create(index: "document_status", on: "document", columns: ["status"])
        }
        try migrator.migrate(writer)
    }
}
```

- [ ] **Step 4: Run the migration test and the full suite**

Run: `swift test --filter AppDatabaseTests`

Expected: PASS with 1 test.

Run: `swift test`

Expected: PASS with no failures.

- [ ] **Step 5: Commit the package foundation**

```bash
git add Package.swift Sources/LinkLoomCore/Models Sources/LinkLoomCore/Persistence/AppDatabase.swift Tests/LinkLoomCoreTests/Support/TestDatabase.swift Tests/LinkLoomCoreTests/AppDatabaseTests.swift Package.resolved
git commit -m "feat: establish local catalog database"
```

### Task 2: Persistent source access and source repository

**Files:**
- Create: `Sources/LinkLoomCore/FileAccess/SourceAccess.swift`
- Create: `Sources/LinkLoomCore/FileAccess/DefaultSourceAccess.swift`
- Create: `Sources/LinkLoomCore/Persistence/SourceRootRepository.swift`
- Test: `Tests/LinkLoomCoreTests/SourceAccessTests.swift`

**Interfaces:**
- Consumes: `SourceRootRecord`, migrated `sourceRoot` table.
- Produces: `SourceAccessing.createBookmark(for:)` and `SourceAccessing.withAccess(to:operation:)`.
- Produces: `SourceRootRepository.add(url:sourceAccess:)`, `all()`, `updateLastScan(id:at:)`, and `remove(id:)`.

- [ ] **Step 1: Write failing repository and access-lifetime tests**

Create `SourceAccessTests.swift` with a fake access adapter that records balanced start/stop calls:

```swift
import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Source access")
struct SourceAccessTests {
    @Test func repositoryPersistsBookmarkAndReturnsSource() async throws {
        let db = try TestDatabase.make()
        let repository = SourceRootRepository(dbWriter: db)
        let access = FakeSourceAccess(url: URL(fileURLWithPath: "/Volumes/Test"))

        let source = try await repository.add(
            url: access.url,
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(source.displayName == "Test")
        #expect(try await repository.all() == [source])
        #expect(access.createdBookmarkCount == 1)
    }

    @Test func withAccessStopsAfterThrownOperation() async {
        let access = FakeSourceAccess(url: URL(fileURLWithPath: "/Volumes/Test"))

        await #expect(throws: ProbeError.self) {
            try await access.withAccess(to: Data("bookmark".utf8)) { _ in
                throw ProbeError()
            }
        }
        #expect(access.startCount == 1)
        #expect(access.stopCount == 1)
    }
}

private struct ProbeError: Error {}
```

The same file defines `FakeSourceAccess: SourceAccessing` with `NSLock`-protected counters, a deterministic bookmark, and the supplied URL.

- [ ] **Step 2: Run the tests to verify the missing interfaces fail**

Run: `swift test --filter SourceAccessTests`

Expected: FAIL because `SourceAccessing`, `FakeSourceAccess`, and `SourceRootRepository` are undefined.

- [ ] **Step 3: Implement the source-access protocol and Foundation adapter**

Create `SourceAccess.swift`:

```swift
import Foundation

public struct ResolvedSource: Sendable {
    public let url: URL
    public let bookmarkWasStale: Bool
}

public protocol SourceAccessing: Sendable {
    func createBookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> ResolvedSource
    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T
}
```

Create `DefaultSourceAccess.swift`:

```swift
import Foundation

public struct DefaultSourceAccess: SourceAccessing {
    public init() {}

    public func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolve(_ bookmark: Data) throws -> ResolvedSource {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return ResolvedSource(url: url, bookmarkWasStale: stale)
    }

    public func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let resolved = try resolve(bookmark)
        let started = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if started { resolved.url.stopAccessingSecurityScopedResource() }
        }
        return try await operation(resolved.url)
    }
}
```

- [ ] **Step 4: Implement repository operations**

Create `SourceRootRepository.swift` as an actor with a GRDB writer:

```swift
import Foundation
import GRDB

public actor SourceRootRepository {
    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func add(
        url: URL,
        sourceAccess: any SourceAccessing,
        now: Date = .now
    ) async throws -> SourceRootRecord {
        let bookmark = try sourceAccess.createBookmark(for: url)
        let record = SourceRootRecord(
            displayName: url.lastPathComponent,
            pathHint: url.path,
            bookmarkData: bookmark,
            createdAt: now
        )
        try dbWriter.write { db in try record.insert(db) }
        return record
    }

    public func all() async throws -> [SourceRootRecord] {
        try dbWriter.read { db in
            try SourceRootRecord.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func updateLastScan(id: UUID, at date: Date) async throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE sourceRoot SET lastScanAt = ? WHERE id = ?",
                arguments: [date, id]
            )
        }
    }

    public func remove(id: UUID) async throws {
        try dbWriter.write { db in
            _ = try SourceRootRecord.deleteOne(db, key: id)
        }
    }
}
```

- [ ] **Step 5: Run access tests and all tests**

Run: `swift test --filter SourceAccessTests`

Expected: PASS with 2 tests.

Run: `swift test`

Expected: PASS with no failures and balanced access counters.

- [ ] **Step 6: Commit source access**

```bash
git add Sources/LinkLoomCore/FileAccess Sources/LinkLoomCore/Persistence/SourceRootRepository.swift Tests/LinkLoomCoreTests/SourceAccessTests.swift
git commit -m "feat: persist user-selected source access"
```

### Task 3: Supported-file enumeration and streaming fingerprints

**Files:**
- Create: `Sources/LinkLoomCore/Catalog/FileEnumerator.swift`
- Create: `Sources/LinkLoomCore/Catalog/FileFingerprinter.swift`
- Create: `Tests/LinkLoomCoreTests/Support/TemporaryDirectory.swift`
- Test: `Tests/LinkLoomCoreTests/FileEnumeratorTests.swift`
- Test: `Tests/LinkLoomCoreTests/FileFingerprinterTests.swift`

**Interfaces:**
- Consumes: `SupportedMediaType`.
- Produces: `FileCandidate`, `FileEnumerating.files(in:)`, `FileFingerprint`, and `FileFingerprinting.fingerprint(_:)`.
- Guarantees: enumeration is deterministic, ignores hidden files and package descendants, and returns only supported media.

- [ ] **Step 1: Write failing enumeration and hash tests**

The enumeration test creates `a.pdf`, `b.JPG`, `c.png`, `d.heic`, `.hidden.pdf`, and `notes.txt` under a temporary root and asserts that the four visible supported files are returned in relative-path order.

The fingerprint test writes equal bytes at two different paths and different bytes at a third path:

```swift
@Test func fingerprintDependsOnContentNotPath() async throws {
    let directory = try TemporaryDirectory()
    let first = try directory.write("first.pdf", bytes: Data("same".utf8))
    let second = try directory.write("second.pdf", bytes: Data("same".utf8))
    let changed = try directory.write("changed.pdf", bytes: Data("changed".utf8))
    let fingerprinter = SHA256FileFingerprinter()

    let firstHash = try await fingerprinter.fingerprint(first).sha256
    let secondHash = try await fingerprinter.fingerprint(second).sha256
    let changedHash = try await fingerprinter.fingerprint(changed).sha256

    #expect(firstHash == secondHash)
    #expect(firstHash != changedHash)
}
```

- [ ] **Step 2: Run the tests to verify missing implementations fail**

Run: `swift test --filter FileEnumeratorTests`

Expected: FAIL with undefined `DefaultFileEnumerator`.

Run: `swift test --filter FileFingerprinterTests`

Expected: FAIL with undefined `SHA256FileFingerprinter`.

- [ ] **Step 3: Implement deterministic enumeration**

Create `FileEnumerator.swift`:

```swift
import Foundation
import UniformTypeIdentifiers

public struct FileCandidate: Sendable, Equatable {
    public let url: URL
    public let relativePath: String
    public let mediaType: SupportedMediaType
    public let byteCount: Int64
    public let modifiedAt: Date
}

public protocol FileEnumerating: Sendable {
    func files(in root: URL) throws -> [FileCandidate]
}

public struct DefaultFileEnumerator: FileEnumerating {
    public init() {}

    public func files(in root: URL) throws -> [FileCandidate] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let iterator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var files: [FileCandidate] = []
        while let url = iterator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, let media = SupportedMediaType.detect(url) else { continue }
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            files.append(FileCandidate(
                url: url,
                relativePath: relative,
                mediaType: media,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}

public extension SupportedMediaType {
    static func detect(_ url: URL) -> SupportedMediaType? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .png) { return .png }
        if type.identifier == "public.heic" || type.conforms(to: .heic) { return .heic }
        return nil
    }
}
```

- [ ] **Step 4: Implement streaming SHA-256**

Create `FileFingerprinter.swift`:

```swift
import CryptoKit
import Foundation

public struct FileFingerprint: Sendable, Equatable {
    public let sha256: String
    public let byteCount: Int64
}

public protocol FileFingerprinting: Sendable {
    func fingerprint(_ url: URL) async throws -> FileFingerprint
}

public struct SHA256FileFingerprinter: FileFingerprinting {
    public init() {}

    public func fingerprint(_ url: URL) async throws -> FileFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteCount += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileFingerprint(sha256: digest, byteCount: byteCount)
    }
}
```

- [ ] **Step 5: Run focused and complete tests**

Run: `swift test --filter FileEnumeratorTests`

Expected: PASS; only four supported visible files are returned.

Run: `swift test --filter FileFingerprinterTests`

Expected: PASS; equal content has equal hashes and changed content has a different hash.

Run: `swift test`

Expected: PASS with no failures.

- [ ] **Step 6: Commit enumeration and fingerprints**

```bash
git add Sources/LinkLoomCore/Catalog/FileEnumerator.swift Sources/LinkLoomCore/Catalog/FileFingerprinter.swift Tests/LinkLoomCoreTests/Support/TemporaryDirectory.swift Tests/LinkLoomCoreTests/FileEnumeratorTests.swift Tests/LinkLoomCoreTests/FileFingerprinterTests.swift
git commit -m "feat: enumerate and fingerprint supported documents"
```

### Task 4: Idempotent catalog reconciliation

**Files:**
- Create: `Sources/LinkLoomCore/Persistence/DocumentRepository.swift`
- Create: `Sources/LinkLoomCore/Catalog/CatalogService.swift`
- Test: `Tests/LinkLoomCoreTests/CatalogServiceTests.swift`

**Interfaces:**
- Consumes: `SourceRootRecord`, `SourceAccessing`, `FileEnumerating`, and `FileFingerprinting`.
- Produces: `ScanReport` and `CatalogService.scan(source:now:)`.
- Produces repository queries `all(sourceRootID:)`, `pendingExtraction(limit:)`, `markStatus(id:status:pageCount:failureCode:)`, `markAvailability(id:availability:)`, and reconciliation writes.

- [ ] **Step 1: Write failing catalog scenarios**

Cover six behaviors in `CatalogServiceTests.swift`:

```swift
@Test func firstScanDiscoversSupportedDocuments() async throws
@Test func unchangedRescanDoesNotFingerprintAgain() async throws
@Test func changedFileKeepsIdentityAndReturnsToDiscovered() async throws
@Test func missingFileIsMarkedMissingWithoutDeletingRecord() async throws
@Test func movedFileKeepsIdentityWhenHashMatchIsUnique() async throws
@Test func duplicateContentAtNewPathCreatesSeparateRecord() async throws
```

Use fakes for source access, enumeration, and fingerprinting. The second test asserts the fake fingerprinter’s call count remains unchanged on the second scan. The changed-file test uses the same relative path with a different byte count and modification date and asserts the document UUID remains stable. A move reuses an unmatched record only when exactly one unmatched record has the same content hash; otherwise a new UUID preserves duplicate paths as separate source records.

- [ ] **Step 2: Run the suite to verify missing catalog types fail**

Run: `swift test --filter CatalogServiceTests`

Expected: FAIL because `DocumentRepository`, `CatalogService`, and `ScanReport` are undefined.

- [ ] **Step 3: Implement document repository operations**

Create `DocumentRepository.swift` with these exact public signatures:

```swift
public actor DocumentRepository {
    public init(dbWriter: any DatabaseWriter)
    public func all(sourceRootID: UUID) async throws -> [DocumentRecord]
    public func all() async throws -> [DocumentRecord]
    public func pendingExtraction(limit: Int) async throws -> [DocumentRecord]
    public func save(_ document: DocumentRecord) async throws
    public func markMissing(sourceRootID: UUID, excludingDocumentIDs: Set<UUID>) async throws -> Int
    public func markAvailability(id: UUID, availability: DocumentAvailability) async throws
    public func markStatus(
        id: UUID,
        status: DocumentStatus,
        pageCount: Int? = nil,
        failureCode: String? = nil
    ) async throws
}
```

Implement `markMissing` by fetching IDs for the source and updating unmatched IDs inside one transaction. Do not construct a 10,000-value `NOT IN` clause, and never delete source-document knowledge during reconciliation. `pendingExtraction` returns only records whose availability is `.available` and whose status is `.discovered`.

- [ ] **Step 4: Implement catalog reconciliation**

Create `CatalogService.swift`:

```swift
import Foundation

public struct ScanReport: Sendable, Equatable {
    public let sourceRootID: UUID
    public let discovered: Int
    public let changed: Int
    public let unchanged: Int
    public let missing: Int
}

public struct CatalogService: Sendable {
    private let sourceAccess: any SourceAccessing
    private let enumerator: any FileEnumerating
    private let fingerprinter: any FileFingerprinting
    private let documents: DocumentRepository
    private let sources: SourceRootRepository

    public init(
        sourceAccess: any SourceAccessing,
        enumerator: any FileEnumerating,
        fingerprinter: any FileFingerprinting,
        documents: DocumentRepository,
        sources: SourceRootRepository
    ) {
        self.sourceAccess = sourceAccess
        self.enumerator = enumerator
        self.fingerprinter = fingerprinter
        self.documents = documents
        self.sources = sources
    }

    public func scan(source: SourceRootRecord, now: Date = .now) async throws -> ScanReport {
        try await sourceAccess.withAccess(to: source.bookmarkData) { root in
            let candidates = try enumerator.files(in: root)
            let existing = try await documents.all(sourceRootID: source.id)
            let byPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.relativePath, $0) })
            var matchedExistingIDs = Set<UUID>()
            var newPathCandidates: [FileCandidate] = []
            var discovered = 0, changed = 0, unchanged = 0

            for candidate in candidates {
                guard var previous = byPath[candidate.relativePath] else {
                    newPathCandidates.append(candidate)
                    continue
                }
                matchedExistingIDs.insert(previous.id)
                previous.lastSeenAt = now
                previous.availability = .available

                if previous.byteCount == candidate.byteCount,
                   previous.modifiedAt == candidate.modifiedAt {
                    try await documents.save(previous)
                    unchanged += 1
                    continue
                }

                let fingerprint = try await fingerprinter.fingerprint(candidate.url)
                previous.contentHash = fingerprint.sha256
                previous.byteCount = fingerprint.byteCount
                previous.modifiedAt = candidate.modifiedAt
                previous.mediaType = candidate.mediaType
                previous.status = .discovered
                previous.pageCount = nil
                previous.failureCode = nil
                try await documents.save(previous)
                changed += 1
            }

            for candidate in newPathCandidates {
                let fingerprint = try await fingerprinter.fingerprint(candidate.url)
                let relocationMatches = existing.filter {
                    !matchedExistingIDs.contains($0.id) && $0.contentHash == fingerprint.sha256
                }
                let relocated = relocationMatches.count == 1 ? relocationMatches[0] : nil
                let record = DocumentRecord(
                    id: relocated?.id ?? UUID(),
                    sourceRootID: source.id,
                    relativePath: candidate.relativePath,
                    contentHash: fingerprint.sha256,
                    byteCount: fingerprint.byteCount,
                    modifiedAt: candidate.modifiedAt,
                    mediaType: candidate.mediaType,
                    status: .discovered,
                    availability: .available,
                    lastSeenAt: now
                )
                try await documents.save(record)
                matchedExistingIDs.insert(record.id)
                if relocated == nil { discovered += 1 } else { changed += 1 }
            }

            let missing = try await documents.markMissing(
                sourceRootID: source.id,
                excludingDocumentIDs: matchedExistingIDs
            )
            try await sources.updateLastScan(id: source.id, at: now)
            return ScanReport(sourceRootID: source.id, discovered: discovered, changed: changed, unchanged: unchanged, missing: missing)
        }
    }
}
```

- [ ] **Step 5: Run catalog tests and the full suite**

Run: `swift test --filter CatalogServiceTests`

Expected: PASS with 6 tests.

Run: `swift test`

Expected: PASS with no failures.

- [ ] **Step 6: Commit catalog reconciliation**

```bash
git add Sources/LinkLoomCore/Persistence/DocumentRepository.swift Sources/LinkLoomCore/Catalog/CatalogService.swift Tests/LinkLoomCoreTests/CatalogServiceTests.swift
git commit -m "feat: reconcile catalog scans idempotently"
```

### Task 5: Page-scoped PDF embedded-text extraction

**Files:**
- Create: `Sources/LinkLoomCore/Models/ExtractionModels.swift`
- Create: `Sources/LinkLoomCore/Extraction/DocumentTextExtractor.swift`
- Create: `Sources/LinkLoomCore/Extraction/PDFEmbeddedTextExtractor.swift`
- Create: `Tests/LinkLoomCoreTests/Support/FixtureFactory.swift`
- Test: `Tests/LinkLoomCoreTests/PDFEmbeddedTextExtractorTests.swift`

**Interfaces:**
- Consumes: `SupportedMediaType.pdf`.
- Produces: `ExtractedDocument`, `ExtractedPage`, `TextRegion`, `ExtractionMethod`, and `DocumentTextExtracting.extract(from:mediaType:)`.
- Produces: `PDFEmbeddedTextExtractor.minimumCharacterCount`, defaulting to 40 non-whitespace characters.

- [ ] **Step 1: Write failing PDF extraction tests**

Create a two-page PDF fixture with selectable text using Core Graphics and Core Text. Assert:

```swift
@Test func extractsTextPerPage() async throws {
    let pdf = try FixtureFactory.makeTextPDF(pages: ["Heimvertrag 2026", "Tarif CHF 7'840"])
    let result = try await PDFEmbeddedTextExtractor(minimumCharacterCount: 1)
        .extract(from: pdf, mediaType: .pdf)

    #expect(result.method == .embeddedPDFText)
    #expect(result.pages.map(\.pageIndex) == [0, 1])
    #expect(result.pages[0].text.contains("Heimvertrag"))
    #expect(result.pages[1].text.contains("7'840"))
}

@Test func rejectsImageOnlyPDFForOCRFallback() async throws {
    let pdf = try FixtureFactory.makeImageOnlyPDF(text: "Rechnung")
    await #expect(throws: TextExtractionError.insufficientEmbeddedText) {
        try await PDFEmbeddedTextExtractor().extract(from: pdf, mediaType: .pdf)
    }
}
```

- [ ] **Step 2: Run PDF tests to verify missing extraction types fail**

Run: `swift test --filter PDFEmbeddedTextExtractorTests`

Expected: FAIL because extraction models and `PDFEmbeddedTextExtractor` are undefined.

- [ ] **Step 3: Add extraction models and protocol**

Create `ExtractionModels.swift`:

```swift
import CoreGraphics
import Foundation

public enum ExtractionMethod: String, Codable, Sendable {
    case embeddedPDFText
    case visionOCR
}

public struct TextRegion: Codable, Sendable, Equatable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect
}

public struct ExtractedPage: Codable, Sendable, Equatable {
    public let pageIndex: Int
    public let text: String
    public let regions: [TextRegion]
}

public struct ExtractedDocument: Codable, Sendable, Equatable {
    public let method: ExtractionMethod
    public let pages: [ExtractedPage]
    public var joinedText: String { pages.map(\.text).joined(separator: "\n\n") }
}
```

Create `DocumentTextExtractor.swift`:

```swift
import Foundation

public enum TextExtractionError: Error, Equatable {
    case unsupportedMedia
    case unreadableDocument
    case passwordProtected
    case insufficientEmbeddedText
    case noRecognizedText
}

public protocol DocumentTextExtracting: Sendable {
    func extract(from url: URL, mediaType: SupportedMediaType) async throws -> ExtractedDocument
}
```

- [ ] **Step 4: Implement PDFKit extraction without write operations**

Create `PDFEmbeddedTextExtractor.swift`:

```swift
import Foundation
import PDFKit

public struct PDFEmbeddedTextExtractor: DocumentTextExtracting {
    public let minimumCharacterCount: Int

    public init(minimumCharacterCount: Int = 40) {
        self.minimumCharacterCount = minimumCharacterCount
    }

    public func extract(from url: URL, mediaType: SupportedMediaType) async throws -> ExtractedDocument {
        guard mediaType == .pdf else { throw TextExtractionError.unsupportedMedia }
        guard let document = PDFDocument(url: url) else { throw TextExtractionError.unreadableDocument }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw TextExtractionError.passwordProtected
        }
        let pages = (0..<document.pageCount).map { index in
            ExtractedPage(
                pageIndex: index,
                text: document.page(at: index)?.string ?? "",
                regions: []
            )
        }
        let characterCount = pages.reduce(0) {
            $0 + $1.text.filter { !$0.isWhitespace }.count
        }
        guard characterCount >= minimumCharacterCount else {
            throw TextExtractionError.insufficientEmbeddedText
        }
        return ExtractedDocument(method: .embeddedPDFText, pages: pages)
    }
}
```

- [ ] **Step 5: Run PDF tests and the full suite**

Run: `swift test --filter PDFEmbeddedTextExtractorTests`

Expected: PASS with embedded text preserved by page and image-only PDF routed to OCR fallback.

Run: `swift test`

Expected: PASS with no failures.

- [ ] **Step 6: Commit PDF extraction**

```bash
git add Sources/LinkLoomCore/Models/ExtractionModels.swift Sources/LinkLoomCore/Extraction/DocumentTextExtractor.swift Sources/LinkLoomCore/Extraction/PDFEmbeddedTextExtractor.swift Tests/LinkLoomCoreTests/Support/FixtureFactory.swift Tests/LinkLoomCoreTests/PDFEmbeddedTextExtractorTests.swift
git commit -m "feat: extract page-scoped PDF text"
```

### Task 6: Vision OCR for images and scanned PDFs

**Files:**
- Create: `Sources/LinkLoomCore/Extraction/VisionOCRRecognizer.swift`
- Create: `Sources/LinkLoomCore/Extraction/PDFPageRenderer.swift`
- Create: `Sources/LinkLoomCore/Extraction/CompositeTextExtractor.swift`
- Test: `Tests/LinkLoomCoreTests/VisionOCRRecognizerTests.swift`
- Test: `Tests/LinkLoomCoreTests/CompositeTextExtractorTests.swift`

**Interfaces:**
- Consumes: extraction models and `PDFEmbeddedTextExtractor`.
- Produces: `ImageOCRRecognizing.recognize(cgImage:pageIndex:)` and `PDFPageRendering.renderPages(at:)`.
- Produces: `CompositeTextExtractor.extract(from:mediaType:)` for all supported media types.

- [ ] **Step 1: Write failing OCR and routing tests**

Create one integration test image containing large black text on white background: “Rechnung Juli 2026 CHF 7840”. Assert the recognized page contains `Rechnung` and `2026`, has page index 0, and has at least one region with confidence above 0.

Create protocol fakes for the composite tests and cover:

```swift
@Test func imageUsesVisionDirectly() async throws
@Test func textPDFUsesEmbeddedTextWithoutOCR() async throws
@Test func imageOnlyPDFRendersEachPageForOCR() async throws
```

- [ ] **Step 2: Run OCR tests to verify missing types fail**

Run: `swift test --filter VisionOCRRecognizerTests`

Expected: FAIL because `VisionOCRRecognizer` is undefined.

Run: `swift test --filter CompositeTextExtractorTests`

Expected: FAIL because `CompositeTextExtractor` and rendering interfaces are undefined.

- [ ] **Step 3: Implement Vision text recognition**

Create `VisionOCRRecognizer.swift`:

```swift
import CoreGraphics
import Foundation
import Vision

public protocol ImageOCRRecognizing: Sendable {
    func recognize(cgImage: CGImage, pageIndex: Int) async throws -> ExtractedPage
}

public struct VisionOCRRecognizer: ImageOCRRecognizing {
    public init() {}

    public func recognize(cgImage: CGImage, pageIndex: Int) async throws -> ExtractedPage {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "fr-FR", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let regions = (request.results ?? []).compactMap { observation -> TextRegion? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextRegion(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox
            )
        }
        guard !regions.isEmpty else { throw TextExtractionError.noRecognizedText }
        let ordered = regions.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        return ExtractedPage(
            pageIndex: pageIndex,
            text: ordered.map(\.text).joined(separator: "\n"),
            regions: ordered
        )
    }
}
```

- [ ] **Step 4: Render PDF pages and implement extraction routing**

`PDFPageRenderer` uses `PDFDocument` and draws each `PDFPage` into an RGB `CGContext` at 200 DPI without writing any file. Its public protocol is:

```swift
public protocol PDFPageRendering: Sendable {
    func renderPages(at url: URL) throws -> [CGImage]
}
```

`CompositeTextExtractor` has this initializer:

```swift
public init(
    pdfText: any DocumentTextExtracting = PDFEmbeddedTextExtractor(),
    pdfRenderer: any PDFPageRendering = PDFPageRenderer(dpi: 200),
    ocr: any ImageOCRRecognizing = VisionOCRRecognizer()
)
```

Its routing is exact:

1. `.pdf`: try embedded PDF text; only `insufficientEmbeddedText` falls back to page rendering and OCR.
2. `.jpeg`, `.png`, `.heic`: load a `CGImage` with `CGImageSource`, then OCR page 0.
3. A render or decode failure becomes `unreadableDocument`.
4. OCR pages are returned in source page order with method `.visionOCR`.

- [ ] **Step 5: Run focused OCR tests and all tests**

Run: `swift test --filter VisionOCRRecognizerTests`

Expected: PASS on the synthetic high-contrast image.

Run: `swift test --filter CompositeTextExtractorTests`

Expected: PASS for all three routing scenarios.

Run: `swift test`

Expected: PASS with no failures.

- [ ] **Step 6: Commit OCR and composite extraction**

```bash
git add Sources/LinkLoomCore/Extraction/VisionOCRRecognizer.swift Sources/LinkLoomCore/Extraction/PDFPageRenderer.swift Sources/LinkLoomCore/Extraction/CompositeTextExtractor.swift Tests/LinkLoomCoreTests/VisionOCRRecognizerTests.swift Tests/LinkLoomCoreTests/CompositeTextExtractorTests.swift
git commit -m "feat: add local Vision OCR fallback"
```

### Task 7: Persisted extraction pipeline with failure isolation

**Files:**
- Modify: `Sources/LinkLoomCore/Persistence/AppDatabase.swift`
- Create: `Sources/LinkLoomCore/Persistence/ExtractionRepository.swift`
- Create: `Sources/LinkLoomCore/Pipeline/IngestionPipeline.swift`
- Test: `Tests/LinkLoomCoreTests/IngestionPipelineTests.swift`

**Interfaces:**
- Consumes: `DocumentRepository.pendingExtraction`, `CompositeTextExtractor`, and source access.
- Produces: `ExtractionRepository.replace(documentID:analysisVersion:extraction:at:)` and `extraction(documentID:)`.
- Produces: `IngestionReport` and `IngestionPipeline.processPending(source:limit:)`.

- [ ] **Step 1: Write failing persistence and isolation tests**

Add tests that seed three discovered documents. The fake extractor succeeds for the first and third and throws `unreadableDocument` for the second. Assert:

- the report contains 2 completed and 1 failed;
- successful documents are `.ready` with page counts;
- the failed document is `.failed` with failure code `unreadableDocument`;
- both successful extractions are persisted despite the middle failure;
- rerunning with the same `analysisVersion` does not re-extract ready documents.

- [ ] **Step 2: Run the tests to verify migration and pipeline types are missing**

Run: `swift test --filter IngestionPipelineTests`

Expected: FAIL because extraction tables, repository, and pipeline are undefined.

- [ ] **Step 3: Add the v2 extraction migration**

Append migration `v2_extraction` in `AppDatabase.migrate`:

```swift
migrator.registerMigration("v2_extraction") { db in
    try db.create(table: "documentExtraction") { table in
        table.column("documentID", .text).primaryKey()
            .references("document", onDelete: .cascade)
        table.column("analysisVersion", .text).notNull()
        table.column("method", .text).notNull()
        table.column("joinedText", .text).notNull()
        table.column("updatedAt", .datetime).notNull()
    }
    try db.create(table: "extractedPage") { table in
        table.column("documentID", .text).notNull()
            .references("document", onDelete: .cascade)
        table.column("pageIndex", .integer).notNull()
        table.column("text", .text).notNull()
        table.column("regionsJSON", .blob).notNull()
        table.primaryKey(["documentID", "pageIndex"])
    }
    try db.create(virtualTable: "extractionFTS", using: FTS5()) { table in
        table.column("documentID").notIndexed()
        table.column("joinedText")
        table.tokenizer = .unicode61()
    }
}
```

- [ ] **Step 4: Implement atomic extraction replacement**

`ExtractionRepository.replace` performs one GRDB transaction that:

1. deletes old page rows and the old FTS row for the document;
2. upserts `documentExtraction`;
3. inserts all page rows with `JSONEncoder`-encoded regions;
4. inserts one FTS row containing joined text.

Expose this exact record for reads:

```swift
public struct StoredExtraction: Sendable, Equatable {
    public let documentID: UUID
    public let analysisVersion: String
    public let extraction: ExtractedDocument
    public let updatedAt: Date
}
```

- [ ] **Step 5: Implement bounded, failure-isolated processing**

Create `IngestionPipeline.swift`:

```swift
public struct IngestionReport: Sendable, Equatable {
    public let completed: Int
    public let failed: Int
}

public actor IngestionPipeline {
    public static let analysisVersion = "text-v1"

    public init(
        sourceAccess: any SourceAccessing,
        documents: DocumentRepository,
        extractions: ExtractionRepository,
        extractor: any DocumentTextExtracting
    )

    public func processPending(
        source: SourceRootRecord,
        limit: Int = 2
    ) async -> IngestionReport
}
```

Process at most `limit` documents concurrently with a task group. Each child resolves the original URL from `source root + relativePath`, marks `.extracting`, extracts, atomically stores results, and marks `.ready`. Each error is converted to a stable failure code and marks only that document `.failed`. Never include an absolute path in the failure code.

- [ ] **Step 6: Run pipeline tests and full verification**

Run: `swift test --filter IngestionPipelineTests`

Expected: PASS with 2 successes, 1 isolated failure, and no repeat extraction.

Run: `swift test`

Expected: PASS with no failures.

- [ ] **Step 7: Commit persisted ingestion**

```bash
git add Sources/LinkLoomCore/Persistence/AppDatabase.swift Sources/LinkLoomCore/Persistence/ExtractionRepository.swift Sources/LinkLoomCore/Pipeline/IngestionPipeline.swift Tests/LinkLoomCoreTests/IngestionPipelineTests.swift
git commit -m "feat: persist failure-isolated text ingestion"
```

### Task 8: SwiftUI diagnostic application

**Files:**
- Create: `Sources/LinkLoomApp/LinkLoomApp.swift`
- Create: `Sources/LinkLoomAppFeature/AppModel.swift`
- Create: `Sources/LinkLoomAppFeature/FolderPicker.swift`
- Create: `Sources/LinkLoomAppFeature/ContentView.swift`
- Create: `Sources/LinkLoomAppFeature/SourceSidebar.swift`
- Create: `Sources/LinkLoomAppFeature/ScanDashboard.swift`
- Test: `Tests/LinkLoomAppFeatureTests/AppModelTests.swift`

**Interfaces:**
- Consumes: repositories, `CatalogService`, and `IngestionPipeline`.
- Produces: `@MainActor AppModel` with sources, documents, scan state, add-source, remove-source, and scan actions.
- Produces: a runnable `LinkLoomApp` executable; this is a diagnostic ingestion UI, not final Dossier UX Variant 1A.

- [ ] **Step 1: Write failing AppModel state-transition tests**

Define protocol facades `CatalogScanning` and `PendingIngesting` in `AppModel.swift` so tests can inject fakes. Test:

```swift
@Test @MainActor func scanPublishesProgressAndReloadsDocuments() async throws
@Test @MainActor func scanFailureAppearsWithoutRemovingExistingDocuments() async throws
@Test @MainActor func addingSourcePersistsAndSelectsIt() async throws
```

The success test records the state sequence `.idle → .scanning → .extracting → .idle` and asserts the final document list contains fake results.

- [ ] **Step 2: Run AppModel tests to verify the app state is missing**

Run: `swift test --filter AppModelTests`

Expected: FAIL because `AppModel`, `AppScanState`, and protocol facades are undefined.

- [ ] **Step 3: Implement folder selection and app composition**

`FolderPicker` wraps `NSOpenPanel` with:

```swift
panel.canChooseDirectories = true
panel.canChooseFiles = false
panel.allowsMultipleSelection = true
panel.canDownloadUbiquitousContents = false
```

`LinkLoomApp` creates the database under `Application Support/LinkLoom/linkloom.sqlite`, composes default core services, constructs `AppModel`, and injects it into `ContentView`.

- [ ] **Step 4: Implement the minimal diagnostic views**

`ContentView` uses `NavigationSplitView`:

- `SourceSidebar` lists saved sources and an “Ordner hinzufügen” button.
- `ScanDashboard` shows the selected source, last scan time, counts by `DocumentStatus`, “Jetzt analysieren,” and a table with relative path, media type, status, and page count.
- Absolute source paths are confined to a local source-detail disclosure and never printed to stdout.
- Failed rows show only stable failure codes.

- [ ] **Step 5: Run model tests, build, and launch manually**

Run: `swift test --filter AppModelTests`

Expected: PASS with 3 tests.

Run: `swift build`

Expected: BUILD SUCCEEDED.

Run: `swift run LinkLoomApp`

Expected manual result: the app opens, lets the user choose a temporary fixture folder, scans it, and shows ready/failed document rows without moving or renaming files. Quit the app after inspection.

- [ ] **Step 6: Commit the diagnostic app**

```bash
git add Sources/LinkLoomApp Sources/LinkLoomAppFeature Tests/LinkLoomAppFeatureTests
git commit -m "feat: add local ingestion workspace"
```

### Task 9: Filesystem-event driven incremental rescans

**Files:**
- Create: `Sources/LinkLoomCore/Watching/DirectoryWatcher.swift`
- Create: `Sources/LinkLoomCore/Watching/FSEventsDirectoryWatcher.swift`
- Create: `Sources/LinkLoomCore/Watching/RescanScheduler.swift`
- Modify: `Sources/LinkLoomAppFeature/AppModel.swift`
- Test: `Tests/LinkLoomCoreTests/RescanSchedulerTests.swift`

**Interfaces:**
- Consumes: resolved source-root URLs and the core-level `SourceRescanning` protocol.
- Produces: `DirectoryWatching.events(for:) -> AsyncThrowingStream<DirectoryChange, Error>`.
- Produces: `RescanScheduler.start(source:)`, `stop(sourceID:)`, and `stopAll()`.
- Guarantees: bursts are debounced for 500 ms and only the affected source is rescanned.

- [ ] **Step 1: Write failing debounce and lifecycle tests**

Use a fake watcher backed by `AsyncThrowingStream`. Emit five events within 100 ms and assert exactly one scan occurs after the 500 ms debounce window. Add tests that stopping one source cancels only its stream and that an unavailable-root event does not mark individual documents missing.

- [ ] **Step 2: Run watcher tests to verify missing interfaces fail**

Run: `swift test --filter RescanSchedulerTests`

Expected: FAIL because directory-watching interfaces and scheduler are undefined.

- [ ] **Step 3: Implement FSEvents adapter**

Create `DirectoryWatcher.swift`:

```swift
import Foundation

public struct DirectoryChange: Sendable, Equatable {
    public enum Kind: Sendable { case contentChanged, rootUnavailable, rootAvailable }
    public let sourceRootID: UUID
    public let kind: Kind
}

public protocol DirectoryWatching: Sendable {
    func events(
        for sourceRootID: UUID,
        url: URL
    ) -> AsyncThrowingStream<DirectoryChange, Error>
}

public protocol SourceRescanning: Sendable {
    func rescan(source: SourceRootRecord) async
}
```

`FSEventsDirectoryWatcher` creates `FSEventStreamCreate`, schedules it with `FSEventStreamSetDispatchQueue`, maps root-change and mount flags into `DirectoryChange.Kind`, and invalidates/releases the stream when the async continuation terminates.

- [ ] **Step 4: Implement the rescan scheduler and app lifecycle wiring**

`RescanScheduler` stores one task per source UUID, coalesces `.contentChanged` events for 500 ms using `ContinuousClock`, and invokes `SourceRescanning`. The app target supplies an adapter that runs catalog reconciliation followed by pending ingestion. `.rootUnavailable` updates source availability in app state but does not reconcile missing paths. `AppModel` starts watchers after loading saved sources and stops all watchers during termination.

- [ ] **Step 5: Run watcher tests and full verification**

Run: `swift test --filter RescanSchedulerTests`

Expected: PASS; five rapid events produce one rescan and cancellation is source-specific.

Run: `swift test`

Expected: PASS with no failures.

Run: `swift build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit incremental watching**

```bash
git add Sources/LinkLoomCore/Watching Sources/LinkLoomAppFeature/AppModel.swift Tests/LinkLoomCoreTests/RescanSchedulerTests.swift
git commit -m "feat: rescan changed sources incrementally"
```

### Task 10: Acceptance fixtures, source-integrity check, and operator documentation

**Files:**
- Create: `Tests/LinkLoomCoreTests/IngestionAcceptanceTests.swift`
- Modify: `Tests/LinkLoomCoreTests/Support/FixtureFactory.swift`
- Create: `README.md`

**Interfaces:**
- Consumes: the complete ingestion vertical slice.
- Produces: a deterministic acceptance workflow and documented local run commands.
- Guarantees: source names, paths, bytes, sizes, and modification dates remain unchanged across scanning and extraction.

- [ ] **Step 1: Write the failing end-to-end source-integrity test**

The test creates a temporary source with:

- one selectable-text PDF;
- one image-only PDF;
- one JPG scan;
- one PNG scan;
- one HEIC scan when ImageIO can encode HEIC on the host;
- one corrupt PDF;
- one unsupported text file.

Before processing, capture this snapshot for every source file:

```swift
struct SourceSnapshot: Equatable {
    let relativePath: String
    let sha256: String
    let byteCount: Int64
    let modifiedAt: Date
}
```

Run catalog plus ingestion, then capture the same snapshot and assert exact equality. Also assert that supported valid documents are ready, the corrupt PDF is failed, and the unsupported text file has no catalog record.

- [ ] **Step 2: Run acceptance test and observe its first missing behavior**

Run: `swift test --filter IngestionAcceptanceTests`

Expected: FAIL with unresolved `FixtureFactory.makeAcceptanceSource()` and `runAcceptanceIngestion(source:)` helpers.

- [ ] **Step 3: Complete deterministic fixtures and acceptance orchestration**

Add fixture helpers that generate all supported formats locally using PDFKit, Core Graphics, AppKit, and ImageIO. Keep real personal documents outside the repository. Make HEIC coverage conditional on `CGImageDestinationCopyTypeIdentifiers()` containing `public.heic`; all other formats are mandatory.

- [ ] **Step 4: Add an opt-in 10,000-document catalog benchmark**

Add `@Test(.enabled(if: ProcessInfo.processInfo.environment["LINKLOOM_PERF_TEST"] == "1"))` that creates 10,000 small supported fixture files, scans them twice, asserts 10,000 records after both scans, and asserts the second scan performs zero fingerprint calls.

Run: `LINKLOOM_PERF_TEST=1 swift test --filter catalogHandlesTenThousandDocumentsIdempotently`

Expected: PASS with 10,000 records and no second-pass fingerprinting. Record wall-clock time in the implementation handoff without turning it into a hard threshold until a baseline exists.

- [ ] **Step 5: Document setup and operation**

Create `README.md` with:

- prerequisites: macOS 15+, Swift 6.2+; full Xcode is optional for this SwiftPM slice;
- `swift build`, `swift test`, and `swift run LinkLoomApp` commands;
- supported formats and the 10,000-document boundary;
- local database location;
- statement that originals remain untouched;
- instructions for selecting a temporary test folder;
- command for the opt-in 10,000-document benchmark;
- troubleshooting for password-protected PDFs, unavailable mounts, and OCR failures.

- [ ] **Step 6: Run final verification for this subproject**

Run: `swift test`

Expected: PASS with no failures; the opt-in 10,000-document benchmark is skipped in the normal suite.

Run: `LINKLOOM_PERF_TEST=1 swift test --filter catalogHandlesTenThousandDocumentsIdempotently`

Expected: PASS.

Run: `swift build -c release`

Expected: BUILD SUCCEEDED.

Run: `git diff --check`

Expected: no output and exit code 0.

- [ ] **Step 7: Commit acceptance coverage and documentation**

```bash
git add Tests/LinkLoomCoreTests/IngestionAcceptanceTests.swift Tests/LinkLoomCoreTests/Support/FixtureFactory.swift README.md
git commit -m "test: verify local ingestion acceptance"
```

## Implementation References

- [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple: NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)
- [Apple: PDFDocument text](https://developer.apple.com/documentation/pdfkit/pdfdocument/string)
- [Apple: Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [Apple: File System Events](https://developer.apple.com/documentation/coreservices/file_system_events)
- [Apple: Swift Testing](https://developer.apple.com/documentation/testing)
- [GRDB.swift releases and Swift Package installation](https://github.com/groue/GRDB.swift)
