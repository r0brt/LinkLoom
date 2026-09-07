import Foundation

public enum DossierKind: String, CaseIterable, Sendable, Equatable {
    case costsAndPayments
    case personMatter
}

public enum DossierValidationError: Error, Sendable, Equatable {
    case invalidRecord
}

public enum DossierAnchor: Sendable, Equatable {
    case document(UUID)
    case person(PersonDossierAnchor)
}

public struct DossierRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: DossierKind
    public let displayName: String
    public let anchor: DossierAnchor
    public let createdAt: Date
    public let updatedAt: Date

    public var documentAnchorID: UUID? {
        guard case let .document(id) = anchor else { return nil }
        return id
    }

    public var personAnchor: PersonDossierAnchor? {
        guard case let .person(anchor) = anchor else { return nil }
        return anchor
    }

    public init(
        id: UUID, kind: DossierKind, displayName: String,
        anchor: DossierAnchor, createdAt: Date, updatedAt: Date
    ) throws {
        let validAnchor = switch (kind, anchor) {
        case (.costsAndPayments, .document(_)),
             (.personMatter, .person(_)):
            true
        default: false
        }
        guard validAnchor,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              updatedAt >= createdAt else {
            throw DossierValidationError.invalidRecord
        }
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.anchor = anchor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(
        id: UUID, kind: DossierKind, displayName: String,
        anchorDocumentID: UUID, createdAt: Date, updatedAt: Date
    ) throws {
        try self.init(
            id: id,
            kind: kind,
            displayName: displayName,
            anchor: .document(anchorDocumentID),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
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
