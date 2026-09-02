import Foundation
import GRDB

struct DossierProjectionReader: Sendable {
    private let target: DocumentDNAAnalysisTarget
    private let candidateProjector: InvoicePaymentCandidateProjector

    init(
        target: DocumentDNAAnalysisTarget,
        candidateProjector: InvoicePaymentCandidateProjector
    ) {
        self.target = target
        self.candidateProjector = candidateProjector
    }

    func isEligibleAnchor(in db: Database, documentID: UUID) throws -> Bool {
        guard let current = try DocumentDNARepository.currentSnapshot(
            in: db,
            documentID: documentID,
            target: target
        ) else {
            return false
        }
        return current.documentType == .invoice
            || current.documentType == .paymentConfirmation
    }

    func summary(in db: Database, dossier: DossierRecord) throws -> DossierSummary {
        guard let anchor = try DocumentRecord.fetchOne(
            db,
            key: dossier.anchorDocumentID
        ) else {
            throw DossierRepositoryError.invalidStoredState
        }
        return DossierSummary(dossier: dossier, anchor: anchor)
    }

    func snapshot(in db: Database, dossier: DossierRecord) throws -> DossierSnapshot {
        guard dossier.kind == .costsAndPayments,
              let anchor = try DocumentRecord.fetchOne(
                  db,
                  key: dossier.anchorDocumentID
              )
        else {
            throw DossierRepositoryError.invalidStoredState
        }

        let exclusions = try DossierStore.exclusions(in: db, dossierID: dossier.id)
        var documentsByID = [anchor.id: anchor]
        for exclusion in exclusions {
            if let document = try DocumentRecord.fetchOne(db, key: exclusion.documentID) {
                documentsByID[document.id] = document
            }
        }

        var currentDocumentsByID: [UUID: CurrentDocumentDNA] = [:]
        var candidates: [InvoicePaymentCandidate] = []
        if let currentAnchor = try DocumentDNARepository.currentSnapshot(
            in: db,
            documentID: anchor.id,
            target: target
        ) {
            currentDocumentsByID[currentAnchor.document.id] = currentAnchor
            var matchesByReference: [String: [CurrentDocumentDNA]] = [:]
            for reference in candidateProjector.normalizedReferences(in: currentAnchor) {
                let matches = try DocumentDNARepository.currentSnapshotsMatchingReference(
                    in: db,
                    normalizedValue: reference,
                    target: target
                )
                matchesByReference[reference] = matches
                for match in matches {
                    currentDocumentsByID[match.document.id] = match
                    documentsByID[match.document.id] = match.document
                }
            }
            candidates = candidateProjector.candidates(
                from: InvoicePaymentCandidateProjectionInput(
                    selected: currentAnchor,
                    matchesByNormalizedReference: matchesByReference
                )
            )
        }

        let decisionKeys = try candidates.map(InvoicePaymentDecisionKey.init(candidate:))
        let decisionsByKey = try InvoicePaymentDecisionRepository.currentRecords(
            in: db,
            keys: decisionKeys
        )
        let sourceDisplayNames = try sourceDisplayNames(
            in: db,
            sourceIDs: Set(documentsByID.values.map(\.sourceRootID))
        )
        do {
            return try CostsAndPaymentsDossierProjector().project(
                CostsAndPaymentsDossierProjectionInput(
                    dossier: dossier,
                    anchor: anchor,
                    documentsByID: documentsByID,
                    currentDocumentsByID: currentDocumentsByID,
                    candidates: candidates,
                    decisionsByKey: decisionsByKey,
                    sourceDisplayNames: sourceDisplayNames,
                    exclusions: exclusions
                )
            )
        } catch DossierProjectionError.invalidStoredState {
            throw DossierRepositoryError.invalidStoredState
        }
    }

    func snapshot(in db: Database, dossierID: UUID) throws -> DossierSnapshot {
        guard let dossier = try DossierStore.record(in: db, id: dossierID) else {
            throw DossierRepositoryError.dossierNotFound
        }
        return try snapshot(in: db, dossier: dossier)
    }

    private func sourceDisplayNames(
        in db: Database,
        sourceIDs: Set<UUID>
    ) throws -> [UUID: String] {
        var names: [UUID: String] = [:]
        for sourceID in sourceIDs {
            if let name = try String.fetchOne(
                db,
                sql: "SELECT displayName FROM sourceRoot WHERE id = ?",
                arguments: [sourceID]
            ) {
                names[sourceID] = name
            }
        }
        return names
    }
}
