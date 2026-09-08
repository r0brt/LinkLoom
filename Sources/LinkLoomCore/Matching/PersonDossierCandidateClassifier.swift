import Foundation

enum PersonDossierCandidateClassification: Sendable, Equatable {
    case automatic([PersonDossierFindingSupportIdentity])
    case suggestion(
        kind: PersonDossierCandidateKind,
        conflict: PersonDossierConflictState,
        supports: [PersonDossierCandidateSupportIdentity],
        commandSupport: PersonDossierCandidateSupportIdentity
    )
    case hidden
}

struct PersonDossierCandidateClassifier: Sendable {
    func classify(
        _ current: CurrentDocumentDNA,
        for anchor: PersonDossierAnchor
    ) -> PersonDossierCandidateClassification {
        let supports = exactSupports(in: current, matching: anchor.normalizedName)
        let primarySupports = supports.filter { $0.role.isPrimary }
        let conflict = hardBirthDateConflict(in: current.snapshot, for: anchor)

        if conflict == nil, !primarySupports.isEmpty {
            return .automatic(primarySupports)
        }

        if let conflict,
           let commandSupport = primarySupports.first,
           let suggestionSupport = try? PersonDossierCandidateSupportIdentity(
            kind: .birthDateConflict,
            person: commandSupport,
            conflict: conflict
           ) {
            return .suggestion(
                kind: .birthDateConflict,
                conflict: conflict,
                supports: [suggestionSupport],
                commandSupport: suggestionSupport
            )
        }

        let secondarySupports = supports.filter { !$0.role.isPrimary }
        let suggestions = secondarySupports.compactMap {
            try? PersonDossierCandidateSupportIdentity(
                kind: .secondaryRole,
                person: $0,
                conflict: .none
            )
        }
        guard let commandSupport = suggestions.first else {
            return .hidden
        }
        return .suggestion(
            kind: .secondaryRole,
            conflict: .none,
            supports: suggestions,
            commandSupport: commandSupport
        )
    }

    private func exactSupports(
        in current: CurrentDocumentDNA,
        matching normalizedName: String
    ) -> [PersonDossierFindingSupportIdentity] {
        let ordered: [(Int, Int, PersonDossierFindingSupportIdentity)] = current.snapshot.findings
            .enumerated()
            .compactMap { index, finding -> (Int, Int, PersonDossierFindingSupportIdentity)? in
            guard finding.kind == .person,
                  finding.normalizedValue.utf8.elementsEqual(normalizedName.utf8),
                  let role = finding.qualifier.flatMap(PersonDossierRole.init(rawValue:)),
                  let support = try? PersonDossierFindingSupportIdentity(
                    current: current,
                    role: role,
                    finding: finding
                  )
            else {
                return nil
            }
            return (roleIndex(role), index, support)
        }.sorted { lhs, rhs in
            (lhs.0, lhs.1) < (rhs.0, rhs.1)
        }
        return ordered.map(\.2)
    }

    private func hardBirthDateConflict(
        in snapshot: DocumentDNA,
        for anchor: PersonDossierAnchor
    ) -> PersonDossierConflictState? {
        guard let anchorBirthDate = anchor.birthDate else { return nil }
        let primaryPeople = snapshot.findings.filter { finding in
            finding.kind == .person
                && finding.qualifier.flatMap(PersonDossierRole.init(rawValue:))?.isPrimary == true
        }
        let birthDates = snapshot.findings.filter {
            $0.kind == .date && $0.qualifier == DocumentDNADateRole.birthDate.rawValue
        }
        guard primaryPeople.count == 1,
              primaryPeople[0].normalizedValue == anchor.normalizedName,
              birthDates.count == 1,
              birthDates[0].normalizedValue != anchorBirthDate.normalizedValue
        else { return nil }
        return .hardBirthDateConflict(anchor: anchorBirthDate, candidate: birthDates[0])
    }

    private func roleIndex(_ role: PersonDossierRole) -> Int {
        switch role {
        case .resident: 0
        case .insuredPerson: 1
        case .accountHolder: 2
        case .invoiceRecipient: 3
        case .grantor: 4
        case .authorizedPerson: 5
        }
    }
}
