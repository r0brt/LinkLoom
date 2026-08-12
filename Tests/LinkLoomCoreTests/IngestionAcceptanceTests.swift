import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Local ingestion acceptance")
struct IngestionAcceptanceTests {
    @Test func realMixedPDFPreservesEmbeddedAndRecognizedPages() async throws {
        let pdf = try FixtureFactory.makeMixedPDF(
            embeddedText: "Embedded agreement 2026",
            scannedText: "Scanned invoice CHF 7840"
        )
        defer { try? FileManager.default.removeItem(at: pdf) }

        let result = try await CompositeTextExtractor().extract(from: pdf, mediaType: .pdf)

        #expect(result.method == .hybridPDFTextAndOCR)
        #expect(result.pages[0].text.contains("Embedded agreement"))
        #expect(result.pages[0].regions.isEmpty)
        #expect(result.pages[1].text.contains("invoice"))
        #expect(!result.pages[1].regions.isEmpty)
    }

    @Test func ingestionLeavesEverySourceFileUnchanged() async throws {
        let source = try FixtureFactory.makeAcceptanceSource()
        let before = try await snapshots(in: source.rootURL)

        let documents = try await runAcceptanceIngestion(source: source)

        let after = try await snapshots(in: source.rootURL)
        #expect(after == before)

        var expectedReadyPaths: Set<String> = [
            "selectable.pdf",
            "scan.pdf",
            "scan.jpg",
            "scan.png",
        ]
        if source.includesHEIC {
            expectedReadyPaths.insert("scan.heic")
        }
        let readyPaths = Set(documents.lazy
            .filter { $0.status == .ready }
            .map(\.relativePath))
        #expect(readyPaths == expectedReadyPaths)

        let corrupt = try #require(documents.first { $0.relativePath == "corrupt.pdf" })
        #expect(corrupt.status == .failed)
        #expect(corrupt.failureCode == "unreadableDocument")
        #expect(!documents.contains { $0.relativePath == "unsupported.txt" })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINKLOOM_PERF_TEST"] == "1"))
    func catalogHandlesTenThousandDocumentsIdempotently() async throws {
        let source = try FixtureFactory.makeCatalogBenchmarkSource(documentCount: 10_000)

        let result = try await runCatalogBenchmark(source: source)

        #expect(result.firstRecordCount == 10_000)
        #expect(result.secondRecordCount == 10_000)
        #expect(result.fingerprintCallsAfterFirstScan == 10_000)
        #expect(result.fingerprintCallsAfterSecondScan == 10_000)
    }

    private func snapshots(in root: URL) async throws -> [SourceSnapshot] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys)
        )
        var snapshots: [SourceSnapshot] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  let relativePath = DefaultFileEnumerator.relativePath(for: url, under: root),
                  let modifiedAt = values.contentModificationDate
            else {
                continue
            }
            let fingerprint = try await SHA256FileFingerprinter().fingerprint(url)
            snapshots.append(SourceSnapshot(
                relativePath: relativePath,
                sha256: fingerprint.sha256,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: modifiedAt
            ))
        }
        return snapshots.sorted { $0.relativePath < $1.relativePath }
    }
}

private struct SourceSnapshot: Equatable {
    let relativePath: String
    let sha256: String
    let byteCount: Int64
    let modifiedAt: Date
}

private struct CatalogBenchmarkResult {
    let firstRecordCount: Int
    let secondRecordCount: Int
    let fingerprintCallsAfterFirstScan: Int
    let fingerprintCallsAfterSecondScan: Int
}

private func runCatalogBenchmark(
    source: CatalogBenchmarkSource
) async throws -> CatalogBenchmarkResult {
    let database = try TestDatabase.make()
    let sourceAccess = AcceptanceSourceAccess(rootURL: source.rootURL)
    let sources = SourceRootRepository(dbWriter: database)
    let documents = DocumentRepository(dbWriter: database)
    let sourceRecord = try await sources.add(
        url: source.rootURL,
        sourceAccess: sourceAccess
    )
    let fingerprinter = CountingFileFingerprinter()
    let catalog = CatalogService(
        sourceAccess: sourceAccess,
        enumerator: DefaultFileEnumerator(),
        fingerprinter: fingerprinter,
        documents: documents,
        sources: sources
    )

    _ = try await catalog.scan(source: sourceRecord)
    let firstRecords = try await documents.all(sourceRootID: sourceRecord.id)
    let firstRecordCount = firstRecords.count
    let fingerprintCallsAfterFirstScan = await fingerprinter.callCount
    _ = try await catalog.scan(source: sourceRecord)
    let secondRecordCount = try await documents.all(sourceRootID: sourceRecord.id).count
    let fingerprintCallsAfterSecondScan = await fingerprinter.callCount

    return CatalogBenchmarkResult(
        firstRecordCount: firstRecordCount,
        secondRecordCount: secondRecordCount,
        fingerprintCallsAfterFirstScan: fingerprintCallsAfterFirstScan,
        fingerprintCallsAfterSecondScan: fingerprintCallsAfterSecondScan
    )
}

private actor CountingFileFingerprinter: FileFingerprinting {
    private(set) var callCount = 0

    func fingerprint(_ url: URL) async throws -> FileFingerprint {
        callCount += 1
        return try await SHA256FileFingerprinter().fingerprint(url)
    }
}

private func runAcceptanceIngestion(
    source: AcceptanceSource
) async throws -> [DocumentRecord] {
    let database = try TestDatabase.make()
    let sourceAccess = AcceptanceSourceAccess(rootURL: source.rootURL)
    let sources = SourceRootRepository(dbWriter: database)
    let documents = DocumentRepository(dbWriter: database)
    let sourceRecord = try await sources.add(
        url: source.rootURL,
        sourceAccess: sourceAccess
    )
    let catalog = CatalogService(
        sourceAccess: sourceAccess,
        enumerator: DefaultFileEnumerator(),
        fingerprinter: SHA256FileFingerprinter(),
        documents: documents,
        sources: sources
    )
    _ = try await catalog.scan(source: sourceRecord)
    let pipeline = IngestionPipeline(
        sourceAccess: sourceAccess,
        documents: documents,
        extractions: ExtractionRepository(dbWriter: database),
        extractor: CompositeTextExtractor()
    )
    _ = await pipeline.processPending(source: sourceRecord)
    return try await documents.all(sourceRootID: sourceRecord.id)
}

private struct AcceptanceSourceAccess: SourceAccessing {
    let rootURL: URL

    func createBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        ResolvedSource(url: rootURL, bookmarkWasStale: false)
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await operation(rootURL)
    }
}
