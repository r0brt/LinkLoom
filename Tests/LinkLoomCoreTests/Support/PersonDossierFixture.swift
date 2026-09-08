import Foundation
import GRDB
@testable import LinkLoomCore

struct PersonDossierFixture: Sendable {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func repositoryUUID(_ sequence: Int) -> UUID {
        UUID(uuidString: String(
            format: "77000000-0000-0000-0000-%012d",
            sequence
        ))!
    }

    static func repositoryDate(_ offset: TimeInterval) -> Date {
        date.addingTimeInterval(offset)
    }

    let database: DatabaseQueue
    let source: SourceRootRecord
    let repository: DocumentDNARepository
    let target: DocumentDNAAnalysisTarget

    static func make() async throws -> Self {
        let database = try TestDatabase.make()
        let source = SourceRootRecord(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
            displayName: "Person dossier candidates",
            pathHint: "/synthetic/person-dossier-candidates",
            bookmarkData: Data("person-dossier-candidates-bookmark".utf8),
            createdAt: date
        )
        try await database.write { db in try source.insert(db) }
        return try Self(
            database: database,
            source: source,
            repository: DocumentDNARepository(dbWriter: database),
            target: DocumentDNAAnalysisTarget(
                schemaVersion: 1,
                analyzerIdentifier: "local-rules",
                analyzerVersion: "1"
            )
        )
    }

    func makeDossierRepository(
        sequence: Int = 900,
        timestamp: Date? = nil
    ) -> DossierRepository {
        let proposedIDs = PersonDossierProposedIDs(startingAt: sequence)
        return DossierRepository(
            dbWriter: database,
            target: target,
            now: { timestamp ?? Self.repositoryDate(TimeInterval(sequence)) },
            makeUUID: { proposedIDs.next() }
        )
    }

    func selection(
        current: CurrentDocumentDNA,
        finding: DocumentDNAFinding
    ) throws -> PersonDossierAnchorSelection {
        try PersonDossierAnchorSelection(
            document: current.document,
            snapshot: current.snapshot,
            finding: finding
        )
    }

