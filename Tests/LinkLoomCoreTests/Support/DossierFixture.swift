import Foundation
import GRDB
@testable import LinkLoomCore

struct DossierFixture: Sendable {
    static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    static let proposedDossierID = uuid("82000000-0000-0000-0000-000000000090")

    let db: DatabaseQueue
    let repository: DossierRepository
    let target: DocumentDNAAnalysisTarget
    let source: SourceRootRecord
    let sharedPayment: DocumentRecord
    let expectedChoiceIDs: [UUID]

    static func empty() async throws -> Self {
        let db = try TestDatabase.make()
        let source = SourceRootRecord(
            id: uuid("82000000-0000-0000-0000-000000000001"),
            displayName: "Dossier documents",
            pathHint: "/synthetic/dossiers",
            bookmarkData: Data("dossier-bookmark".utf8),
            createdAt: baseDate
        )
        try await db.write { database in
            try source.insert(database)
        }
        let target = try DocumentDNAAnalysisTarget(
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "1"
        )
        return Self(
            db: db,
            repository: DossierRepository(
                dbWriter: db,
                target: target,
                now: { baseDate },
                makeUUID: { proposedDossierID }
            ),
            target: target,
            source: source,
            sharedPayment: placeholderDocument(sourceID: source.id),
            expectedChoiceIDs: []
        )
    }

    static func confirmedPair() async throws -> (
        fixture: Self, invoice: DocumentRecord, payment: DocumentRecord, dossier: DossierRecord
    ) {
        var fixture = try await empty()
        let invoice = try await fixture.insertAnalyzedDocument(
            id: uuid("82000000-0000-0000-0000-000000000010"),
            path: "invoice.pdf",
            type: .invoice,
            reference: "INV42"
        )
        let payment = try await fixture.insertAnalyzedDocument(
            id: uuid("82000000-0000-0000-0000-000000000011"),
            path: "payment.pdf",
            type: .paymentConfirmation,
            reference: "INV42"
        )
        try await fixture.confirm(invoice: invoice, payment: payment)
        let dossier = try fixture.makeDossier(
            id: uuid("82000000-0000-0000-0000-000000000020"),
            anchor: invoice,
            createdAt: baseDate.addingTimeInterval(20)
        )
        try await fixture.insert(dossier)
        fixture = fixture.replacing(sharedPayment: payment)
        return (fixture, invoice, payment, dossier)
    }

    static func multipleMatchingDossiers() async throws -> Self {
        var fixture = try await empty()
        let firstInvoice = try await fixture.insertAnalyzedDocument(
            id: uuid("82000000-0000-0000-0000-000000000012"),
            path: "a-invoice.pdf",
            type: .invoice,
            reference: "SHARED42"
        )
        let secondInvoice = try await fixture.insertAnalyzedDocument(
            id: uuid("82000000-0000-0000-0000-000000000013"),
            path: "b-invoice.pdf",
            type: .invoice,
            reference: "SHARED42"
        )
        let payment = try await fixture.insertAnalyzedDocument(
            id: uuid("82000000-0000-0000-0000-000000000014"),
            path: "shared-payment.pdf",
            type: .paymentConfirmation,
            reference: "SHARED42"
        )
        try await fixture.confirm(invoice: firstInvoice, payment: payment)
        try await fixture.confirm(invoice: secondInvoice, payment: payment)
        let firstID = uuid("82000000-0000-0000-0000-000000000021")
        let secondID = uuid("82000000-0000-0000-0000-000000000022")
        try await fixture.insert(try fixture.makeDossier(
            id: secondID,
            anchor: secondInvoice,
            createdAt: baseDate.addingTimeInterval(40)
        ))
        try await fixture.insert(try fixture.makeDossier(
            id: firstID,
            anchor: firstInvoice,
            createdAt: baseDate.addingTimeInterval(30)
        ))
        fixture = fixture.replacing(
            sharedPayment: payment,
            expectedChoiceIDs: [firstID, secondID]
        )
        return fixture
    }

    func insertPlainDocument(
        id: UUID = UUID(),
        path: String,
        contentHash: String? = nil
    ) async throws -> DocumentRecord {
        let document = DocumentRecord(
            id: id,
            sourceRootID: source.id,
            relativePath: path,
            contentHash: contentHash ?? "hash-\(path)",
            byteCount: 64,
            modifiedAt: Self.baseDate,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: Self.baseDate,
            lastFingerprintAt: Self.baseDate
        )
        try await db.write { database in
            try document.insert(database)
        }
        try await ExtractionRepository(dbWriter: db).replace(
            documentID: document.id,
            analysisVersion: "text-v1",
            extraction: Self.extraction,
            at: Self.baseDate
        )
        return document
    }

