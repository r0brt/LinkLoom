import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Catalog reconciliation")
struct CatalogServiceTests {
    @Test func firstScanDiscoversSupportedDocuments() async throws {
        let fixture = try await CatalogFixture.make()
        let pdf = fixture.candidate("a.pdf", byteCount: 4, modifiedAt: 100, mediaType: .pdf)
        let image = fixture.candidate("b.jpg", byteCount: 5, modifiedAt: 101, mediaType: .jpeg)
        fixture.enumerator.setCandidates([pdf, image])
        await fixture.fingerprinter.set(pdf, hash: "hash-a")
        await fixture.fingerprinter.set(image, hash: "hash-b")

        let report = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)

        #expect(report == ScanReport(
            sourceRootID: fixture.source.id,
            discovered: 2,
            changed: 0,
            unchanged: 0,
            missing: 0
        ))
        #expect(documents.map(\.relativePath) == ["a.pdf", "b.jpg"])
        #expect(documents.allSatisfy { $0.status == .discovered })
        #expect(documents.allSatisfy { $0.availability == .available })
    }

    @Test func unchangedRescanDoesNotFingerprintAgain() async throws {
        let fixture = try await CatalogFixture.make()
        let candidate = fixture.candidate("a.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([candidate])
        await fixture.fingerprinter.set(candidate, hash: "hash-a")
        _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        let callsAfterFirstScan = await fixture.fingerprinter.callCount

        let report = try await fixture.service.scan(source: fixture.source, now: fixture.date(300))
        let callsAfterSecondScan = await fixture.fingerprinter.callCount

        #expect(callsAfterFirstScan == 1)
        #expect(callsAfterSecondScan == 1)
        #expect(report.unchanged == 1)
        #expect(report.discovered == 0)
        #expect(report.changed == 0)
    }

    @Test func changedFileKeepsIdentityAndReturnsToDiscovered() async throws {
        let fixture = try await CatalogFixture.make()
        let original = fixture.candidate("a.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([original])
        await fixture.fingerprinter.set(original, hash: "hash-a")
        _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        let initialDocuments = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let initial = try #require(initialDocuments.first)
        try await fixture.documents.markStatus(
            id: initial.id,
            status: .failed,
            pageCount: 9,
            failureCode: "oldFailure"
        )

        let changed = fixture.candidate("a.pdf", byteCount: 7, modifiedAt: 300)
        fixture.enumerator.setCandidates([changed])
        await fixture.fingerprinter.set(changed, hash: "hash-b", byteCount: 7)

        let report = try await fixture.service.scan(source: fixture.source, now: fixture.date(400))
        let rescannedDocuments = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let rescanned = try #require(rescannedDocuments.first)

        #expect(rescanned.id == initial.id)
        #expect(rescanned.contentHash == "hash-b")
        #expect(rescanned.status == .discovered)
        #expect(rescanned.pageCount == nil)
        #expect(rescanned.failureCode == nil)
        #expect(report.changed == 1)
    }

    @Test func missingFileIsMarkedMissingWithoutDeletingRecord() async throws {
        let fixture = try await CatalogFixture.make()
        let candidate = fixture.candidate("a.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([candidate])
        await fixture.fingerprinter.set(candidate, hash: "hash-a")
        _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))

        fixture.enumerator.setCandidates([])
        let report = try await fixture.service.scan(source: fixture.source, now: fixture.date(300))
        let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let document = try #require(documents.first)

        #expect(documents.count == 1)
        #expect(document.relativePath == "a.pdf")
        #expect(document.availability == .missing)
        #expect(report.missing == 1)
    }

    @Test func movedFileKeepsIdentityWhenHashMatchIsUnique() async throws {
        let fixture = try await CatalogFixture.make()
        let original = fixture.candidate("old/a.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([original])
        await fixture.fingerprinter.set(original, hash: "same-hash")
        _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        let initialDocuments = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let initial = try #require(initialDocuments.first)

        let moved = fixture.candidate("new/a.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([moved])
        await fixture.fingerprinter.set(moved, hash: "same-hash")

        let report = try await fixture.service.scan(source: fixture.source, now: fixture.date(300))
        let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let document = try #require(documents.first)

        #expect(documents.count == 1)
        #expect(document.id == initial.id)
        #expect(document.relativePath == "new/a.pdf")
        #expect(document.availability == .available)
        #expect(report.changed == 1)
        #expect(report.missing == 0)
    }

    @Test func movedFilePreservesReadyExtractionState() async throws {
        let fixture = try await CatalogFixture.make()
        let original = fixture.candidate("old/a.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([original])
        await fixture.fingerprinter.set(original, hash: "same-hash")
        _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        let initial = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id).first
        )
        try await fixture.documents.markStatus(id: initial.id, status: .ready, pageCount: 9)

        let moved = fixture.candidate("new/a.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([moved])
        await fixture.fingerprinter.set(moved, hash: "same-hash")

        _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(300))
        let document = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id).first
        )

        #expect(document.id == initial.id)
        #expect(document.status == .ready)
        #expect(document.pageCount == 9)
        #expect(document.failureCode == nil)
    }

    @Test func metadataOnlyChangePreservesReadyExtractionState() async throws {
        let fixture = try await CatalogFixture.make()
        let original = fixture.candidate("a.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([original])
        await fixture.fingerprinter.set(original, hash: "same-hash")
        _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        let initial = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id).first
        )
        try await fixture.documents.markStatus(id: initial.id, status: .ready, pageCount: 9)

        let touched = fixture.candidate("a.pdf", byteCount: 4, modifiedAt: 300)
        fixture.enumerator.setCandidates([touched])
        await fixture.fingerprinter.set(touched, hash: "same-hash")

        let report = try await fixture.service.scan(source: fixture.source, now: fixture.date(400))
        let document = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id).first
        )

        #expect(document.status == .ready)
        #expect(document.pageCount == 9)
        #expect(document.modifiedAt == fixture.date(300))
        #expect(report.changed == 0)
        #expect(report.unchanged == 1)
    }

    @Test func duplicateContentAtNewPathCreatesSeparateRecord() async throws {
        let fixture = try await CatalogFixture.make()
        let original = fixture.candidate("a.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([original])
        await fixture.fingerprinter.set(original, hash: "same-hash")
        _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        let initialDocuments = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let initial = try #require(initialDocuments.first)

        let duplicate = fixture.candidate("copy.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([original, duplicate])
        await fixture.fingerprinter.set(duplicate, hash: "same-hash")

        let report = try await fixture.service.scan(source: fixture.source, now: fixture.date(300))
        let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let duplicateRecord = try #require(documents.first { $0.relativePath == "copy.pdf" })

        #expect(documents.count == 2)
        #expect(duplicateRecord.id != initial.id)
        #expect(report.discovered == 1)
        #expect(report.unchanged == 1)
        #expect(report.missing == 0)
    }

    @Test func oneOldPathAndTwoNewMatchingPathsDoNotGuessWhichFileMoved() async throws {
        let fixture = try await CatalogFixture.make()
        let original = fixture.candidate("old.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([original])
        await fixture.fingerprinter.set(original, hash: "same-hash")
        _ = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        let initial = try #require(
            try await fixture.documents.all(sourceRootID: fixture.source.id).first
        )

        let first = fixture.candidate("new-a.pdf", byteCount: 4, modifiedAt: 100)
        let second = fixture.candidate("new-b.pdf", byteCount: 4, modifiedAt: 100)
        fixture.enumerator.setCandidates([first, second])
        await fixture.fingerprinter.set(first, hash: "same-hash")
        await fixture.fingerprinter.set(second, hash: "same-hash")

        let report = try await fixture.service.scan(source: fixture.source, now: fixture.date(300))
        let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let newDocuments = documents.filter { $0.relativePath.hasPrefix("new-") }
        let oldDocument = try #require(documents.first { $0.id == initial.id })

        #expect(documents.count == 3)
        #expect(newDocuments.count == 2)
        #expect(newDocuments.allSatisfy { $0.id != initial.id })
        #expect(oldDocument.relativePath == "old.pdf")
        #expect(oldDocument.availability == .missing)
        #expect(report.discovered == 2)
        #expect(report.missing == 1)
    }

    @Test func fingerprintFailureDoesNotStopOtherDocuments() async throws {
        let fixture = try await CatalogFixture.make()
        let first = fixture.candidate("a.pdf", byteCount: 4, modifiedAt: 100)
        let unreadable = fixture.candidate("b.pdf", byteCount: 5, modifiedAt: 101)
        let third = fixture.candidate("c.pdf", byteCount: 6, modifiedAt: 102)
        fixture.enumerator.setCandidates([first, unreadable, third])
        await fixture.fingerprinter.set(first, hash: "hash-a")
        await fixture.fingerprinter.set(third, hash: "hash-c")

        let report = try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)

        #expect(documents.map(\.relativePath) == ["a.pdf", "c.pdf"])
        #expect(report.discovered == 2)
        #expect(await fixture.fingerprinter.callCount == 3)
    }

    @Test func concurrentScansForSameSourceAreSerialized() async throws {
        let fixture = try await CatalogFixture.make()
        let firstVersion = fixture.candidate("a.pdf", byteCount: 4, modifiedAt: 100)
        let secondVersion = fixture.candidate("a.pdf", byteCount: 7, modifiedAt: 300)
        fixture.enumerator.setCandidateBatches([[firstVersion], [secondVersion]])
        await fixture.fingerprinter.setSequence(
            for: firstVersion.url,
            fingerprints: [
                FileFingerprint(sha256: "hash-a", byteCount: 4),
                FileFingerprint(sha256: "hash-b", byteCount: 7),
            ]
        )
        await fixture.fingerprinter.blockFirstCall()

        let firstScan = Task {
            try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        }
        await fixture.fingerprinter.waitUntilFirstCallStarts()
        let secondScan = Task {
            try await fixture.service.scan(source: fixture.source, now: fixture.date(400))
        }
        let release = Task {
            try await Task.sleep(for: .milliseconds(100))
            await fixture.fingerprinter.releaseFirstCall()
        }

        _ = try await firstScan.value
        _ = try await secondScan.value
        _ = try await release.value
        let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let document = try #require(documents.first)

        #expect(documents.count == 1)
        #expect(document.contentHash == "hash-b")
        #expect(document.byteCount == 7)
        #expect(document.modifiedAt == fixture.date(300))
    }

    @Test func cancellingQueuedScanPreventsWorkAndPersistence() async throws {
        let fixture = try await CatalogFixture.make()
        let firstVersion = fixture.candidate("a.pdf", byteCount: 4, modifiedAt: 100)
        let secondVersion = fixture.candidate("a.pdf", byteCount: 7, modifiedAt: 300)
        fixture.enumerator.setCandidateBatches([[firstVersion], [secondVersion]])
        await fixture.fingerprinter.setSequence(
            for: firstVersion.url,
            fingerprints: [
                FileFingerprint(sha256: "hash-a", byteCount: 4),
                FileFingerprint(sha256: "hash-b", byteCount: 7),
            ]
        )
        await fixture.fingerprinter.blockFirstCall()

        let firstScan = Task {
            try await fixture.service.scan(source: fixture.source, now: fixture.date(200))
        }
        await fixture.fingerprinter.waitUntilFirstCallStarts()
        let queuedScan = Task {
            try await fixture.service.scan(source: fixture.source, now: fixture.date(400))
        }
        queuedScan.cancel()
        await fixture.fingerprinter.releaseFirstCall()

        _ = try await firstScan.value
        var cancellationObserved = false
        do {
            _ = try await queuedScan.value
        } catch is CancellationError {
            cancellationObserved = true
        }
        let documents = try await fixture.documents.all(sourceRootID: fixture.source.id)
        let document = try #require(documents.first)

        #expect(cancellationObserved)
        #expect(fixture.enumerator.invocationCount == 1)
        #expect(await fixture.fingerprinter.callCount == 1)
        #expect(document.contentHash == "hash-a")
    }
}

