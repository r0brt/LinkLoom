import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Invoice payment decision repository")
struct InvoicePaymentDecisionRepositoryTests {
    @Test func decisionKeyRejectsInvalidRoleIdentityAndContentHashes() {
        let invoiceID = UUID()
        let paymentID = UUID()

        #expect(throws: InvoicePaymentDecisionValidationError.invalidKey) {
            try InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: invoiceID,
                paymentDocumentID: invoiceID,
                invoiceContentHash: "hash-invoice",
                paymentContentHash: "hash-payment"
            )
        }
        #expect(throws: InvoicePaymentDecisionValidationError.invalidKey) {
            try InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: invoiceID,
                paymentDocumentID: paymentID,
                invoiceContentHash: " ",
                paymentContentHash: "hash-payment"
            )
        }
        #expect(throws: InvoicePaymentDecisionValidationError.invalidKey) {
            try InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: invoiceID,
                paymentDocumentID: paymentID,
                invoiceContentHash: "hash-invoice",
                paymentContentHash: "\n"
            )
        }
    }

    @Test func savingConfirmedDecisionTwiceRoundTripsOneRow() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let key = try fixture.key()
        let record = InvoicePaymentDecisionRecord(
            key: key,
            decision: .confirmed,
            updatedAt: fixture.date
        )

        try await fixture.repository.save(record)
        try await fixture.repository.save(record)

        #expect(try await fixture.repository.currentDecision(for: key) == record)
        #expect(try await fixture.rowCount() == 1)
    }

    @Test func savingChangedDecisionUpdatesTheExistingRow() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let key = try fixture.key()
        let confirmed = InvoicePaymentDecisionRecord(
            key: key,
            decision: .confirmed,
            updatedAt: fixture.date
        )
        let changedAt = fixture.date.addingTimeInterval(60)
        let excluded = InvoicePaymentDecisionRecord(
            key: key,
            decision: .excluded,
            updatedAt: changedAt
        )

        try await fixture.repository.save(confirmed)
        try await fixture.repository.save(excluded)

        #expect(try await fixture.repository.currentDecision(for: key) == excluded)
        #expect(try await fixture.rowCount() == 1)
    }

    @Test func deletingDecisionTwiceIsIdempotent() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let key = try fixture.key()
        try await fixture.repository.save(InvoicePaymentDecisionRecord(
            key: key,
            decision: .confirmed,
            updatedAt: fixture.date
        ))

        try await fixture.repository.delete(key)
        try await fixture.repository.delete(key)

        #expect(try await fixture.repository.currentDecision(for: key) == nil)
        #expect(try await fixture.rowCount() == 0)
    }

    @Test func changedDocumentContentHidesDecisionAndRejectsStaleSave() async throws {
        for changedDocument in [ChangedDecisionDocument.invoice, .payment] {
            let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
            let key = try fixture.key()
            let record = InvoicePaymentDecisionRecord(
                key: key,
                decision: .confirmed,
                updatedAt: fixture.date
            )
            try await fixture.repository.save(record)

            try await fixture.changeContentHash(
                documentID: changedDocument == .invoice
                    ? fixture.invoice.id
                    : fixture.payment.id,
                to: "hash-changed"
            )

            #expect(try await fixture.repository.currentDecision(for: key) == nil)
            await #expect(throws: InvoicePaymentDecisionRepositoryError.staleInput) {
                try await fixture.repository.save(record)
            }
            #expect(try await fixture.rowCount() == 1)
        }
    }

    @Test func reanalysisAndRecognizedMovesPreserveCurrentDecision() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let key = try fixture.key()
        let record = InvoicePaymentDecisionRecord(
            key: key,
            decision: .confirmed,
            updatedAt: fixture.date
        )
        try await fixture.replaceDNASnapshots(analyzerVersion: "1")
        try await fixture.repository.save(record)

        try await fixture.moveDocuments()
        try await fixture.replaceDNASnapshots(analyzerVersion: "2")

        #expect(try await fixture.repository.currentDecision(for: key) == record)
        #expect(try await fixture.rowCount() == 1)
    }

    @Test func changedContentRequiresANewExplicitDecision() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let oldKey = try fixture.key()
        try await fixture.repository.save(InvoicePaymentDecisionRecord(
            key: oldKey,
            decision: .confirmed,
            updatedAt: fixture.date
        ))
        try await fixture.changeContentHash(
            documentID: fixture.invoice.id,
            to: "hash-invoice-v2"
        )
        let newKey = try fixture.key(invoiceContentHash: "hash-invoice-v2")

        #expect(try await fixture.repository.currentDecision(for: oldKey) == nil)
        #expect(try await fixture.repository.currentDecision(for: newKey) == nil)

        let newDecision = InvoicePaymentDecisionRecord(
            key: newKey,
            decision: .excluded,
            updatedAt: fixture.date.addingTimeInterval(60)
        )
        try await fixture.repository.save(newDecision)

        #expect(try await fixture.repository.currentDecision(for: newKey) == newDecision)
        #expect(try await fixture.rowCount() == 2)
    }
}

