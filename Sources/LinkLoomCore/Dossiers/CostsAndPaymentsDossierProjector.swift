import Foundation

enum DossierProjectionError: Error, Sendable, Equatable {
    case invalidStoredState
}

struct CostsAndPaymentsDossierProjectionInput: Sendable {
    let dossier: DossierRecord
    let anchor: DocumentRecord?
    let documentsByID: [UUID: DocumentRecord]
    let currentDocumentsByID: [UUID: CurrentDocumentDNA]
    let candidates: [InvoicePaymentCandidate]
    let decisionsByKey: [InvoicePaymentDecisionKey: InvoicePaymentDecisionRecord]
    let sourceDisplayNames: [UUID: String]
    let exclusions: [DossierMembershipExclusion]
}

struct CostsAndPaymentsDossierProjector: Sendable {
    func project(_ input: CostsAndPaymentsDossierProjectionInput) throws -> DossierSnapshot {
        guard let anchor = input.anchor,
              anchor.id == input.dossier.anchorDocumentID
        else {
            throw DossierProjectionError.invalidStoredState
        }

        let excludedDocumentIDs = Set(input.exclusions.map(\.documentID))
        let anchorMember = member(
            document: anchor,
            currentDocument: input.currentDocumentsByID[anchor.id],
            sourceDisplayNames: input.sourceDisplayNames,
            explanation: DossierMembershipExplanation(
                role: .anchor,
                relationshipType: nil,
                signals: []
            ),
            support: nil
        )
        let inferredMembers = deduplicatedAndSortedMembers(
            candidates: input.candidates,
            anchorID: anchor.id,
            decisionsByKey: input.decisionsByKey,
            excludedDocumentIDs: excludedDocumentIDs,
            sourceDisplayNames: input.sourceDisplayNames
        )
        let corrections = try sortedCorrections(
            exclusions: input.exclusions,
            documentsByID: input.documentsByID,
            currentDocumentsByID: input.currentDocumentsByID,
            sourceDisplayNames: input.sourceDisplayNames
        )
        return DossierSnapshot(
            dossier: input.dossier,
            members: [anchorMember] + inferredMembers,
            corrections: corrections,
            token: DossierProjectionToken(
                dossierUpdatedAt: input.dossier.updatedAt,
                anchorContentHash: anchor.contentHash,
                memberSupports: inferredMembers.compactMap(\.support),
                exclusionRevisionIDs: corrections.map(\.exclusion.revisionID)
            )
        )
    }

    private func deduplicatedAndSortedMembers(
        candidates: [InvoicePaymentCandidate],
        anchorID: UUID,
        decisionsByKey: [InvoicePaymentDecisionKey: InvoicePaymentDecisionRecord],
        excludedDocumentIDs: Set<UUID>,
        sourceDisplayNames: [UUID: String]
    ) -> [DossierMember] {
        var membersByDocumentID: [UUID: DossierMember] = [:]
        for candidate in candidates {
            guard let counterpart = candidate.counterpart(to: anchorID),
                  let key = try? InvoicePaymentDecisionKey(candidate: candidate),
                  let decision = decisionsByKey[key],
                  decision.decision == .confirmed,
                  !excludedDocumentIDs.contains(counterpart.document.id)
            else {
                continue
            }
            let member = member(
                document: counterpart.document,
                currentDocument: counterpart,
                sourceDisplayNames: sourceDisplayNames,
                explanation: DossierMembershipExplanation(
                    role: counterpart.document.id == candidate.invoice.document.id
                        ? .invoice : .payment,
                    relationshipType: key.relationshipType,
                    signals: candidate.signals
                ),
                support: DossierMembershipSupportIdentity(
                    decisionKey: key,
                    decisionUpdatedAt: decision.updatedAt,
                    invoiceDNAAnalyzedAt: candidate.invoice.snapshot.analyzedAt,
                    paymentDNAAnalyzedAt: candidate.payment.snapshot.analyzedAt,
                    resolverVersion: candidate.resolverVersion
                )
            )
            membersByDocumentID[member.document.id] = member
        }
        return membersByDocumentID.values.sorted(by: memberOrder)
    }

    private func sortedCorrections(
        exclusions: [DossierMembershipExclusion],
        documentsByID: [UUID: DocumentRecord],
        currentDocumentsByID: [UUID: CurrentDocumentDNA],
        sourceDisplayNames: [UUID: String]
    ) throws -> [DossierCorrection] {
        let corrections = try exclusions.map { exclusion in
            guard let document = documentsByID[exclusion.documentID] else {
                throw DossierProjectionError.invalidStoredState
            }
            return DossierCorrection(
                exclusion: exclusion,
                document: document,
                sourceDisplayName: sourceDisplayNames[document.sourceRootID]
                    ?? document.sourceRootID.uuidString,
                documentType: currentDocumentsByID[document.id]?.documentType
            )
        }
        return corrections.sorted {
            presentationOrder(
                sourceDisplayName: $0.sourceDisplayName,
                document: $0.document
            ) < presentationOrder(
                sourceDisplayName: $1.sourceDisplayName,
                document: $1.document
            )
        }
    }

    private func member(
        document: DocumentRecord,
        currentDocument: CurrentDocumentDNA?,
        sourceDisplayNames: [UUID: String],
        explanation: DossierMembershipExplanation,
        support: DossierMembershipSupportIdentity?
    ) -> DossierMember {
        DossierMember(
            document: document,
            sourceDisplayName: sourceDisplayNames[document.sourceRootID]
                ?? document.sourceRootID.uuidString,
            documentType: currentDocument?.documentType,
            explanation: explanation,
            support: support
        )
    }

    private func memberOrder(_ lhs: DossierMember, _ rhs: DossierMember) -> Bool {
        presentationOrder(
            sourceDisplayName: lhs.sourceDisplayName,
            document: lhs.document
        ) < presentationOrder(
            sourceDisplayName: rhs.sourceDisplayName,
            document: rhs.document
        )
    }

    private func presentationOrder(
        sourceDisplayName: String,
        document: DocumentRecord
    ) -> (String, String, String) {
        (sourceDisplayName, document.relativePath, document.id.uuidString)
    }
}

extension InvoicePaymentDecisionKey {
    init(candidate: InvoicePaymentCandidate) throws {
        try self.init(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: candidate.invoice.document.id,
            paymentDocumentID: candidate.payment.document.id,
            invoiceContentHash: candidate.invoice.document.contentHash,
            paymentContentHash: candidate.payment.document.contentHash
        )
    }
}

extension InvoicePaymentCandidate {
    func counterpart(to documentID: UUID) -> CurrentDocumentDNA? {
        if invoice.document.id == documentID {
            return payment
        }
        if payment.document.id == documentID {
            return invoice
        }
        return nil
    }
}

extension CurrentDocumentDNA {
    var documentType: DocumentType? {
        snapshot.findings.first { $0.kind == .documentType }.flatMap {
            DocumentType(rawValue: $0.normalizedValue)
        }
    }
}