@Suite("Document repository")
struct DocumentRepositoryTests {
    @Test func pendingExtractionReturnsOnlyAvailableDiscoveredDocumentsWithinLimit() async throws {
        let fixture = try await CatalogFixture.make()
        let first = fixture.document("a.pdf", status: .discovered, availability: .available)
        let ready = fixture.document("b.pdf", status: .ready, availability: .available)
        let missing = fixture.document("c.pdf", status: .discovered, availability: .missing)
        let second = fixture.document("d.pdf", status: .discovered, availability: .available)
        for document in [first, ready, missing, second] {
            try await fixture.documents.save(document)
        }

        let limited = try await fixture.documents.pendingExtraction(limit: 1)
        let allPending = try await fixture.documents.pendingExtraction(limit: 10)

        #expect(limited.count == 1)
        #expect(allPending.map(\.relativePath) == ["a.pdf", "d.pdf"])
    }

    @Test func markAvailabilityIsVisibleThroughGlobalQuery() async throws {
        let fixture = try await CatalogFixture.make()
        let document = fixture.document("a.pdf")
        try await fixture.documents.save(document)

        try await fixture.documents.markAvailability(id: document.id, availability: .unavailable)

        let documents = try await fixture.documents.all()
        let stored = try #require(documents.first)
        #expect(stored.availability == .unavailable)
    }

