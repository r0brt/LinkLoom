import Foundation
import GRDB

public actor DossierRepository {
    private let dbWriter: any DatabaseWriter
    private nonisolated let projectionReader: DossierProjectionReader
    private nonisolated let personProjectionReader: PersonDossierProjectionReader
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    public init(
        dbWriter: any DatabaseWriter,
        target: DocumentDNAAnalysisTarget,
        resolver: InvoicePaymentCandidateResolver = InvoicePaymentCandidateResolver(),
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.dbWriter = dbWriter
        projectionReader = DossierProjectionReader(
            target: target,
            candidateProjector: InvoicePaymentCandidateProjector(resolver: resolver)
        )
        personProjectionReader = PersonDossierProjectionReader(
            target: target,
            candidateProjector: InvoicePaymentCandidateProjector(resolver: resolver)
        )
        self.now = now
        self.makeUUID = makeUUID
    }

    public func summaries() async throws -> [DossierSummary] {
        do {
            return try await dbWriter.read { db in
                try DossierStore.all(in: db).filter {
                    $0.kind == .costsAndPayments
                }.map {
                    try self.projectionReader.summary(in: db, dossier: $0)
                }
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func personDossierSummaries() async throws -> [PersonDossierSummary] {
        do {
            return try await dbWriter.read { db in
                try DossierStore.all(in: db).filter {
                    $0.kind == .personMatter
                }.map {
                    try self.personProjectionReader.summary(in: db, dossier: $0)
                }
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func personDossierEntryDisposition(
        for selection: PersonDossierAnchorSelection
    ) async throws -> PersonDossierEntryDisposition {
        do {
            return try await dbWriter.read { db in
                let validated = try self.personProjectionReader.currentSelection(
                    in: db,
                    selection: selection
                )
                if let stable = try self.stablePersonSummary(
                    in: db,
                    support: validated.support
                ) {
                    return .open(stable)
                }
                let choices = try self.personChoices(
                    in: db,
                    normalizedName: validated.support.normalizedName
                )
                return choices.isEmpty ? .create : .choose(choices)
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func createOrOpenPersonDossier(
        from selection: PersonDossierAnchorSelection
    ) async throws -> PersonDossierOpenResult {
        let proposedAnchorID = makeUUID()
        let proposedDossierID = makeUUID()
        let timestamp = now()
        do {
            return try await dbWriter.write { db in
                let validated = try self.personProjectionReader.currentSelection(
                    in: db,
                    selection: selection
                )
                if let stable = try self.stablePersonSummary(
                    in: db,
                    support: validated.support
                ) {
                    return .opened(try self.personProjectionReader.snapshot(
                        in: db,
                        dossier: stable.dossier
                    ))
                }
                let choices = try self.personChoices(
                    in: db,
                    normalizedName: validated.support.normalizedName
                )
                guard choices.isEmpty else {
                    return .choose(choices)
                }
                return .opened(try self.createPersonDossier(
                    in: db,
                    current: validated.current,
                    support: validated.support,
                    proposedAnchorID: proposedAnchorID,
                    proposedDossierID: proposedDossierID,
                    timestamp: timestamp
                ))
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func chooseOrCreatePersonDossier(
        from selection: PersonDossierAnchorSelection,
        choice: PersonDossierCreationChoice
    ) async throws -> PersonDossierSnapshot {
        let proposedAnchorID = makeUUID()
        let proposedDossierID = makeUUID()
        let timestamp = now()
        do {
            return try await dbWriter.write { db in
                let validated = try self.personProjectionReader.currentSelection(
                    in: db,
                    selection: selection
                )
                let stable = try self.stablePersonSummary(
                    in: db,
                    support: validated.support
                )
                switch choice {
                case .existing(let dossierID):
                    guard stable == nil else {
                        throw DossierRepositoryError.staleInput
                    }
                    let choices = try self.personChoices(
                        in: db,
                        normalizedName: validated.support.normalizedName
                    )
                    guard let selected = choices.first(where: { $0.id == dossierID }) else {
                        throw DossierRepositoryError.staleInput
                    }
                    return try self.personProjectionReader.snapshot(
                        in: db,
                        dossier: selected.dossier
                    )
                case .new:
                    if let stable {
                        return try self.personProjectionReader.snapshot(
                            in: db,
                            dossier: stable.dossier
                        )
                    }
                    return try self.createPersonDossier(
                        in: db,
                        current: validated.current,
                        support: validated.support,
                        proposedAnchorID: proposedAnchorID,
                        proposedDossierID: proposedDossierID,
                        timestamp: timestamp
                    )
                }
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func entryDisposition(
        for documentID: UUID
    ) async throws -> DossierEntryDisposition {
        do {
            return try await dbWriter.read { db in
                guard try self.projectionReader.isEligibleAnchor(
                    in: db,
                    documentID: documentID
                ) else {
                    throw DossierRepositoryError.invalidAnchor
                }
                let dossiers = try DossierStore.all(in: db).filter {
                    $0.kind == .costsAndPayments
                }
                if let anchored = dossiers.first(where: {
                    $0.documentAnchorID == documentID
                }) {
                    return .open(try self.projectionReader.summary(
                        in: db,
                        dossier: anchored
                    ))
                }
                let matches = try self.matchingSummaries(
                    in: db,
                    documentID: documentID,
                    dossiers: dossiers
                )
                switch matches.count {
                case 0: return .create
                case 1: return .open(matches[0])
                default: return .choose(matches)
                }
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func createOrOpen(
        anchorDocumentID: UUID
    ) async throws -> DossierOpenResult {
        let proposedID = makeUUID()
        let timestamp = now()
        do {
            return try await dbWriter.write { db in
                guard try self.projectionReader.isEligibleAnchor(
                    in: db,
                    documentID: anchorDocumentID
                ) else {
                    throw DossierRepositoryError.invalidAnchor
                }
                let dossiers = try DossierStore.all(in: db).filter {
                    $0.kind == .costsAndPayments
                }
                if let anchored = dossiers.first(where: {
                    $0.documentAnchorID == anchorDocumentID
                }) {
                    return .opened(try self.projectionReader.snapshot(
                        in: db,
                        dossier: anchored
                    ))
                }
                let matches = try self.matchingSummaries(
                    in: db,
                    documentID: anchorDocumentID,
                    dossiers: dossiers
                )
                if matches.count == 1, let match = matches.first {
                    return .opened(try self.projectionReader.snapshot(
                        in: db,
                        dossierID: match.id
                    ))
                }
                if matches.count > 1 {
                    return .choose(matches)
                }
                let proposed = try DossierRecord(
                    id: proposedID,
                    kind: .costsAndPayments,
                    displayName: "Kosten und Zahlungen",
                    anchorDocumentID: anchorDocumentID,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
                let stored = try DossierStore.insertOrFetchAnchored(
                    in: db,
                    proposed: proposed
                )
                return .opened(try self.projectionReader.snapshot(
                    in: db,
                    dossier: stored
                ))
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func snapshot(id: UUID) async throws -> DossierSnapshot {
        do {
            return try await dbWriter.read { db in
                try self.projectionReader.snapshot(in: db, dossierID: id)
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func personDossierSnapshot(id: UUID) async throws -> PersonDossierSnapshot {
        do {
            return try await dbWriter.read { db in
                try self.personProjectionReader.snapshot(in: db, dossierID: id)
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func acceptPersonSuggestion(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: PersonDossierCandidateSupportIdentity,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot {
        let makeUUID = self.makeUUID
        let now = self.now
        do {
            return try await dbWriter.write { db in
                try Task.checkCancellation()
                guard let dossier = try DossierStore.record(in: db, id: dossierID) else {
                    throw DossierRepositoryError.dossierNotFound
                }
                let snapshot = try self.personProjectionReader.snapshot(
                    in: db,
                    dossier: dossier
                )
                guard snapshot.token == expectedToken,
                      let suggestion = snapshot.suggestions.first(where: {
                          $0.document.id == documentID
                      }),
                      suggestion.commandSupport == expectedSupport
                else {
                    throw DossierRepositoryError.staleInput
                }
                let person = expectedSupport.person
                let confirmation = try DossierMembershipConfirmation(
                    dossierID: dossierID,
                    documentID: documentID,
                    revisionID: makeUUID(),
                    confirmedAt: now(),
                    candidateKind: expectedSupport.kind,
                    acceptedContentHash: person.contentHash,
                    acceptedExtractionVersion: person.extractionVersion,
                    acceptedDNASchemaVersion: person.dnaSchemaVersion,
                    acceptedDNAAnalyzerIdentifier: person.dnaAnalyzerIdentifier,
                    acceptedDNAAnalyzerVersion: person.dnaAnalyzerVersion,
                    acceptedDNAAnalyzedAt: person.dnaAnalyzedAt,
                    acceptedRole: person.role,
                    acceptedNormalizedName: person.normalizedName
                )
                do {
                    try DossierStore.insertConfirmation(in: db, confirmation: confirmation)
                } catch let error as DatabaseError
                    where error.extendedResultCode == .SQLITE_CONSTRAINT_PRIMARYKEY
                        || error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
                {
                    throw DossierRepositoryError.staleInput
                }
                try Task.checkCancellation()
                return try self.personProjectionReader.snapshot(in: db, dossier: dossier)
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func rejectPersonSuggestion(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: PersonDossierCandidateSupportIdentity,
        expectedToken: PersonDossierProjectionToken
    ) async throws -> PersonDossierSnapshot {
        let makeUUID = self.makeUUID
        let now = self.now
        do {
            return try await dbWriter.write { db in
                try Task.checkCancellation()
                guard let dossier = try DossierStore.record(in: db, id: dossierID) else {
                    throw DossierRepositoryError.dossierNotFound
                }
                let snapshot = try self.personProjectionReader.snapshot(
                    in: db,
                    dossier: dossier
                )
                guard snapshot.token == expectedToken,
                      let suggestion = snapshot.suggestions.first(where: {
                          $0.document.id == documentID
                      }),
                      suggestion.commandSupport == expectedSupport
                else {
                    throw DossierRepositoryError.staleInput
                }
                let exclusion = DossierMembershipExclusion(
                    dossierID: dossierID,
                    documentID: documentID,
                    revisionID: makeUUID(),
                    excludedAt: now()
                )
                do {
                    try DossierStore.insertExclusion(in: db, exclusion: exclusion)
                } catch let error as DatabaseError
                    where error.extendedResultCode == .SQLITE_CONSTRAINT_PRIMARYKEY
                        || error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
                {
                    throw DossierRepositoryError.staleInput
                }
                try Task.checkCancellation()
                return try self.personProjectionReader.snapshot(in: db, dossier: dossier)
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func excludeMember(
        dossierID: UUID,
        documentID: UUID,
        expectedSupport: DossierMembershipSupportIdentity
    ) async throws -> DossierSnapshot {
        let makeUUID = self.makeUUID
        let now = self.now
        do {
            return try await dbWriter.write { db in
                guard let dossier = try DossierStore.record(in: db, id: dossierID) else {
                    throw DossierRepositoryError.dossierNotFound
                }
                let snapshot = try self.projectionReader.snapshot(
                    in: db,
                    dossier: dossier
                )
                guard let current = snapshot.members.first(where: {
                    $0.document.id == documentID && $0.support == expectedSupport
                }), current.explanation.role != .anchor else {
                    throw DossierRepositoryError.staleInput
                }
                let exclusion = DossierMembershipExclusion(
                    dossierID: dossierID,
                    documentID: documentID,
                    revisionID: makeUUID(),
                    excludedAt: now()
                )
                do {
                    try DossierStore.insertExclusion(in: db, exclusion: exclusion)
                } catch let error as DatabaseError
                    where error.extendedResultCode == .SQLITE_CONSTRAINT_PRIMARYKEY
                        || error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
                {
                    throw DossierRepositoryError.staleInput
                }
                return try self.projectionReader.snapshot(in: db, dossier: dossier)
            }
        } catch {
            throw mappedError(error)
        }
    }

    public func resetExclusion(
        dossierID: UUID,
        documentID: UUID,
        expectedRevisionID: UUID
    ) async throws -> DossierSnapshot {
        do {
            return try await dbWriter.write { db in
                guard let dossier = try DossierStore.record(in: db, id: dossierID) else {
                    throw DossierRepositoryError.dossierNotFound
                }
                let snapshot = try self.projectionReader.snapshot(
                    in: db,
                    dossier: dossier
                )
                guard snapshot.corrections.contains(where: {
                    $0.document.id == documentID
                        && $0.exclusion.revisionID == expectedRevisionID
                }), try DossierStore.deleteExclusion(
                    in: db,
                    dossierID: dossierID,
                    documentID: documentID,
                    expectedRevisionID: expectedRevisionID
                ) else {
                    throw DossierRepositoryError.staleInput
                }
                return try self.projectionReader.snapshot(in: db, dossier: dossier)
            }
        } catch {
            throw mappedError(error)
        }
    }

    private nonisolated func matchingSummaries(
        in db: Database,
        documentID: UUID,
        dossiers: [DossierRecord]
    ) throws -> [DossierSummary] {
        var matches: [DossierSummary] = []
        for dossier in dossiers {
            let snapshot = try projectionReader.snapshot(in: db, dossier: dossier)
            guard snapshot.members.contains(where: { $0.id == documentID }) else {
                continue
            }
            matches.append(try projectionReader.summary(in: db, dossier: dossier))
        }
        return matches.sorted {
            if $0.dossier.createdAt != $1.dossier.createdAt {
                return $0.dossier.createdAt < $1.dossier.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private nonisolated func stablePersonSummary(
        in db: Database,
        support: PersonDossierFindingSupportIdentity
    ) throws -> PersonDossierSummary? {
        guard let anchor = try PersonDossierAnchorStore.record(
            in: db,
            originDocumentID: support.documentID,
            primaryRole: support.role,
            normalizedName: support.normalizedName
        ) else {
            return nil
        }
        return try personProjectionReader.summary(in: db, anchor: anchor)
    }

    private nonisolated func personChoices(
        in db: Database,
        normalizedName: String
    ) throws -> [PersonDossierSummary] {
        try PersonDossierAnchorStore.records(
            in: db,
            normalizedName: normalizedName
        ).map { try personProjectionReader.summary(in: db, anchor: $0) }
    }

    private nonisolated func createPersonDossier(
        in db: Database,
        current: CurrentDocumentDNA,
        support: PersonDossierFindingSupportIdentity,
        proposedAnchorID: UUID,
        proposedDossierID: UUID,
        timestamp: Date
    ) throws -> PersonDossierSnapshot {
        let birthDate = try capturedBirthDate(in: current.snapshot)
        let proposedAnchor = try PersonDossierAnchor(
            id: proposedAnchorID,
            displayName: support.finding.displayValue,
            normalizedName: support.normalizedName,
            primaryRole: support.role,
            originDocumentID: support.documentID,
            originContentHash: support.contentHash,
            originExtractionVersion: support.extractionVersion,
            originDNASchemaVersion: support.dnaSchemaVersion,
            originDNAAnalyzerIdentifier: support.dnaAnalyzerIdentifier,
            originDNAAnalyzerVersion: support.dnaAnalyzerVersion,
            originDNAAnalyzedAt: support.dnaAnalyzedAt,
            personEvidence: support.finding.evidence,
            birthDate: birthDate,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let storedAnchor = try PersonDossierAnchorStore.insertOrFetch(
            in: db,
            proposed: proposedAnchor
        )
        let proposedDossier = try DossierRecord(
            id: proposedDossierID,
            kind: .personMatter,
            displayName: "Meine Mutter im Pflegeheim",
            anchor: .person(storedAnchor),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let storedDossier = try DossierStore.insertOrFetchAnchored(
            in: db,
            proposed: proposedDossier
        )
        return try personProjectionReader.snapshot(in: db, dossier: storedDossier)
    }

    private nonisolated func capturedBirthDate(
        in snapshot: DocumentDNA
    ) throws -> PersonDossierBirthDate? {
        let primaryPeople = snapshot.findings.filter { finding in
            finding.kind == .person
                && finding.qualifier.flatMap(PersonDossierRole.init(rawValue:))?.isPrimary == true
        }
        let birthDates = snapshot.findings.filter { finding in
            finding.kind == .date
                && finding.qualifier == DocumentDNADateRole.birthDate.rawValue
        }
        guard primaryPeople.count == 1, birthDates.count == 1 else {
            return nil
        }
        let birthDate = birthDates[0]
        return try PersonDossierBirthDate(
            displayValue: birthDate.displayValue,
            normalizedValue: birthDate.normalizedValue,
            evidence: birthDate.evidence
        )
    }

    private nonisolated func mappedError(_ error: any Error) -> any Error {
        if let repositoryError = error as? DossierRepositoryError {
            return repositoryError
        }
        if error is DossierStoreError
            || error is DossierProjectionError
            || error is DocumentDNARepositoryError
            || error is DocumentDNAValidationError
            || error is CurrentDocumentDNAError
            || error is DossierValidationError
            || error is InvoicePaymentDecisionRepositoryError
            || error is InvoicePaymentDecisionValidationError
            || error is PersonDossierAnchorStoreError
            || error is PersonDossierProjectionError
        {
            return DossierRepositoryError.invalidStoredState
        }
        return error
    }
}
