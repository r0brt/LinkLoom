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

actor PersonDossierWatchScheduler: SourceWatchScheduling {
    nonisolated let changes: AsyncStream<DirectoryChange>
    nonisolated let rescanCompletions: AsyncStream<UUID>
    nonisolated private let changesContinuation: AsyncStream<DirectoryChange>.Continuation
    nonisolated private let rescanContinuation: AsyncStream<UUID>.Continuation
    private var activeSourceIDs = Set<UUID>()

    init() {
        let changesPair = AsyncStream<DirectoryChange>.makeStream()
        let rescanPair = AsyncStream<UUID>.makeStream()
        changes = changesPair.stream
        rescanCompletions = rescanPair.stream
        changesContinuation = changesPair.continuation
        rescanContinuation = rescanPair.continuation
    }

    func start(source: SourceRootRecord, url: URL) {
        activeSourceIDs.insert(source.id)
    }

    func stop(sourceID: UUID) {
        activeSourceIDs.remove(sourceID)
    }

    func stopAll() {
        activeSourceIDs.removeAll()
    }

    func isWatching(sourceID: UUID) -> Bool {
        activeSourceIDs.contains(sourceID)
    }

    nonisolated func completeRescan(sourceID: UUID) {
        rescanContinuation.yield(sourceID)
    }

    nonisolated func emit(_ change: DirectoryChange) {
        changesContinuation.yield(change)
    }
}

/// A deliberately tiny seam for races at AppModel's irreversible removal
/// boundary. The production composition leaves the corresponding AppModel
/// hooks nil; tests use this actor to block exactly deletion or watcher stop.
actor SourceRemovalCommitGate {
    enum Boundary: Sendable {
        case delete
        case watcherStop
    }

    private var arrived = Set<String>()
    private var arrivalWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func block(_ boundary: Boundary) async {
        let key = key(for: boundary)
        arrived.insert(key)
        for waiter in arrivalWaiters.removeValue(forKey: key) ?? [] {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters[key, default: []].append(continuation)
        }
    }

    func waitUntilBlocked(_ boundary: Boundary) async {
        let key = key(for: boundary)
        guard !arrived.contains(key) else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters[key, default: []].append(continuation)
        }
    }

    func release(_ boundary: Boundary) {
        let key = key(for: boundary)
        for waiter in releaseWaiters.removeValue(forKey: key) ?? [] {
            waiter.resume()
        }
    }

    private func key(for boundary: Boundary) -> String {
        switch boundary {
        case .delete: "delete"
        case .watcherStop: "watcherStop"
        }
    }
}

@MainActor
final class PersonDossierDiagnosticRecorder: @unchecked Sendable {
    private(set) var diagnostics: [AppRuntimeDiagnostic] = []

    func record(_ diagnostic: AppRuntimeDiagnostic) {
        diagnostics.append(diagnostic)
    }
}

