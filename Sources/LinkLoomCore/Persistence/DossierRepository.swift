import Foundation
import GRDB

public actor DossierRepository {
    private let dbWriter: any DatabaseWriter
    private nonisolated let projectionReader: DossierProjectionReader
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    public init(
        dbWriter: any DatabaseWriter,
        target: DocumentDNAAnalysisTarget,
        resolver: InvoicePaymentCandidateResolver = InvoicePaymentCandidateResolver(),
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.dbWriter = dbWriter
        projectionReader = DossierProjectionReader(
            target: target,
            candidateProjector: InvoicePaymentCandidateProjector(resolver: resolver)
        )
        self.now = now
        self.makeUUID = makeUUID
    }

    public func summaries() async throws -> [DossierSummary] {
        do {
            return try await dbWriter.read { db in
                try DossierStore.all(in: db).map {
                    try self.projectionReader.summary(in: db, dossier: $0)
                }
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func entryDisposition(
        for documentID: UUID
    ) async throws -> DossierEntryDisposition {
        do {
            return try await dbWriter.read { db in
                guard try self.projectionReader.isEligibleAnchor(
                    in: db,
                    documentID: documentID
                ) else {
                    throw DossierRepositoryError.invalidAnchor
                }
                let dossiers = try DossierStore.all(in: db)
                if let anchored = dossiers.first(where: {
                    $0.kind == .costsAndPayments
                        && $0.anchorDocumentID == documentID
                }) {
                    return .open(try self.projectionReader.summary(
                        in: db,
                        dossier: anchored
                    ))
                }
                let matches = try self.matchingSummaries(
                    in: db,
                    documentID: documentID,
                    dossiers: dossiers
                )
                switch matches.count {
                case 0: return .create
                case 1: return .open(matches[0])
                default: return .choose(matches)
                }
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func createOrOpen(
        anchorDocumentID: UUID
    ) async throws -> DossierOpenResult {
        let proposedID = makeUUID()
        let timestamp = now()
        do {
            return try await dbWriter.write { db in
                guard try self.projectionReader.isEligibleAnchor(
                    in: db,
                    documentID: anchorDocumentID
                ) else {
                    throw DossierRepositoryError.invalidAnchor
                }
                let dossiers = try DossierStore.all(in: db)
                if let anchored = dossiers.first(where: {
                    $0.kind == .costsAndPayments
                        && $0.anchorDocumentID == anchorDocumentID
                }) {
                    return .opened(try self.projectionReader.snapshot(
                        in: db,
                        dossier: anchored
                    ))
                }
                let matches = try self.matchingSummaries(
                    in: db,
                    documentID: anchorDocumentID,
                    dossiers: dossiers
                )
                if matches.count == 1, let match = matches.first {
                    return .opened(try self.projectionReader.snapshot(
                        in: db,
                        dossierID: match.id
                    ))
                }
                if matches.count > 1 {
                    return .choose(matches)
                }
                let proposed = try DossierRecord(
                    id: proposedID,
                    kind: .costsAndPayments,
                    displayName: "Kosten und Zahlungen",
                    anchorDocumentID: anchorDocumentID,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
                let stored = try DossierStore.insertOrFetchAnchored(
                    in: db,
                    proposed: proposed
                )
                return .opened(try self.projectionReader.snapshot(
                    in: db,
                    dossier: stored
                ))
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func snapshot(id: UUID) async throws -> DossierSnapshot {
        do {
            return try await dbWriter.read { db in
                try self.projectionReader.snapshot(in: db, dossierID: id)
            }
        } catch {
            throw mappedError(error)
        }
    }

    private nonisolated func matchingSummaries(
        in db: Database,
        documentID: UUID,
        dossiers: [DossierRecord]
    ) throws -> [DossierSummary] {
        var matches: [DossierSummary] = []
        for dossier in dossiers {
            let snapshot = try projectionReader.snapshot(in: db, dossier: dossier)
            guard snapshot.members.contains(where: { $0.id == documentID }) else {
                continue
            }
            matches.append(try projectionReader.summary(in: db, dossier: dossier))
        }
        return matches.sorted {
            if $0.dossier.createdAt != $1.dossier.createdAt {
                return $0.dossier.createdAt < $1.dossier.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private nonisolated func mappedError(_ error: any Error) -> any Error {
        if let repositoryError = error as? DossierRepositoryError {
            return repositoryError
        }
        if error is DossierStoreError
            || error is DossierProjectionError
            || error is DocumentDNARepositoryError
            || error is DocumentDNAValidationError
            || error is CurrentDocumentDNAError
            || error is DossierValidationError
            || error is InvoicePaymentDecisionRepositoryError
            || error is InvoicePaymentDecisionValidationError
        {
            return DossierRepositoryError.invalidStoredState
        }
        return error
    }
}
