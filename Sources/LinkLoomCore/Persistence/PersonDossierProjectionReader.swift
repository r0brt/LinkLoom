import Foundation
import GRDB

struct PersonDossierProjectionReader: Sendable {
    private let target: DocumentDNAAnalysisTarget
    private let candidateProjector: InvoicePaymentCandidateProjector

    init(
        target: DocumentDNAAnalysisTarget,
        candidateProjector: InvoicePaymentCandidateProjector
    ) {
        self.target = target
        self.candidateProjector = candidateProjector
    }

    func summary(in _: Database, dossier: DossierRecord) throws -> PersonDossierSummary {
        guard dossier.kind == .personMatter,
              case let .person(anchor) = dossier.anchor
        else {
            throw DossierRepositoryError.invalidStoredState
        }
        return PersonDossierSummary(dossier: dossier, anchor: anchor)
    }

    func snapshot(in db: Database, dossier: DossierRecord) throws
        -> PersonDossierSnapshot
    {
        guard dossier.kind == .personMatter,
              case let .person(anchor) = dossier.anchor
        else {
            throw DossierRepositoryError.invalidStoredState
        }

        let originDocument = try DocumentRecord.fetchOne(
            db,
            key: anchor.originDocumentID
        )
        try Task.checkCancellation()
        let personCandidates = try DocumentDNARepository.currentSnapshotsMatchingPerson(
            in: db,
            normalizedName: anchor.normalizedName,
            target: target
        )
        let confirmations = try DossierStore.confirmations(in: db, dossierID: dossier.id)
        let exclusions = try DossierStore.exclusions(in: db, dossierID: dossier.id)
        guard Set(confirmations.map(\.documentID)).isDisjoint(
            with: Set(exclusions.map(\.documentID))
        ) else {
            throw PersonDossierProjectionError.invalidStoredState
        }

        var documentsByID = Dictionary(
            uniqueKeysWithValues: personCandidates.map { ($0.document.id, $0.document) }
        )
        var currentDocumentsByID = Dictionary(
            uniqueKeysWithValues: personCandidates.map { ($0.document.id, $0) }
        )
        if let originDocument {
            documentsByID[originDocument.id] = originDocument
        }
        let currentOrigin: CurrentDocumentDNA?
        if let loaded = currentDocumentsByID[anchor.originDocumentID] {
            currentOrigin = loaded
        } else {
            currentOrigin = try DocumentDNARepository.currentSnapshot(
                in: db,
                documentID: anchor.originDocumentID,
                target: target
            )
            if let currentOrigin {
                currentDocumentsByID[currentOrigin.document.id] = currentOrigin
                documentsByID[currentOrigin.document.id] = currentOrigin.document
            }
        }

        let correctionDocumentIDs = Set(
            confirmations.map(\.documentID) + exclusions.map(\.documentID)
        )
        for documentID in correctionDocumentIDs {
            if documentsByID[documentID] == nil,
               let document = try DocumentRecord.fetchOne(db, key: documentID) {
                documentsByID[documentID] = document
            }
            if currentDocumentsByID[documentID] == nil,
               let current = try DocumentDNARepository.currentSnapshot(
                   in: db,
                   documentID: documentID,
                   target: target
               ) {
                currentDocumentsByID[documentID] = current
                documentsByID[current.document.id] = current.document
            }
        }

        var sourceDisplayNames: [UUID: String] = [:]
        var loadedSourceIDs: Set<UUID> = []
        try loadSourceDisplayNames(
            in: db,
            sourceIDs: Set(documentsByID.values.map(\.sourceRootID)),
            names: &sourceDisplayNames,
            loadedSourceIDs: &loadedSourceIDs
        )

        try Task.checkCancellation()
        let frozen = try PersonDossierProjector().project(
            PersonDossierProjectionInput(
                dossier: dossier,
                originDocument: originDocument,
                currentOrigin: currentOrigin,
                documentsByID: documentsByID,
                currentDocumentsByID: currentDocumentsByID,
                personCandidates: personCandidates,
                relationshipCandidates: [],
                relationshipDecisionsByKey: [:],
                sourceDisplayNames: sourceDisplayNames,
                confirmations: confirmations,
                exclusions: exclusions
            )
        )

        let includedInvoices: [CurrentDocumentDNA] = frozen.costsAndPayments.compactMap { member in
            guard member.documentType == .invoice else { return nil }
            return currentDocumentsByID[member.document.id]
        }
        let references = Set(
            includedInvoices.flatMap(candidateProjector.normalizedReferences(in:))
        ).sorted()
        var matchesByReference: [String: [CurrentDocumentDNA]] = [:]
        for reference in references {
            matchesByReference[reference] = try DocumentDNARepository
                .currentSnapshotsMatchingReference(
                    in: db,
                    normalizedValue: reference,
                    target: target
                )
        }

        var relationshipCandidates: [InvoicePaymentCandidate] = []
        var seenDecisionKeys: Set<InvoicePaymentDecisionKey> = []
        for invoice in includedInvoices {
            let candidates = candidateProjector.candidates(
                from: InvoicePaymentCandidateProjectionInput(
                    selected: invoice,
                    matchesByNormalizedReference: matchesByReference
                )
            )
            for candidate in candidates {
                let key = try InvoicePaymentDecisionKey(candidate: candidate)
                guard seenDecisionKeys.insert(key).inserted else { continue }
                relationshipCandidates.append(candidate)
                for endpoint in [candidate.invoice, candidate.payment] {
                    documentsByID[endpoint.document.id] = endpoint.document
                    currentDocumentsByID[endpoint.document.id] = endpoint
                }
            }
        }
        let relationshipDecisionsByKey = try InvoicePaymentDecisionRepository
            .currentRecords(in: db, keys: Array(seenDecisionKeys))

        try loadSourceDisplayNames(
            in: db,
            sourceIDs: Set(documentsByID.values.map(\.sourceRootID)),
            names: &sourceDisplayNames,
            loadedSourceIDs: &loadedSourceIDs
        )
        try Task.checkCancellation()
        return try PersonDossierProjector().project(
            PersonDossierProjectionInput(
                dossier: dossier,
                originDocument: originDocument,
                currentOrigin: currentOrigin,
                documentsByID: documentsByID,
                currentDocumentsByID: currentDocumentsByID,
                personCandidates: personCandidates,
                relationshipCandidates: relationshipCandidates,
                relationshipDecisionsByKey: relationshipDecisionsByKey,
                sourceDisplayNames: sourceDisplayNames,
                confirmations: confirmations,
                exclusions: exclusions
            )
        )
    }

    func snapshot(in db: Database, dossierID: UUID) throws -> PersonDossierSnapshot {
        guard let dossier = try DossierStore.record(in: db, id: dossierID) else {
            throw DossierRepositoryError.dossierNotFound
        }
        return try snapshot(in: db, dossier: dossier)
    }

    private func loadSourceDisplayNames(
        in db: Database,
        sourceIDs: Set<UUID>,
        names: inout [UUID: String],
        loadedSourceIDs: inout Set<UUID>
    ) throws {
        for sourceID in sourceIDs.subtracting(loadedSourceIDs) {
            loadedSourceIDs.insert(sourceID)
            if let displayName = try String.fetchOne(
                db,
                sql: "SELECT displayName FROM sourceRoot WHERE id = ?",
                arguments: [sourceID]
            ) {
                names[sourceID] = displayName
            }
        }
    }
}