actor ScriptedPersonDossierLoader: PersonDossierLoading, PersonDossierMutating {
    struct SuggestionInvocation: Sendable, Equatable {
        let dossierID: UUID
        let documentID: UUID
        let expectedSupport: PersonDossierCandidateSupportIdentity
        let expectedToken: PersonDossierProjectionToken
    }

    struct MemberInvocation: Sendable, Equatable {
        let dossierID: UUID
        let documentID: UUID
        let expectedSupport: PersonDossierMembershipSupport
        let expectedToken: PersonDossierProjectionToken
    }

    struct CorrectionInvocation: Sendable, Equatable {
        let dossierID: UUID
        let documentID: UUID
        let expectedDecision: PersonDossierCorrectionDecision
        let expectedToken: PersonDossierProjectionToken
    }

    enum CorrectionStep: Sendable {
        case result(PersonDossierSnapshot)
        case failure
        case staleInput
        case cancellation
        case blocked(Result<PersonDossierSnapshot, PersonDossierAppModelTestError>)
    }

    enum SummaryStep: Sendable {
        case result([PersonDossierSummary])
        case failure
        case cancellation
        case blocked(Result<[PersonDossierSummary], PersonDossierAppModelTestError>)
    }

    enum SnapshotStep: Sendable {
        case result(PersonDossierSnapshot)
        case failure
        case cancellation
        case blocked(Result<PersonDossierSnapshot, PersonDossierAppModelTestError>)
        case blockedCancellation
        case dossierFailure(DossierRepositoryError)
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
    private var acceptSteps: [CorrectionStep]
    private var rejectSteps: [CorrectionStep]
    private var removeSteps: [CorrectionStep]
    private var resetSteps: [CorrectionStep]
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
    private(set) var acceptInvocations: [SuggestionInvocation] = []
    private(set) var rejectInvocations: [SuggestionInvocation] = []
    private(set) var removeInvocations: [MemberInvocation] = []
    private(set) var resetInvocations: [CorrectionInvocation] = []
    private(set) var summaryInvocationCount = 0

    var pendingSummaryStartWaiterCount: Int { summaryStartWaiters.count }
    var pendingSnapshotStartWaiterCount: Int { snapshotStartWaiters.count }
    var pendingMutationStartWaiterCount: Int { mutationStartWaiters.count }

    init(
        summarySteps: [SummaryStep] = [.result([])],
        snapshotSteps: [SnapshotStep] = [],
        openSteps: [OpenStep] = [],
        choiceSteps: [ChoiceStep] = [],
        acceptSteps: [CorrectionStep] = [],
        rejectSteps: [CorrectionStep] = [],
        removeSteps: [CorrectionStep] = [],
        resetSteps: [CorrectionStep] = []
    ) {
        self.summarySteps = summarySteps
        self.snapshotSteps = snapshotSteps
        self.openSteps = openSteps
        self.choiceSteps = choiceSteps
        self.acceptSteps = acceptSteps
        self.rejectSteps = rejectSteps
        self.removeSteps = removeSteps
        self.resetSteps = resetSteps
    }

    func personDossierSummaries() async throws -> [PersonDossierSummary] {
        summaryInvocationCount += 1
        let step = summarySteps.isEmpty ? .result([]) : summarySteps.removeFirst()
        switch step {
        case .result(let summaries): return summaries
        case .failure: throw PersonDossierAppModelTestError.loadFailed
        case .cancellation: throw CancellationError()
        case .blocked(let result):
            blockedSummaryCount += 1
            let readyWaiters = summaryStartWaiters.filter {
                $0.targetCount <= blockedSummaryCount
            }
            summaryStartWaiters.removeAll {
                $0.targetCount <= blockedSummaryCount
            }
            readyWaiters.forEach { $0.continuation.resume() }
            await withCheckedContinuation { summaryReleaseWaiters.append($0) }
            return try result.get()
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
        acceptInvocations.append(.init(
            dossierID: dossierID,
            documentID: documentID,
            expectedSupport: expectedSupport,
            expectedToken: expectedToken
        ))
        let step = acceptSteps.isEmpty ? .failure : acceptSteps.removeFirst()
        return try await runCorrection(step)
    }

    func rejectPersonSuggestion(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: PersonDossierCandidateSupportIdentity,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot {
        rejectInvocations.append(.init(
            dossierID: dossierID,
            documentID: documentID,
            expectedSupport: expectedSupport,
            expectedToken: expectedToken
        ))
        let step = rejectSteps.isEmpty ? .failure : rejectSteps.removeFirst()
        return try await runCorrection(step)
    }

    func removePersonMember(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: PersonDossierMembershipSupport,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot {
        removeInvocations.append(.init(
            dossierID: dossierID,
            documentID: documentID,
            expectedSupport: expectedSupport,
            expectedToken: expectedToken
        ))
        let step = removeSteps.isEmpty ? .failure : removeSteps.removeFirst()
        return try await runCorrection(step)
    }

    func resetPersonCorrection(
        dossierID: UUID,
        documentID: UUID,
        expectedDecision: PersonDossierCorrectionDecision,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot {
        resetInvocations.append(.init(
            dossierID: dossierID,
            documentID: documentID,
            expectedDecision: expectedDecision,
            expectedToken: expectedToken
        ))
        let step = resetSteps.isEmpty ? .failure : resetSteps.removeFirst()
        return try await runCorrection(step)
    }

    func setSnapshotSteps(_ steps: [SnapshotStep]) { snapshotSteps = steps }
    func setSummarySteps(_ steps: [SummaryStep]) { summarySteps = steps }
    func setOpenSteps(_ steps: [OpenStep]) { openSteps = steps }
    func setAcceptSteps(_ steps: [CorrectionStep]) { acceptSteps = steps }
    func setRejectSteps(_ steps: [CorrectionStep]) { rejectSteps = steps }
    func setRemoveSteps(_ steps: [CorrectionStep]) { removeSteps = steps }
    func setResetSteps(_ steps: [CorrectionStep]) { resetSteps = steps }

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

    func releaseMostRecentBlockedSnapshot() {
        guard let waiter = snapshotReleaseWaiters.popLast() else { return }
        waiter.resume()
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

    func releaseNextBlockedMutation() {
        guard !mutationReleaseWaiters.isEmpty else { return }
        mutationReleaseWaiters.removeFirst().resume()
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
        case .blockedCancellation:
            blockedSnapshotCount += 1
            let readyWaiters = snapshotStartWaiters.filter {
                $0.targetCount <= blockedSnapshotCount
            }
            snapshotStartWaiters.removeAll {
                $0.targetCount <= blockedSnapshotCount
            }
            readyWaiters.forEach { $0.continuation.resume() }
            await withCheckedContinuation { snapshotReleaseWaiters.append($0) }
            throw CancellationError()
        case .dossierFailure(let error):
            throw error
        }
    }

    private func runCorrection(
        _ step: CorrectionStep
    ) async throws -> PersonDossierSnapshot {
        switch step {
        case .result(let snapshot): return snapshot
        case .failure: throw PersonDossierAppModelTestError.loadFailed
        case .staleInput: throw DossierRepositoryError.staleInput
        case .cancellation: throw CancellationError()
        case .blocked(let result):
            await blockMutation()
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

    func setSnapshots(_ snapshots: [DocumentDNA], documentID: UUID) {
        snapshotsByDocument[documentID] = snapshots
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

actor ScriptedPersonDossierDocumentLoader {
    enum Step: Sendable {
        case result([DocumentRecord])
        case failure
        case cancellation
        case blocked(Result<[DocumentRecord], PersonDossierAppModelTestError>)
    }

    private var documentsBySource: [UUID: [DocumentRecord]]
    private var stepsBySource: [UUID: [Step]] = [:]
    private var blockedLoadCount = 0
    private var startWaiters: [(
        targetCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sourceIDs: [UUID] = []

    init(documentsBySource: [UUID: [DocumentRecord]]) {
        self.documentsBySource = documentsBySource
    }

    func setDocuments(_ documents: [DocumentRecord], sourceID: UUID) {
        documentsBySource[sourceID] = documents
    }

    func setSteps(_ steps: [Step], sourceID: UUID) {
        stepsBySource[sourceID] = steps
    }

    func load(sourceID: UUID) async throws -> [DocumentRecord] {
        sourceIDs.append(sourceID)
        guard var steps = stepsBySource[sourceID], !steps.isEmpty else {
            return documentsBySource[sourceID] ?? []
        }
        let step = steps.removeFirst()
        stepsBySource[sourceID] = steps
        switch step {
        case .result(let documents):
            return documents
        case .failure:
            throw PersonDossierAppModelTestError.loadFailed
        case .cancellation:
            throw CancellationError()
        case .blocked(let result):
            blockedLoadCount += 1
            let ready = startWaiters.filter { $0.targetCount <= blockedLoadCount }
            startWaiters.removeAll { $0.targetCount <= blockedLoadCount }
            ready.forEach { $0.continuation.resume() }
            await withCheckedContinuation { releaseWaiters.append($0) }
            return try result.get()
        }
    }

    func waitUntilBlockedLoadStarts(count: Int = 1) async {
        guard blockedLoadCount >= count else {
            await withCheckedContinuation { startWaiters.append((count, $0)) }
            return
        }
    }

    func releaseBlockedLoads() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

actor PersonDossierCandidateLoader: InvoicePaymentCandidateLoading {
    private let candidatesByDocument: [UUID: [InvoicePaymentCandidateWithDecision]]

    init(candidatesByDocument: [UUID: [InvoicePaymentCandidateWithDecision]]) {
        self.candidatesByDocument = candidatesByDocument
    }

    func candidates(involving documentID: UUID) async throws
        -> [InvoicePaymentCandidateWithDecision]
    {
        candidatesByDocument[documentID] ?? []
    }
}

actor ScriptedPersonDossierCostsLoader: DossierLoading, DossierMutating {
    enum SummaryStep: Sendable {
        case result([DossierSummary])
        case failure
        case blocked(Result<[DossierSummary], PersonDossierAppModelTestError>)
    }

    enum SnapshotStep: Sendable {
        case result(DossierSnapshot)
        case failure
    }

    enum OpenStep: Sendable {
        case result(DossierOpenResult)
        case failure
    }

    private var summarySteps: [SummaryStep]
    private var snapshotSteps: [SnapshotStep]
    private var openSteps: [OpenStep]
    private var blockedSummaryCount = 0
    private var summaryStartWaiters: [(
        targetCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var summaryReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var snapshotIDs: [UUID] = []
    private(set) var summaryInvocationCount = 0

    init(
        summaries: [DossierSummary] = [],
        summarySteps: [SummaryStep]? = nil,
        snapshots: [DossierSnapshot] = [],
        openSteps: [OpenStep] = []
    ) {
        self.summarySteps = summarySteps ?? [.result(summaries)]
        snapshotSteps = snapshots.map(SnapshotStep.result)
        self.openSteps = openSteps
    }

    func summaries() async throws -> [DossierSummary] {
        summaryInvocationCount += 1
        let step = summarySteps.isEmpty ? .result([]) : summarySteps.removeFirst()
        switch step {
        case .result(let summaries): return summaries
        case .failure: throw PersonDossierAppModelTestError.loadFailed
        case .blocked(let result):
            blockedSummaryCount += 1
            let readyWaiters = summaryStartWaiters.filter {
                $0.targetCount <= blockedSummaryCount
            }
            summaryStartWaiters.removeAll {
                $0.targetCount <= blockedSummaryCount
            }
            readyWaiters.forEach { $0.continuation.resume() }
            await withCheckedContinuation { summaryReleaseWaiters.append($0) }
            return try result.get()
        }
    }

    func setSummarySteps(_ steps: [SummaryStep]) {
        summarySteps = steps
    }

    func waitUntilBlockedSummaryStarts(count: Int = 1) async {
        guard blockedSummaryCount < count else { return }
        await withCheckedContinuation { summaryStartWaiters.append((count, $0)) }
    }

    func releaseBlockedSummaries() {
        summaryReleaseWaiters.forEach { $0.resume() }
        summaryReleaseWaiters.removeAll()
    }

    func entryDisposition(for documentID: UUID) async throws -> DossierEntryDisposition {
        .create
    }

    func snapshot(id: UUID) async throws -> DossierSnapshot {
        snapshotIDs.append(id)
        guard !snapshotSteps.isEmpty else {
            throw PersonDossierAppModelTestError.loadFailed
        }
        switch snapshotSteps.removeFirst() {
        case .result(let snapshot): return snapshot
        case .failure: throw PersonDossierAppModelTestError.loadFailed
        }
    }

    func setSnapshotSteps(_ steps: [SnapshotStep]) {
        snapshotSteps = steps
    }

    func setOpenSteps(_ steps: [OpenStep]) {
        openSteps = steps
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

struct PersonDossierNavigationValues {
    static let directID = UUID(
        uuidString: "73000000-0000-0000-0000-000000000001"
    )!
    static let paymentID = UUID(
        uuidString: "73000000-0000-0000-0000-000000000004"
    )!

    let origin: DocumentRecord
    let direct: DocumentRecord
    let crossSourceDirect: DocumentRecord
    let invoice: DocumentRecord
    let payment: DocumentRecord
    let suggestion: DocumentRecord
    let correction: DocumentRecord
    let dnaByDocument: [UUID: DocumentDNA]
    let snapshot: PersonDossierSnapshot
    let candidate: InvoicePaymentCandidateWithDecision

    static func make(originSourceID: UUID, otherSourceID: UUID) throws -> Self {
        let base = try PersonDossierAppModelValues.make(sourceID: originSourceID)
        let origin = base.document
        let direct = document(
            id: directID,
            sourceID: originSourceID,
            path: "direct.pdf",
            hash: "direct-hash"
        )
        let crossSourceDirect = document(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000002")!,
            sourceID: otherSourceID,
            path: "cross-source-direct.pdf",
            hash: "cross-source-direct-hash"
        )
        let invoice = document(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000003")!,
            sourceID: originSourceID,
            path: "invoice.pdf",
            hash: "invoice-hash"
        )
        let payment = document(
            id: paymentID,
            sourceID: otherSourceID,
            path: "payment.pdf",
            hash: "payment-hash"
        )
        let suggestion = document(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000005")!,
            sourceID: otherSourceID,
            path: "suggestion.pdf",
            hash: "suggestion-hash"
        )
        let correction = document(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000006")!,
            sourceID: originSourceID,
            path: "correction.pdf",
            hash: "correction-hash"
        )
        let documents = [origin, direct, crossSourceDirect, invoice, payment, suggestion, correction]
        var dnaByDocument: [UUID: DocumentDNA] = [origin.id: base.dna]
        for document in documents.dropFirst() {
            dnaByDocument[document.id] = try dna(document: document)
        }
        let directMembers = try [direct, crossSourceDirect].map {
            try member(document: $0, dna: dnaByDocument[$0.id]!, section: .directDocuments)
        }
        let costMembers = try [invoice, payment].map {
            try member(document: $0, dna: dnaByDocument[$0.id]!, section: .costsAndPayments)
        }
        let suggestionDNA = dnaByDocument[suggestion.id]!
        let suggestionFinding = suggestionDNA.findings.first { $0.kind == .person }!
        let suggestionPerson = try PersonDossierFindingSupportIdentity(
            current: CurrentDocumentDNA(document: suggestion, snapshot: suggestionDNA),
            role: .authorizedPerson,
            finding: suggestionFinding
        )
        let suggestionSupport = try PersonDossierCandidateSupportIdentity(
            kind: .secondaryRole,
            person: suggestionPerson,
            conflict: .none
        )
        let suggestionRow = try PersonDossierSuggestion(
            document: suggestion,
            sourceDisplayName: "Other archive",
            documentType: .unknown,
            section: .directDocuments,
            kind: .secondaryRole,
            conflict: .none,
            currentSupports: [suggestionSupport],
            commandSupport: suggestionSupport
        )
        let exclusion = DossierMembershipExclusion(
            dossierID: base.snapshot.dossier.id,
            documentID: correction.id,
            revisionID: UUID(uuidString: "73000000-0000-0000-0000-000000000007")!,
            excludedAt: Date(timeIntervalSince1970: 300)
        )
        let correctionRow = try PersonDossierCorrection(
            document: correction,
            sourceDisplayName: "Archive",
            documentType: .unknown,
            decision: .exclusion(exclusion)
        )
        let projectionDocuments = documents.map {
            PersonDossierDocumentProjectionIdentity(
                document: $0,
                dnaAnalyzedAt: dnaByDocument[$0.id]?.analyzedAt
            )
        }
        let token = PersonDossierProjectionToken(
            dossierUpdatedAt: base.snapshot.token.dossierUpdatedAt,
            anchorUpdatedAt: base.snapshot.token.anchorUpdatedAt,
            originValidity: .current,
            documents: projectionDocuments,
            memberSupports: (directMembers + costMembers).map(\.supports),
            suggestionSupports: [suggestionSupport],
            confirmationRevisionIDs: [],
            exclusionRevisionIDs: [exclusion.revisionID]
        )
        let snapshot = PersonDossierSnapshot(
            dossier: base.snapshot.dossier,
            anchor: base.snapshot.anchor,
            origin: base.snapshot.origin,
            directMembers: directMembers,
            costsAndPayments: costMembers,
            suggestions: [suggestionRow],
            corrections: [correctionRow],
            token: token
        )
        let invoiceDNA = dnaByDocument[invoice.id]!
        let paymentDNA = dnaByDocument[payment.id]!
        let candidate = try InvoicePaymentCandidate(
            invoice: CurrentDocumentDNA(document: invoice, snapshot: invoiceDNA),
            payment: CurrentDocumentDNA(document: payment, snapshot: paymentDNA),
            disposition: .automatic,
            resolverVersion: "invoice-payment-v1",
            signals: []
        )
        return Self(
            origin: origin,
            direct: direct,
            crossSourceDirect: crossSourceDirect,
            invoice: invoice,
            payment: payment,
            suggestion: suggestion,
            correction: correction,
            dnaByDocument: dnaByDocument,
            snapshot: snapshot,
            candidate: InvoicePaymentCandidateWithDecision(
                candidate: candidate,
                decision: .confirmed
            )
        )
    }

    func replacingSnapshot(
        dossier: DossierRecord? = nil,
        origin: PersonDossierOriginState? = nil,
        directMembers: [PersonDossierMember]? = nil,
        costsAndPayments: [PersonDossierMember]? = nil,
        suggestions: [PersonDossierSuggestion]? = nil,
        corrections: [PersonDossierCorrection]? = nil,
        token: PersonDossierProjectionToken? = nil
    ) -> PersonDossierSnapshot {
        PersonDossierSnapshot(
            dossier: dossier ?? snapshot.dossier,
            anchor: snapshot.anchor,
            origin: origin ?? snapshot.origin,
            directMembers: directMembers ?? snapshot.directMembers,
            costsAndPayments: costsAndPayments ?? snapshot.costsAndPayments,
            suggestions: suggestions ?? snapshot.suggestions,
            corrections: corrections ?? snapshot.corrections,
            token: token ?? snapshot.token
        )
    }

    func duplicateFirstWinsSnapshot(
        laterSourceID: UUID
    ) throws -> (snapshot: PersonDossierSnapshot, laterDocument: DocumentRecord) {
        let earlier = snapshot.directMembers.first { $0.id == direct.id }!
        var laterDocument = direct
        laterDocument.sourceRootID = laterSourceID
        laterDocument.relativePath = "later-duplicate.pdf"
        laterDocument.contentHash = "later-duplicate-hash"
        laterDocument.byteCount = 999
        let later = try PersonDossierMember(
            document: laterDocument,
            sourceDisplayName: "Other archive",
            documentType: .paymentConfirmation,
            section: .costsAndPayments,
            supports: earlier.supports,
            isConfirmationAuthoritative: earlier.isConfirmationAuthoritative,
            preferredPaymentSupport: earlier.preferredPaymentSupport
        )
        return (
            replacingSnapshot(
                costsAndPayments: [later] + snapshot.costsAndPayments
            ),
            laterDocument
        )
    }

    private static func document(
        id: UUID,
        sourceID: UUID,
        path: String,
        hash: String
    ) -> DocumentRecord {
        DocumentRecord(
            id: id,
            sourceRootID: sourceID,
            relativePath: path,
            contentHash: hash,
            byteCount: 30,
            modifiedAt: Date(timeIntervalSince1970: 200),
            mediaType: .pdf,
            status: .ready,
            pageCount: 1,
            lastSeenAt: Date(timeIntervalSince1970: 200)
        )
    }

    private static func dna(document: DocumentRecord) throws -> DocumentDNA {
        let name = "Elise Muster"
        let evidence = try DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 0,
            lengthUTF16: name.utf16.count,
            exactText: name,
            ocrRegionIndexes: []
        )
        let role: PersonDossierRole = document.relativePath == "suggestion.pdf"
            ? .authorizedPerson
            : .resident
        let finding = try DocumentDNAFinding(
            kind: .person,
            qualifier: role.rawValue,
            displayValue: name,
            normalizedValue: name.lowercased(),
            secondaryNormalizedValue: nil,
            confidence: 0.9,
            evidence: [evidence]
        )
        let documentType: DocumentType = switch document.relativePath {
        case "invoice.pdf": .invoice
        case "payment.pdf": .paymentConfirmation
        default: .unknown
        }
        let classificationDisplayValue = documentType == .unknown
            ? ""
            : documentType.rawValue
        let classificationEvidence = documentType == .unknown
            ? []
            : [try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: classificationDisplayValue.utf16.count,
                exactText: classificationDisplayValue,
                ocrRegionIndexes: []
            )]
        let classification = try DocumentDNAFinding(
            kind: .documentType,
            qualifier: nil,
            displayValue: classificationDisplayValue,
            normalizedValue: documentType.rawValue,
            secondaryNormalizedValue: nil,
            confidence: documentType == .unknown ? 0 : 0.9,
            evidence: classificationEvidence
        )
        return try DocumentDNA(
            documentID: document.id,
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1",
            inputContentHash: document.contentHash,
            inputExtractionVersion: "text-v1",
            findings: [classification, finding],
            analyzedAt: Date(timeIntervalSince1970: 200)
        )
    }

    private static func member(
        document: DocumentRecord,
        dna: DocumentDNA,
        section: PersonDossierSection
    ) throws -> PersonDossierMember {
        let finding = dna.findings.first { $0.kind == .person }!
        let support = try PersonDossierFindingSupportIdentity(
            current: CurrentDocumentDNA(document: document, snapshot: dna),
            role: .resident,
            finding: finding
        )
        return try PersonDossierMember(
            document: document,
            sourceDisplayName: "Archive",
            documentType: .unknown,
            section: section,
            supports: [.exactPrimary(support)],
            isConfirmationAuthoritative: false,
            preferredPaymentSupport: nil
        )
    }
}
