import Foundation
import GRDB
@testable import LinkLoomCore

struct PersonDossierFixture: Sendable {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

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
        extractedText: String = "x",
        schemaVersion: Int? = nil,
        analyzerIdentifier: String? = nil,
        analyzerVersion: String? = nil
    ) async throws -> CurrentDocumentDNA {
        let document = DocumentRecord(
            id: id,
            sourceRootID: source.id,
            relativePath: path,
            contentHash: "hash-\(path)",
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
            analyzedAt: Self.date
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
