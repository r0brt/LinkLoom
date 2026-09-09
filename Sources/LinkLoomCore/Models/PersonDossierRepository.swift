import Foundation

public struct PersonDossierAnchorSelection: Sendable, Equatable {
    public let support: PersonDossierFindingSupportIdentity

    public init(
        document: DocumentRecord,
        snapshot: DocumentDNA,
        finding: DocumentDNAFinding
    ) throws {
        do {
            guard document.contentHash.utf8.elementsEqual(snapshot.inputContentHash.utf8) else {
                throw DossierValidationError.invalidRecord
            }
            let current = try CurrentDocumentDNA(document: document, snapshot: snapshot)
            guard let role = finding.qualifier.flatMap(PersonDossierRole.init(rawValue:)),
                  role.isPrimary
            else {
                throw DossierValidationError.invalidRecord
            }
            self.support = try PersonDossierFindingSupportIdentity(
                current: current,
                role: role,
                finding: finding
            )
        } catch {
            throw DossierValidationError.invalidRecord
        }
    }
}

extension DocumentDNAFinding {
    func isByteIdentical(to other: DocumentDNAFinding) -> Bool {
        kind == other.kind
            && qualifier.isByteIdentical(to: other.qualifier)
            && displayValue.utf8.elementsEqual(other.displayValue.utf8)
            && normalizedValue.utf8.elementsEqual(other.normalizedValue.utf8)
            && secondaryNormalizedValue.isByteIdentical(to: other.secondaryNormalizedValue)
            && confidence.bitPattern == other.confidence.bitPattern
            && evidence.count == other.evidence.count
            && zip(evidence, other.evidence).allSatisfy { lhs, rhs in
                lhs.isByteIdentical(to: rhs)
            }
    }
}

extension PersonDossierFindingSupportIdentity {
    func isByteIdentical(to other: PersonDossierFindingSupportIdentity) -> Bool {
        documentID == other.documentID
            && contentHash.utf8.elementsEqual(other.contentHash.utf8)
            && extractionVersion.utf8.elementsEqual(other.extractionVersion.utf8)
            && dnaSchemaVersion == other.dnaSchemaVersion
            && dnaAnalyzerIdentifier.utf8.elementsEqual(other.dnaAnalyzerIdentifier.utf8)
            && dnaAnalyzerVersion.utf8.elementsEqual(other.dnaAnalyzerVersion.utf8)
            && dnaAnalyzedAt == other.dnaAnalyzedAt
            && role == other.role
            && normalizedName.utf8.elementsEqual(other.normalizedName.utf8)
            && finding.isByteIdentical(to: other.finding)
    }
}

extension PersonDossierCandidateSupportIdentity {
    func isByteIdentical(to other: PersonDossierCandidateSupportIdentity) -> Bool {
        kind == other.kind
            && person.isByteIdentical(to: other.person)
            && conflict.isByteIdentical(to: other.conflict)
    }
}

extension PersonDossierMembershipSupport {
    func isByteIdentical(to other: PersonDossierMembershipSupport) -> Bool {
        switch (self, other) {
        case let (.exactPrimary(lhs), .exactPrimary(rhs)):
            lhs.isByteIdentical(to: rhs)
        case let (.manualConfirmation(lhsConfirmation, lhsCandidate),
                  .manualConfirmation(rhsConfirmation, rhsCandidate)):
            lhsConfirmation.isByteIdentical(to: rhsConfirmation)
                && lhsCandidate.isByteIdentical(to: rhsCandidate)
        case let (.confirmedPayment(lhs), .confirmedPayment(rhs)):
            lhs.isByteIdentical(to: rhs)
        default:
            false
        }
    }
}

extension PersonDossierCorrectionDecision {
    func isByteIdentical(to other: PersonDossierCorrectionDecision) -> Bool {
        switch (self, other) {
        case let (.confirmation(lhs), .confirmation(rhs)):
            lhs.isByteIdentical(to: rhs)
        case let (.exclusion(lhs), .exclusion(rhs)):
            lhs == rhs
        default:
            false
        }
    }
}

