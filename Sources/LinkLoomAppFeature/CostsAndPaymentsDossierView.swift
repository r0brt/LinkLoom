import LinkLoomCore
import SwiftUI

public struct CostsAndPaymentsDossierView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let snapshot = model.dossierDetailState.snapshot {
                dossier(snapshot)
            } else {
                emptyState
            }
        }
        .navigationTitle("Kosten und Zahlungen")
        .accessibilityIdentifier("dossier.workspace")
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.dossierDetailState {
        case .loading:
            ProgressView("Dossier wird geladen …")
        case .failed:
            dossierError
        case .none, .available:
            ContentUnavailableView(
                "Kein Dossier ausgewählt",
                systemImage: "folder",
                description: Text("Wähle links ein Dossier aus.")
            )
        }
    }

    private func dossier(_ snapshot: DossierSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.dossier.displayName)
                        .font(.largeTitle.bold())
                    Text("Direkte bestätigte Beziehungen · lokal verarbeitet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if isLoading {
                    ProgressView("Dossier wird aktualisiert …")
                }

                if isFailed {
                    dossierError
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Dokumente")
                        .font(.title2.bold())
                    ForEach(snapshot.members) { member in
                        memberRow(member)
                    }
                }

                if !snapshot.corrections.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Korrekturen")
                            .font(.title2.bold())
                        ForEach(snapshot.corrections) { correction in
                            correctionRow(correction)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func memberRow(_ member: DossierMember) -> some View {
        let presentation = DossierMemberPresentation(
            member: member,
            selectedSourceID: model.selectedSourceID
        )
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await model.selectDossierMember(documentID: member.id) }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(
                            presentation.roleTitle,
                            systemImage: member.explanation.role == .anchor
                                ? "pin.fill"
                                : "doc.text"
                        )
                        .font(.headline)
                        Spacer(minLength: 8)
                        Text(presentation.availabilityTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(presentation.location)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                    Text("Dokumenttyp: \(presentation.documentTypeTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(presentation.signals.enumerated()), id: \.offset) {
                        _, signal in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(signal.title)
                                .font(.caption.weight(.semibold))
                            Text(signal.comparison)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                DossierAccessibilityIdentifier.member(member.id)
            )

            if member.explanation.role != .anchor, member.support != nil {
                Button("Aus Dossier entfernen", role: .destructive) {
                    Task { await model.excludeDossierMember(member) }
                }
                .disabled(mutationIsInFlight)
                .accessibilityIdentifier(
                    DossierAccessibilityIdentifier.removeMember(member.id)
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func correctionRow(_ correction: DossierCorrection) -> some View {
        let documentTypeTitle = correction.documentType.map(
            DocumentDNADetailPresentation.title
        ) ?? "Nicht verfügbar"
        let availabilityTitle = DossierMemberPresentation.availabilityTitle(
            for: correction.document.availability
        )
        let location = correction.document.sourceRootID == model.selectedSourceID
            ? correction.document.relativePath
            : "\(correction.sourceDisplayName) · \(correction.document.relativePath)"
        return VStack(alignment: .leading, spacing: 8) {
            Text(location)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
            Text("Dokumenttyp: \(documentTypeTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(availabilityTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Wieder aufnehmen") {
                Task { await model.resetDossierCorrection(correction) }
            }
            .disabled(mutationIsInFlight)
            .accessibilityIdentifier(
                DossierAccessibilityIdentifier.resetCorrection(correction.id)
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            DossierAccessibilityIdentifier.correction(correction.id)
        )
    }

    private var dossierError: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                model.lastErrorMessage
                    ?? "Das Dossier konnte nicht geladen werden. Bitte versuche es erneut.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)
            Button("Erneut versuchen") {
                Task { await model.refreshSelectedDossier() }
            }
            .disabled(isLoading || mutationIsInFlight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dossier.error")
    }

    private var mutationIsInFlight: Bool {
        model.dossierMutationState != .idle
    }

    private var isLoading: Bool {
        if case .loading = model.dossierDetailState {
            true
        } else {
            false
        }
    }

    private var isFailed: Bool {
        if case .failed = model.dossierDetailState {
            true
        } else {
            false
        }
    }
}
