import LinkLoomCore

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
        switch role {
        case .resident:
            "Bewohnerin"
        case .insuredPerson:
            "Versicherte Person"
        case .accountHolder:
            "Kontoinhaberin"
        case .invoiceRecipient:
            "Rechnungsempfängerin"
        case .grantor:
            "Vollmachtgeberin"
        case .authorizedPerson:
            "Bevollmächtigte"
        }
    }
}