    func personPersistenceCounts() async throws -> (anchors: Int, dossiers: Int) {
        try await database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personDossierAnchor") ?? 0,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM dossier WHERE kind = ?",
                    arguments: [DossierKind.personMatter.rawValue]
                ) ?? 0
            )
        }
    }

    func setAvailability(
        _ availability: DocumentAvailability,
        for documentID: UUID
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE document SET availability = ? WHERE id = ?",
                arguments: [availability.rawValue, documentID]
            )
        }
    }

    func insertSource(
        sequence: Int,
        displayName: String
    ) async throws -> SourceRootRecord {
        let source = SourceRootRecord(
            id: Self.repositoryUUID(sequence),
            displayName: displayName,
            pathHint: "/synthetic/\(sequence)",
            bookmarkData: Data("bookmark-\(sequence)".utf8),
            createdAt: Self.repositoryDate(TimeInterval(sequence))
        )
        try await database.write { db in try source.insert(db) }
        return source
    }

    func insertPersonDossier(
        sequence: Int,
        origin: CurrentDocumentDNA,
        finding: DocumentDNAFinding,
        displayName: String = "Elise Muster"
    ) async throws -> (PersonDossierAnchor, DossierRecord) {
        guard let role = finding.qualifier.flatMap(PersonDossierRole.init(rawValue:)) else {
            throw PersonDossierFixtureError.invalidPersonRole
        }
        let anchor = try PersonDossierAnchor(
            id: Self.repositoryUUID(sequence),
            displayName: displayName,
            normalizedName: finding.normalizedValue,
            primaryRole: role,
            originDocumentID: origin.document.id,
            originContentHash: origin.snapshot.inputContentHash,
            originExtractionVersion: origin.snapshot.inputExtractionVersion,
            originDNASchemaVersion: origin.snapshot.schemaVersion,
            originDNAAnalyzerIdentifier: origin.snapshot.analyzerIdentifier,
            originDNAAnalyzerVersion: origin.snapshot.analyzerVersion,
            originDNAAnalyzedAt: origin.snapshot.analyzedAt,
            personEvidence: finding.evidence,
            birthDate: nil,
            createdAt: Self.repositoryDate(TimeInterval(sequence)),
            updatedAt: Self.repositoryDate(TimeInterval(sequence))
        )
        let dossier = try DossierRecord(
            id: Self.repositoryUUID(sequence + 1),
            kind: .personMatter,
            displayName: "Meine Mutter im Pflegeheim",
            anchor: .person(anchor),
            createdAt: Self.repositoryDate(TimeInterval(sequence + 1)),
            updatedAt: Self.repositoryDate(TimeInterval(sequence + 1))
        )
        try await database.write { db in
            let storedAnchor = try PersonDossierAnchorStore.insertOrFetch(
                in: db,
                proposed: anchor
            )
            _ = try DossierStore.insertOrFetchAnchored(
                in: db,
                proposed: try DossierRecord(
                    id: dossier.id,
                    kind: dossier.kind,
                    displayName: dossier.displayName,
                    anchor: .person(storedAnchor),
                    createdAt: dossier.createdAt,
                    updatedAt: dossier.updatedAt
                )
            )
        }
        return (anchor, dossier)
    }

    func makePersonAnchor(
        sequence: Int,
        origin: CurrentDocumentDNA,
        finding: DocumentDNAFinding,
        birthDate: PersonDossierBirthDate? = nil
    ) throws -> PersonDossierAnchor {
        guard let role = finding.qualifier.flatMap(PersonDossierRole.init(rawValue:)) else {
            throw PersonDossierFixtureError.invalidPersonRole
        }
        return try PersonDossierAnchor(
            id: Self.repositoryUUID(sequence),
            displayName: finding.displayValue,
            normalizedName: finding.normalizedValue,
            primaryRole: role,
            originDocumentID: origin.document.id,
            originContentHash: origin.snapshot.inputContentHash,
            originExtractionVersion: origin.snapshot.inputExtractionVersion,
            originDNASchemaVersion: origin.snapshot.schemaVersion,
            originDNAAnalyzerIdentifier: origin.snapshot.analyzerIdentifier,
            originDNAAnalyzerVersion: origin.snapshot.analyzerVersion,
            originDNAAnalyzedAt: origin.snapshot.analyzedAt,
            personEvidence: finding.evidence,
            birthDate: birthDate,
            createdAt: Self.repositoryDate(TimeInterval(sequence)),
            updatedAt: Self.repositoryDate(TimeInterval(sequence))
        )
    }

    func insertConfirmation(_ confirmation: DossierMembershipConfirmation) async throws {
        try await database.write { db in
            try DossierStore.insertConfirmation(in: db, confirmation: confirmation)
        }
    }

    func insertExclusion(_ exclusion: DossierMembershipExclusion) async throws {
        try await database.write { db in
            try DossierStore.insertExclusion(in: db, exclusion: exclusion)
        }
    }

    func insertDecision(_ decision: InvoicePaymentDecisionRecord) async throws {
        try await InvoicePaymentDecisionRepository(dbWriter: database).save(decision)
    }

    func makeAcceptanceCorpus(
        documentCount: Int
    ) async throws -> PersonDossierAcceptanceCorpus {
        guard documentCount >= 4 else {
            throw PersonDossierFixtureError.invalidAcceptanceDocumentCount
        }
        let ids = (0..<documentCount).map { index in
            UUID(uuidString: String(
                format: "76000000-0000-0000-0000-%012d",
                index + 1
            ))!
        }
        let directDocumentID = ids[0]
        let invoiceDocumentID = ids[1]
        let secondaryDocumentID = ids[2]
        let paymentDocumentID = ids[3]
        let anchorNormalizedName = "elise muster"
        let relationshipReference = "REL000001"
        let storedDate = Self.date.timeIntervalSinceReferenceDate
        let emptyOCRIndexes = Data("[]".utf8)

        try await database.write { db in
            let insertDocument = try db.makeStatement(sql: """
                INSERT INTO document (
                    id, sourceRootID, relativePath, contentHash, byteCount, modifiedAt,
                    mediaType, status, availability, pageCount, failureCode, lastSeenAt,
                    lastFingerprintAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                """)
            let insertExtraction = try db.makeStatement(sql: """
                INSERT INTO documentExtraction (
                    documentID, analysisVersion, method, joinedText, updatedAt
                ) VALUES (?, ?, ?, ?, ?)
                """)
            let insertDNA = try db.makeStatement(sql: """
                INSERT INTO documentDNA (
                    documentID, schemaVersion, analyzerIdentifier, analyzerVersion,
                    inputContentHash, inputExtractionVersion, analyzedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            let insertFinding = try db.makeStatement(sql: """
                INSERT INTO documentDNAFinding (
                    documentID, kind, qualifier, displayValue, normalizedValue,
                    secondaryNormalizedValue, confidence, sortOrder
                ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?)
                """)
            let insertEvidence = try db.makeStatement(sql: """
                INSERT INTO documentDNAEvidence (
                    findingID, evidenceOrder, pageIndex, startUTF16, lengthUTF16,
                    exactText, ocrRegionIndexesJSON
                ) VALUES (?, 0, 0, 0, 1, 'x', ?)
                """)

            func addFinding(
                documentID: UUID,
                kind: DocumentDNAFindingKind,
                qualifier: String?,
                normalizedValue: String,
                sortOrder: Int
            ) throws {
                try insertFinding.execute(arguments: [
                    documentID,
                    kind.rawValue,
                    qualifier,
                    "x",
                    normalizedValue,
                    1.0,
                    sortOrder,
                ])
                try insertEvidence.execute(arguments: [db.lastInsertedRowID, emptyOCRIndexes])
            }

            for (index, documentID) in ids.enumerated() {
                let path = String(format: "acceptance/%05d.pdf", index)
                let contentHash = String(format: "hash-%05d", index)
                let documentType: DocumentType = switch index {
                case 1: .invoice
                case 2: .powerOfAttorney
                case 3: .paymentConfirmation
                default: .correspondence
                }
                let role: PersonDossierRole = switch index {
                case 1: .invoiceRecipient
                case 2: .authorizedPerson
                default: .resident
                }
                let normalizedName = index < 3
                    ? anchorNormalizedName
                    : String(format: "unrelated person %05d", index)
                let normalizedReference = index == 1 || index == 3
                    ? relationshipReference
                    : String(format: "REF%06d", index)
                let referenceRole: DocumentDNAReferenceNumberKind = index == 3
                    ? .paymentReference
                    : .invoiceNumber

                try insertDocument.execute(arguments: [
                    documentID,
                    source.id,
                    path,
                    contentHash,
                    1,
                    storedDate,
                    SupportedMediaType.pdf.rawValue,
                    DocumentStatus.ready.rawValue,
                    DocumentAvailability.available.rawValue,
                    1,
                    storedDate,
                    storedDate,
                ])
                try insertExtraction.execute(arguments: [
                    documentID,
                    "text-v1",
                    ExtractionMethod.embeddedPDFText.rawValue,
                    "x",
                    storedDate,
                ])
                try insertDNA.execute(arguments: [
                    documentID,
                    target.schemaVersion,
                    target.analyzerIdentifier,
                    target.analyzerVersion,
                    contentHash,
                    "text-v1",
                    storedDate,
                ])
                try addFinding(
                    documentID: documentID,
                    kind: .documentType,
                    qualifier: nil,
                    normalizedValue: documentType.rawValue,
                    sortOrder: 0
                )
                try addFinding(
                    documentID: documentID,
                    kind: .person,
                    qualifier: role.rawValue,
                    normalizedValue: normalizedName,
                    sortOrder: 1
                )
                try addFinding(
                    documentID: documentID,
                    kind: .referenceNumber,
                    qualifier: referenceRole.rawValue,
                    normalizedValue: normalizedReference,
                    sortOrder: 2
                )
                if index == 1 || index == 3 {
                    try addFinding(
                        documentID: documentID,
                        kind: .monetaryAmount,
                        qualifier: "CHF",
                        normalizedValue: "1250",
                        sortOrder: 3
                    )
                }
            }
        }

        let evidence = try Self.evidence(displayText: "x")
        let anchor = try PersonDossierAnchor(
            id: UUID(uuidString: "76000000-0000-0000-0001-000000000001")!,
            displayName: "x",
            normalizedName: anchorNormalizedName,
            primaryRole: .resident,
            originDocumentID: directDocumentID,
            originContentHash: "hash-00000",
            originExtractionVersion: "text-v1",
            originDNASchemaVersion: target.schemaVersion,
            originDNAAnalyzerIdentifier: target.analyzerIdentifier,
            originDNAAnalyzerVersion: target.analyzerVersion,
            originDNAAnalyzedAt: Self.date,
            personEvidence: [evidence],
            birthDate: nil,
            createdAt: Self.date,
            updatedAt: Self.date
        )
        let dossier = try DossierRecord(
            id: UUID(uuidString: "76000000-0000-0000-0002-000000000001")!,
            kind: .personMatter,
            displayName: "Acceptance dossier",
            anchor: .person(anchor),
            createdAt: Self.date,
            updatedAt: Self.date
        )
        return PersonDossierAcceptanceCorpus(
            dossier: dossier,
            anchor: anchor,
            directDocumentID: directDocumentID,
            invoiceDocumentID: invoiceDocumentID,
            secondaryDocumentID: secondaryDocumentID,
            paymentDocumentID: paymentDocumentID,
            expectedPersonMatchIDs: [
                directDocumentID,
                invoiceDocumentID,
                secondaryDocumentID,
            ],
            unrelatedDocumentIDs: Set(ids.dropFirst(4))
        )
    }

    static func currentDocument(
        id: UUID,
        sourceRootID: UUID,
        path: String,
        documentType: DocumentType = .correspondence,
        availability: DocumentAvailability = .available,
        contentHash: String? = nil,
        extractionVersion: String = "text-v1",
        schemaVersion: Int = 1,
        analyzerIdentifier: String = "local-rules",
        analyzerVersion: String = "1",
        analyzedAt: Date = date,
        personFindings: [DocumentDNAFinding]
    ) throws -> CurrentDocumentDNA {
        let resolvedHash = contentHash ?? "hash-\(path)"
        let document = document(
            id: id,
            sourceRootID: sourceRootID,
            path: path,
            contentHash: resolvedHash,
            availability: availability
        )
        let typeFinding: DocumentDNAFinding
        if documentType == .unknown {
            typeFinding = try DocumentDNAFinding(
                kind: .documentType,
                qualifier: nil,
                displayValue: "",
                normalizedValue: documentType.rawValue,
                secondaryNormalizedValue: nil,
                confidence: 0,
                evidence: []
            )
        } else {
            typeFinding = try finding(
                kind: .documentType,
                qualifier: nil,
                displayValue: documentType.rawValue,
                normalizedValue: documentType.rawValue
            )
        }
        return try CurrentDocumentDNA(
            document: document,
            snapshot: DocumentDNA(
                documentID: id,
                schemaVersion: schemaVersion,
                analyzerIdentifier: analyzerIdentifier,
                analyzerVersion: analyzerVersion,
                inputContentHash: resolvedHash,
                inputExtractionVersion: extractionVersion,
                findings: [typeFinding] + personFindings,
                analyzedAt: analyzedAt
            )
        )
    }

    static func invoicePaymentDocument(
        id: UUID,
        sourceRootID: UUID,
        path: String,
        documentType: DocumentType,
        contentHash: String? = nil,
        analyzedAt: Date = date,
        personFindings: [DocumentDNAFinding] = []
    ) throws -> CurrentDocumentDNA {
        let referenceQualifier: DocumentDNAReferenceNumberKind = documentType == .invoice
            ? .invoiceNumber : .paymentReference
        let organizationQualifier = documentType == .invoice ? "issuer" : "payee"
        return try currentDocument(
            id: id,
            sourceRootID: sourceRootID,
            path: path,
            documentType: documentType,
            contentHash: contentHash,
            analyzedAt: analyzedAt,
            personFindings: personFindings + [
                try finding(
                    kind: .referenceNumber,
                    qualifier: referenceQualifier.rawValue,
                    displayValue: "INV-42",
                    normalizedValue: "INV42"
                ),
                try finding(
                    kind: .monetaryAmount,
                    qualifier: "CHF",
                    displayValue: "CHF 1250",
                    normalizedValue: "1250"
                ),
                try finding(
                    kind: .organization,
                    qualifier: organizationQualifier,
                    displayValue: "Alpha AG",
                    normalizedValue: "alpha ag"
                ),
            ]
        )
    }

    static func invoicePaymentCandidate(
        invoice: CurrentDocumentDNA,
        payment: CurrentDocumentDNA,
        disposition: InvoicePaymentCandidateDisposition? = nil,
        resolverVersion: String? = nil,
        signals: [InvoicePaymentCandidateSignal]? = nil
    ) throws -> InvoicePaymentCandidate {
        guard let resolved = InvoicePaymentCandidateResolver().candidates(
            matching: "INV42",
            in: [invoice, payment]
        ).first else {
            throw PersonDossierFixtureError.missingRelationshipCandidate
        }
        return InvoicePaymentCandidate(
            invoice: invoice,
            payment: payment,
            disposition: disposition ?? resolved.disposition,
            resolverVersion: resolverVersion ?? resolved.resolverVersion,
            signals: signals ?? resolved.signals
        )
    }

    static func relationshipDecision(
        for candidate: InvoicePaymentCandidate,
        decision: InvoicePaymentUserDecision = .confirmed,
        updatedAt: Date = date.addingTimeInterval(50),
        invoiceContentHash: String? = nil,
        paymentContentHash: String? = nil
    ) throws -> (InvoicePaymentDecisionKey, InvoicePaymentDecisionRecord) {
        let key = try InvoicePaymentDecisionKey(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: candidate.invoice.document.id,
            paymentDocumentID: candidate.payment.document.id,
            invoiceContentHash: invoiceContentHash ?? candidate.invoice.document.contentHash,
            paymentContentHash: paymentContentHash ?? candidate.payment.document.contentHash
        )
        return (key, InvoicePaymentDecisionRecord(
            key: key,
            decision: decision,
            updatedAt: updatedAt
        ))
    }

    static func document(
        id: UUID,
        sourceRootID: UUID,
        path: String,
        contentHash: String,
        availability: DocumentAvailability = .available
    ) -> DocumentRecord {
        DocumentRecord(
            id: id,
            sourceRootID: sourceRootID,
            relativePath: path,
            contentHash: contentHash,
            byteCount: 1,
            modifiedAt: date,
            mediaType: .pdf,
            status: .ready,
            availability: availability,
            pageCount: 1,
            lastSeenAt: date,
            lastFingerprintAt: date
        )
    }

    static func personFinding(
        displayName: String = "Elise Muster",
        normalizedName: String = "elise muster",
        role: PersonDossierRole,
        evidence: [DocumentDNAEvidence]? = nil
    ) throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: .person,
            qualifier: role.rawValue,
            displayValue: displayName,
            normalizedValue: normalizedName,
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: evidence ?? [try self.evidence(displayText: displayName)]
        )
    }

    static func evidence(
        displayText: String = "Elise Muster",
        pageIndex: Int = 0,
        startUTF16: Int = 0,
        ocrRegionIndexes: [Int] = []
    ) throws -> DocumentDNAEvidence {
        try DocumentDNAEvidence(
            pageIndex: pageIndex,
            startUTF16: startUTF16,
            lengthUTF16: displayText.utf16.count,
            exactText: displayText,
            ocrRegionIndexes: ocrRegionIndexes
        )
    }

    static func finding(
        kind: DocumentDNAFindingKind,
        qualifier: String?,
        displayValue: String,
        normalizedValue: String
    ) throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: kind,
            qualifier: qualifier,
            displayValue: displayValue,
            normalizedValue: normalizedValue,
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: [try evidence(displayText: displayValue)]
        )
    }

    func insertSnapshot(
        id: UUID = UUID(),
        path: String,
        findings: [DocumentDNAFinding],
        documentType: DocumentType = .invoice,
        sourceRoot: SourceRootRecord? = nil,
        contentHash: String? = nil,
        extractedText: String = "x",
        schemaVersion: Int? = nil,
        analyzerIdentifier: String? = nil,
        analyzerVersion: String? = nil,
        analyzedAt: Date? = nil
    ) async throws -> CurrentDocumentDNA {
        let resolvedSource = sourceRoot ?? source
        let document = DocumentRecord(
            id: id,
            sourceRootID: resolvedSource.id,
            relativePath: path,
            contentHash: contentHash ?? "hash-\(path)",
            byteCount: 1,
            modifiedAt: Self.date,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: Self.date,
            lastFingerprintAt: Self.date
        )
        try await database.write { db in try document.insert(db) }
        try await ExtractionRepository(dbWriter: database).replace(
            documentID: document.id,
            analysisVersion: "text-v1",
            extraction: ExtractedDocument(
                method: .embeddedPDFText,
                pages: [ExtractedPage(pageIndex: 0, text: extractedText, regions: [])]
            ),
            at: Self.date
        )
        let snapshot = try DocumentDNA(
            documentID: document.id,
            schemaVersion: schemaVersion ?? target.schemaVersion,
            analyzerIdentifier: analyzerIdentifier ?? target.analyzerIdentifier,
            analyzerVersion: analyzerVersion ?? target.analyzerVersion,
            inputContentHash: document.contentHash,
            inputExtractionVersion: "text-v1",
            findings: [try documentTypeFinding(documentType)] + findings,
            analyzedAt: analyzedAt ?? Self.date
        )
        try await repository.replace(snapshot)
        return try CurrentDocumentDNA(document: document, snapshot: snapshot)
    }

    func personFinding(
        normalizedName: String = "elise muster",
        qualifier: String?
    ) throws -> DocumentDNAFinding {
        return try finding(
            kind: .person,
            qualifier: qualifier,
            displayValue: "Elise Muster",
            normalizedValue: normalizedName
        )
    }

    func birthDateFinding(
        displayValue: String = "01.02.1940",
        normalizedValue: String
    ) throws -> DocumentDNAFinding {
        try finding(
            kind: .date,
            qualifier: DocumentDNADateRole.birthDate.rawValue,
            displayValue: displayValue,
            normalizedValue: normalizedValue
        )
    }

    func finding(
        kind: DocumentDNAFindingKind,
        qualifier: String?,
        displayValue: String,
        normalizedValue: String
    ) throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: kind,
            qualifier: qualifier,
            displayValue: displayValue,
            normalizedValue: normalizedValue,
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: [try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: 1,
                exactText: "x",
                ocrRegionIndexes: []
            )]
        )
    }

    func makeStale(
        _ documentID: UUID,
        by mutation: PersonDossierStaleness
    ) async throws {
        try await database.write { db in
            switch mutation {
            case .contentHash:
                try db.execute(
                    sql: "UPDATE document SET contentHash = 'changed-hash' WHERE id = ?",
                    arguments: [documentID]
                )
            case .extractionVersion:
                try db.execute(
                    sql: "UPDATE documentExtraction SET analysisVersion = 'text-v2' WHERE documentID = ?",
                    arguments: [documentID]
                )
            case .schemaVersion:
                try db.execute(
                    sql: "UPDATE documentDNA SET schemaVersion = 2 WHERE documentID = ?",
                    arguments: [documentID]
                )
            case .analyzerIdentifier:
                try db.execute(
                    sql: "UPDATE documentDNA SET analyzerIdentifier = 'other-rules' WHERE documentID = ?",
                    arguments: [documentID]
                )
            case .analyzerVersion:
                try db.execute(
                    sql: "UPDATE documentDNA SET analyzerVersion = '2' WHERE documentID = ?",
                    arguments: [documentID]
                )
            }
        }
    }

    private func documentTypeFinding(_ type: DocumentType) throws -> DocumentDNAFinding {
        if type == .unknown {
            return try DocumentDNAFinding(
                kind: .documentType,
                qualifier: nil,
                displayValue: "",
                normalizedValue: type.rawValue,
                secondaryNormalizedValue: nil,
                confidence: 0,
                evidence: []
            )
        }
        return try finding(
            kind: .documentType,
            qualifier: nil,
            displayValue: type.rawValue,
            normalizedValue: type.rawValue
        )
    }
}

enum PersonDossierStaleness: CaseIterable {
    case contentHash
    case extractionVersion
    case schemaVersion
    case analyzerIdentifier
    case analyzerVersion
}

struct PersonDossierAcceptanceCorpus: Sendable {
    let dossier: DossierRecord
    let anchor: PersonDossierAnchor
    let directDocumentID: UUID
    let invoiceDocumentID: UUID
    let secondaryDocumentID: UUID
    let paymentDocumentID: UUID
    let expectedPersonMatchIDs: [UUID]
    let unrelatedDocumentIDs: Set<UUID>
}

private enum PersonDossierFixtureError: Error {
    case missingRelationshipCandidate
    case invalidAcceptanceDocumentCount
    case invalidPersonRole
}

private final class PersonDossierProposedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: Int

    init(startingAt sequence: Int) {
        nextSequence = sequence
    }

    func next() -> UUID {
        lock.withLock {
            defer { nextSequence += 1 }
            return PersonDossierFixture.repositoryUUID(nextSequence)
        }
    }
}
