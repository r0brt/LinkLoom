import LinkLoomCore
import SwiftUI

struct DocumentDNAInspector: View {
    @ObservedObject var model: AppModel
    let document: DocumentRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Document DNA")
                .font(.title2.bold())
            if let document {
                Text(document.relativePath)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            documentDNADetailContent
            Spacer(minLength: 0)
        }
        .padding()
        .frame(minWidth: 320, idealWidth: 380)
        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("document-dna.inspector")
    }

    @ViewBuilder
    private var documentDNADetailContent: some View {
        switch model.documentDNADetailState {
        case .none:
            EmptyView()
        case .loading:
            ProgressView("Document DNA wird geladen …")
        case .unavailable:
            if let failureCode = selectedDocumentDNAFailureCode {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "Document DNA nicht verfügbar",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Das Originaldokument bleibt unverändert.")
                    )
                    Text("Fehlergrund: \(DocumentDNAFailurePresentation.title(for: failureCode))")
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "Fehlergrund: \(DocumentDNAFailurePresentation.title(for: failureCode))"
                        )
                        .accessibilityIdentifier("document-dna.failure-reason")
                    if model.documentDNARetryingDocumentID == model.selectedDocumentID {
                        ProgressView("Wird erneut analysiert …")
                            .accessibilityIdentifier("document-dna.retry-progress")
                    }
                    Button("Erneut analysieren") {
                        Task { await model.retrySelectedDocumentDNA() }
                    }
                    .accessibilityIdentifier("document-dna.retry")
                    .disabled(model.documentDNARetryingDocumentID != nil)
                }
            } else {
                ContentUnavailableView(
                    "Keine aktuelle Document DNA",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Die lokale Analyse ist noch nicht bereit.")
                )
            }
        case .failed:
            ContentUnavailableView(
                "Document DNA konnte nicht geladen werden",
                systemImage: "exclamationmark.triangle",
                description: Text("Die Dokumentliste und das Original bleiben unverändert.")
            )
        case .available(let snapshot):
            documentDNADetail(DocumentDNADetailPresentation(snapshot: snapshot))
        }
    }

    private var selectedDocumentDNAFailureCode: DocumentDNAAnalysisFailureCode? {
        guard let selectedDocumentID = model.selectedDocumentID,
              let phase = model.documentDNAAnalysisPhases[selectedDocumentID],
              case .failed(let failureCode) = phase
        else {
            return nil
        }
        return failureCode
    }

    private func documentDNADetail(
        _ presentation: DocumentDNADetailPresentation
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dokumenttyp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(presentation.documentTypeTitle)
                        .font(.headline)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Dokumenttyp: \(presentation.documentTypeTitle)")
                .accessibilityIdentifier("document-dna.document-type")

                evidenceList(
                    presentation.documentTypeEvidence,
                    identifierPrefix: "document-dna.document-type.evidence"
                )

                if presentation.facts.isEmpty {
                    Text("Keine weiteren Befunde")
                        .foregroundStyle(.secondary)
                } else {
                    Divider()
                    Text("Erkannte Befunde")
                        .font(.headline)
                    ForEach(Array(presentation.facts.enumerated()), id: \.offset) { index, fact in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(fact.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(fact.displayValue)
                                .font(.body.weight(.medium))
                                .textSelection(.enabled)
                            Text(fact.confidence, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Konfidenz")
                                .accessibilityValue(
                                    Text(
                                        fact.confidence,
                                        format: .percent.precision(.fractionLength(0))
                                    )
                                )
                            evidenceList(
                                fact.evidence,
                                identifierPrefix: "document-dna.fact.\(index).evidence"
                            )
                        }
                        .padding(.vertical, 4)
                    }
                }
                invoicePaymentCandidateContent
                dossierEntryContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var invoicePaymentCandidateContent: some View {
        switch model.invoicePaymentCandidateState {
        case .none:
            EmptyView()
        case .loading:
            Divider()
            ProgressView("Verknüpfungskandidaten werden geladen …")
                .accessibilityIdentifier("invoice-payment-candidates.loading")
        case .failed:
            Divider()
            ContentUnavailableView(
                "Kandidaten nicht verfügbar",
                systemImage: "link.badge.plus",
                description: Text(
                    "Document DNA bleibt verfügbar. Bitte versuche es später erneut."
                )
            )
            .accessibilityIdentifier("invoice-payment-candidates.failed")
        case .available(_, let candidates):
            if !candidates.isEmpty, let selectedDocumentID = model.selectedDocumentID {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verknüpfungskandidaten")
                        .font(.headline)
                    Text("Kandidaten lokal berechnet · nur Entscheidungen werden gespeichert")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("invoice-payment-candidates.header")
                ForEach(Array(candidates.enumerated()), id: \.offset) { index, annotated in
                    invoicePaymentCandidateCard(
                        annotated: annotated,
                        candidate: InvoicePaymentCandidatePresentation(
                            candidate: annotated.candidate,
                            selectedDocumentID: selectedDocumentID,
                            sourceDisplayNames: Dictionary(
                                uniqueKeysWithValues: model.sources.map {
                                    ($0.id, $0.displayName)
                                }
                            )
                        ),
                        index: index
                    )
                }
            }
        }
    }

    private func invoicePaymentCandidateCard(
        annotated: InvoicePaymentCandidateWithDecision,
        candidate: InvoicePaymentCandidatePresentation,
        index: Int
    ) -> some View {
        let updatingCandidate = model.invoicePaymentDecisionUpdatingCandidate
        let navigatingCandidate = model.invoicePaymentCounterpartNavigatingCandidate
        let decision = InvoicePaymentDecisionPresentation(
            decision: annotated.decision,
            actionsDisabled: model.isInvoicePaymentDecisionUpdateInFlight
                || navigatingCandidate != nil,
            isSaving: updatingCandidate == annotated.candidate
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.counterpartLocation)
                    .font(.body.weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier(
                        "invoice-payment-candidates.\(index).counterpart"
                    )
                Spacer(minLength: 8)
                Text(candidate.dispositionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "invoice-payment-candidates.\(index).disposition"
                    )
            }
            ForEach(Array(candidate.signals.enumerated()), id: \.offset) { signalIndex, signal in
                VStack(alignment: .leading, spacing: 6) {
                    Text(signal.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "invoice-payment-candidates.\(index).signal.\(signalIndex).title"
                        )
                    Text(signal.comparison)
                        .font(.caption.weight(.medium))
                        .textSelection(.enabled)
                        .accessibilityIdentifier(
                            "invoice-payment-candidates.\(index).signal.\(signalIndex).comparison"
                        )
                    invoicePaymentEvidence(
                        signal.invoiceEvidence,
                        role: "Rechnung",
                        identifierPrefix:
                            "invoice-payment-candidates.\(index).signal.\(signalIndex).invoice"
                    )
                    invoicePaymentEvidence(
                        signal.paymentEvidence,
                        role: "Zahlung",
                        identifierPrefix:
                            "invoice-payment-candidates.\(index).signal.\(signalIndex).payment"
                    )
                }
            }
            Button("Gegenstück anzeigen") {
                Task {
                    await model.showInvoicePaymentCounterpart(
                        candidate: annotated.candidate
                    )
                }
            }
            .disabled(
                navigatingCandidate != nil
                    || model.isInvoicePaymentDecisionUpdateInFlight
            )
            .accessibilityIdentifier(
                "invoice-payment-candidates.\(index).show-counterpart"
            )
            if navigatingCandidate == annotated.candidate {
                ProgressView("Gegenstück wird geladen …")
                    .controlSize(.small)
                    .accessibilityIdentifier(
                        "invoice-payment-candidates.\(index).counterpart-loading"
                    )
            }
            HStack(spacing: 8) {
                Text(decision.title)
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier(
                        "invoice-payment-candidates.\(index).decision"
                    )
                if decision.isSaving {
                    ProgressView("Wird gespeichert …")
                        .controlSize(.small)
                        .accessibilityIdentifier(
                            "invoice-payment-candidates.\(index).saving"
                        )
                }
            }
            HStack(spacing: 8) {
                Button("Bestätigen") {
                    Task {
                        await model.updateInvoicePaymentDecision(
                            candidate: annotated.candidate,
                            command: .set(.confirmed)
                        )
                    }
                }
                .disabled(!decision.canConfirm)
                .accessibilityIdentifier(
                    "invoice-payment-candidates.\(index).confirm"
                )
                Button("Ausschließen") {
                    Task {
                        await model.updateInvoicePaymentDecision(
                            candidate: annotated.candidate,
                            command: .set(.excluded)
                        )
                    }
                }
                .disabled(!decision.canExclude)
                .accessibilityIdentifier(
                    "invoice-payment-candidates.\(index).exclude"
                )
            }
            if decision.showsReset {
                Button("Entscheidung zurücksetzen") {
                    Task {
                        await model.updateInvoicePaymentDecision(
                            candidate: annotated.candidate,
                            command: .reset
                        )
                    }
                }
                .disabled(!decision.canReset)
                .accessibilityIdentifier(
                    "invoice-payment-candidates.\(index).reset"
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("invoice-payment-candidates.\(index)")
    }

    private func invoicePaymentEvidence(
        _ evidence: [InvoicePaymentEvidencePresentation],
        role: String,
        identifierPrefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(evidence.enumerated()), id: \.offset) { index, item in
                Text("\(role) · Seite \(item.pageNumber): \(item.exactText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("\(identifierPrefix).\(index)")
            }
        }
    }

    @ViewBuilder
    private var dossierEntryContent: some View {
        switch model.dossierEntryState {
        case .none:
            EmptyView()
        case .loading(let documentID):
            if documentID == document?.id {
                Divider()
                Button("Dossier wird geprüft …") {}
                    .disabled(true)
                    .accessibilityIdentifier("document-dna.costs-dossier")
            }
        case .available(let documentID, let disposition):
            if documentID == document?.id {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Button(DossierEntryPresentation(
                        disposition: disposition
                    ).actionTitle) {
                        Task { await model.openOrCreateDossierForSelectedDocument() }
                    }
                    .disabled(model.dossierMutationState != .idle)
                    .accessibilityIdentifier("document-dna.costs-dossier")

                    if !model.dossierChoices.isEmpty {
                        Text("Dossier auswählen")
                            .font(.headline)
                        ForEach(model.dossierChoices) { summary in
                            Button {
                                Task { await model.chooseDossier(id: summary.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.dossier.displayName)
                                    Text(summary.anchor.relativePath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier(
                                DossierAccessibilityIdentifier.row(summary.id)
                            )
                        }
                    }
                }
            }
        case .failed(let documentID):
            if documentID == document?.id {
                Divider()
                Text(
                    model.lastErrorMessage
                        ?? "Das Dossier konnte nicht geladen werden. Bitte versuche es erneut."
                )
                .foregroundStyle(.red)
            }
        }
    }

    private func evidenceList(
        _ evidence: [DocumentDNAEvidencePresentation],
        identifierPrefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(evidence.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Seite \(item.pageNumber)")
                        .font(.caption.bold())
                    Text(item.exactText)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Seite \(item.pageNumber): \(item.exactText)")
                .accessibilityIdentifier("\(identifierPrefix).\(index)")
            }
        }
    }
}
