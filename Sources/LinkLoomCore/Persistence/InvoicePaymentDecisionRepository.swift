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
            try Self.currentRecords(in: db, keys: [key])[key]
        }
    }

    static func currentRecords(
        in db: Database,
        keys: [InvoicePaymentDecisionKey]
    ) throws -> [InvoicePaymentDecisionKey: InvoicePaymentDecisionRecord] {
        guard !keys.isEmpty else { return [:] }
        var uniqueKeys: [InvoicePaymentDecisionKey] = []
        var seenKeys: Set<InvoicePaymentDecisionKey> = []
        for key in keys where seenKeys.insert(key).inserted {
            uniqueKeys.append(key)
        }
        var arguments = StatementArguments()
        let requestedRows = uniqueKeys.map { key in
            _ = arguments.append(contentsOf: [
                key.relationshipType.rawValue,
                key.invoiceDocumentID,
                key.paymentDocumentID,
                key.invoiceContentHash,
                key.paymentContentHash,
            ])
            return "(?, ?, ?, ?, ?)"
        }.joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
                WITH requested (
                    relationshipType, invoiceDocumentID, paymentDocumentID,
                    invoiceContentHash, paymentContentHash
                ) AS (
                    VALUES \(requestedRows)
                )
                SELECT userDecision.relationshipType, userDecision.invoiceDocumentID,
                       userDecision.paymentDocumentID, userDecision.invoiceContentHash,
                       userDecision.paymentContentHash, userDecision.decision,
                       userDecision.updatedAt
                FROM requested
                JOIN document AS invoice
                    ON invoice.id = requested.invoiceDocumentID
                    AND invoice.contentHash = requested.invoiceContentHash
                JOIN document AS payment
                    ON payment.id = requested.paymentDocumentID
                    AND payment.contentHash = requested.paymentContentHash
                JOIN invoicePaymentUserDecision AS userDecision
                    ON userDecision.relationshipType = requested.relationshipType
                    AND userDecision.invoiceDocumentID = requested.invoiceDocumentID
                    AND userDecision.paymentDocumentID = requested.paymentDocumentID
                    AND userDecision.invoiceContentHash = requested.invoiceContentHash
                    AND userDecision.paymentContentHash = requested.paymentContentHash
                """,
            arguments: arguments
        )
        var records: [InvoicePaymentDecisionKey: InvoicePaymentDecisionRecord] = [:]
        for row in rows {
            let relationshipTypeValue: String = row["relationshipType"]
            let decisionValue: String = row["decision"]
            guard let relationshipType = DocumentRelationshipType(
                rawValue: relationshipTypeValue
            ),
            let decision = InvoicePaymentUserDecision(rawValue: decisionValue)
            else {
                throw InvoicePaymentDecisionRepositoryError.invalidStoredState
            }
            let key = try InvoicePaymentDecisionKey(
                relationshipType: relationshipType,
                invoiceDocumentID: row["invoiceDocumentID"],
                paymentDocumentID: row["paymentDocumentID"],
                invoiceContentHash: row["invoiceContentHash"],
                paymentContentHash: row["paymentContentHash"]
            )
            records[key] = InvoicePaymentDecisionRecord(
                key: key,
                decision: decision,
                updatedAt: row["updatedAt"]
            )
        }
        return records
    }

    public func candidatesWithCurrentDecisions(
        _ candidates: [InvoicePaymentCandidate]
    ) async throws -> [InvoicePaymentCandidateWithDecision] {
        guard !candidates.isEmpty else { return [] }
        let keys = try candidates.map { candidate in
            try InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: candidate.invoice.document.id,
                paymentDocumentID: candidate.payment.document.id,
                invoiceContentHash: candidate.invoice.document.contentHash,
                paymentContentHash: candidate.payment.document.contentHash
            )
        }
        let recordsByKey = try await dbWriter.read { db in
            try Self.currentRecords(in: db, keys: keys)
        }
        return zip(candidates, keys).map { candidate, key in
            InvoicePaymentCandidateWithDecision(
                candidate: candidate,
                decision: recordsByKey[key].map { record in
                    switch record.decision {
                    case .confirmed: .confirmed
                    case .excluded: .excluded
                    }
                } ?? .undecided
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
