import LinkLoomCore
import SwiftUI

public struct PersonDossierView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let snapshot = model.dossierDetailState.personSnapshot {
                dossier(snapshot)
            } else {
                emptyState
            }
        }
        .navigationTitle("Meine Mutter im Pflegeheim")
        .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.workspace)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.dossierDetailState {
        case .loading:
            ProgressView("Hauptdossier wird aktualisiert …")
        case .failed:
            errorState
        case .none, .available:
            ContentUnavailableView(
                "Kein Hauptdossier ausgewählt",
                systemImage: "person.crop.circle",
                description: Text("Wähle links ein Hauptdossier aus.")
            )
        }
    }

    private func dossier(_ snapshot: PersonDossierSnapshot) -> some View {
        let documents = documentIndex(in: snapshot)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Meine Mutter im Pflegeheim")
                        .font(.largeTitle.bold())
                    anchor(snapshot)
                }

                if isLoading {
                    ProgressView("Hauptdossier wird aktualisiert …")
                }
                if isFailed {
                    errorState
                }

                memberSection(
                    title: "Direkte Dokumente",
                    emptyCopy: "Noch keine direkten Dokumente.",
                    members: snapshot.directMembers,
                    snapshot: snapshot,
                    documents: documents,
                    identifier: PersonDossierAccessibilityIdentifier.directMembers
                )

                memberSection(
                    title: "Kosten und Zahlungen",
                    emptyCopy: "Noch keine Kosten oder Zahlungen.",
                    members: snapshot.costsAndPayments,
                    snapshot: snapshot,
                    documents: documents,
                    identifier: PersonDossierAccessibilityIdentifier.costs
                )
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func anchor(_ snapshot: PersonDossierSnapshot) -> some View {
        let presentation = PersonDossierAnchorPresentation(
            snapshot: snapshot
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(presentation.displayName)
                .font(.title2.bold())
            Text("Rolle: \(presentation.roleTitle)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(presentation.evidenceValidityTitle)
                .font(.subheadline.weight(.semibold))
            if let sourceAvailabilityTitle = presentation.sourceAvailabilityTitle {
                Text(sourceAvailabilityTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.anchor)
    }

    private func memberSection(
        title: String,
        emptyCopy: String,
        members: [PersonDossierMember],
        snapshot: PersonDossierSnapshot,
        documents: [UUID: DocumentRecord],
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
            if members.isEmpty {
                Text(emptyCopy)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(members) { member in
                    memberRow(member, snapshot: snapshot, documents: documents)
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private func memberRow(
        _ member: PersonDossierMember,
        snapshot: PersonDossierSnapshot,
        documents: [UUID: DocumentRecord]
    ) -> some View {
        let presentation = PersonDossierMemberPresentation(
            member: member,
            selectedSourceID: model.selectedSourceID,
            documents: documents
        )
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.location)
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Dokumenttyp: \(presentation.documentTypeTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(presentation.availabilityTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(presentation.membershipRoleTitle)
                    .font(.caption.weight(.semibold))
                ForEach(Array(presentation.reasons.enumerated()), id: \.offset) { ordinal, reason in
                    Text(reason)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(presentation.reasonAccessibilityIdentifiers[ordinal])
                }
            }
            .allowsHitTesting(false)
            .background {
                Button {
                    Task { await model.selectPersonDossierDocument(documentID: member.id) }
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(presentation.documentSummaryAccessibilityLabel)
                .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.member(member.id))
            }

            if let counterpartID = presentation.preferredCounterpartDocumentID {
                Button("Gegenstück anzeigen") {
                    Task {
                        await model.selectPersonDossierDocument(documentID: counterpartID)
                    }
                }
                .accessibilityIdentifier(
                    PersonDossierAccessibilityIdentifier.counterpart(member.id)
                )
            }

            if member.id != snapshot.anchor.originDocumentID {
                Button("Aus Dossier entfernen", role: .destructive) {
                    Task { await model.removePersonDossierMember(member) }
                }
                .disabled(mutationIsInFlight)
                .accessibilityIdentifier(
                    PersonDossierAccessibilityIdentifier.removeMember(member.id)
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var errorState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                model.lastErrorMessage
                    ?? "Das Hauptdossier konnte nicht geladen werden. Bitte versuche es erneut.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)
            Button("Erneut versuchen") {
                Task { await model.refreshSelectedDossier() }
            }
            .disabled(isLoading || mutationIsInFlight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dossier.person.error")
    }

    private func documentIndex(in snapshot: PersonDossierSnapshot) -> [UUID: DocumentRecord] {
        let origin = snapshot.origin.document.map { [$0.id: $0] } ?? [:]
        return (snapshot.directMembers + snapshot.costsAndPayments).reduce(into: origin) {
            $0[$1.id] = $1.document
        }
    }

    private var mutationIsInFlight: Bool {
        model.dossierMutationState != .idle
    }

    private var isLoading: Bool {
        if case .loading = model.dossierDetailState { true } else { false }
    }

    private var isFailed: Bool {
        if case .failed = model.dossierDetailState { true } else { false }
    }
}
