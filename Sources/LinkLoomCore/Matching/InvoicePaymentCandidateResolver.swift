import Foundation

/// Rejects a catalog record and DNA snapshot that do not describe the same input.
public enum CurrentDocumentDNAError: Error, Sendable, Equatable {
    case invalidDocumentIdentity
}

/// One catalog document paired with a content-current Document DNA snapshot.
public struct CurrentDocumentDNA: Sendable, Equatable {
    public let document: DocumentRecord
    public let snapshot: DocumentDNA

    public init(document: DocumentRecord, snapshot: DocumentDNA) throws {
        guard document.id == snapshot.documentID,
              document.contentHash == snapshot.inputContentHash
        else {
            throw CurrentDocumentDNAError.invalidDocumentIdentity
        }
        self.document = document
        self.snapshot = snapshot
    }
}

/// A transient routing decision, not a persisted relationship or user decision.
public enum InvoicePaymentCandidateDisposition: String, Sendable, Equatable {
    /// Both independent signals match and the pair has no equally strong counterpart.
    case automatic
    /// Exactly one independent signal matches or an otherwise automatic pair is ambiguous.
    case suggestion
}

/// The evidence categories supported by the first deterministic resolver version.
public enum InvoicePaymentCandidateSignalKind: String, Sendable, Equatable {
    case referenceNumber
    case monetaryAmount
    case organization
}

/// The source-faithful findings from both documents that support one signal.
public struct InvoicePaymentCandidateSignal: Sendable, Equatable {
    public let kind: InvoicePaymentCandidateSignalKind
    public let invoiceFinding: DocumentDNAFinding
    public let paymentFinding: DocumentDNAFinding

    init(
        kind: InvoicePaymentCandidateSignalKind,
        invoiceFinding: DocumentDNAFinding,
        paymentFinding: DocumentDNAFinding
    ) {
        self.kind = kind
        self.invoiceFinding = invoiceFinding
        self.paymentFinding = paymentFinding
    }
}

/// A rebuildable invoice/payment pair with complete input snapshots and evidence.
public struct InvoicePaymentCandidate: Sendable, Equatable {
    public let invoice: CurrentDocumentDNA
    public let payment: CurrentDocumentDNA
    public let disposition: InvoicePaymentCandidateDisposition
    public let resolverVersion: String
    public let signals: [InvoicePaymentCandidateSignal]

    init(
        invoice: CurrentDocumentDNA,
        payment: CurrentDocumentDNA,
        disposition: InvoicePaymentCandidateDisposition,
        resolverVersion: String,
        signals: [InvoicePaymentCandidateSignal]
    ) {
        self.invoice = invoice
        self.payment = payment
        self.disposition = disposition
        self.resolverVersion = resolverVersion
        self.signals = signals
    }
}

/// Resolves exact, qualifier-compatible reference groups without performing normalization.
public struct InvoicePaymentCandidateResolver: Sendable {
    public static let version = "invoice-payment-v1"

    public init() {}

    /// Produces deterministic candidates for one already-normalized reference value.
    ///
    /// A reference alone is insufficient. Exact currency/amount and issuer/payee
    /// organization matches are independent signals. Any explicit conflict rejects
    /// the pair, and multiple equally strong counterparts cannot be automatic.
    public func candidates(
        matching normalizedReference: String,
        in documents: [CurrentDocumentDNA]
    ) -> [InvoicePaymentCandidate] {
        let invoices = documents.filter {
            documentType(of: $0) == .invoice
                && reference(
                    in: $0,
                    qualifier: .invoiceNumber,
                    normalizedValue: normalizedReference
                ) != nil
        }
        let payments = documents.filter {
            documentType(of: $0) == .paymentConfirmation
                && reference(
                    in: $0,
                    qualifier: .paymentReference,
                    normalizedValue: normalizedReference
                ) != nil
        }

        var candidates: [InvoicePaymentCandidate] = []
        for invoice in invoices {
            for payment in payments where invoice.document.id != payment.document.id {
                guard hasSameAnalysisTarget(invoice.snapshot, payment.snapshot),
                      let referenceSignal = referenceSignal(
                    invoice: invoice,
                    payment: payment,
                    normalizedValue: normalizedReference
                ) else {
                    continue
                }
                let amountAssessment = exactSignal(
                    kind: .monetaryAmount,
                    signalKind: .monetaryAmount,
                    invoiceQualifier: nil,
                    paymentQualifier: nil,
                    requireSameQualifier: true,
                    invoice: invoice,
                    payment: payment
                )
                let organizationAssessment = exactSignal(
                    kind: .organization,
                    signalKind: .organization,
                    invoiceQualifier: "issuer",
                    paymentQualifier: "payee",
                    requireSameQualifier: false,
                    invoice: invoice,
                    payment: payment
                )
                guard !amountAssessment.isConflict,
                      !organizationAssessment.isConflict
                else {
                    continue
                }
                let amountSignal = amountAssessment.signal
                let organizationSignal = organizationAssessment.signal
                guard amountSignal != nil || organizationSignal != nil else {
                    continue
                }
                let signals = [referenceSignal, amountSignal, organizationSignal]
                    .compactMap { $0 }
                candidates.append(InvoicePaymentCandidate(
                    invoice: invoice,
                    payment: payment,
                    disposition: amountAssessment.isUnambiguousMatch
                        && organizationAssessment.isUnambiguousMatch
                        ? .automatic
                        : .suggestion,
                    resolverVersion: Self.version,
                    signals: signals
                ))
            }
        }
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

    private func documentType(of document: CurrentDocumentDNA) -> DocumentType? {
        document.snapshot.findings.first {
            $0.kind == .documentType
        }.flatMap { DocumentType(rawValue: $0.normalizedValue) }
    }

    private func hasSameAnalysisTarget(_ lhs: DocumentDNA, _ rhs: DocumentDNA) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.analyzerIdentifier == rhs.analyzerIdentifier
            && lhs.analyzerVersion == rhs.analyzerVersion
    }