    mutating func insertAnalyzedDocument(
        id: UUID,
        path: String,
        type: DocumentType,
        reference: String
    ) async throws -> DocumentRecord {
        let document = try await insertPlainDocument(id: id, path: path)
        let referenceKind: DocumentDNAReferenceNumberKind = type == .invoice
            ? .invoiceNumber : .paymentReference
        let organizationQualifier = type == .invoice ? "issuer" : "payee"
        let snapshot = try DocumentDNA(
            documentID: document.id,
            schemaVersion: target.schemaVersion,
            analyzerIdentifier: target.analyzerIdentifier,
            analyzerVersion: target.analyzerVersion,
            inputContentHash: document.contentHash,
            inputExtractionVersion: "text-v1",
            findings: [
                try Self.finding(
                    kind: .documentType,
                    qualifier: nil,
                    displayValue: type.rawValue,
                    normalizedValue: type.rawValue
                ),
                try Self.finding(
                    kind: .referenceNumber,
                    qualifier: referenceKind.rawValue,
                    displayValue: reference,
                    normalizedValue: reference
                ),
                try Self.finding(
                    kind: .monetaryAmount,
                    qualifier: "CHF",
                    displayValue: "CHF 42",
                    normalizedValue: "42"
                ),
                try Self.finding(
                    kind: .organization,
                    qualifier: organizationQualifier,
                    displayValue: "Example AG",
                    normalizedValue: "example ag"
                ),
            ],
            analyzedAt: Self.baseDate.addingTimeInterval(10)
        )
        try await DocumentDNARepository(dbWriter: db).replace(snapshot)
        return document
    }

    func confirm(invoice: DocumentRecord, payment: DocumentRecord) async throws {
        let key = try InvoicePaymentDecisionKey(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: invoice.id,
            paymentDocumentID: payment.id,
            invoiceContentHash: invoice.contentHash,
            paymentContentHash: payment.contentHash
        )
        try await InvoicePaymentDecisionRepository(dbWriter: db).save(
            InvoicePaymentDecisionRecord(
                key: key,
                decision: .confirmed,
                updatedAt: Self.baseDate.addingTimeInterval(15)
            )
        )
    }

    func makeDossier(
        id: UUID,
        anchor: DocumentRecord,
        createdAt: Date,
        displayName: String = "Kosten und Zahlungen"
    ) throws -> DossierRecord {
        try DossierRecord(
            id: id,
            kind: .costsAndPayments,
            displayName: displayName,
            anchorDocumentID: anchor.id,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    func insert(_ dossier: DossierRecord) async throws {
        try await db.write { database in
            _ = try DossierStore.insertOrFetchAnchored(in: database, proposed: dossier)
        }
    }

    func dossierCount() async throws -> Int {
        try await db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM dossier")!
        }
    }

    func makeDNAStale(for documentID: UUID) async throws {
        try await db.write { database in
            try database.execute(
                sql: "UPDATE document SET contentHash = ? WHERE id = ?",
                arguments: ["changed-content-hash", documentID]
            )
        }
    }

    func corruptDocumentTypeFinding(for documentID: UUID) async throws {
        try await db.write { database in
            try database.execute(
                sql: """
                    UPDATE documentDNAFinding
                    SET normalizedValue = 'unsupported-document-type'
                    WHERE documentID = ? AND kind = 'documentType'
                    """,
                arguments: [documentID]
            )
        }
    }

    private func replacing(
        sharedPayment: DocumentRecord? = nil,
        expectedChoiceIDs: [UUID]? = nil
    ) -> Self {
        Self(
            db: db,
            repository: repository,
            target: target,
            source: source,
            sharedPayment: sharedPayment ?? self.sharedPayment,
            expectedChoiceIDs: expectedChoiceIDs ?? self.expectedChoiceIDs
        )
    }

    private static func placeholderDocument(sourceID: UUID) -> DocumentRecord {
        DocumentRecord(
            id: uuid("82000000-0000-0000-0000-000000000099"),
            sourceRootID: sourceID,
            relativePath: "placeholder.pdf",
            contentHash: "placeholder",
            byteCount: 0,
            modifiedAt: baseDate,
            mediaType: .pdf,
            status: .discovered,
            availability: .available,
            lastSeenAt: baseDate
        )
    }

    private static func finding(
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
                ocrRegionIndexes: [0]
            )]
        )
    }

    private static let extraction = ExtractedDocument(
        method: .visionOCR,
        pages: [ExtractedPage(
            pageIndex: 0,
            text: "x",
            regions: [TextRegion(
                text: "x",
                confidence: 1,
                boundingBox: .zero
            )]
        )]
    )

    private static func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}

private func uuid(_ value: String) -> UUID {
    UUID(uuidString: value)!
}
