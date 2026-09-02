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
        guard input.exclusions.allSatisfy({ exclusion in
            exclusion.dossierID == input.dossier.id && exclusion.documentID != anchor.id
        }) else {
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
        let inferredMembers = try deduplicatedAndSortedMembers(
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
    ) throws -> [DossierMember] {
        var candidatesByDocumentID: [UUID: InvoicePaymentCandidate] = [:]
        for candidate in candidates {
            guard let counterpart = candidate.counterpart(to: anchorID),
                  let key = try? InvoicePaymentDecisionKey(candidate: candidate),
                  let decision = decisionsByKey[key],
                  decision.decision == .confirmed,
                  !excludedDocumentIDs.contains(counterpart.document.id)
            else {
                continue
            }
            if let existing = candidatesByDocumentID[counterpart.document.id],
               !isPreferred(candidate, over: existing) {
                continue
            }
            candidatesByDocumentID[counterpart.document.id] = candidate
        }
        return try candidatesByDocumentID.values.map { candidate in
            guard let counterpart = candidate.counterpart(to: anchorID),
                  let key = try? InvoicePaymentDecisionKey(candidate: candidate),
                  let decision = decisionsByKey[key]
            else {
                throw DossierProjectionError.invalidStoredState
            }
            return member(
                document: counterpart.document,
                currentDocument: counterpart,
                sourceDisplayNames: sourceDisplayNames,
                explanation: DossierMembershipExplanation(
                    role: counterpart.document.id == candidate.invoice.document.id
                        ? .invoice : .payment,
                    relationshipType: key.relationshipType,
                    signals: DossierCandidateTieBreakKey.canonicalSignals(candidate.signals)
                ),
                support: DossierMembershipSupportIdentity(
                    decisionKey: key,
                    decisionUpdatedAt: decision.updatedAt,
                    invoiceDNAAnalyzedAt: candidate.invoice.snapshot.analyzedAt,
                    paymentDNAAnalyzedAt: candidate.payment.snapshot.analyzedAt,
                    resolverVersion: candidate.resolverVersion
                )
            )
        }.sorted(by: memberOrder)
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

    private func isPreferred(
        _ candidate: InvoicePaymentCandidate,
        over existing: InvoicePaymentCandidate
    ) -> Bool {
        let candidateStrength = InvoicePaymentCandidateStrength(candidate)
        let existingStrength = InvoicePaymentCandidateStrength(existing)
        guard candidateStrength == existingStrength else {
            return candidateStrength > existingStrength
        }
        return DossierCandidateTieBreakKey(candidate)
            < DossierCandidateTieBreakKey(existing)
    }
}

private struct DossierCandidateTieBreakKey: Comparable {
    let resolverVersion: String
    let invoiceAnalyzedAt: UInt64
    let paymentAnalyzedAt: UInt64
    let invoiceDocumentType: String
    let paymentDocumentType: String
    let signals: [String]

    init(_ candidate: InvoicePaymentCandidate) {
        resolverVersion = candidate.resolverVersion
        invoiceAnalyzedAt = candidate.invoice.snapshot.analyzedAt
            .timeIntervalSinceReferenceDate.bitPattern
        paymentAnalyzedAt = candidate.payment.snapshot.analyzedAt
            .timeIntervalSinceReferenceDate.bitPattern
        invoiceDocumentType = candidate.invoice.documentType?.rawValue ?? ""
        paymentDocumentType = candidate.payment.documentType?.rawValue ?? ""
        signals = candidate.signals.map(Self.signalKey).sorted()
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.resolverVersion != rhs.resolverVersion {
            return lhs.resolverVersion < rhs.resolverVersion
        }
        if lhs.invoiceAnalyzedAt != rhs.invoiceAnalyzedAt {
            return lhs.invoiceAnalyzedAt < rhs.invoiceAnalyzedAt
        }
        if lhs.paymentAnalyzedAt != rhs.paymentAnalyzedAt {
            return lhs.paymentAnalyzedAt < rhs.paymentAnalyzedAt
        }
        if lhs.invoiceDocumentType != rhs.invoiceDocumentType {
            return lhs.invoiceDocumentType < rhs.invoiceDocumentType
        }
        if lhs.paymentDocumentType != rhs.paymentDocumentType {
            return lhs.paymentDocumentType < rhs.paymentDocumentType
        }
        return lhs.signals.lexicographicallyPrecedes(rhs.signals)
    }

    static func canonicalSignals(
        _ signals: [InvoicePaymentCandidateSignal]
    ) -> [InvoicePaymentCandidateSignal] {
        signals.sorted { lhs, rhs in
            let lhsKindOrder = signalKindOrder(lhs.kind)
            let rhsKindOrder = signalKindOrder(rhs.kind)
            if lhsKindOrder != rhsKindOrder {
                return lhsKindOrder < rhsKindOrder
            }
            return signalKey(lhs) < signalKey(rhs)
        }
    }

    private static func signalKey(_ signal: InvoicePaymentCandidateSignal) -> String {
        component(signal.kind.rawValue)
            + findingKey(signal.invoiceFinding)
            + findingKey(signal.paymentFinding)
    }

    private static func signalKindOrder(_ kind: InvoicePaymentCandidateSignalKind) -> Int {
        switch kind {
        case .referenceNumber: 0
        case .monetaryAmount: 1
        case .organization: 2
        }
    }

    private static func findingKey(_ finding: DocumentDNAFinding) -> String {
        component(finding.kind.rawValue)
            + component(finding.qualifier)
            + component(finding.displayValue)
            + component(finding.normalizedValue)
            + component(finding.secondaryNormalizedValue)
            + component(String(finding.confidence.bitPattern))
            + finding.evidence.map(evidenceKey).joined()
    }

    private static func evidenceKey(_ evidence: DocumentDNAEvidence) -> String {
        component(String(evidence.pageIndex))
            + component(String(evidence.startUTF16))
            + component(String(evidence.lengthUTF16))
            + component(evidence.exactText)
            + component(evidence.ocrRegionIndexes.map(String.init).joined(separator: ","))
    }

    private static func component(_ value: String?) -> String {
        guard let value else { return "-" }
        return "\(value.utf8.count):\(value)"
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
