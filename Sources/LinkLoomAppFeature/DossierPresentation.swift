import Foundation
import LinkLoomCore

struct DossierMemberPresentation: Equatable {
    let roleTitle: String
    let documentTypeTitle: String
    let location: String
    let availabilityTitle: String
    let signals: [InvoicePaymentSignalPresentation]

    init(member: DossierMember, selectedSourceID: UUID?) {
        roleTitle = switch member.explanation.role {
        case .anchor:
            "Ankerdokument"
        case .invoice:
            "Rechnung"
        case .payment:
            "Zahlung"
        }
        documentTypeTitle = member.documentType.map(
            DocumentDNADetailPresentation.title
        ) ?? "Nicht verfügbar"
        location = if member.document.sourceRootID == selectedSourceID {
            member.document.relativePath
        } else {
            "\(member.sourceDisplayName) · \(member.document.relativePath)"
        }
        availabilityTitle = Self.availabilityTitle(
            for: member.document.availability
        )
        signals = member.explanation.signals.map(
            InvoicePaymentSignalPresentation.init
        )
    }

    static func availabilityTitle(for availability: DocumentAvailability) -> String {
        switch availability {
        case .available:
            "Verfügbar"
        case .unavailable:
            "Vorübergehend nicht verfügbar"
        case .missing:
            "Fehlt"
        }
    }
}

struct DossierEntryPresentation: Equatable {
    let actionTitle: String

    init(disposition: DossierEntryDisposition) {
        actionTitle = switch disposition {
        case .create:
            "Dossier erstellen"
        case .open:
            "Dossier öffnen"
        case .choose:
            "Dossier auswählen"
        }
    }
}

enum DossierAccessibilityIdentifier {
    static func row(_ dossierID: UUID) -> String {
        "dossier.row.\(persistedString(dossierID))"
    }

    static func member(_ documentID: UUID) -> String {
        "dossier.member.\(persistedString(documentID))"
    }

    static func removeMember(_ documentID: UUID) -> String {
        "dossier.member.remove.\(persistedString(documentID))"
    }

    static func correction(_ documentID: UUID) -> String {
        "dossier.correction.\(persistedString(documentID))"
    }

    static func resetCorrection(_ documentID: UUID) -> String {
        "dossier.correction.reset.\(persistedString(documentID))"
    }

    private static func persistedString(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}
