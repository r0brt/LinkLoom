import Foundation
import GRDB

public enum InvoicePaymentDecisionRepositoryError: Error, Sendable, Equatable {
    case invalidStoredState
    case staleInput
}

public actor InvoicePaymentDecisionRepository {
    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func save(_ record: InvoicePaymentDecisionRecord) async throws {
        try await dbWriter.write { db in
            guard try Self.matchesCurrentDocuments(record.key, in: db) else {
                throw InvoicePaymentDecisionRepositoryError.staleInput
            }
            try db.execute(
                sql: """
                    INSERT INTO invoicePaymentUserDecision (
                        relationshipType, invoiceDocumentID, paymentDocumentID,
                        invoiceContentHash, paymentContentHash, decision, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (
                        relationshipType, invoiceDocumentID, paymentDocumentID,
                        invoiceContentHash, paymentContentHash
                    ) DO UPDATE SET
                        decision = excluded.decision,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [
                    record.key.relationshipType.rawValue,
                    record.key.invoiceDocumentID,
                    record.key.paymentDocumentID,
                    record.key.invoiceContentHash,
                    record.key.paymentContentHash,
                    record.decision.rawValue,
                    record.updatedAt,
                ]
            )
        }
    }

    public func currentDecision(
        for key: InvoicePaymentDecisionKey
    ) async throws -> InvoicePaymentDecisionRecord? {
        try await dbWriter.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT relationshipType, invoiceDocumentID, paymentDocumentID,
                           invoiceContentHash, paymentContentHash, decision, updatedAt
                    FROM invoicePaymentUserDecision AS userDecision
                    JOIN document AS invoice
                        ON invoice.id = userDecision.invoiceDocumentID
                    JOIN document AS payment
                        ON payment.id = userDecision.paymentDocumentID
                    WHERE userDecision.relationshipType = ?
                        AND userDecision.invoiceDocumentID = ?
                        AND userDecision.paymentDocumentID = ?
                        AND userDecision.invoiceContentHash = ?
                        AND userDecision.paymentContentHash = ?
                        AND invoice.contentHash = userDecision.invoiceContentHash
                        AND payment.contentHash = userDecision.paymentContentHash
                    """,
                arguments: [
                    key.relationshipType.rawValue,
                    key.invoiceDocumentID,
                    key.paymentDocumentID,
                    key.invoiceContentHash,
                    key.paymentContentHash,
                ]
            ) else {
                return nil
            }
            let relationshipTypeValue: String = row["relationshipType"]
            let decisionValue: String = row["decision"]
            guard let relationshipType = DocumentRelationshipType(
                rawValue: relationshipTypeValue
            ),
            let decision = InvoicePaymentUserDecision(rawValue: decisionValue)
            else {
                throw InvoicePaymentDecisionRepositoryError.invalidStoredState
            }
            return InvoicePaymentDecisionRecord(
                key: try InvoicePaymentDecisionKey(
                    relationshipType: relationshipType,
                    invoiceDocumentID: row["invoiceDocumentID"],
                    paymentDocumentID: row["paymentDocumentID"],
                    invoiceContentHash: row["invoiceContentHash"],
                    paymentContentHash: row["paymentContentHash"]
                ),
                decision: decision,
                updatedAt: row["updatedAt"]
            )
        }
    }

    public func delete(_ key: InvoicePaymentDecisionKey) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    DELETE FROM invoicePaymentUserDecision
                    WHERE relationshipType = ?
                        AND invoiceDocumentID = ?
                        AND paymentDocumentID = ?
                        AND invoiceContentHash = ?
                        AND paymentContentHash = ?
                    """,
                arguments: [
                    key.relationshipType.rawValue,
                    key.invoiceDocumentID,
                    key.paymentDocumentID,
                    key.invoiceContentHash,
                    key.paymentContentHash,
                ]
            )
        }
    }

    private static func matchesCurrentDocuments(
        _ key: InvoicePaymentDecisionKey,
        in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM document AS invoice, document AS payment
                    WHERE invoice.id = ?
                        AND invoice.contentHash = ?
                        AND payment.id = ?
                        AND payment.contentHash = ?
                )
                """,
            arguments: [
                key.invoiceDocumentID,
                key.invoiceContentHash,
                key.paymentDocumentID,
                key.paymentContentHash,
            ]
        ) ?? false
    }
}
