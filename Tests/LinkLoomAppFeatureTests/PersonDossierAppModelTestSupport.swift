import Foundation
@testable import LinkLoomAppFeature
@testable import LinkLoomCore

enum PersonDossierAppModelTestError: Error {
    case loadFailed
}

final class PersonDossierAppModelFixture: @unchecked Sendable {
    let directory: URL
    let sources: SourceRootRepository
    let documents: DocumentRepository
    let sourceAccess = PersonDossierTestSourceAccess()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkLoomPersonDossierAppModelTests-\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.makeQueue(
            at: directory.appendingPathComponent("linkloom.sqlite")
        )
        sources = SourceRootRepository(dbWriter: database)
        documents = DocumentRepository(dbWriter: database)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func addSource(named name: String) async throws -> SourceRootRecord {
        try await sources.add(
            url: directory.appendingPathComponent(name, isDirectory: true),
            sourceAccess: sourceAccess,
            now: Date(timeIntervalSince1970: 100)
        )
    }
}

struct PersonDossierTestSourceAccess: SourceAccessing {
    func createBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolve(_ bookmark: Data) throws -> ResolvedSource {
        ResolvedSource(
            url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)),
            bookmarkWasStale: false
        )
    }

    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await operation(URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)))
    }
}

struct PersonDossierNoopCatalog: CatalogScanning {
    func scan(source: SourceRootRecord) async throws {}
}

struct PersonDossierNoopIngester: PendingIngesting {
    func processPending(source: SourceRootRecord) async throws {}
}

actor ScriptedPersonDossierLoader: PersonDossierLoading {
    enum SummaryStep: Sendable {
        case result([PersonDossierSummary])
        case failure
        case cancellation
        case blocked([PersonDossierSummary])
    }

    enum SnapshotStep: Sendable {
        case result(PersonDossierSnapshot)
        case failure
        case cancellation
        case blocked(Result<PersonDossierSnapshot, PersonDossierAppModelTestError>)
    }

    private var summarySteps: [SummaryStep]
    private var snapshotSteps: [SnapshotStep]
    private var blockedSummaryStarted = false
    private var summaryStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var summaryReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedSnapshotCount = 0
    private var snapshotStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var snapshotIDs: [UUID] = []

    init(
        summarySteps: [SummaryStep] = [.result([])],
        snapshotSteps: [SnapshotStep] = []
    ) {
        self.summarySteps = summarySteps
        self.snapshotSteps = snapshotSteps
    }

    func personDossierSummaries() async throws -> [PersonDossierSummary] {
        let step = summarySteps.isEmpty ? .result([]) : summarySteps.removeFirst()
        switch step {
        case .result(let summaries): return summaries
        case .failure: throw PersonDossierAppModelTestError.loadFailed
        case .cancellation: throw CancellationError()
        case .blocked(let summaries):
            blockedSummaryStarted = true
            summaryStartWaiters.forEach { $0.resume() }
            summaryStartWaiters.removeAll()
            await withCheckedContinuation { summaryReleaseWaiters.append($0) }
            return summaries
        }
    }

    func personDossierSnapshot(id: UUID) async throws -> PersonDossierSnapshot {
        snapshotIDs.append(id)
        return try await run(nextSnapshotStep())
    }

    func waitUntilBlockedSnapshotStarts(count: Int = 1) async {
        guard blockedSnapshotCount >= count else {
            await withCheckedContinuation { snapshotStartWaiters.append($0) }
            return
        }
    }

    func waitUntilBlockedSummaryStarts() async {
        guard !blockedSummaryStarted else { return }
        await withCheckedContinuation { summaryStartWaiters.append($0) }
    }

    func releaseBlockedSummaries() {
        summaryReleaseWaiters.forEach { $0.resume() }
        summaryReleaseWaiters.removeAll()
    }

    func releaseBlockedSnapshots() {
        snapshotReleaseWaiters.forEach { $0.resume() }
        snapshotReleaseWaiters.removeAll()
    }

    private func nextSnapshotStep() -> SnapshotStep {
        snapshotSteps.isEmpty ? .failure : snapshotSteps.removeFirst()
    }

    private func run(_ step: SnapshotStep) async throws -> PersonDossierSnapshot {
        switch step {
        case .result(let snapshot): return snapshot
        case .failure: throw PersonDossierAppModelTestError.loadFailed
        case .cancellation: throw CancellationError()
        case .blocked(let result):
            blockedSnapshotCount += 1
            snapshotStartWaiters.forEach { $0.resume() }
            snapshotStartWaiters.removeAll()
            await withCheckedContinuation { snapshotReleaseWaiters.append($0) }
            return try result.get()
        }
    }
}

