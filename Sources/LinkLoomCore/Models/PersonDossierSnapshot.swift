import Foundation

public enum PersonDossierOriginEvidenceValidity: String, Sendable, Equatable {
    case current
    case stale
    case unavailable
}

public struct PersonDossierOriginState: Sendable, Equatable {
    public let validity: PersonDossierOriginEvidenceValidity
    public let document: DocumentRecord?
    public let sourceDisplayName: String?

    init(
        validity: PersonDossierOriginEvidenceValidity,
        document: DocumentRecord?,
        sourceDisplayName: String?
    ) throws {
        let hasCurrentDocument = document != nil
        let hasSourceName = sourceDisplayName.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        guard (validity == .unavailable && !hasCurrentDocument && sourceDisplayName == nil)
                || (validity != .unavailable && hasCurrentDocument && hasSourceName)
        else {
            throw DossierValidationError.invalidRecord
        }
        self.validity = validity
        self.document = document
        self.sourceDisplayName = sourceDisplayName
    }
}

public struct PersonDossierFindingSupportIdentity: Sendable, Equatable {
    public let documentID: UUID
    public let contentHash: String
    public let extractionVersion: String
    public let dnaSchemaVersion: Int
    public let dnaAnalyzerIdentifier: String
    public let dnaAnalyzerVersion: String
    public let dnaAnalyzedAt: Date
    public let role: PersonDossierRole
    public let normalizedName: String
    public let finding: DocumentDNAFinding

    init(
        current: CurrentDocumentDNA,
        role: PersonDossierRole,
        finding: DocumentDNAFinding
    ) throws {
        let snapshot = current.snapshot
        guard finding.kind == .person,
              finding.qualifier == role.rawValue,
              !finding.normalizedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !finding.evidence.isEmpty,
              snapshot.findings.contains(finding)
        else {
            throw DossierValidationError.invalidRecord
        }
        self.documentID = current.document.id
        self.contentHash = snapshot.inputContentHash
        self.extractionVersion = snapshot.inputExtractionVersion
        self.dnaSchemaVersion = snapshot.schemaVersion
        self.dnaAnalyzerIdentifier = snapshot.analyzerIdentifier
        self.dnaAnalyzerVersion = snapshot.analyzerVersion
        self.dnaAnalyzedAt = snapshot.analyzedAt
        self.role = role
        self.normalizedName = finding.normalizedValue
        self.finding = finding
    }
}

public enum PersonDossierConflictState: Sendable, Equatable {
    case none
    case hardBirthDateConflict(
        anchor: PersonDossierBirthDate,
        candidate: DocumentDNAFinding
    )
}

public struct PersonDossierCandidateSupportIdentity: Sendable, Equatable {
    public let kind: PersonDossierCandidateKind
    public let person: PersonDossierFindingSupportIdentity
    public let conflict: PersonDossierConflictState

    init(
        kind: PersonDossierCandidateKind,
        person: PersonDossierFindingSupportIdentity,
        conflict: PersonDossierConflictState
    ) throws {
        let isValid = switch (kind, person.role, conflict) {
        case (.secondaryRole, .authorizedPerson, .none):
            true
        case (.birthDateConflict, let role, .hardBirthDateConflict(_, _)) where role.isPrimary:
            true
        default:
            false
        }
        guard isValid else {
            throw DossierValidationError.invalidRecord
        }
        self.kind = kind
        self.person = person
        self.conflict = conflict
    }
}