    private func reference(
        in document: CurrentDocumentDNA,
        qualifier: DocumentDNAReferenceNumberKind,
        normalizedValue: String
    ) -> DocumentDNAFinding? {
        document.snapshot.findings.first {
            $0.kind == .referenceNumber
                && $0.qualifier == qualifier.rawValue
                && $0.normalizedValue == normalizedValue
        }
    }

    private func referenceSignal(
        invoice: CurrentDocumentDNA,
        payment: CurrentDocumentDNA,
        normalizedValue: String
    ) -> InvoicePaymentCandidateSignal? {
        guard let invoiceFinding = reference(
            in: invoice,
            qualifier: .invoiceNumber,
            normalizedValue: normalizedValue
        ),
        let paymentFinding = reference(
            in: payment,
            qualifier: .paymentReference,
            normalizedValue: normalizedValue
        ) else {
            return nil
        }
        return InvoicePaymentCandidateSignal(
            kind: .referenceNumber,
            invoiceFinding: invoiceFinding,
            paymentFinding: paymentFinding
        )
    }

    private func exactSignal(
        kind: DocumentDNAFindingKind,
        signalKind: InvoicePaymentCandidateSignalKind,
        invoiceQualifier: String?,
        paymentQualifier: String?,
        requireSameQualifier: Bool,
        invoice: CurrentDocumentDNA,
        payment: CurrentDocumentDNA
    ) -> SignalAssessment {
        let invoiceFindings = invoice.snapshot.findings.filter {
            $0.kind == kind && (invoiceQualifier == nil || $0.qualifier == invoiceQualifier)
        }
        let paymentFindings = payment.snapshot.findings.filter {
            $0.kind == kind && (paymentQualifier == nil || $0.qualifier == paymentQualifier)
        }
        guard !invoiceFindings.isEmpty, !paymentFindings.isEmpty else {
            return .missing
        }
        let invoiceValues = Set(invoiceFindings.map {
            SignalValue(
                qualifier: requireSameQualifier ? $0.qualifier : nil,
                normalizedValue: $0.normalizedValue
            )
        })
        let paymentValues = Set(paymentFindings.map {
            SignalValue(
                qualifier: requireSameQualifier ? $0.qualifier : nil,
                normalizedValue: $0.normalizedValue
            )
        })
        for invoiceFinding in invoiceFindings {
            if let paymentFinding = paymentFindings.first(where: {
                (!requireSameQualifier || $0.qualifier == invoiceFinding.qualifier)
                    && $0.normalizedValue == invoiceFinding.normalizedValue
            }) {
                return .matching(
                    InvoicePaymentCandidateSignal(
                        kind: signalKind,
                        invoiceFinding: invoiceFinding,
                        paymentFinding: paymentFinding
                    ),
                    isUnambiguous: invoiceValues.count == 1 && paymentValues.count == 1
                )
            }
        }
        return .conflict
    }

    private func candidateOrder(
        _ lhs: InvoicePaymentCandidate,
        _ rhs: InvoicePaymentCandidate
    ) -> Bool {
        let lhsKey = (
            lhs.invoice.document.sourceRootID.uuidString,
            lhs.invoice.document.relativePath,
            lhs.invoice.document.id.uuidString,
            lhs.payment.document.sourceRootID.uuidString,
            lhs.payment.document.relativePath,
            lhs.payment.document.id.uuidString
        )
        let rhsKey = (
            rhs.invoice.document.sourceRootID.uuidString,
            rhs.invoice.document.relativePath,
            rhs.invoice.document.id.uuidString,
            rhs.payment.document.sourceRootID.uuidString,
            rhs.payment.document.relativePath,
            rhs.payment.document.id.uuidString
        )
        return lhsKey < rhsKey
    }
}

private struct SignalValue: Hashable {
    let qualifier: String?
    let normalizedValue: String
}

private enum SignalAssessment {
    case missing
    case matching(InvoicePaymentCandidateSignal, isUnambiguous: Bool)
    case conflict

    var signal: InvoicePaymentCandidateSignal? {
        guard case let .matching(signal, _) = self else { return nil }
        return signal
    }

    var isUnambiguousMatch: Bool {
        guard case let .matching(_, isUnambiguous) = self else { return false }
        return isUnambiguous
    }

    var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }
}
