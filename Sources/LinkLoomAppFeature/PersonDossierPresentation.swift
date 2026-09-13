import Combine
import Foundation
import LinkLoomCore

struct PersonDossierEntryInput: Equatable {
    let documentID: UUID?
    let snapshot: DocumentDNA?
    let workspaceSelection: AppWorkspaceSelection?

    init(
        documentID: UUID?,
        snapshot: DocumentDNA?,
        workspaceSelection: AppWorkspaceSelection? = nil
    ) {
        self.documentID = documentID
        self.snapshot = snapshot
        self.workspaceSelection = workspaceSelection
    }
}

struct PersonDossierEntryResult {
    let choices: [PersonDossierSummary]
    let errorCode: String?
}

/// Owns only Inspector feedback; AppModel remains authoritative for mutations.
@MainActor
final class PersonDossierEntryContext: ObservableObject {
    static let errorAccessibilityIdentifier = "document-dna.person-dossier.error"

    @Published private(set) var pendingSelection: PersonDossierAnchorSelection?
    @Published private(set) var choices: [PersonDossierSummary] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPending = false
    private var input: PersonDossierEntryInput?
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    func observeInput(_ input: PersonDossierEntryInput) {
        guard self.input != input else { return }
        invalidate()
        self.input = input
    }

    func observeAuthoritativeChoices(_ authoritativeChoices: [PersonDossierSummary]) {
        guard !isPending, !choices.isEmpty, choices != authoritativeChoices else { return }
        invalidate()
    }

    func invalidate() {
        requestID = nil
        task?.cancel()
        task = nil
        pendingSelection = nil
        choices = []
        errorMessage = nil
        isPending = false
    }

    @discardableResult
    func perform(
        selection: PersonDossierAnchorSelection,
        operation: @escaping @MainActor () async -> PersonDossierEntryResult
    ) -> Task<Void, Never> {
        task?.cancel()
        let requestID = UUID()
        self.requestID = requestID
        if pendingSelection != selection { choices = [] }
        pendingSelection = selection
        errorMessage = nil
        isPending = true
        let task = Task { [weak self] in
            let result = await operation()
            guard let self, self.requestID == requestID, !Task.isCancelled else { return }
            self.choices = result.choices
            self.errorMessage = result.errorCode == "dossierOpenFailure"
                ? "Das Hauptdossier konnte nicht geöffnet werden. Bitte versuche es erneut."
                : nil
            if self.choices.isEmpty && self.errorMessage == nil {
                self.pendingSelection = nil
            }
            self.isPending = false
            self.requestID = nil
            self.task = nil
        }
        self.task = task
        return task
    }
}

enum WorkspaceDossierSidebarItem: Identifiable, Equatable {
    case costs(DossierSummary)
    case person(PersonDossierSummary)

    var id: UUID { dossier.id }

    var dossier: DossierRecord {
        switch self {
        case .costs(let summary): summary.dossier
        case .person(let summary): summary.dossier
        }
    }

    var subtitle: String {
        switch self {
        case .costs(let summary): summary.anchor.relativePath
        case .person(let summary): summary.anchor.displayName
        }
    }

    static func items(
        costs: [DossierSummary],
        people: [PersonDossierSummary]
    ) -> [Self] {
        (costs.map { Self.costs($0) } + people.map { Self.person($0) }).sorted { lhs, rhs in
            if lhs.dossier.createdAt != rhs.dossier.createdAt {
                return lhs.dossier.createdAt < rhs.dossier.createdAt
            }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }
}

enum DossierWorkspaceViewKind: Equatable {
    case costsAndPayments
    case personMatter

