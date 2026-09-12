import Foundation
import LinkLoomCore

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
    let accessibilityLabel: String

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
        accessibilityLabel = [
            location,
            documentTypeTitle,
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
