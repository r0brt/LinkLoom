import Foundation

struct InvoicePaymentCandidateProjectionInput: Sendable {
    let selected: CurrentDocumentDNA
    let matchesByNormalizedReference: [String: [CurrentDocumentDNA]]
}

struct InvoicePaymentCandidateProjector: Sendable {
    private let resolver: InvoicePaymentCandidateResolver

    init(resolver: InvoicePaymentCandidateResolver = InvoicePaymentCandidateResolver()) {
        self.resolver = resolver
    }

    func normalizedReferences(in selected: CurrentDocumentDNA) -> [String] {
        guard let referenceQualifier = referenceQualifier(for: selected.snapshot) else {
            return []
        }
        return Set(selected.snapshot.findings.compactMap { finding in
            finding.kind == .referenceNumber
                && finding.qualifier == referenceQualifier.rawValue
                ? finding.normalizedValue
                : nil
        }).sorted()
    }

    func candidates(
        from input: InvoicePaymentCandidateProjectionInput
    ) -> [InvoicePaymentCandidate] {
        var candidatesByPair: [InvoicePaymentCandidatePair: InvoicePaymentCandidate] = [:]
        for reference in normalizedReferences(in: input.selected) {
            let documents = input.matchesByNormalizedReference[reference] ?? []
            for candidate in resolver.candidates(matching: reference, in: documents)
            where candidate.invoice.document.id == input.selected.document.id
                || candidate.payment.document.id == input.selected.document.id
            {
                let pair = InvoicePaymentCandidatePair(candidate)
                if let old = candidatesByPair[pair], strength(old) >= strength(candidate) {
                    continue
                }
                candidatesByPair[pair] = candidate
            }
        }
        return normalizeAmbiguityAndSort(Array(candidatesByPair.values))
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

    private func strength(
        _ candidate: InvoicePaymentCandidate
    ) -> (Int, Int) {
        (candidate.disposition == .automatic ? 1 : 0, candidate.signals.count)
    }

    private func normalizeAmbiguityAndSort(
        _ candidates: [InvoicePaymentCandidate]
    ) -> [InvoicePaymentCandidate] {
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

    private func candidateOrder(
        _ lhs: InvoicePaymentCandidate,
        _ rhs: InvoicePaymentCandidate
    ) -> Bool {
        InvoicePaymentCandidatePair(lhs).sortKey < InvoicePaymentCandidatePair(rhs).sortKey
    }
}

private struct InvoicePaymentCandidatePair: Hashable {
    let invoiceID: UUID
    let paymentID: UUID
    let sortKey: InvoicePaymentCandidateSortKey

    init(_ candidate: InvoicePaymentCandidate) {
        invoiceID = candidate.invoice.document.id
        paymentID = candidate.payment.document.id
        sortKey = InvoicePaymentCandidateSortKey(candidate)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.invoiceID == rhs.invoiceID && lhs.paymentID == rhs.paymentID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(invoiceID)
        hasher.combine(paymentID)
    }
}

private struct InvoicePaymentCandidateSortKey: Comparable {
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
