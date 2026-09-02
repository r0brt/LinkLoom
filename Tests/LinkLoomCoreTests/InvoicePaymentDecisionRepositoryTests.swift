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
        #expect(throws: InvoicePaymentDecisionValidationError.invalidKey) {
            try InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: invoiceID,
                paymentDocumentID: paymentID,
                invoiceContentHash: "\u{00A0}",
                paymentContentHash: "hash-payment"
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

    @Test func currentRecordsReturnsOnlyExactCurrentRowsAndPreservesUpdatedAt() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let currentKey = try fixture.key()
        let stalePayment = try await fixture.insertPayment(
            path: "stale-payment.pdf",
            contentHash: "hash-stale-payment-v1"
        )
        let staleKey = try fixture.key(payment: stalePayment)
        let currentRecord = InvoicePaymentDecisionRecord(
            key: currentKey,
            decision: .confirmed,
            updatedAt: fixture.date.addingTimeInterval(60)
        )
        let staleRecord = InvoicePaymentDecisionRecord(
            key: staleKey,
            decision: .excluded,
            updatedAt: fixture.date.addingTimeInterval(120)
        )
        try await fixture.repository.save(currentRecord)
        try await fixture.repository.save(staleRecord)
        try await fixture.changeContentHash(
            documentID: stalePayment.id,
            to: "hash-stale-payment-v2"
        )

        let records = try await fixture.db.read { db in
            try InvoicePaymentDecisionRepository.currentRecords(
                in: db,
                keys: [staleKey, currentKey]
            )
        }

        #expect(records == [currentKey: currentRecord])
        #expect(records[currentKey]?.updatedAt == currentRecord.updatedAt)
    }

    @Test func currentRecordsReturnsEmptyWithoutAStatementForEmptyInput() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let counter = DecisionSQLReadCounter()
        try await fixture.db.write { database in
            database.trace(options: .statement) { event in
                counter.record(event)
            }
        }
        counter.reset()

        let records = try await fixture.db.read { db in
            try InvoicePaymentDecisionRepository.currentRecords(in: db, keys: [])
        }
        let readCount = counter.value
        try await fixture.db.write { database in
            database.trace(options: [])
        }

        #expect(records.isEmpty)
        #expect(readCount == 0)
    }

    @Test func currentRecordsDeduplicatesRepeatedKeys() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let key = try fixture.key()
        let record = InvoicePaymentDecisionRecord(
            key: key,
            decision: .confirmed,
            updatedAt: fixture.date
        )
        try await fixture.repository.save(record)
        let counter = DecisionSQLReadCounter()
        try await fixture.db.write { database in
            database.trace(options: .statement) { event in
                counter.record(event)
            }
        }
        counter.reset()

        let records = try await fixture.db.read { db in
            try InvoicePaymentDecisionRepository.currentRecords(
                in: db,
                keys: [key, key]
            )
        }
        let readCount = counter.value
        try await fixture.db.write { database in
            database.trace(options: [])
        }

        #expect(records == [key: record])
        #expect(readCount == 1)
    }

    @Test func currentRecordsChunksAtSQLiteStatementArgumentLimit() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let keysPerStatement = try await fixture.db.read { db in
            db.maximumStatementArgumentCount / 5
        }
        let keys = try (0...keysPerStatement).map { index in
            try InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: UUID(),
                paymentDocumentID: UUID(),
                invoiceContentHash: "invoice-hash-\(index)",
                paymentContentHash: "payment-hash-\(index)"
            )
        }
        let counter = DecisionSQLReadCounter()
        try await fixture.db.write { database in
            database.trace(options: .statement) { event in
                counter.record(event)
            }
        }
        counter.reset()

        let atLimitRecords = try await fixture.db.read { db in
            try InvoicePaymentDecisionRepository.currentRecords(
                in: db,
                keys: Array(keys.dropLast())
            )
        }
        let atLimitReadCount = counter.value
        counter.reset()
        let overLimitRecords = try await fixture.db.read { db in
            try InvoicePaymentDecisionRepository.currentRecords(in: db, keys: keys)
        }
        let overLimitReadCount = counter.value
        try await fixture.db.write { database in
            database.trace(options: [])
        }

        #expect(atLimitRecords.isEmpty)
        #expect(atLimitReadCount == 1)
        #expect(overLimitRecords.isEmpty)
        #expect(overLimitReadCount == 2)
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

    @Test func stableCatalogIdentitySurvivesReanalysisAndPathChanges() async throws {
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
        for changedDocument in [ChangedDecisionDocument.invoice, .payment] {
            let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
            let oldKey = try fixture.key()
            try await fixture.repository.save(InvoicePaymentDecisionRecord(
                key: oldKey,
                decision: .confirmed,
                updatedAt: fixture.date
            ))
            let newHash = changedDocument == .invoice
                ? "hash-invoice-v2"
                : "hash-payment-v2"
            try await fixture.changeContentHash(
                documentID: changedDocument == .invoice
                    ? fixture.invoice.id
                    : fixture.payment.id,
                to: newHash
            )
            let newKey = try fixture.key(
                invoiceContentHash: changedDocument == .invoice ? newHash : nil,
                paymentContentHash: changedDocument == .payment ? newHash : nil
            )

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

            try await fixture.changeContentHash(
                documentID: changedDocument == .invoice
                    ? fixture.invoice.id
                    : fixture.payment.id,
                to: changedDocument == .invoice
                    ? fixture.invoice.contentHash
                    : fixture.payment.contentHash
            )

            #expect(try await fixture.repository.currentDecision(for: oldKey)?.decision == .confirmed)
            #expect(try await fixture.repository.currentDecision(for: newKey) == nil)
            #expect(try await fixture.rowCount() == 2)
        }
    }

    @Test func batchAnnotationMapsExactCurrentDecisionsInInputOrder() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let excludedPayment = try await fixture.insertPayment(
            path: "excluded-payment.pdf",
            contentHash: "hash-excluded-payment"
        )
        let undecidedPayment = try await fixture.insertPayment(
            path: "undecided-payment.pdf",
            contentHash: "hash-undecided-payment"
        )
        let candidates = [
            try fixture.candidate(),
            try fixture.candidate(payment: excludedPayment),
            try fixture.candidate(payment: undecidedPayment),
        ]
        try await fixture.repository.save(InvoicePaymentDecisionRecord(
            key: try fixture.key(),
            decision: .confirmed,
            updatedAt: fixture.date
        ))
        try await fixture.repository.save(InvoicePaymentDecisionRecord(
            key: try fixture.key(payment: excludedPayment),
            decision: .excluded,
            updatedAt: fixture.date.addingTimeInterval(60)
        ))

        let annotated = try await fixture.repository.candidatesWithCurrentDecisions(
            candidates
        )

        #expect(annotated.map(\.candidate) == candidates)
        #expect(annotated.map(\.decision) == [
            .confirmed,
            .excluded,
            .undecided,
        ])
    }

    @Test func batchAnnotationUsesOneReadOnlyStatement() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let secondPayment = try await fixture.insertPayment(
            path: "second-payment.pdf",
            contentHash: "hash-second-payment"
        )
        let candidates = [
            try fixture.candidate(),
            try fixture.candidate(payment: secondPayment),
        ]
        try await fixture.repository.save(InvoicePaymentDecisionRecord(
            key: try fixture.key(),
            decision: .confirmed,
            updatedAt: fixture.date
        ))
        let rowCountBefore = try await fixture.rowCount()
        let counter = DecisionSQLReadCounter()
        try await fixture.db.write { database in
            database.trace(options: .statement) { event in
                counter.record(event)
            }
        }
        counter.reset()

        _ = try await fixture.repository.candidatesWithCurrentDecisions(candidates)
        let readCount = counter.value
        try await fixture.db.write { database in
            database.trace(options: [])
        }

        #expect(readCount == 1)
        #expect(try await fixture.rowCount() == rowCountBefore)
    }

    @Test func batchAnnotationDoesNotApplyDecisionAfterEitherContentChanges() async throws {
        for changedDocument in [ChangedDecisionDocument.invoice, .payment] {
            let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
            let candidate = try fixture.candidate()
            try await fixture.repository.save(InvoicePaymentDecisionRecord(
                key: try fixture.key(),
                decision: .confirmed,
                updatedAt: fixture.date
            ))
            let changedDocumentID = changedDocument == .invoice
                ? fixture.invoice.id
                : fixture.payment.id
            try await fixture.changeContentHash(
                documentID: changedDocumentID,
                to: "hash-changed"
            )

            #expect(try await fixture.repository.candidatesWithCurrentDecisions([
                candidate,
            ]).map(\.decision) == [.undecided])
            #expect(try await fixture.rowCount() == 1)

            try await fixture.changeContentHash(
                documentID: changedDocumentID,
                to: changedDocument == .invoice
                    ? fixture.invoice.contentHash
                    : fixture.payment.contentHash
            )

            #expect(try await fixture.repository.candidatesWithCurrentDecisions([
                candidate,
            ]).map(\.decision) == [.confirmed])
        }
    }

    @Test func batchAnnotationSurvivesPathChangesAndDNAReanalysis() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let candidate = try fixture.candidate()
        try await fixture.repository.save(InvoicePaymentDecisionRecord(
            key: try fixture.key(),
            decision: .excluded,
            updatedAt: fixture.date
        ))

        try await fixture.moveDocuments()
        try await fixture.replaceDNASnapshots(analyzerVersion: "2")

        #expect(try await fixture.repository.candidatesWithCurrentDecisions([
            candidate,
        ]).map(\.decision) == [.excluded])
    }

    @Test func emptyBatchAnnotationPerformsNoRead() async throws {
        let fixture = try await InvoicePaymentDecisionRepositoryFixture.make()
        let counter = DecisionSQLReadCounter()
        try await fixture.db.write { database in
            database.trace(options: .statement) { event in
                counter.record(event)
            }
        }
        counter.reset()

        let annotated = try await fixture.repository.candidatesWithCurrentDecisions([])
        let readCount = counter.value
        try await fixture.db.write { database in
            database.trace(options: [])
        }

        #expect(annotated.isEmpty)
        #expect(readCount == 0)
    }
}

