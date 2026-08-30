import Foundation

/// Resolves the current invoice/payment candidates involving one selected document.
public struct InvoicePaymentCandidateLookup: Sendable {
    private let repository: DocumentDNARepository
    private let target: DocumentDNAAnalysisTarget
    private let resolver: InvoicePaymentCandidateResolver

    public init(
        repository: DocumentDNARepository,
        target: DocumentDNAAnalysisTarget,
        resolver: InvoicePaymentCandidateResolver = InvoicePaymentCandidateResolver()
    ) {
        self.repository = repository
        self.target = target
        self.resolver = resolver
    }

    public func candidates(involving documentID: UUID) async throws
        -> [InvoicePaymentCandidate]
    {
        guard let snapshot = try await repository.currentSnapshot(
            documentID: documentID,
            target: target
        ),
        let referenceQualifier = referenceQualifier(for: snapshot)
        else {
            return []
        }
        let normalizedReferences = Set(snapshot.findings.compactMap { finding in
            finding.kind == .referenceNumber
                && finding.qualifier == referenceQualifier.rawValue
                ? finding.normalizedValue
                : nil
        }).sorted()
        var candidatesByPair: [CandidatePair: InvoicePaymentCandidate] = [:]
        for normalizedReference in normalizedReferences {
            let documents = try await repository.currentSnapshotsMatchingReference(
                normalizedReference,
                target: target
            )
            for candidate in resolver.candidates(
                matching: normalizedReference,
                in: documents
            ) where candidate.invoice.document.id == documentID
                || candidate.payment.document.id == documentID
            {
                let pair = CandidatePair(candidate)
                if let existing = candidatesByPair[pair],
                   candidateStrength(existing) >= candidateStrength(candidate) {
                    continue
                }
                candidatesByPair[pair] = candidate
            }
        }
        let candidates = Array(candidatesByPair.values)
        let automaticCandidates = candidates.filter { $0.disposition == .automatic }
        let invoiceCounts = Dictionary(
            grouping: automaticCandidates,
            by: { $0.invoice.document.id }
        ).mapValues(\.count)
        let paymentCounts = Dictionary(
            grouping: automaticCandidates,
            by: { $0.payment.document.id }
        ).mapValues(\.count)
        return candidates.map { candidate in
            guard candidate.disposition == .automatic,
                  invoiceCounts[candidate.invoice.document.id, default: 0] > 1
                    || paymentCounts[candidate.payment.document.id, default: 0] > 1
            else {
                return candidate
            }
            return InvoicePaymentCandidate(
                invoice: candidate.invoice,
                payment: candidate.payment,
                disposition: .suggestion,
                resolverVersion: candidate.resolverVersion,
                signals: candidate.signals
            )
        }.sorted(by: candidateOrder)
    }

    private func referenceQualifier(
        for snapshot: DocumentDNA
    ) -> DocumentDNAReferenceNumberKind? {
        let type = snapshot.findings.first {
            $0.kind == .documentType
        }.flatMap { DocumentType(rawValue: $0.normalizedValue) }
        switch type {
        case .invoice:
            return .invoiceNumber
        case .paymentConfirmation:
            return .paymentReference
        default:
            return nil
        }
    }

    private func candidateStrength(
        _ candidate: InvoicePaymentCandidate
    ) -> (Int, Int) {
        (candidate.disposition == .automatic ? 1 : 0, candidate.signals.count)
    }

    private func candidateOrder(
        _ lhs: InvoicePaymentCandidate,
        _ rhs: InvoicePaymentCandidate
    ) -> Bool {
        CandidatePair(lhs).sortKey < CandidatePair(rhs).sortKey
    }
}

private struct CandidatePair: Hashable {
    let invoiceID: UUID
    let paymentID: UUID
    let sortKey: CandidateSortKey

    init(_ candidate: InvoicePaymentCandidate) {
        invoiceID = candidate.invoice.document.id
        paymentID = candidate.payment.document.id
        sortKey = CandidateSortKey(candidate)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.invoiceID == rhs.invoiceID && lhs.paymentID == rhs.paymentID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(invoiceID)
        hasher.combine(paymentID)
    }
}

private struct CandidateSortKey: Comparable {
    let invoiceSourceID: String
    let invoicePath: String
    let invoiceID: String
    let paymentSourceID: String
    let paymentPath: String
    let paymentID: String

    init(_ candidate: InvoicePaymentCandidate) {
        invoiceSourceID = candidate.invoice.document.sourceRootID.uuidString
        invoicePath = candidate.invoice.document.relativePath
        invoiceID = candidate.invoice.document.id.uuidString
        paymentSourceID = candidate.payment.document.sourceRootID.uuidString
        paymentPath = candidate.payment.document.relativePath
        paymentID = candidate.payment.document.id.uuidString
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (
            lhs.invoiceSourceID,
            lhs.invoicePath,
            lhs.invoiceID,
            lhs.paymentSourceID,
            lhs.paymentPath,
            lhs.paymentID
        ) < (
            rhs.invoiceSourceID,
            rhs.invoicePath,
            rhs.invoiceID,
            rhs.paymentSourceID,
            rhs.paymentPath,
            rhs.paymentID
        )
    }
}