extension PersonDossierProjectionToken {
    func isByteIdentical(to other: PersonDossierProjectionToken) -> Bool {
        dossierUpdatedAt == other.dossierUpdatedAt
            && anchorUpdatedAt == other.anchorUpdatedAt
            && originValidity == other.originValidity
            && documents.count == other.documents.count
            && zip(documents, other.documents).allSatisfy { lhs, rhs in
                lhs.isByteIdentical(to: rhs)
            }
            && memberSupports.count == other.memberSupports.count
            && zip(memberSupports, other.memberSupports).allSatisfy { lhs, rhs in
                lhs.count == rhs.count
                    && zip(lhs, rhs).allSatisfy { lhsSupport, rhsSupport in
                        lhsSupport.isByteIdentical(to: rhsSupport)
                    }
            }
            && suggestionSupports.count == other.suggestionSupports.count
            && zip(suggestionSupports, other.suggestionSupports).allSatisfy { lhs, rhs in
                lhs.isByteIdentical(to: rhs)
            }
            && confirmationRevisionIDs == other.confirmationRevisionIDs
            && exclusionRevisionIDs == other.exclusionRevisionIDs
    }
}

private extension PersonDossierConflictState {
    func isByteIdentical(to other: PersonDossierConflictState) -> Bool {
        switch (self, other) {
        case (.none, .none):
            true
        case let (.hardBirthDateConflict(lhsAnchor, lhsCandidate),
                  .hardBirthDateConflict(rhsAnchor, rhsCandidate)):
            lhsAnchor.isByteIdentical(to: rhsAnchor)
                && lhsCandidate.isByteIdentical(to: rhsCandidate)
        default:
            false
        }
    }
}

private extension PersonDossierBirthDate {
    func isByteIdentical(to other: PersonDossierBirthDate) -> Bool {
        displayValue.utf8.elementsEqual(other.displayValue.utf8)
            && normalizedValue.utf8.elementsEqual(other.normalizedValue.utf8)
            && evidence.count == other.evidence.count
            && zip(evidence, other.evidence).allSatisfy { lhs, rhs in
                lhs.isByteIdentical(to: rhs)
            }
    }
}

private extension PersonDossierDocumentProjectionIdentity {
    func isByteIdentical(to other: PersonDossierDocumentProjectionIdentity) -> Bool {
        documentID == other.documentID
            && sourceRootID == other.sourceRootID
            && relativePath.utf8.elementsEqual(other.relativePath.utf8)
            && contentHash.utf8.elementsEqual(other.contentHash.utf8)
            && availability == other.availability
            && dnaAnalyzedAt == other.dnaAnalyzedAt
    }
}

private extension Optional where Wrapped == PersonDossierCandidateSupportIdentity {
    func isByteIdentical(to other: Wrapped?) -> Bool {
        switch (self, other) {
        case let (.some(lhs), .some(rhs)):
            lhs.isByteIdentical(to: rhs)
        case (.none, .none):
            true
        default:
            false
        }
    }
}

private extension DossierMembershipConfirmation {
    func isByteIdentical(to other: DossierMembershipConfirmation) -> Bool {
        dossierID == other.dossierID
            && documentID == other.documentID
            && revisionID == other.revisionID
            && confirmedAt == other.confirmedAt
            && candidateKind == other.candidateKind
            && acceptedContentHash.utf8.elementsEqual(other.acceptedContentHash.utf8)
            && acceptedExtractionVersion.utf8.elementsEqual(other.acceptedExtractionVersion.utf8)
            && acceptedDNASchemaVersion == other.acceptedDNASchemaVersion
            && acceptedDNAAnalyzerIdentifier.utf8.elementsEqual(
                other.acceptedDNAAnalyzerIdentifier.utf8
            )
            && acceptedDNAAnalyzerVersion.utf8.elementsEqual(other.acceptedDNAAnalyzerVersion.utf8)
            && acceptedDNAAnalyzedAt == other.acceptedDNAAnalyzedAt
            && acceptedRole == other.acceptedRole
            && acceptedNormalizedName.utf8.elementsEqual(other.acceptedNormalizedName.utf8)
    }
}