    init(
        selection: AppWorkspaceSelection?,
        detail: DossierDetailState,
        personSummaries: [PersonDossierSummary]
    ) {
        guard case let .dossier(dossierID) = selection else {
            self = .costsAndPayments
            return
        }
        switch detail.workspaceSnapshot {
        case let .personMatter(snapshot)?:
            self = snapshot.dossier.id == dossierID
                || personSummaries.contains(where: { $0.id == dossierID })
                ? .personMatter
                : .costsAndPayments
        case let .costsAndPayments(snapshot)?:
            self = snapshot.dossier.id == dossierID
                ? .costsAndPayments
                : personSummaries.contains(where: { $0.id == dossierID })
                    ? .personMatter
                    : .costsAndPayments
        case nil:
            self = personSummaries.contains(where: { $0.id == dossierID })
                ? .personMatter
                : .costsAndPayments
        }
    }
}

struct PersonDossierAnchorPresentation: Equatable {
    let displayName: String
    let roleTitle: String
    let evidenceValidityTitle: String
    let sourceAvailabilityTitle: String?
    let accessibilityLabel: String

    init(snapshot: PersonDossierSnapshot) {
        displayName = snapshot.anchor.displayName
        roleTitle = PersonDossierPresentationTitle.role(for: snapshot.anchor.primaryRole)
        evidenceValidityTitle = switch snapshot.origin.validity {
        case .current: "Ursprungsnachweis aktuell"
        case .stale: "Ursprungsnachweis veraltet"
        case .unavailable: "Ursprungsnachweis nicht verfügbar"
        }
        sourceAvailabilityTitle = snapshot.origin.document.map {
            DossierMemberPresentation.availabilityTitle(for: $0.availability)
        }
        accessibilityLabel = [
            displayName,
            "Rolle: \(roleTitle).",
            evidenceValidityTitle,
            sourceAvailabilityTitle,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

struct PersonDossierMemberPresentation: Equatable {
    let documentID: UUID
    let location: String
    let documentTypeTitle: String
    let availabilityTitle: String
    let membershipRoleTitle: String
    let reasons: [String]
    let reasonAccessibilityIdentifiers: [String]
    let preferredCounterpartDocumentID: UUID?
    let documentSummaryAccessibilityLabel: String

    init(
        member: PersonDossierMember,
        selectedSourceID: UUID?,
        documents: [UUID: DocumentRecord]
    ) {
        documentID = member.id
        location = member.document.sourceRootID == selectedSourceID
            ? member.document.relativePath
            : "\(member.sourceDisplayName) · \(member.document.relativePath)"
        documentTypeTitle = member.documentType.map(DocumentDNADetailPresentation.title)
            ?? "Nicht verfügbar"
        availabilityTitle = DossierMemberPresentation.availabilityTitle(
            for: member.document.availability
        )
        membershipRoleTitle = switch member.section {
        case .directDocuments: "Direktes Dokument"
        case .costsAndPayments: "Kosten oder Zahlung"
        }
        reasons = member.supports.flatMap { support in
            Self.reasonTexts(for: support, documents: documents)
        }
        reasonAccessibilityIdentifiers = reasons.indices.map {
            PersonDossierAccessibilityIdentifier.reason(member.id, ordinal: $0)
        }
        preferredCounterpartDocumentID = member.preferredPaymentSupport?.invoiceDocumentID
        documentSummaryAccessibilityLabel = [
            location,
            "Dokumenttyp: \(documentTypeTitle)",
            availabilityTitle,
            membershipRoleTitle,
            reasons.joined(separator: " "),
        ]
        .joined(separator: ". ")
    }

    private static func reasonTexts(
        for support: PersonDossierMembershipSupport,
        documents: [UUID: DocumentRecord]
    ) -> [String] {
        switch support {
        case .exactPrimary(let finding):
            return [
                "Der Name ‹\(finding.finding.displayValue)› stimmt exakt mit dem Personenanker überein. Rolle: \(PersonDossierPresentationTitle.role(for: finding.role)).",
            ]
        case .manualConfirmation(_, let currentCandidate):
            return currentCandidate == nil
                ? [
                    "Von dir aus einem Vorschlag aufgenommen.",
                    "Der ursprüngliche Vorschlagsnachweis ist nicht mehr aktuell.",
                ]
                : ["Von dir aus einem Vorschlag aufgenommen."]
        case .confirmedPayment(let payment):
            let invoicePath = documents[payment.invoiceDocumentID]?.relativePath
                ?? "Rechnung"
            let basis = switch payment.invoiceMembershipBasis {
            case .exactPerson:
                "Der Name der Rechnung stimmt exakt mit dem Personenanker überein."
            case .manualConfirmation:
                "Die Rechnung wurde aus einem Vorschlag aufgenommen."
            }
            let signals = payment.signals.flatMap { signal in
                let presentation = InvoicePaymentSignalPresentation(signal: signal)
                return ["\(presentation.title): \(presentation.comparison)"]
            }
            return ["Zahlung über die Rechnung ‹\(invoicePath)›. \(basis)"] + signals
        }
    }
}

enum PersonDossierAccessibilityIdentifier {
    static let workspace = "dossier.person.workspace"
    static let anchor = "dossier.person.anchor"
    static let directMembers = "dossier.person.direct-members"
    static let costs = "dossier.person.costs"
    static let suggestions = "dossier.person.suggestions"
    static let corrections = "dossier.person.corrections"
    static let error = "dossier.person.error"

    static func suggestion(_ id: UUID) -> String {
        "dossier.person.suggestion.\(persistedString(id))"
    }

    static func acceptSuggestion(_ id: UUID) -> String {
        "dossier.person.suggestion.accept.\(persistedString(id))"
    }

    static func rejectSuggestion(_ id: UUID) -> String {
        "dossier.person.suggestion.reject.\(persistedString(id))"
    }

    static func correction(_ id: UUID) -> String {
        "dossier.person.correction.\(persistedString(id))"
    }

    static func resetCorrection(_ id: UUID) -> String {
        "dossier.person.correction.reset.\(persistedString(id))"
    }

    static func member(_ documentID: UUID) -> String {
        "dossier.person.member.\(persistedString(documentID))"
    }

    static func removeMember(_ documentID: UUID) -> String {
        "dossier.person.member.remove.\(persistedString(documentID))"
    }

    static func counterpart(_ documentID: UUID) -> String {
        "\(member(documentID)).counterpart"
    }

    static func reason(_ documentID: UUID, ordinal: Int) -> String {
        "\(member(documentID)).reason.\(ordinal)"
    }

    private static func persistedString(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

struct PersonDossierSuggestionPresentation: Equatable {
    let location: String
    let documentTypeTitle: String
    let availabilityTitle: String
    let roleTitle: String
    let reason: String
    let accessibilityLabel: String

    init(suggestion: PersonDossierSuggestion, selectedSourceID: UUID?) {
        location = suggestion.document.sourceRootID == selectedSourceID
            ? suggestion.document.relativePath
            : "\(suggestion.sourceDisplayName) · \(suggestion.document.relativePath)"
        documentTypeTitle = suggestion.documentType.map(DocumentDNADetailPresentation.title)
            ?? "Nicht verfügbar"
        availabilityTitle = DossierMemberPresentation.availabilityTitle(for: suggestion.document.availability)
        roleTitle = PersonDossierPresentationTitle.role(for: suggestion.commandSupport.person.role)
        reason = switch suggestion.kind {
        case .secondaryRole:
            "Der Name stimmt exakt, erscheint aber nur in der Rolle \(roleTitle)."
        case .birthDateConflict:
            "Der Name stimmt, aber dieses Dokument nennt ein anderes Geburtsdatum."
        }
        accessibilityLabel = "\(location). Dokumenttyp: \(documentTypeTitle). \(availabilityTitle). \(suggestion.commandSupport.person.finding.displayValue), Rolle: \(roleTitle). \(reason) Aufnehmen oder ablehnen."
    }
}

struct PersonDossierCorrectionPresentation: Equatable {
    let location: String
    let documentTypeTitle: String
    let availabilityTitle: String
    let decisionTitle: String
    let resetTitle: String
    let accessibilityLabel: String

    init(correction: PersonDossierCorrection, selectedSourceID: UUID?) {
        location = correction.document.sourceRootID == selectedSourceID
            ? correction.document.relativePath
            : "\(correction.sourceDisplayName) · \(correction.document.relativePath)"
        documentTypeTitle = correction.documentType.map(DocumentDNADetailPresentation.title)
            ?? "Nicht verfügbar"
        availabilityTitle = DossierMemberPresentation.availabilityTitle(for: correction.document.availability)
        switch correction.decision {
        case .confirmation:
            decisionTitle = "Von dir aufgenommen"
            resetTitle = "Aufnahme zurücksetzen"
        case .exclusion:
            decisionTitle = "Von dir ausgeschlossen"
            resetTitle = "Ausschluss zurücksetzen"
        }
        accessibilityLabel = "\(location). Dokumenttyp: \(documentTypeTitle). \(availabilityTitle). \(decisionTitle). \(resetTitle)."
    }
}

enum PersonDossierSectionFocus: Hashable {
    case suggestions, corrections
}

enum PersonDossierFocusTarget: Hashable {
    case workspace
    case member(UUID)
    case suggestion(UUID)
    case correction(UUID)
    case section(PersonDossierSectionFocus)
}

@MainActor
final class PersonDossierFeedbackContext {
    private var requestID: UUID?
    private var dossierID: UUID?
    private var task: Task<Void, Never>?

    func invalidate() {
        requestID = nil
        dossierID = nil
        task?.cancel()
        task = nil
    }

    func observeSelection(_ selection: AppWorkspaceSelection?) {
        if let dossierID, selection != .dossier(dossierID) {
            invalidate()
        }
    }

    func observeDetail(_ detail: DossierDetailState) {
        if case .loading = detail { invalidate() }
    }

    @discardableResult
    func perform(
        dossierID: UUID,
        operation: @escaping @MainActor () async -> PersonDossierSnapshot?,
        publish: @escaping @MainActor (PersonDossierSnapshot) -> Void
    ) -> Task<Void, Never> {
        invalidate()
        let id = UUID()
        requestID = id
        self.dossierID = dossierID
        let pending = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let receipt = await operation()
            guard let self, self.requestID == id else { return }
            defer {
                if self.requestID == id {
                    self.requestID = nil
                    self.dossierID = nil
                    self.task = nil
                }
            }
            guard !Task.isCancelled, let receipt else { return }
            publish(receipt)
        }
        task = pending
        return pending
    }
}

struct PersonDossierMutationOutcome: Equatable {
    let focus: PersonDossierFocusTarget
    let announcement: String

    static func accepted(_ id: UUID, in snapshot: PersonDossierSnapshot) -> Self {
        Self(focus: memberExists(id, in: snapshot) ? .member(id) : .section(.suggestions), announcement: "Dokument aufgenommen.")
    }

    static func rejected(_ id: UUID, in snapshot: PersonDossierSnapshot) -> Self {
        Self(focus: correctionFocus(id, in: snapshot), announcement: "Vorschlag abgelehnt.")
    }

    static func removed(_ id: UUID, in snapshot: PersonDossierSnapshot) -> Self {
        Self(focus: correctionFocus(id, in: snapshot), announcement: "Dokument aus dem Dossier entfernt.")
    }

    static func reset(_ id: UUID, in snapshot: PersonDossierSnapshot) -> Self {
        let focus: PersonDossierFocusTarget
        if memberExists(id, in: snapshot) {
            focus = .member(id)
        } else if snapshot.suggestions.contains(where: { $0.id == id }) {
            focus = .suggestion(id)
        } else {
            focus = .section(.corrections)
        }
        return Self(focus: focus, announcement: "Korrektur zurückgesetzt.")
    }

    static func canPublish(
        after previous: PersonDossierSnapshot,
        receipt: PersonDossierSnapshot?,
        detail: DossierDetailState,
        errorCode: String?,
        isCancelled: Bool
    ) -> Bool {
        guard !isCancelled, errorCode == nil, let receipt,
              case let .available(.personMatter(current)) = detail else { return false }
        return receipt == current
            && receipt.dossier.id == previous.dossier.id
            && receipt.token != previous.token
    }

    static func errorMessage(detail: DossierDetailState, errorCode: String?) -> String? {
        if errorCode == "dossierMutationFailure" {
            return "Die Dossier-Korrektur konnte nicht gespeichert werden. Bitte aktualisiere das Hauptdossier und versuche es erneut."
        }
        if case .failed = detail {
            return "Das Hauptdossier konnte nicht geladen werden. Bitte versuche es erneut."
        }
        return nil
    }

    static func isActive(_ state: DossierMutationState, dossierID: UUID, documentID: UUID) -> Bool {
        switch state {
        case let .acceptingPerson(dossier, document), let .rejectingPerson(dossier, document),
             let .removingPerson(dossier, document), let .resettingPerson(dossier, document):
            dossier == dossierID && document == documentID
        default: false
        }
    }

    static func progressTarget(_ state: DossierMutationState, dossierID: UUID) -> PersonDossierFocusTarget? {
        let documentID: UUID
        let target: PersonDossierFocusTarget
        switch state {
        case let .acceptingPerson(_, id), let .rejectingPerson(_, id):
            documentID = id
            target = .suggestion(id)
        case let .removingPerson(_, id):
            documentID = id
            target = .member(id)
        case let .resettingPerson(_, id):
            documentID = id
            target = .correction(id)
        default:
            return nil
        }
        return isActive(state, dossierID: dossierID, documentID: documentID) ? target : nil
    }

    private static func memberExists(_ id: UUID, in snapshot: PersonDossierSnapshot) -> Bool {
        (snapshot.directMembers + snapshot.costsAndPayments).contains { $0.id == id }
    }

    private static func correctionFocus(_ id: UUID, in snapshot: PersonDossierSnapshot) -> PersonDossierFocusTarget {
        snapshot.corrections.contains { $0.id == id } ? .correction(id) : .section(.corrections)
    }
}

private enum PersonDossierPresentationTitle {
    static func role(for role: PersonDossierRole) -> String {
        switch role {
        case .resident: "Bewohnerin"
        case .insuredPerson: "Versicherte Person"
        case .accountHolder: "Kontoinhaberin"
        case .invoiceRecipient: "Rechnungsempfängerin"
        case .grantor: "Vollmachtgeberin"
        case .authorizedPerson: "Bevollmächtigte"
        }
    }
}

struct PersonDossierEntryPresentation: Identifiable, Equatable {
    var id: Int { ordinal }

    let ordinal: Int
    let findingIndex: Int
    let displayName: String
    let roleTitle: String
    let actionTitle: String
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let selection: PersonDossierAnchorSelection

    static func entries(
        document: DocumentRecord,
        snapshot: DocumentDNA,
        summaries: [PersonDossierSummary]
    ) -> [Self] {
        let eligible: [(Int, DocumentDNAFinding, PersonDossierAnchorSelection)] = snapshot.findings
            .enumerated()
            .compactMap { item in
                let (findingIndex, finding) = item
                guard finding.kind == .person,
                      let selection = try? PersonDossierAnchorSelection(
                          document: document,
                          snapshot: snapshot,
                          finding: finding
                      )
                else {
                    return nil
                }
                return (findingIndex, finding, selection)
            }
        return eligible.enumerated().map { item in
            let (ordinal, candidate) = item
            let (findingIndex, finding, selection) = candidate
            let roleTitle = roleTitle(for: selection.support.role)
            let opensExisting = summaries.contains { summary in
                summary.anchor.originDocumentID == selection.support.documentID
                    && summary.anchor.primaryRole == selection.support.role
                    && summary.anchor.normalizedName == selection.support.normalizedName
            }
            let actionTitle = opensExisting
                ? "Hauptdossier öffnen"
                : "Hauptdossier erstellen"
            return Self(
                ordinal: ordinal,
                findingIndex: findingIndex,
                displayName: finding.displayValue,
                roleTitle: roleTitle,
                actionTitle: actionTitle,
                accessibilityIdentifier: "document-dna.person-dossier.\(ordinal)",
                accessibilityLabel: "\(actionTitle) für \(finding.displayValue) Rolle \(roleTitle)",
                selection: selection
            )
        }
    }

    private static func roleTitle(for role: PersonDossierRole) -> String {
        PersonDossierPresentationTitle.role(for: role)
    }
}

enum PersonDossierEntryInteractionPresentation {
    static func actionIsDisabled(
        mutationState: DossierMutationState,
        hasUnresolvedChoice: Bool
    ) -> Bool {
        if hasUnresolvedChoice {
            return true
        }
        if case .openingPerson = mutationState {
            return true
        }
        return false
    }
}
