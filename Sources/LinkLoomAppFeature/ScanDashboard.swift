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
            .disabled(
                model.scanState != .idle
                    || model.unavailableSourceIDs.contains(source.id)
            )
        }
        if model.scanState != .idle {
            ProgressView(scanProgressTitle)
        }
        if let errorCode = model.lastErrorCode {
            Text(errorCode)
                .foregroundStyle(.red)
                .accessibilityLabel("Fehlercode: \(errorCode)")
        }
    }

    private var statusSummary: some View {
        HStack(spacing: 12) {
            statusCard("Entdeckt", status: .discovered)
            statusCard("Extraktion", status: .extracting)
            statusCard("Bereit", status: .ready)
            statusCard("Fehler", status: .failed)
        }
    }

    private func statusCard(_ title: String, status: DocumentStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(model.documents.filter { $0.status == status }.count.formatted())
                .font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var documentTable: some View {
        Table(model.documents) {
            TableColumn("Relativer Pfad", value: \.relativePath)
            TableColumn("Medientyp") { document in
                Text(document.mediaType.rawValue.uppercased())
            }
            TableColumn("Status") { document in
                Text(document.status.rawValue)
            }
            TableColumn("Seiten") { document in
                Text(document.pageCount?.formatted() ?? "—")
            }
            TableColumn("Fehlercode") { document in
                Text(document.status == .failed ? document.failureCode ?? "ingestionFailure" : "—")
            }
        }
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