    @Test func reconciliationBatchRollsBackAllWritesOnConflict() async throws {
        let fixture = try await CatalogFixture.make()
        let first = fixture.document("same.pdf")
        var conflicting = fixture.document("same.pdf")
        conflicting.contentHash = "different-hash"
        var didThrow = false

        do {
            _ = try await fixture.documents.reconcile(
                sourceRootID: fixture.source.id,
                saving: [first, conflicting],
                excludingDocumentIDs: [first.id, conflicting.id]
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try await fixture.documents.all(sourceRootID: fixture.source.id).isEmpty)
    }
}

private struct CatalogFixture {
    let root = URL(fileURLWithPath: "/Volumes/Test")
    let source: SourceRootRecord
    let documents: DocumentRepository
    let enumerator: CatalogFileEnumerator
    let fingerprinter: CatalogFingerprinter
    let service: CatalogService

    static func make() async throws -> CatalogFixture {
        let db = try TestDatabase.make()
        let access = CatalogSourceAccess(root: URL(fileURLWithPath: "/Volumes/Test"))
        let sources = SourceRootRepository(dbWriter: db)
        let source = try await sources.add(
            url: access.root,
            sourceAccess: access,
            now: Date(timeIntervalSince1970: 50)
        )
        let documents = DocumentRepository(dbWriter: db)
        let enumerator = CatalogFileEnumerator()
        let fingerprinter = CatalogFingerprinter()
        let service = CatalogService(
            sourceAccess: access,
            enumerator: enumerator,
            fingerprinter: fingerprinter,
            documents: documents,
            sources: sources
        )
        return CatalogFixture(
            source: source,
            documents: documents,
            enumerator: enumerator,
            fingerprinter: fingerprinter,
            service: service
        )
    }