actor ScriptedPersonDossierCostsLoader: DossierLoading {
    private let summariesValue: [DossierSummary]
    private var snapshots: [DossierSnapshot]
    private(set) var snapshotIDs: [UUID] = []

    init(summaries: [DossierSummary] = [], snapshots: [DossierSnapshot] = []) {
        summariesValue = summaries
        self.snapshots = snapshots
    }

    func summaries() async throws -> [DossierSummary] { summariesValue }

    func entryDisposition(for documentID: UUID) async throws -> DossierEntryDisposition {
        .create
    }

    func snapshot(id: UUID) async throws -> DossierSnapshot {
        snapshotIDs.append(id)
        guard !snapshots.isEmpty else {
            throw PersonDossierAppModelTestError.loadFailed
        }
        return snapshots.removeFirst()
    }
}

struct CostsAndPaymentsDossierAppModelValues {
    let snapshot: DossierSnapshot

    static func make() throws -> Self {
        let anchorID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
        let sourceID = UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
        let timestamp = Date(timeIntervalSince1970: 100)
        let dossier = try DossierRecord(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000003")!,
            kind: .costsAndPayments,
            displayName: "Kosten und Zahlungen",
            anchorDocumentID: anchorID,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let anchor = DocumentRecord(
            id: anchorID,
            sourceRootID: sourceID,
            relativePath: "invoice.pdf",
            contentHash: "invoice-hash",
            byteCount: 10,
            modifiedAt: timestamp,
            mediaType: .pdf,
            status: .ready,
            pageCount: 1,
            lastSeenAt: timestamp
        )
        return Self(snapshot: DossierSnapshot(
            dossier: dossier,
            members: [DossierMember(
                document: anchor,
                sourceDisplayName: "Archive",
                documentType: .invoice,
                explanation: DossierMembershipExplanation(
                    role: .anchor,
                    relationshipType: nil,
                    signals: []
                ),
                support: nil
            )],
            corrections: [],
            token: DossierProjectionToken(
                dossierUpdatedAt: timestamp,
                anchorContentHash: anchor.contentHash,
                memberSupports: [],
                exclusionRevisionIDs: []
            )
        ))
    }
}

struct PersonDossierAppModelValues {
    let snapshot: PersonDossierSnapshot

    static func make(
        dossierID: UUID = UUID(uuidString: "72000000-0000-0000-0000-000000000004")!
    ) throws -> Self {
        let originID = UUID(uuidString: "72000000-0000-0000-0000-000000000001")!
        let sourceID = UUID(uuidString: "72000000-0000-0000-0000-000000000002")!
        let anchorID = UUID(uuidString: "72000000-0000-0000-0000-000000000003")!
        let timestamp = Date(timeIntervalSince1970: 200)
        let evidence = try DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 0,
            lengthUTF16: 12,
            exactText: "Elise Muster",
            ocrRegionIndexes: []
        )
        let origin = DocumentRecord(
            id: originID,
            sourceRootID: sourceID,
            relativePath: "person.pdf",
            contentHash: "person-hash",
            byteCount: 20,
            modifiedAt: timestamp,
            mediaType: .pdf,
            status: .ready,
            pageCount: 1,
            lastSeenAt: timestamp
        )
        let anchor = try PersonDossierAnchor(
            id: anchorID,
            displayName: "Elise Muster",
            normalizedName: "elise muster",
            primaryRole: .resident,
            originDocumentID: originID,
            originContentHash: origin.contentHash,
            originExtractionVersion: "text-v1",
            originDNASchemaVersion: 1,
            originDNAAnalyzerIdentifier: "local-rules",
            originDNAAnalyzerVersion: "1",
            originDNAAnalyzedAt: timestamp,
            personEvidence: [evidence],
            birthDate: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let dossier = try DossierRecord(
            id: dossierID,
            kind: .personMatter,
            displayName: "Elise Muster",
            anchor: .person(anchor),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let projectionIdentity = PersonDossierDocumentProjectionIdentity(
            document: origin,
            dnaAnalyzedAt: timestamp
        )
        return Self(snapshot: PersonDossierSnapshot(
            dossier: dossier,
            anchor: anchor,
            origin: try PersonDossierOriginState(
                validity: .current,
                document: origin,
                sourceDisplayName: "Archive"
            ),
            directMembers: [],
            costsAndPayments: [],
            suggestions: [],
            corrections: [],
            token: PersonDossierProjectionToken(
                dossierUpdatedAt: timestamp,
                anchorUpdatedAt: timestamp,
                originValidity: .current,
                documents: [projectionIdentity],
                memberSupports: [],
                suggestionSupports: [],
                confirmationRevisionIDs: [],
                exclusionRevisionIDs: []
            )
        ))
    }
}
