import LinkLoomCore
import SwiftUI

public struct ScanDashboard: View {
    @ObservedObject private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let source = selectedSource {
                VStack(alignment: .leading, spacing: 16) {
                    header(source)
                    statusSummary
                    documentTable
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "Keine Quelle ausgewählt",
                    systemImage: "folder",
                    description: Text("Füge links einen Ordner hinzu.")
                )
            }
        }
        .navigationTitle("Lokale Analyse")
    }

    private var selectedSource: SourceRootRecord? {
        model.sources.first { $0.id == model.selectedSourceID }
    }

    @ViewBuilder
    private func header(_ source: SourceRootRecord) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(source.displayName)
                    .font(.title2.bold())
                Text(lastScanText(source.lastScanAt))
                    .foregroundStyle(.secondary)
                DisclosureGroup("Lokaler Quellpfad") {
                    Text(source.pathHint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if model.unavailableSourceIDs.contains(source.id) {
                    Label(
                        "Quelle vorübergehend nicht verfügbar",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Jetzt analysieren") {
                Task { await model.scanSelectedSource() }
            }
            .accessibilityIdentifier("scan.start")
            .disabled(
                model.scanState != .idle
                    || model.unavailableSourceIDs.contains(source.id)
            )
        }
        if model.scanState != .idle {
            ProgressView(scanProgressTitle)
        }
        if let errorMessage = model.lastErrorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .accessibilityLabel("Fehler: \(errorMessage)")
                .accessibilityIdentifier("scan.error")
        }
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Textverarbeitung").font(.headline)
            HStack(spacing: 12) {
                statusCard("Entdeckt", status: .discovered, identifier: "status.discovered")
                statusCard("Extraktion", status: .extracting, identifier: "status.extracting")
                statusCard("Bereit", status: .ready, identifier: "status.ready")
                statusCard("Fehler", status: .failed, identifier: "status.failed")
            }
            Text("Document DNA").font(.headline).padding(.top, 4)
            documentDNAStatusSummary
        }
    }

    private var documentDNAStatusSummary: some View {
        let summary = DocumentDNAAnalysisSummary(phases: model.documentDNAAnalysisPhases)
        return HStack(spacing: 12) {
            documentDNAStatusCard("Ausstehend", count: summary.pending, identifier: "dna-status.pending")
            documentDNAStatusCard("Läuft", count: summary.analyzing, identifier: "dna-status.analyzing")
            documentDNAStatusCard("Bereit", count: summary.ready, identifier: "dna-status.ready")
            documentDNAStatusCard("Fehler", count: summary.failed, identifier: "dna-status.failed")
        }
    }

    private func statusCard(
        _ title: String,
        status: DocumentStatus,
        identifier: String
    ) -> some View {
        let count = model.documents.filter { $0.status == status }.count
        return countCard(
            title,
            count: count,
            accessibilityTitle: title,
            identifier: identifier
        )
    }

    private func documentDNAStatusCard(
        _ title: String,
        count: Int,
        identifier: String
    ) -> some View {
        countCard(
            title,
            count: count,
            accessibilityTitle: "Document DNA \(title)",
            identifier: identifier
        )
    }

    private func countCard(
        _ title: String,
        count: Int,
        accessibilityTitle: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(count.formatted())
                .font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityTitle): \(count)")
        .accessibilityIdentifier(identifier)
    }

    private var documentTable: some View {
        Table(model.documents, selection: selectedDocument) {
            TableColumn("Relativer Pfad", value: \.relativePath)
            TableColumn("Medientyp") { document in
                Text(document.mediaType.rawValue.uppercased())
            }
            TableColumn("Status") { document in
                Text(document.status.rawValue)
            }
            TableColumn("Document DNA") { document in
                Text(DocumentDNAAnalysisPresentation.title(
                    for: model.documentDNAAnalysisPhases[document.id]
                ))
            }
            TableColumn("Seiten") { document in
                Text(document.pageCount?.formatted() ?? "—")
            }
            TableColumn("Fehlercode") { document in
                Text(document.status == .failed ? document.failureCode ?? "ingestionFailure" : "—")
            }
        }
        .accessibilityIdentifier("documents.table")
    }

    private var selectedDocument: Binding<UUID?> {
        Binding(
            get: { model.selectedDocumentID },
            set: { id in Task { await model.selectDocument(id: id) } }
        )
    }

    private var scanProgressTitle: String {
        switch model.scanState {
        case .idle:
            "Bereit"
        case .scanning:
            "Dateien werden erfasst …"
        case .extracting:
            "Text wird lokal extrahiert …"
        }
    }

    private func lastScanText(_ date: Date?) -> String {
        guard let date else { return "Noch nicht analysiert" }
        return "Letzter Scan: \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

enum DocumentDNAAnalysisPresentation {
    static func title(for phase: DocumentDNAAnalysisPhase?) -> String {
        switch phase {
        case nil:
            "—"
        case .pending:
            "Ausstehend"
        case .analyzing:
            "Läuft"
        case .ready:
            "Bereit"
        case .failed(.analysisFailure):
            "Analyse fehlgeschlagen"
        case .failed(.invalidFinding):
            "Ungültiger Befund"
        case .failed(.invalidProvenance):
            "Ungültiger Nachweis"
        }
    }
}

enum DocumentDNAFailurePresentation {
    static func title(for failureCode: DocumentDNAAnalysisFailureCode) -> String {
        switch failureCode {
        case .analysisFailure:
            "Lokale Analyse fehlgeschlagen"
        case .invalidFinding:
            "Ungültiger Befund"
        case .invalidProvenance:
            "Ungültiger Nachweis"
        }
    }
}

struct DocumentDNAAnalysisSummary: Equatable {
    let pending, analyzing, ready, failed: Int

    init(phases: [UUID: DocumentDNAAnalysisPhase]) {
        var pending = 0
        var analyzing = 0
        var ready = 0
        var failed = 0
        for phase in phases.values {
            switch phase {
            case .pending:
                pending += 1
            case .analyzing:
                analyzing += 1
            case .ready:
                ready += 1
            case .failed:
                failed += 1
            }
        }
        self.pending = pending
        self.analyzing = analyzing
        self.ready = ready
        self.failed = failed
    }
}

struct DocumentDNAEvidencePresentation: Equatable {
    let pageNumber: Int
    let exactText: String
}

struct DocumentDNAFactPresentation: Equatable {
    let title: String
    let displayValue: String
    let confidence: Double
    let evidence: [DocumentDNAEvidencePresentation]
}

struct DocumentDNADetailPresentation: Equatable {
    let documentTypeTitle: String
    let documentTypeEvidence: [DocumentDNAEvidencePresentation]
    let facts: [DocumentDNAFactPresentation]

    init(snapshot: DocumentDNA) {
        let classification = snapshot.findings.first { $0.kind == .documentType }
        let documentType = classification.flatMap {
            DocumentType(rawValue: $0.normalizedValue)
        } ?? .unknown
        documentTypeTitle = Self.title(for: documentType)
        documentTypeEvidence = classification?.evidence.map {
            DocumentDNAEvidencePresentation(
                pageNumber: $0.pageIndex + 1,
                exactText: $0.exactText
            )
        } ?? []
        facts = snapshot.findings.compactMap { finding in
            guard finding.kind != .documentType else { return nil }
            return DocumentDNAFactPresentation(
                title: Self.factTitle(for: finding),
                displayValue: finding.displayValue,
                confidence: finding.confidence,
                evidence: finding.evidence.map {
                    DocumentDNAEvidencePresentation(
                        pageNumber: $0.pageIndex + 1,
                        exactText: $0.exactText
                    )
                }
            )
        }
    }

    static func title(for documentType: DocumentType) -> String {
        switch documentType {
        case .contract:
            "Vertrag"
        case .invoice:
            "Rechnung"
        case .paymentConfirmation:
            "Zahlungsbestätigung"
        case .insuranceStatement:
            "Versicherungsabrechnung"
        case .medicalOrCareDocument:
            "Medizin- oder Pflegedokument"
        case .powerOfAttorney:
            "Vollmacht"
        case .correspondence:
            "Korrespondenz"
        case .unknown:
            "Unbekannt"
        }
    }

    private static func factTitle(for finding: DocumentDNAFinding) -> String {
        let kind: String
        switch finding.kind {
        case .documentType:
            kind = "Dokumenttyp"
        case .person:
            kind = "Person"
        case .organization:
            kind = "Organisation"
        case .date:
            kind = "Datum"
        case .monetaryAmount:
            kind = "Betrag"
        case .referenceNumber:
            kind = "Referenz"
        }
        guard let qualifier = qualifierTitle(for: finding) else { return kind }
        return "\(kind) · \(qualifier)"
    }

    private static func qualifierTitle(for finding: DocumentDNAFinding) -> String? {
        guard let qualifier = finding.qualifier else { return nil }
        if finding.kind == .monetaryAmount {
            return qualifier
        }
        let titles = [
            "resident": "Bewohner:in",
            "provider": "Leistungserbringer",
            "invoiceRecipient": "Rechnungsempfänger:in",
            "issuer": "Aussteller:in",
            "insuredPerson": "Versicherte Person",
            "insurer": "Versicherung",
            "accountHolder": "Kontoinhaber:in",
            "payee": "Zahlungsempfänger:in",
            "authority": "Behörde",
            "authorizedPerson": "Bevollmächtigte Person",
            "grantor": "Vollmachtgeber:in",
            DocumentDNADateRole.issueDate.rawValue: "Ausstellungsdatum",
            DocumentDNADateRole.dueDate.rawValue: "Fälligkeitsdatum",
            DocumentDNADateRole.serviceDate.rawValue: "Leistungsdatum",
            DocumentDNADateRole.servicePeriod.rawValue: "Leistungszeitraum",
            DocumentDNADateRole.bookingDate.rawValue: "Buchungsdatum",
            DocumentDNADateRole.birthDate.rawValue: "Geburtsdatum",
            DocumentDNADateRole.unknown.rawValue: "Unbekannte Rolle",
            DocumentDNAReferenceNumberKind.contractNumber.rawValue: "Vertragsnummer",
            DocumentDNAReferenceNumberKind.invoiceNumber.rawValue: "Rechnungsnummer",
            DocumentDNAReferenceNumberKind.policyNumber.rawValue: "Policennummer",
            DocumentDNAReferenceNumberKind.claimNumber.rawValue: "Schadennummer",
            DocumentDNAReferenceNumberKind.customerNumber.rawValue: "Kundennummer",
            DocumentDNAReferenceNumberKind.paymentReference.rawValue: "Zahlungsreferenz",
            DocumentDNAReferenceNumberKind.other.rawValue: "Sonstige Referenz",
        ]
        return titles[qualifier]
    }
}