    func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    func candidate(
        _ relativePath: String,
        byteCount: Int64,
        modifiedAt: TimeInterval,
        mediaType: SupportedMediaType = .pdf
    ) -> FileCandidate {
        FileCandidate(
            url: root.appendingPathComponent(relativePath),
            relativePath: relativePath,
            mediaType: mediaType,
            byteCount: byteCount,
            modifiedAt: date(modifiedAt)
        )
    }

    func document(
        _ relativePath: String,
        status: DocumentStatus = .discovered,
        availability: DocumentAvailability = .available
    ) -> DocumentRecord {
        DocumentRecord(
            sourceRootID: source.id,
            relativePath: relativePath,
            contentHash: "hash-\(relativePath)",
            byteCount: 1,
            modifiedAt: date(100),
            mediaType: .pdf,
            status: status,
            availability: availability,
            lastSeenAt: date(100)
        )
    }
}

private struct CatalogSourceAccess: SourceAccessing {
    let root: URL

    func createBookmark(for url: URL) throws -> Data {
        Data("catalog-bookmark".utf8)
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        ResolvedSource(url: root, bookmarkWasStale: false)
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await operation(root)
    }
}

private final class CatalogFileEnumerator: FileEnumerating, @unchecked Sendable {
    private let lock = NSLock()
    private var candidates: [FileCandidate] = []
    private var candidateBatches: [[FileCandidate]] = []
    private var callCount = 0

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func setCandidates(_ candidates: [FileCandidate]) {
        lock.lock()
        self.candidates = candidates
        candidateBatches = []
        callCount = 0
        lock.unlock()
    }

    func setCandidateBatches(_ batches: [[FileCandidate]]) {
        lock.lock()
        candidateBatches = batches
        callCount = 0
        lock.unlock()
    }

    func files(in root: URL) throws -> [FileCandidate] {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if !candidateBatches.isEmpty {
            let index = min(callCount - 1, candidateBatches.count - 1)
            return candidateBatches[index]
        }
        return candidates
    }
}

private actor CatalogFingerprinter: FileFingerprinting {
    private var fingerprints: [URL: FileFingerprint] = [:]
    private var fingerprintSequences: [URL: [FileFingerprint]] = [:]
    private var shouldBlockFirstCall = false
    private var firstCallStarted = false
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCallRelease: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func set(_ candidate: FileCandidate, hash: String, byteCount: Int64? = nil) {
        fingerprints[candidate.url] = FileFingerprint(
            sha256: hash,
            byteCount: byteCount ?? candidate.byteCount
        )
    }

    func setSequence(for url: URL, fingerprints: [FileFingerprint]) {
        fingerprintSequences[url] = fingerprints
    }

    func blockFirstCall() {
        shouldBlockFirstCall = true
    }

    func waitUntilFirstCallStarts() async {
        if firstCallStarted { return }
        await withCheckedContinuation { continuation in
            firstCallWaiters.append(continuation)
        }
    }

    func releaseFirstCall() {
        firstCallRelease?.resume()
        firstCallRelease = nil
    }

    func fingerprint(_ url: URL) async throws -> FileFingerprint {
        callCount += 1
        let callIndex = callCount - 1
        if shouldBlockFirstCall && callCount == 1 {
            firstCallStarted = true
            for waiter in firstCallWaiters {
                waiter.resume()
            }
            firstCallWaiters.removeAll()
            await withCheckedContinuation { continuation in
                firstCallRelease = continuation
            }
        }
        if let sequence = fingerprintSequences[url], callIndex < sequence.count {
            return sequence[callIndex]
        }
        guard let fingerprint = fingerprints[url] else {
            throw MissingFingerprintError()
        }
        return fingerprint
    }
}

private struct MissingFingerprintError: Error {}
