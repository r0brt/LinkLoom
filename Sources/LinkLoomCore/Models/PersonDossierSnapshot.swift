import Foundation

public enum PersonDossierOriginEvidenceValidity: String, Sendable, Equatable {
    case current
    case stale
    case unavailable
}

public enum PersonDossierSection: String, Sendable, Equatable {
    case directDocuments
    case costsAndPayments
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
              snapshot.findings.contains(where: { $0.isByteIdentical(to: finding) })
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

public enum PersonDossierInvoiceMembershipBasis: Sendable, Equatable {
    case exactPerson([PersonDossierFindingSupportIdentity])
    case manualConfirmation(revisionID: UUID)
}

public struct PersonDossierPaymentSupportIdentity: Sendable, Equatable {
    public let invoiceDocumentID: UUID
    public let invoiceMembershipBasis: PersonDossierInvoiceMembershipBasis
    public let relationship: DossierMembershipSupportIdentity
    public let signals: [InvoicePaymentCandidateSignal]

    init(
        invoiceDocumentID: UUID,
        invoiceMembershipBasis: PersonDossierInvoiceMembershipBasis,
        relationship: DossierMembershipSupportIdentity,
        signals: [InvoicePaymentCandidateSignal]
    ) throws {
        if case let .exactPerson(supports) = invoiceMembershipBasis {
            guard !supports.isEmpty,
                  supports.allSatisfy({ $0.documentID == invoiceDocumentID })
            else {
                throw DossierValidationError.invalidRecord
            }
        }
        guard relationship.decisionKey.invoiceDocumentID == invoiceDocumentID,
              !signals.isEmpty else {
            throw DossierValidationError.invalidRecord
        }
        self.invoiceDocumentID = invoiceDocumentID
        self.invoiceMembershipBasis = invoiceMembershipBasis
        self.relationship = relationship
        self.signals = signals
    }
}

public enum PersonDossierMembershipSupport: Sendable, Equatable {
    case exactPrimary(PersonDossierFindingSupportIdentity)
    case manualConfirmation(
        confirmation: DossierMembershipConfirmation,
        currentCandidate: PersonDossierCandidateSupportIdentity?
    )
    case confirmedPayment(PersonDossierPaymentSupportIdentity)
}

public struct PersonDossierMember: Identifiable, Sendable, Equatable {
    public var id: UUID { document.id }
    public let document: DocumentRecord
    public let sourceDisplayName: String
    public let documentType: DocumentType?
    public let section: PersonDossierSection
    public let supports: [PersonDossierMembershipSupport]
    public let isConfirmationAuthoritative: Bool
    public let preferredPaymentSupport: PersonDossierPaymentSupportIdentity?

    public var commandSupport: PersonDossierMembershipSupport {
        get throws {
            if isConfirmationAuthoritative {
                guard let confirmation = supports.first(where: { support in
                    if case .manualConfirmation = support { return true }
                    return false
                }) else {
                    throw DossierValidationError.invalidRecord
                }
                return confirmation
            }
            if let exactPrimary = supports.first(where: { support in
                if case .exactPrimary = support { return true }
                return false
            }) {
                return exactPrimary
            }
            if let preferredPaymentSupport {
                return .confirmedPayment(preferredPaymentSupport)
            }
            throw DossierValidationError.invalidRecord
        }
    }

    init(
        document: DocumentRecord,
        sourceDisplayName: String,
        documentType: DocumentType?,
        section: PersonDossierSection,
        supports: [PersonDossierMembershipSupport],
        isConfirmationAuthoritative: Bool,
        preferredPaymentSupport: PersonDossierPaymentSupportIdentity?
    ) throws {
        let hasConfirmation = supports.contains { support in
            guard case let .manualConfirmation(confirmation, candidate) = support else {
                return false
            }
            return confirmation.documentID == document.id
                && (candidate.map { $0.person.documentID == document.id } ?? true)
        }
        let paymentSupports: [PersonDossierPaymentSupportIdentity] = supports.compactMap { support in
            guard case let .confirmedPayment(payment) = support else { return nil }
            return payment
        }
        guard !sourceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !supports.isEmpty,
              supports.allSatisfy({ $0.documentID == document.id }),
              hasConfirmation == isConfirmationAuthoritative,
              (preferredPaymentSupport.map { paymentSupports.contains($0) } ?? true)
        else {
            throw DossierValidationError.invalidRecord
        }
        self.document = document
        self.sourceDisplayName = sourceDisplayName
        self.documentType = documentType
        self.section = section
        self.supports = supports
        self.isConfirmationAuthoritative = isConfirmationAuthoritative
        self.preferredPaymentSupport = preferredPaymentSupport
    }
}

public struct PersonDossierSuggestion: Identifiable, Sendable, Equatable {
    public var id: UUID { document.id }
    public let document: DocumentRecord
    public let sourceDisplayName: String
    public let documentType: DocumentType?
    public let section: PersonDossierSection
    public let kind: PersonDossierCandidateKind
    public let conflict: PersonDossierConflictState
    public let currentSupports: [PersonDossierCandidateSupportIdentity]
    public let commandSupport: PersonDossierCandidateSupportIdentity

