import Foundation

public enum PersonDossierRole: String, CaseIterable, Sendable, Equatable {
    case resident
    case insuredPerson
    case accountHolder
    case invoiceRecipient
    case grantor
    case authorizedPerson

    public var isPrimary: Bool {
        self != .authorizedPerson
    }
}

public enum PersonDossierCandidateKind: String, CaseIterable, Sendable, Equatable {
    case secondaryRole
    case birthDateConflict
}

public struct PersonDossierBirthDate: Sendable, Equatable {
    public let displayValue: String
    public let normalizedValue: String
    public let evidence: [DocumentDNAEvidence]

    public init(
        displayValue: String,
        normalizedValue: String,
        evidence: [DocumentDNAEvidence]
    ) throws {
        guard !evidence.isEmpty else {
            throw DossierValidationError.invalidRecord
        }
        do {
            _ = try DocumentDNAFinding(
                kind: .date,
                qualifier: DocumentDNADateRole.birthDate.rawValue,
                displayValue: displayValue,
                normalizedValue: normalizedValue,
                secondaryNormalizedValue: nil,
                confidence: 1,
                evidence: evidence
            )
        } catch {
            throw DossierValidationError.invalidRecord
        }
        self.displayValue = displayValue
        self.normalizedValue = normalizedValue
        self.evidence = evidence
    }
}

public struct PersonDossierAnchor: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let normalizedName: String
    public let primaryRole: PersonDossierRole
    public let originDocumentID: UUID
    public let originContentHash: String
    public let originExtractionVersion: String
    public let originDNASchemaVersion: Int
    public let originDNAAnalyzerIdentifier: String
    public let originDNAAnalyzerVersion: String
    public let originDNAAnalyzedAt: Date
    public let personEvidence: [DocumentDNAEvidence]
    public let birthDate: PersonDossierBirthDate?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        displayName: String,
        normalizedName: String,
        primaryRole: PersonDossierRole,
        originDocumentID: UUID,
        originContentHash: String,
        originExtractionVersion: String,
        originDNASchemaVersion: Int,
        originDNAAnalyzerIdentifier: String,
        originDNAAnalyzerVersion: String,
        originDNAAnalyzedAt: Date,
        personEvidence: [DocumentDNAEvidence],
        birthDate: PersonDossierBirthDate?,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let nonBlank = [
            displayName, normalizedName, originContentHash,
            originExtractionVersion, originDNAAnalyzerIdentifier,
            originDNAAnalyzerVersion,
        ].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard nonBlank,
              primaryRole.isPrimary,
              originDNASchemaVersion > 0,
              !personEvidence.isEmpty,
              updatedAt >= createdAt else {
            throw DossierValidationError.invalidRecord
        }
        self.id = id
        self.displayName = displayName
        self.normalizedName = normalizedName
        self.primaryRole = primaryRole
        self.originDocumentID = originDocumentID
        self.originContentHash = originContentHash
        self.originExtractionVersion = originExtractionVersion
        self.originDNASchemaVersion = originDNASchemaVersion
        self.originDNAAnalyzerIdentifier = originDNAAnalyzerIdentifier
        self.originDNAAnalyzerVersion = originDNAAnalyzerVersion
        self.originDNAAnalyzedAt = originDNAAnalyzedAt
        self.personEvidence = personEvidence
        self.birthDate = birthDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DossierMembershipConfirmation: Sendable, Equatable {
    public let dossierID: UUID
    public let documentID: UUID
    public let revisionID: UUID
    public let confirmedAt: Date
    public let candidateKind: PersonDossierCandidateKind
    public let acceptedContentHash: String
    public let acceptedExtractionVersion: String
    public let acceptedDNASchemaVersion: Int
    public let acceptedDNAAnalyzerIdentifier: String
    public let acceptedDNAAnalyzerVersion: String
    public let acceptedDNAAnalyzedAt: Date
    public let acceptedRole: PersonDossierRole
    public let acceptedNormalizedName: String

    public init(
        dossierID: UUID,
        documentID: UUID,
        revisionID: UUID,
        confirmedAt: Date,
        candidateKind: PersonDossierCandidateKind,
        acceptedContentHash: String,
        acceptedExtractionVersion: String,
        acceptedDNASchemaVersion: Int,
        acceptedDNAAnalyzerIdentifier: String,
        acceptedDNAAnalyzerVersion: String,
        acceptedDNAAnalyzedAt: Date,
        acceptedRole: PersonDossierRole,
        acceptedNormalizedName: String
    ) throws {
        let nonBlank = [
            acceptedContentHash, acceptedExtractionVersion,
            acceptedDNAAnalyzerIdentifier, acceptedDNAAnalyzerVersion,
            acceptedNormalizedName,
        ].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let roleMatchesKind = candidateKind == .secondaryRole
            ? acceptedRole == .authorizedPerson
            : acceptedRole.isPrimary
        guard nonBlank, acceptedDNASchemaVersion > 0, roleMatchesKind else {
            throw DossierValidationError.invalidRecord
        }
        self.dossierID = dossierID
        self.documentID = documentID
        self.revisionID = revisionID
        self.confirmedAt = confirmedAt
        self.candidateKind = candidateKind
        self.acceptedContentHash = acceptedContentHash
        self.acceptedExtractionVersion = acceptedExtractionVersion
        self.acceptedDNASchemaVersion = acceptedDNASchemaVersion
        self.acceptedDNAAnalyzerIdentifier = acceptedDNAAnalyzerIdentifier
        self.acceptedDNAAnalyzerVersion = acceptedDNAAnalyzerVersion
        self.acceptedDNAAnalyzedAt = acceptedDNAAnalyzedAt
        self.acceptedRole = acceptedRole
        self.acceptedNormalizedName = acceptedNormalizedName
    }
}
