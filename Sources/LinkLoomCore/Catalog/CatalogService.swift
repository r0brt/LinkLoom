import Foundation

public struct ScanReport: Sendable, Equatable {
    public let sourceRootID: UUID
    public let discovered: Int
    public let changed: Int
    public let unchanged: Int
    public let missing: Int
}

public struct CatalogService: Sendable {
    static let fingerprintVerificationInterval: TimeInterval = 30 * 24 * 60 * 60

    private let sourceAccess: any SourceAccessing
    private let enumerator: any FileEnumerating
    private let fingerprinter: any FileFingerprinting
    private let documents: DocumentRepository
    private let sources: SourceRootRepository
    private let scanCoordinator: CatalogScanCoordinator

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
        scanCoordinator = CatalogScanCoordinator()
    }

    public func scan(
        source: SourceRootRecord,
        now: Date = .now
    ) async throws -> ScanReport {
        try await scanCoordinator.acquire(sourceRootID: source.id)
        do {
            try Task.checkCancellation()
            let report = try await scanWithoutCoordination(source: source, now: now)
            await scanCoordinator.release(sourceRootID: source.id)
            return report
        } catch {
            await scanCoordinator.release(sourceRootID: source.id)
            throw error
        }
    }

    private func scanWithoutCoordination(
        source: SourceRootRecord,
        now: Date
    ) async throws -> ScanReport {
        try await sourceAccess.withAccess(to: source.bookmarkData) { root in
            let candidates = try enumerator.files(in: root)
            let existing = try await documents.all(sourceRootID: source.id)
            let byPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.relativePath, $0) })
            var matchedExistingIDs = Set<UUID>()
            var newPathCandidates: [FileCandidate] = []
            var documentsToSave: [DocumentRecord] = []
            var discovered = 0
            var changed = 0
            var unchanged = 0

            for candidate in candidates {
                guard var previous = byPath[candidate.relativePath] else {
                    newPathCandidates.append(candidate)
                    continue
                }
                matchedExistingIDs.insert(previous.id)
                previous.lastSeenAt = now
                previous.availability = .available

                let metadataMatches = previous.byteCount == candidate.byteCount
                    && previous.modifiedAt == candidate.modifiedAt
                let verificationDue = previous.lastFingerprintAt.map {
                    now.timeIntervalSince($0) >= Self.fingerprintVerificationInterval
                } ?? true
                if metadataMatches, !verificationDue {
                    documentsToSave.append(previous)
                    unchanged += 1
                    continue
                }

                let fingerprint: FileFingerprint
                if metadataMatches {
                    fingerprint = try await fingerprinter.fingerprint(candidate.url)
                } else {
                    do {
                        fingerprint = try await fingerprinter.fingerprint(candidate.url)
                    } catch let error as CancellationError {
                        throw error
                    } catch {
                        previous.availability = .unavailable
                        documentsToSave.append(previous)
                        continue
                    }
                }
                let contentChanged = previous.contentHash != fingerprint.sha256
                previous.contentHash = fingerprint.sha256
                previous.byteCount = fingerprint.byteCount
                previous.modifiedAt = candidate.modifiedAt
                previous.mediaType = candidate.mediaType
                previous.lastFingerprintAt = now
                if contentChanged {
                    previous.status = .discovered
                    previous.pageCount = nil
                    previous.failureCode = nil
                }
                documentsToSave.append(previous)
                if contentChanged {
                    changed += 1
                } else {
                    unchanged += 1
                }
            }

            var fingerprintedNewPathCandidates: [(FileCandidate, FileFingerprint)] = []
            for candidate in newPathCandidates {
                let fingerprint = try await fingerprinter.fingerprint(candidate.url)
                fingerprintedNewPathCandidates.append((candidate, fingerprint))
            }
            let newCandidateCountByHash = Dictionary(
                grouping: fingerprintedNewPathCandidates,
                by: { $0.1.sha256 }
            ).mapValues(\.count)
            let relocationCandidatesByHash = Dictionary(
                grouping: existing.filter { !matchedExistingIDs.contains($0.id) },
                by: \.contentHash
            )

            for (candidate, fingerprint) in fingerprintedNewPathCandidates {
                let relocationMatches = relocationCandidatesByHash[fingerprint.sha256] ?? []
                let relocated = relocationMatches.count == 1
                    && newCandidateCountByHash[fingerprint.sha256] == 1
                    ? relocationMatches[0]
                    : nil
                var record = relocated ?? DocumentRecord(
                    sourceRootID: source.id,
                    relativePath: candidate.relativePath,
                    contentHash: fingerprint.sha256,
                    byteCount: fingerprint.byteCount,
                    modifiedAt: candidate.modifiedAt,
                    mediaType: candidate.mediaType,
                    lastSeenAt: now,
                    lastFingerprintAt: now
                )
                record.relativePath = candidate.relativePath
                record.contentHash = fingerprint.sha256
                record.byteCount = fingerprint.byteCount
                record.modifiedAt = candidate.modifiedAt
                record.mediaType = candidate.mediaType
                record.availability = .available
                record.lastSeenAt = now
                record.lastFingerprintAt = now
                documentsToSave.append(record)
                matchedExistingIDs.insert(record.id)
                if relocated == nil {
                    discovered += 1
                } else {
                    changed += 1
                }
            }

            try Task.checkCancellation()
            let missing = try await documents.reconcile(
                sourceRootID: source.id,
                saving: documentsToSave,
                excludingDocumentIDs: matchedExistingIDs
            )
            try await sources.updateLastScan(id: source.id, at: now)
            return ScanReport(
                sourceRootID: source.id,
                discovered: discovered,
                changed: changed,
                unchanged: unchanged,
                missing: missing
            )
        }
    }
}

private actor CatalogScanCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var activeSourceRootIDs = Set<UUID>()
    private var waiters: [UUID: [Waiter]] = [:]

    func acquire(sourceRootID: UUID) async throws {
        try Task.checkCancellation()
        if activeSourceRootIDs.insert(sourceRootID).inserted {
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[sourceRootID, default: []].append(Waiter(
                        id: waiterID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID, sourceRootID: sourceRootID)
            }
        }
    }

    func release(sourceRootID: UUID) {
        guard var sourceWaiters = waiters[sourceRootID], !sourceWaiters.isEmpty else {
            activeSourceRootIDs.remove(sourceRootID)
            waiters[sourceRootID] = nil
            return
        }
        let next = sourceWaiters.removeFirst()
        waiters[sourceRootID] = sourceWaiters.isEmpty ? nil : sourceWaiters
        next.continuation.resume()
    }

    private func cancelWaiter(id: UUID, sourceRootID: UUID) {
        guard var sourceWaiters = waiters[sourceRootID],
              let index = sourceWaiters.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let waiter = sourceWaiters.remove(at: index)
        waiters[sourceRootID] = sourceWaiters.isEmpty ? nil : sourceWaiters
        waiter.continuation.resume(throwing: CancellationError())
    }
}