    init(
        document: DocumentRecord,
        sourceDisplayName: String,
        documentType: DocumentType?,
        section: PersonDossierSection,
        kind: PersonDossierCandidateKind,
        conflict: PersonDossierConflictState,
        currentSupports: [PersonDossierCandidateSupportIdentity],
        commandSupport: PersonDossierCandidateSupportIdentity
    ) throws {
        guard !sourceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !currentSupports.isEmpty,
              currentSupports.contains(commandSupport),
              currentSupports.allSatisfy({
                  $0.kind == kind
                      && $0.conflict == conflict
                      && $0.person.documentID == document.id
              }) else {
            throw DossierValidationError.invalidRecord
        }
        self.document = document
        self.sourceDisplayName = sourceDisplayName
        self.documentType = documentType
        self.section = section
        self.kind = kind
        self.conflict = conflict
        self.currentSupports = currentSupports
        self.commandSupport = commandSupport
    }
}

public enum PersonDossierCorrectionDecision: Sendable, Equatable {
    case confirmation(DossierMembershipConfirmation)
    case exclusion(DossierMembershipExclusion)
}

public struct PersonDossierCorrection: Identifiable, Sendable, Equatable {
    public var id: UUID { document.id }
    public let document: DocumentRecord
    public let sourceDisplayName: String
    public let documentType: DocumentType?
    public let decision: PersonDossierCorrectionDecision

    init(
        document: DocumentRecord,
        sourceDisplayName: String,
        documentType: DocumentType?,
        decision: PersonDossierCorrectionDecision
    ) throws {
        let decisionDocumentID = switch decision {
        case let .confirmation(value): value.documentID
        case let .exclusion(value): value.documentID
        }
        guard decisionDocumentID == document.id,
              !sourceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DossierValidationError.invalidRecord
        }
        self.document = document
        self.sourceDisplayName = sourceDisplayName
        self.documentType = documentType
        self.decision = decision
    }
}

public struct PersonDossierDocumentProjectionIdentity: Sendable, Equatable {
    public let documentID: UUID
    public let sourceRootID: UUID
    public let relativePath: String
    public let contentHash: String
    public let availability: DocumentAvailability
    public let dnaAnalyzedAt: Date?

    init(document: DocumentRecord, dnaAnalyzedAt: Date?) {
        self.documentID = document.id
        self.sourceRootID = document.sourceRootID
        self.relativePath = document.relativePath
        self.contentHash = document.contentHash
        self.availability = document.availability
        self.dnaAnalyzedAt = dnaAnalyzedAt
    }
}

public struct PersonDossierProjectionToken: Sendable, Equatable {
    public let dossierUpdatedAt: Date
    public let anchorUpdatedAt: Date
    public let originValidity: PersonDossierOriginEvidenceValidity
    public let documents: [PersonDossierDocumentProjectionIdentity]
    public let memberSupports: [[PersonDossierMembershipSupport]]
    public let suggestionSupports: [PersonDossierCandidateSupportIdentity]
    public let confirmationRevisionIDs: [UUID]
    public let exclusionRevisionIDs: [UUID]
}

public struct PersonDossierSnapshot: Sendable, Equatable {
    public let dossier: DossierRecord
    public let anchor: PersonDossierAnchor
    public let origin: PersonDossierOriginState
    public let directMembers: [PersonDossierMember]
    public let costsAndPayments: [PersonDossierMember]
    public let suggestions: [PersonDossierSuggestion]
    public let corrections: [PersonDossierCorrection]
    public let token: PersonDossierProjectionToken
}

private extension PersonDossierMembershipSupport {
    var documentID: UUID {
        switch self {
        case let .exactPrimary(value): value.documentID
        case let .manualConfirmation(confirmation, _): confirmation.documentID
        case let .confirmedPayment(value): value.relationship.decisionKey.paymentDocumentID
        }
    }
}