private extension PersonDossierPaymentSupportIdentity {
    func isByteIdentical(to other: PersonDossierPaymentSupportIdentity) -> Bool {
        invoiceDocumentID == other.invoiceDocumentID
            && invoiceMembershipBasis.isByteIdentical(to: other.invoiceMembershipBasis)
            && relationship.isByteIdentical(to: other.relationship)
            && signals.count == other.signals.count
            && zip(signals, other.signals).allSatisfy { lhs, rhs in
                lhs.kind == rhs.kind
                    && lhs.invoiceFinding.isByteIdentical(to: rhs.invoiceFinding)
                    && lhs.paymentFinding.isByteIdentical(to: rhs.paymentFinding)
            }
    }
}

private extension PersonDossierInvoiceMembershipBasis {
    func isByteIdentical(to other: PersonDossierInvoiceMembershipBasis) -> Bool {
        switch (self, other) {
        case let (.exactPerson(lhs), .exactPerson(rhs)):
            lhs.count == rhs.count
                && zip(lhs, rhs).allSatisfy { lhsSupport, rhsSupport in
                    lhsSupport.isByteIdentical(to: rhsSupport)
                }
        case let (.manualConfirmation(lhs), .manualConfirmation(rhs)):
            lhs == rhs
        default:
            false
        }
    }
}

private extension DossierMembershipSupportIdentity {
    func isByteIdentical(to other: DossierMembershipSupportIdentity) -> Bool {
        decisionKey.isByteIdentical(to: other.decisionKey)
            && decisionUpdatedAt == other.decisionUpdatedAt
            && invoiceDNAAnalyzedAt == other.invoiceDNAAnalyzedAt
            && paymentDNAAnalyzedAt == other.paymentDNAAnalyzedAt
            && resolverVersion.utf8.elementsEqual(other.resolverVersion.utf8)
    }
}

private extension InvoicePaymentDecisionKey {
    func isByteIdentical(to other: InvoicePaymentDecisionKey) -> Bool {
        relationshipType == other.relationshipType
            && invoiceDocumentID == other.invoiceDocumentID
            && paymentDocumentID == other.paymentDocumentID
            && invoiceContentHash.utf8.elementsEqual(other.invoiceContentHash.utf8)
            && paymentContentHash.utf8.elementsEqual(other.paymentContentHash.utf8)
    }
}

extension DocumentDNAEvidence {
    func isByteIdentical(to other: DocumentDNAEvidence) -> Bool {
        pageIndex == other.pageIndex
            && startUTF16 == other.startUTF16
            && lengthUTF16 == other.lengthUTF16
            && exactText.utf8.elementsEqual(other.exactText.utf8)
            && ocrRegionIndexes == other.ocrRegionIndexes
    }
}

private extension Optional where Wrapped == String {
    func isByteIdentical(to other: String?) -> Bool {
        switch (self, other) {
        case let (.some(lhs), .some(rhs)):
            lhs.utf8.elementsEqual(rhs.utf8)
        case (.none, .none):
            true
        default:
            false
        }
    }
}

public struct PersonDossierSummary: Identifiable, Sendable, Equatable {
    public var id: UUID { dossier.id }
    public let dossier: DossierRecord
    public let anchor: PersonDossierAnchor
}

public enum PersonDossierEntryDisposition: Sendable, Equatable {
    case create
    case open(PersonDossierSummary)
    case choose([PersonDossierSummary])
}

public enum PersonDossierOpenResult: Sendable, Equatable {
    case opened(PersonDossierSnapshot)
    case choose([PersonDossierSummary])
}

public enum PersonDossierCreationChoice: Sendable, Equatable {
    case existing(dossierID: UUID)
    case new
}