private enum ChangedDecisionDocument {
    case invoice
    case payment
}

private struct InvoicePaymentDecisionRepositoryFixture {
    let db: DatabaseQueue
    let source: SourceRootRecord
    let invoice: DocumentRecord
    let payment: DocumentRecord
    let repository: InvoicePaymentDecisionRepository
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func make() async throws -> Self {
        let db = try TestDatabase.make()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let source = SourceRootRecord(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000001")!,
            displayName: "Decision repository",
            pathHint: "/synthetic/decisions",
            bookmarkData: Data("decision-bookmark".utf8),
            createdAt: date
        )
        let invoice = DocumentRecord(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000002")!,
            sourceRootID: source.id,
            relativePath: "invoice.pdf",
            contentHash: "hash-invoice-v1",
            byteCount: 64,
            modifiedAt: date,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: date,
            lastFingerprintAt: date
        )
        let payment = DocumentRecord(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000003")!,
            sourceRootID: source.id,
            relativePath: "payment.pdf",
            contentHash: "hash-payment-v1",
            byteCount: 64,
            modifiedAt: date,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: date,
            lastFingerprintAt: date
        )
        try await db.write { connection in
            try source.insert(connection)
            try invoice.insert(connection)
            try payment.insert(connection)
        }
        return Self(
            db: db,
            source: source,
            invoice: invoice,
            payment: payment,
            repository: InvoicePaymentDecisionRepository(dbWriter: db)
        )
    }

    func key(
        invoiceContentHash: String? = nil,
        paymentContentHash: String? = nil
    ) throws -> InvoicePaymentDecisionKey {
        try InvoicePaymentDecisionKey(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: invoice.id,
            paymentDocumentID: payment.id,
            invoiceContentHash: invoiceContentHash ?? invoice.contentHash,
            paymentContentHash: paymentContentHash ?? payment.contentHash
        )
    }

    func rowCount() async throws -> Int {
        try await db.read { connection in
            try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM invoicePaymentUserDecision"
            ) ?? 0
        }
    }

    func changeContentHash(documentID: UUID, to contentHash: String) async throws {
        try await db.write { connection in
            try connection.execute(
                sql: "UPDATE document SET contentHash = ? WHERE id = ?",
                arguments: [contentHash, documentID]
            )
        }
    }

    func moveDocuments() async throws {
        try await db.write { connection in
            try connection.execute(
                sql: "UPDATE document SET relativePath = ? WHERE id = ?",
                arguments: ["moved/invoice.pdf", invoice.id]
            )
            try connection.execute(
                sql: "UPDATE document SET relativePath = ? WHERE id = ?",
                arguments: ["moved/payment.pdf", payment.id]
            )
        }
    }

    func replaceDNASnapshots(analyzerVersion: String) async throws {
        try await db.write { connection in
            for document in [invoice, payment] {
                try connection.execute(
                    sql: "DELETE FROM documentDNA WHERE documentID = ?",
                    arguments: [document.id]
                )
                try connection.execute(
                    sql: """
                        INSERT INTO documentDNA (
                            documentID, schemaVersion, analyzerIdentifier,
                            analyzerVersion, inputContentHash,
                            inputExtractionVersion, analyzedAt
                        ) VALUES (?, 1, 'local-rules', ?, ?, 'text-v1', ?)
                        """,
                    arguments: [
                        document.id,
                        analyzerVersion,
                        document.contentHash,
                        date,
                    ]
                )
            }
        }
    }
}
