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

public protocol PersonDossierLoading: Sendable {
    func personDossierSummaries() async throws -> [PersonDossierSummary]
    func personDossierSnapshot(id: UUID) async throws -> PersonDossierSnapshot
}

public protocol PersonDossierMutating: Sendable {
    func createOrOpenPersonDossier(
        from selection: PersonDossierAnchorSelection
    ) async throws -> PersonDossierOpenResult

    func chooseOrCreatePersonDossier(
        from selection: PersonDossierAnchorSelection,
        choice: PersonDossierCreationChoice
    ) async throws -> PersonDossierSnapshot

    func acceptPersonSuggestion(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: PersonDossierCandidateSupportIdentity,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot

    func rejectPersonSuggestion(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: PersonDossierCandidateSupportIdentity,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot

    func removePersonMember(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: PersonDossierMembershipSupport,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot

    func resetPersonCorrection(
        dossierID: UUID,
        documentID: UUID,
        expectedDecision: PersonDossierCorrectionDecision,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot
}

public enum DossierWorkspaceProjectionIdentity: Sendable, Equatable {
    case costsAndPayments(DossierProjectionToken)
    case personMatter(PersonDossierProjectionToken)
}

public enum DossierWorkspaceSnapshot: Sendable, Equatable {
    case costsAndPayments(DossierSnapshot)
    case personMatter(PersonDossierSnapshot)

    public var dossier: DossierRecord {
        switch self {
        case .costsAndPayments(let snapshot): snapshot.dossier
        case .personMatter(let snapshot): snapshot.dossier
        }
    }

    public var projectionIdentity: DossierWorkspaceProjectionIdentity {
        switch self {
        case .costsAndPayments(let snapshot): .costsAndPayments(snapshot.token)
        case .personMatter(let snapshot): .personMatter(snapshot.token)
        }
    }

    public var costsAndPayments: DossierSnapshot? {
        guard case .costsAndPayments(let snapshot) = self else { return nil }
        return snapshot
    }

    public var personMatter: PersonDossierSnapshot? {
        guard case .personMatter(let snapshot) = self else { return nil }
        return snapshot
    }
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
    case loading(dossierID: UUID, previous: DossierWorkspaceSnapshot?)
    case available(DossierWorkspaceSnapshot)
    case failed(dossierID: UUID, previous: DossierWorkspaceSnapshot?)

    public var workspaceSnapshot: DossierWorkspaceSnapshot? {
        switch self {
        case .none:
            nil
        case .loading(_, let previous), .failed(_, let previous):
            previous
        case .available(let snapshot):
            snapshot
        }
    }

    public var snapshot: DossierSnapshot? {
        workspaceSnapshot?.costsAndPayments
    }

    public var personSnapshot: PersonDossierSnapshot? {
        workspaceSnapshot?.personMatter
    }
}

public enum DossierMutationState: Sendable, Equatable {
    case idle
    case opening(documentID: UUID)
    case openingPerson(documentID: UUID)
    case excluding(dossierID: UUID, documentID: UUID)
    case resetting(dossierID: UUID, documentID: UUID)
}
