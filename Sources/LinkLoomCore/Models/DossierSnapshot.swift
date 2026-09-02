import Foundation

public enum DossierMemberRole: Sendable, Equatable {
    case anchor
    case invoice
    case payment
}

public struct DossierMembershipSupportIdentity: Sendable, Equatable {
    public let decisionKey: InvoicePaymentDecisionKey
    public let decisionUpdatedAt: Date
    public let invoiceDNAAnalyzedAt: Date
    public let paymentDNAAnalyzedAt: Date
    public let resolverVersion: String
}

public struct DossierMembershipExplanation: Sendable, Equatable {
    public let role: DossierMemberRole
    public let relationshipType: DocumentRelationshipType?
    public let signals: [InvoicePaymentCandidateSignal]
}

public struct DossierMember: Identifiable, Sendable, Equatable {
    public var id: UUID { document.id }
    public let document: DocumentRecord
    public let sourceDisplayName: String
    public let documentType: DocumentType?
    public let explanation: DossierMembershipExplanation
    public let support: DossierMembershipSupportIdentity?
}

public struct DossierCorrection: Identifiable, Sendable, Equatable {
    public var id: UUID { document.id }
    public let exclusion: DossierMembershipExclusion
    public let document: DocumentRecord
    public let sourceDisplayName: String
    public let documentType: DocumentType?
}

public struct DossierProjectionToken: Sendable, Equatable {
    public let dossierUpdatedAt: Date
    public let anchorContentHash: String
    public let memberSupports: [DossierMembershipSupportIdentity]
    public let exclusionRevisionIDs: [UUID]
}

public struct DossierSnapshot: Sendable, Equatable {
    public let dossier: DossierRecord
    public let members: [DossierMember]
    public let corrections: [DossierCorrection]
    public let token: DossierProjectionToken
}

public struct DossierSummary: Identifiable, Sendable, Equatable {
    public var id: UUID { dossier.id }
    public let dossier: DossierRecord
    public let anchor: DocumentRecord
}

public enum DossierEntryDisposition: Sendable, Equatable {
    case create
    case open(DossierSummary)
    case choose([DossierSummary])
}

public enum DossierOpenResult: Sendable, Equatable {
    case opened(DossierSnapshot)
    case choose([DossierSummary])
}

public enum DossierRepositoryError: Error, Sendable, Equatable {
    case invalidAnchor
    case dossierNotFound
    case staleInput
    case invalidStoredState
}
