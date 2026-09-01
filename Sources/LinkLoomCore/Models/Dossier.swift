import Foundation

public enum DossierKind: String, CaseIterable, Sendable, Equatable {
    case costsAndPayments
}

public enum DossierValidationError: Error, Sendable, Equatable {
    case invalidRecord
}

public struct DossierRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: DossierKind
    public let displayName: String
    public let anchorDocumentID: UUID
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID, kind: DossierKind, displayName: String,
        anchorDocumentID: UUID, createdAt: Date, updatedAt: Date
    ) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              updatedAt >= createdAt else {
            throw DossierValidationError.invalidRecord
        }
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.anchorDocumentID = anchorDocumentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DossierMembershipExclusion: Sendable, Equatable {
    public let dossierID: UUID
    public let documentID: UUID
    public let revisionID: UUID
    public let excludedAt: Date

    public init(
        dossierID: UUID, documentID: UUID, revisionID: UUID, excludedAt: Date
    ) {
        self.dossierID = dossierID
        self.documentID = documentID
        self.revisionID = revisionID
        self.excludedAt = excludedAt
    }
}
