import Foundation
import LinkLoomCore

struct InvoicePaymentCandidatePresentation: Equatable {
    let counterpartLocation: String
    let dispositionTitle: String
    let signals: [InvoicePaymentSignalPresentation]

    init(
        candidate: InvoicePaymentCandidate,
        selectedDocumentID: UUID,
        sourceDisplayNames: [UUID: String]
    ) {
        let selected = candidate.invoice.document.id == selectedDocumentID
            ? candidate.invoice.document
            : candidate.payment.document
        let counterpart = candidate.invoice.document.id == selectedDocumentID
            ? candidate.payment.document
            : candidate.invoice.document
        if selected.sourceRootID == counterpart.sourceRootID {
            counterpartLocation = counterpart.relativePath
        } else {
            let sourceName = sourceDisplayNames[counterpart.sourceRootID]
                ?? counterpart.sourceRootID.uuidString
            counterpartLocation = "\(sourceName) · \(counterpart.relativePath)"
        }
        dispositionTitle = switch candidate.disposition {
        case .automatic:
            "Hohe Übereinstimmung"
        case .suggestion:
            "Vorschlag"
        }
        signals = candidate.signals.map(InvoicePaymentSignalPresentation.init)
    }
}

struct InvoicePaymentSignalPresentation: Equatable {
    let title: String
    let comparison: String
    let invoiceEvidence: [InvoicePaymentEvidencePresentation]
    let paymentEvidence: [InvoicePaymentEvidencePresentation]

    init(signal: InvoicePaymentCandidateSignal) {
        title = switch signal.kind {
        case .referenceNumber:
            "Referenz"
        case .monetaryAmount:
            "Betrag und Währung"
        case .organization:
            "Organisation"
        }
        comparison = "\(signal.invoiceFinding.displayValue) ↔ "
            + signal.paymentFinding.displayValue
        invoiceEvidence = signal.invoiceFinding.evidence.map(
            InvoicePaymentEvidencePresentation.init
        )
        paymentEvidence = signal.paymentFinding.evidence.map(
            InvoicePaymentEvidencePresentation.init
        )
    }
}

struct InvoicePaymentEvidencePresentation: Equatable {
    let pageNumber: Int
    let exactText: String

    init(evidence: DocumentDNAEvidence) {
        pageNumber = evidence.pageIndex + 1
        exactText = evidence.exactText
    }

    init(pageNumber: Int, exactText: String) {
        self.pageNumber = pageNumber
        self.exactText = exactText
    }
}
