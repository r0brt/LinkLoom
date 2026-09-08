import Foundation

public struct PersonDossierAnchorSelection: Sendable, Equatable {
    public let support: PersonDossierFindingSupportIdentity

    public init(
        document: DocumentRecord,
        snapshot: DocumentDNA,
        finding: DocumentDNAFinding
    ) throws {
        do {
            let current = try CurrentDocumentDNA(document: document, snapshot: snapshot)
            guard let role = finding.qualifier.flatMap(PersonDossierRole.init(rawValue:)),
                  role.isPrimary
            else {
                throw DossierValidationError.invalidRecord
            }
            self.support = try PersonDossierFindingSupportIdentity(
                current: current,
                role: role,
                finding: finding
            )
        } catch {
            throw DossierValidationError.invalidRecord
        }
    }
}

public struct PersonDossierSummary: Identifiable, Sendable, Equatable {
    public var id: UUID { dossier.id }
    public let dossier: DossierRecord
    public let anchor: PersonDossierAnchor
}

public enum PersonDossierEntryDisposition: Sendable, Equatable {
    case create
    case open(PersonDossierSummary)
    case choose([PersonDossierSummary])
}

public enum PersonDossierOpenResult: Sendable, Equatable {
    case opened(PersonDossierSnapshot)
    case choose([PersonDossierSummary])
}

public enum PersonDossierCreationChoice: Sendable, Equatable {
    case existing(dossierID: UUID)
    case new
}
