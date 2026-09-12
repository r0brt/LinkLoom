import AppKit
import LinkLoomCore
import SwiftUI

public struct PersonDossierView: View {
    @ObservedObject var model: AppModel
    @AccessibilityFocusState private var accessibilityFocus: PersonDossierFocusTarget?
    @State private var feedbackContext = PersonDossierFeedbackContext()

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let snapshot = model.dossierDetailState.personSnapshot {
                dossier(snapshot)
                    .id(snapshot.dossier.id)
            } else {
                emptyState
            }
        }
        .navigationTitle("Meine Mutter im Pflegeheim")
        .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.workspace)
        .onReceive(model.$workspaceSelection) { feedbackContext.observeSelection($0) }
        .onReceive(model.$dossierDetailState) { feedbackContext.observeDetail($0) }
        .onReceive(model.$selectedDocumentID.dropFirst()) { _ in feedbackContext.invalidate() }
        .onReceive(model.$selectedSourceID.dropFirst()) { _ in feedbackContext.invalidate() }
        .onDisappear { feedbackContext.invalidate() }
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
                    workspaceHeading
                    anchor(snapshot)
                }

                if isLoading {
                    ProgressView("Hauptdossier wird aktualisiert …")
                }
                if errorMessage != nil {
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

                suggestionSection(snapshot)
                correctionSection(snapshot)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var workspaceHeading: some View {
        let heading = Text("Meine Mutter im Pflegeheim")
            .font(.largeTitle.bold())
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($accessibilityFocus, equals: .workspace)
        if #available(macOS 26, *) {
            heading.accessibilityDefaultFocus($accessibilityFocus, .workspace)
        } else {
            heading.onAppear { accessibilityFocus = .workspace }
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
        .accessibilityElement(children: .ignore)
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
        .accessibilityElement(children: .contain)
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(reason)
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
                .accessibilityFocused($accessibilityFocus, equals: .member(member.id))
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
                    mutate(snapshot, outcome: { .removed(member.id, in: $0) }) {
                        await model.removePersonDossierMember(member)
                    }
                }
                .disabled(mutationIsInFlight)
                .accessibilityLabel("Aus Dossier entfernen: \(presentation.location)")
                .accessibilityIdentifier(
                    PersonDossierAccessibilityIdentifier.removeMember(member.id)
                )
            }
            mutationProgress(target: .member(member.id), snapshot: snapshot)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func suggestionSection(_ snapshot: PersonDossierSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vorschläge")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($accessibilityFocus, equals: .section(.suggestions))
            if snapshot.suggestions.isEmpty {
                Text("Keine weiteren Vorschläge.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.suggestions) { suggestion in
                suggestionRow(suggestion, snapshot: snapshot)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.suggestions)
    }

    private func suggestionRow(_ suggestion: PersonDossierSuggestion, snapshot: PersonDossierSnapshot) -> some View {
        let presentation = PersonDossierSuggestionPresentation(suggestion: suggestion, selectedSourceID: model.selectedSourceID)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await model.selectPersonDossierDocument(documentID: suggestion.id) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    rowSummary(location: presentation.location, type: presentation.documentTypeTitle, availability: presentation.availabilityTitle)
                    Text("Rolle: \(presentation.roleTitle)").font(.caption.weight(.semibold))
                    Text(presentation.reason).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.suggestion(suggestion.id))
            .accessibilityFocused($accessibilityFocus, equals: .suggestion(suggestion.id))
            ViewThatFits(in: .horizontal) {
                HStack { suggestionActions(suggestion, snapshot: snapshot, location: presentation.location) }
                VStack(alignment: .leading) { suggestionActions(suggestion, snapshot: snapshot, location: presentation.location) }
            }
            mutationProgress(target: .suggestion(suggestion.id), snapshot: snapshot)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func suggestionActions(_ suggestion: PersonDossierSuggestion, snapshot: PersonDossierSnapshot, location: String) -> some View {
        Button("Aufnehmen") {
            mutate(snapshot, outcome: { .accepted(suggestion.id, in: $0) }) {
                await model.acceptPersonDossierSuggestion(suggestion)
            }
        }
        .disabled(mutationIsInFlight)
        .accessibilityLabel("Aufnehmen: \(location)")
        .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.acceptSuggestion(suggestion.id))
        Button("Ablehnen", role: .destructive) {
            mutate(snapshot, outcome: { .rejected(suggestion.id, in: $0) }) {
                await model.rejectPersonDossierSuggestion(suggestion)
            }
        }
        .disabled(mutationIsInFlight)
        .accessibilityLabel("Ablehnen: \(location)")
        .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.rejectSuggestion(suggestion.id))
    }

    private func correctionSection(_ snapshot: PersonDossierSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Korrekturen")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($accessibilityFocus, equals: .section(.corrections))
            if snapshot.corrections.isEmpty {
                Text("Noch keine Korrekturen.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.corrections) { correction in
                correctionRow(correction, snapshot: snapshot)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.corrections)
    }

    private func correctionRow(_ correction: PersonDossierCorrection, snapshot: PersonDossierSnapshot) -> some View {
        let presentation = PersonDossierCorrectionPresentation(correction: correction, selectedSourceID: model.selectedSourceID)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await model.selectPersonDossierDocument(documentID: correction.id) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    rowSummary(location: presentation.location, type: presentation.documentTypeTitle, availability: presentation.availabilityTitle)
                    Text(presentation.decisionTitle).font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.correction(correction.id))
            .accessibilityFocused($accessibilityFocus, equals: .correction(correction.id))
            Button(presentation.resetTitle) {
                mutate(snapshot, outcome: { .reset(correction.id, in: $0) }) {
                    await model.resetPersonDossierCorrection(correction)
                }
            }
            .disabled(mutationIsInFlight)
            .accessibilityLabel("\(presentation.resetTitle) für \(presentation.location)")
            .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.resetCorrection(correction.id))
            mutationProgress(target: .correction(correction.id), snapshot: snapshot)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func rowSummary(location: String, type: String, availability: String) -> some View {
        Text(location).font(.body.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
        Text("Dokumenttyp: \(type)").font(.caption).foregroundStyle(.secondary)
        Text(availability).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func mutationProgress(target: PersonDossierFocusTarget, snapshot: PersonDossierSnapshot) -> some View {
        if PersonDossierMutationOutcome.progressTarget(model.dossierMutationState, dossierID: snapshot.dossier.id) == target {
            ProgressView("Korrektur wird gespeichert …")
                .font(.caption)
        }
    }

    @MainActor
    private func mutate(
        _ previous: PersonDossierSnapshot,
        outcome: @escaping (PersonDossierSnapshot) -> PersonDossierMutationOutcome,
        operation: @escaping @MainActor () async -> PersonDossierSnapshot?
    ) {
        guard !mutationIsInFlight else { return }
        feedbackContext.perform(dossierID: previous.dossier.id, operation: {
            guard !Task.isCancelled, !mutationIsInFlight,
                  model.workspaceSelection == .dossier(previous.dossier.id),
                  model.dossierDetailState.personSnapshot?.token == previous.token else { return nil }
            return await operation()
        }, publish: { receipt in
            guard PersonDossierMutationOutcome.canPublish(
                after: previous,
                receipt: receipt,
                detail: model.dossierDetailState,
                errorCode: model.lastErrorCode,
                isCancelled: Task.isCancelled
            ), model.workspaceSelection == .dossier(previous.dossier.id) else { return }
            let feedback = outcome(receipt)
            accessibilityFocus = feedback.focus
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: feedback.announcement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        })
    }

    private var errorState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                errorMessage
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
        .accessibilityIdentifier(PersonDossierAccessibilityIdentifier.error)
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

    private var errorMessage: String? {
        PersonDossierMutationOutcome.errorMessage(detail: model.dossierDetailState, errorCode: model.lastErrorCode)
    }
}