private enum ChangedDecisionDocument {
    case invoice
    case payment
}

private final class DecisionSQLReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func reset() {
        lock.withLock { count = 0 }
    }

    func record(_ event: Database.TraceEvent) {
        guard case let .statement(statement) = event,
              statement.sql.hasPrefix("SELECT") || statement.sql.hasPrefix("WITH")
        else {
            return
        }
        lock.withLock { count += 1 }
    }
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
        invoice: DocumentRecord? = nil,
        payment: DocumentRecord? = nil,
        invoiceContentHash: String? = nil,
        paymentContentHash: String? = nil
    ) throws -> InvoicePaymentDecisionKey {
        let invoice = invoice ?? self.invoice
        let payment = payment ?? self.payment
        return try InvoicePaymentDecisionKey(
            relationshipType: .paymentSettlesInvoice,
            invoiceDocumentID: invoice.id,
            paymentDocumentID: payment.id,
            invoiceContentHash: invoiceContentHash ?? invoice.contentHash,
            paymentContentHash: paymentContentHash ?? payment.contentHash
        )
    }

    func insertPayment(path: String, contentHash: String) async throws -> DocumentRecord {
        let document = DocumentRecord(
            id: UUID(),
            sourceRootID: source.id,
            relativePath: path,
            contentHash: contentHash,
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
            try document.insert(connection)
        }
        return document
    }

    func candidate(
        invoice: DocumentRecord? = nil,
        payment: DocumentRecord? = nil
    ) throws -> InvoicePaymentCandidate {
        let invoice = invoice ?? self.invoice
        let payment = payment ?? self.payment
        let invoiceReference = try referenceFinding(
            qualifier: .invoiceNumber,
            displayValue: "INV-42"
        )
        let paymentReference = try referenceFinding(
            qualifier: .paymentReference,
            displayValue: "INV 42"
        )
        return InvoicePaymentCandidate(
            invoice: try currentDocument(
                invoice,
                type: .invoice,
                reference: invoiceReference
            ),
            payment: try currentDocument(
                payment,
                type: .paymentConfirmation,
                reference: paymentReference
            ),
            disposition: .automatic,
            resolverVersion: InvoicePaymentCandidateResolver.version,
            signals: [InvoicePaymentCandidateSignal(
                kind: .referenceNumber,
                invoiceFinding: invoiceReference,
                paymentFinding: paymentReference
            )]
        )
    }

    private func currentDocument(
        _ document: DocumentRecord,
        type: DocumentType,
        reference: DocumentDNAFinding
    ) throws -> CurrentDocumentDNA {
        try CurrentDocumentDNA(
            document: document,
            snapshot: DocumentDNA(
                documentID: document.id,
                schemaVersion: 1,
                analyzerIdentifier: "local-rules",
                analyzerVersion: "2",
                inputContentHash: document.contentHash,
                inputExtractionVersion: "text-v1",
                findings: [
                    try DocumentDNAFinding(
                        kind: .documentType,
                        qualifier: nil,
                        displayValue: type.rawValue,
                        normalizedValue: type.rawValue,
                        secondaryNormalizedValue: nil,
                        confidence: 1,
                        evidence: [try evidence()]
                    ),
                    reference,
                ],
                analyzedAt: date
            )
        )
    }

    private func referenceFinding(
        qualifier: DocumentDNAReferenceNumberKind,
        displayValue: String
    ) throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: .referenceNumber,
            qualifier: qualifier.rawValue,
            displayValue: displayValue,
            normalizedValue: "INV42",
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: [try evidence()]
        )
    }

    private func evidence() throws -> DocumentDNAEvidence {
        try DocumentDNAEvidence(
            pageIndex: 0,
            startUTF16: 0,
            lengthUTF16: 1,
            exactText: "x",
            ocrRegionIndexes: []
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
