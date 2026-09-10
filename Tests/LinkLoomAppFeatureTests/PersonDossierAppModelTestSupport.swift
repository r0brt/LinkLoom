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

actor ScriptedPersonDossierLoader: PersonDossierLoading, PersonDossierMutating {
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

    enum OpenStep: Sendable {
        case result(PersonDossierOpenResult)
        case failure
        case cancellation
        case blocked(Result<PersonDossierOpenResult, PersonDossierAppModelTestError>)
    }

    enum ChoiceStep: Sendable {
        case result(PersonDossierSnapshot)
        case failure
        case cancellation
        case blocked(Result<PersonDossierSnapshot, PersonDossierAppModelTestError>)
    }

    private var summarySteps: [SummaryStep]
    private var snapshotSteps: [SnapshotStep]
    private var openSteps: [OpenStep]
    private var choiceSteps: [ChoiceStep]
    private var blockedSummaryCount = 0
    private var summaryStartWaiters: [(
        targetCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var summaryReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedSnapshotCount = 0
    private var snapshotStartWaiters: [(
        targetCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var snapshotReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedMutationCount = 0
    private var mutationStartWaiters: [(
        targetCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var mutationReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var snapshotIDs: [UUID] = []
    private(set) var openSelections: [PersonDossierAnchorSelection] = []
    private(set) var choiceSelections: [PersonDossierAnchorSelection] = []
    private(set) var creationChoices: [PersonDossierCreationChoice] = []
    private(set) var summaryInvocationCount = 0

    var pendingSummaryStartWaiterCount: Int { summaryStartWaiters.count }
    var pendingSnapshotStartWaiterCount: Int { snapshotStartWaiters.count }
    var pendingMutationStartWaiterCount: Int { mutationStartWaiters.count }

    init(
        summarySteps: [SummaryStep] = [.result([])],
        snapshotSteps: [SnapshotStep] = [],
        openSteps: [OpenStep] = [],
        choiceSteps: [ChoiceStep] = []
    ) {
        self.summarySteps = summarySteps
        self.snapshotSteps = snapshotSteps
        self.openSteps = openSteps
        self.choiceSteps = choiceSteps
    }

    func personDossierSummaries() async throws -> [PersonDossierSummary] {
        summaryInvocationCount += 1
        let step = summarySteps.isEmpty ? .result([]) : summarySteps.removeFirst()
        switch step {
        case .result(let summaries): return summaries
        case .failure: throw PersonDossierAppModelTestError.loadFailed
        case .cancellation: throw CancellationError()
        case .blocked(let summaries):
            blockedSummaryCount += 1
            let readyWaiters = summaryStartWaiters.filter {
                $0.targetCount <= blockedSummaryCount
            }
            summaryStartWaiters.removeAll {
                $0.targetCount <= blockedSummaryCount
            }
            readyWaiters.forEach { $0.continuation.resume() }
            await withCheckedContinuation { summaryReleaseWaiters.append($0) }
            return summaries
        }
    }

    func personDossierSnapshot(id: UUID) async throws -> PersonDossierSnapshot {
        snapshotIDs.append(id)
        return try await run(nextSnapshotStep())
    }

    func createOrOpenPersonDossier(
        from selection: PersonDossierAnchorSelection
    ) async throws -> PersonDossierOpenResult {
        openSelections.append(selection)
        let step = openSteps.isEmpty ? .failure : openSteps.removeFirst()
        switch step {
        case .result(let result): return result
        case .failure: throw PersonDossierAppModelTestError.loadFailed
        case .cancellation: throw CancellationError()
        case .blocked(let result):
            await blockMutation()
            return try result.get()
        }
    }

    func chooseOrCreatePersonDossier(
        from selection: PersonDossierAnchorSelection,
        choice: PersonDossierCreationChoice
    ) async throws -> PersonDossierSnapshot {
        choiceSelections.append(selection)
        creationChoices.append(choice)
        let step = choiceSteps.isEmpty ? .failure : choiceSteps.removeFirst()
        switch step {
        case .result(let snapshot): return snapshot
        case .failure: throw PersonDossierAppModelTestError.loadFailed
        case .cancellation: throw CancellationError()
        case .blocked(let result):
            await blockMutation()
            return try result.get()
        }
    }

    func acceptPersonSuggestion(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: PersonDossierCandidateSupportIdentity,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot {
        throw PersonDossierAppModelTestError.loadFailed
    }

    func rejectPersonSuggestion(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: PersonDossierCandidateSupportIdentity,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot {
        throw PersonDossierAppModelTestError.loadFailed
    }

    func removePersonMember(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: PersonDossierMembershipSupport,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot {
        throw PersonDossierAppModelTestError.loadFailed
    }

    func resetPersonCorrection(
        dossierID: UUID,
        documentID: UUID,
        expectedDecision: PersonDossierCorrectionDecision,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot {
        throw PersonDossierAppModelTestError.loadFailed
    }

    func waitUntilBlockedSnapshotStarts(count: Int = 1) async {
        guard blockedSnapshotCount >= count else {
            await withCheckedContinuation {
                snapshotStartWaiters.append((count, $0))
            }
            return
        }
    }

    func waitUntilBlockedSummaryStarts(count: Int = 1) async {
        guard blockedSummaryCount >= count else {
            await withCheckedContinuation {
                summaryStartWaiters.append((count, $0))
            }
            return
        }
    }

    func releaseBlockedSummaries() {
        summaryReleaseWaiters.forEach { $0.resume() }
        summaryReleaseWaiters.removeAll()
    }

    func releaseBlockedSnapshots() {
        snapshotReleaseWaiters.forEach { $0.resume() }
        snapshotReleaseWaiters.removeAll()
    }

    func waitUntilBlockedMutationStarts(count: Int = 1) async {
        guard blockedMutationCount >= count else {
            await withCheckedContinuation {
                mutationStartWaiters.append((count, $0))
            }
            return
        }
    }

    func releaseBlockedMutations() {
        mutationReleaseWaiters.forEach { $0.resume() }
        mutationReleaseWaiters.removeAll()
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
            let readyWaiters = snapshotStartWaiters.filter {
                $0.targetCount <= blockedSnapshotCount
            }
            snapshotStartWaiters.removeAll {
                $0.targetCount <= blockedSnapshotCount
            }
            readyWaiters.forEach { $0.continuation.resume() }
            await withCheckedContinuation { snapshotReleaseWaiters.append($0) }
            return try result.get()
        }
    }


    private func blockMutation() async {
        blockedMutationCount += 1
        let readyWaiters = mutationStartWaiters.filter {
            $0.targetCount <= blockedMutationCount
        }
        mutationStartWaiters.removeAll {
            $0.targetCount <= blockedMutationCount
        }
        readyWaiters.forEach { $0.continuation.resume() }
        await withCheckedContinuation { mutationReleaseWaiters.append($0) }
    }
}

struct PersonDossierDNAStatusLoader: DocumentDNAStatusLoading {
    let statusesBySource: [UUID: [DocumentDNAAnalysisStatus]]

    func currentAnalysisStatuses(sourceRootID: UUID) async throws -> [DocumentDNAAnalysisStatus] {
        statusesBySource[sourceRootID] ?? []
    }
}

actor ScriptedPersonDossierDNALoader: DocumentDNASnapshotLoading {
    private var snapshotsByDocument: [UUID: [DocumentDNA]]

    init(snapshotsByDocument: [UUID: [DocumentDNA]]) {
        self.snapshotsByDocument = snapshotsByDocument
    }

    func currentSnapshot(documentID: UUID) async throws -> DocumentDNA? {
        guard var snapshots = snapshotsByDocument[documentID], !snapshots.isEmpty else {
            return nil
        }
        let snapshot = snapshots.removeFirst()
        snapshotsByDocument[documentID] = snapshots
        return snapshot
    }
}

actor ScriptedPersonDossierCostsLoader: DossierLoading, DossierMutating {
    enum OpenStep: Sendable {
        case result(DossierOpenResult)
        case failure
    }

    private let summariesValue: [DossierSummary]
    private var snapshots: [DossierSnapshot]
    private var openSteps: [OpenStep]
    private(set) var snapshotIDs: [UUID] = []

    init(
        summaries: [DossierSummary] = [],
        snapshots: [DossierSnapshot] = [],
        openSteps: [OpenStep] = []
    ) {
        summariesValue = summaries
        self.snapshots = snapshots
        self.openSteps = openSteps
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

    func createOrOpen(anchorDocumentID: UUID) async throws -> DossierOpenResult {
        guard !openSteps.isEmpty else {
            throw PersonDossierAppModelTestError.loadFailed
        }
        switch openSteps.removeFirst() {
        case .result(let result): return result
        case .failure: throw PersonDossierAppModelTestError.loadFailed
        }
    }

    func excludeMember(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: DossierMembershipSupportIdentity
    ) async throws -> DossierSnapshot {
        throw PersonDossierAppModelTestError.loadFailed
    }

    func resetExclusion(
        dossierID: UUID,
        documentID: UUID,
        expectedRevisionID: UUID
    ) async throws -> DossierSnapshot {
        throw PersonDossierAppModelTestError.loadFailed
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
    static let defaultDocumentID = UUID(
        uuidString: "72000000-0000-0000-0000-000000000001"
    )!

    let document: DocumentRecord
    let dna: DocumentDNA
    let selection: PersonDossierAnchorSelection
    let snapshot: PersonDossierSnapshot

    static func make(
        dossierID: UUID = UUID(uuidString: "72000000-0000-0000-0000-000000000004")!,
        sourceID: UUID = UUID(uuidString: "72000000-0000-0000-0000-000000000002")!,
        documentID: UUID = defaultDocumentID,
        name: String = "Elise Muster",
        documentType: DocumentType = .unknown
    ) throws -> Self {
        let anchorID = UUID(uuidString: "72000000-0000-0000-0000-000000000003")!
        let timestamp = Date(timeIntervalSince1970: 200)
        let evidence = try DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 0,
            lengthUTF16: name.utf16.count,
            exactText: name,
            ocrRegionIndexes: []
        )
        let origin = DocumentRecord(
            id: documentID,
            sourceRootID: sourceID,
            relativePath: "person-\(documentID.uuidString).pdf",
            contentHash: "person-hash",
            byteCount: 20,
            modifiedAt: timestamp,
            mediaType: .pdf,
            status: .ready,
            pageCount: 1,
            lastSeenAt: timestamp
        )
        let finding = try DocumentDNAFinding(
            kind: .person,
            qualifier: PersonDossierRole.resident.rawValue,
            displayValue: name,
            normalizedValue: name.lowercased(),
            secondaryNormalizedValue: nil,
            confidence: 0.9,
            evidence: [evidence]
        )
        let documentTypeFinding: DocumentDNAFinding
        if documentType == .unknown {
            documentTypeFinding = try DocumentDNAFinding(
                kind: .documentType,
                qualifier: nil,
                displayValue: "",
                normalizedValue: DocumentType.unknown.rawValue,
                secondaryNormalizedValue: nil,
                confidence: 0,
                evidence: []
            )
        } else {
            let displayValue = documentType.rawValue
            let evidence = try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: displayValue.utf16.count,
                exactText: displayValue,
                ocrRegionIndexes: []
            )
            documentTypeFinding = try DocumentDNAFinding(
                kind: .documentType,
                qualifier: nil,
                displayValue: displayValue,
                normalizedValue: documentType.rawValue,
                secondaryNormalizedValue: nil,
                confidence: 0.9,
                evidence: [evidence]
            )
        }
        let dna = try DocumentDNA(
            documentID: origin.id,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: origin.contentHash,
            inputExtractionVersion: "text-v1",
            findings: [documentTypeFinding, finding],
            analyzedAt: timestamp
        )
        let selection = try PersonDossierAnchorSelection(
            document: origin,
            snapshot: dna,
            finding: finding
        )
        let anchor = try PersonDossierAnchor(
            id: anchorID,
            displayName: name,
            normalizedName: name.lowercased(),
            primaryRole: .resident,
            originDocumentID: origin.id,
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
        return Self(
            document: origin,
            dna: dna,
            selection: selection,
            snapshot: PersonDossierSnapshot(
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
            )
        )
    }
}
