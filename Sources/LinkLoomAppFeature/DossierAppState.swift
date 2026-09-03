import Foundation
import LinkLoomCore

public protocol DossierLoading: Sendable {
    func summaries() async throws -> [DossierSummary]
    func entryDisposition(for documentID: UUID) async throws -> DossierEntryDisposition
    func snapshot(id: UUID) async throws -> DossierSnapshot
}

public protocol DossierMutating: Sendable {
    func createOrOpen(anchorDocumentID: UUID) async throws -> DossierOpenResult
    func excludeMember(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: DossierMembershipSupportIdentity
    ) async throws -> DossierSnapshot
    func resetExclusion(
        dossierID: UUID,
        documentID: UUID,
        expectedRevisionID: UUID
    ) async throws -> DossierSnapshot
}

public enum AppWorkspaceSelection: Hashable, Sendable {
    case source(UUID)
    case dossier(UUID)
}

public enum DossierEntryState: Sendable, Equatable {
    case none
    case loading(documentID: UUID)
    case available(documentID: UUID, disposition: DossierEntryDisposition)
    case failed(documentID: UUID)
}

public enum DossierDetailState: Sendable, Equatable {
    case none
    case loading(dossierID: UUID, previous: DossierSnapshot?)
    case available(DossierSnapshot)
    case failed(dossierID: UUID, previous: DossierSnapshot?)

    public var snapshot: DossierSnapshot? {
        switch self {
        case .none:
            nil
        case .loading(_, let previous), .failed(_, let previous):
            previous
        case .available(let snapshot):
            snapshot
        }
    }
}
