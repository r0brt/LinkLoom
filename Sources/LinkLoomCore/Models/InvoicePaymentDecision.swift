import Foundation

public enum DocumentRelationshipType: String, Sendable, Equatable {
    case paymentSettlesInvoice
}

public enum InvoicePaymentUserDecision: String, Sendable, Equatable {
    case confirmed
    case excluded
}

public enum InvoicePaymentDecisionValidationError: Error, Sendable, Equatable {
    case invalidKey
}

public struct InvoicePaymentDecisionKey: Sendable, Equatable, Hashable {
    public let relationshipType: DocumentRelationshipType
    public let invoiceDocumentID: UUID
    public let paymentDocumentID: UUID
    public let invoiceContentHash: String
    public let paymentContentHash: String

    public init(
        relationshipType: DocumentRelationshipType,
        invoiceDocumentID: UUID,
        paymentDocumentID: UUID,
        invoiceContentHash: String,
        paymentContentHash: String
    ) throws {
        guard invoiceDocumentID != paymentDocumentID,
              !invoiceContentHash.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              !paymentContentHash.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw InvoicePaymentDecisionValidationError.invalidKey
        }
        self.relationshipType = relationshipType
        self.invoiceDocumentID = invoiceDocumentID
        self.paymentDocumentID = paymentDocumentID
        self.invoiceContentHash = invoiceContentHash
        self.paymentContentHash = paymentContentHash
    }
}

public struct InvoicePaymentDecisionRecord: Sendable, Equatable {
    public let key: InvoicePaymentDecisionKey
    public let decision: InvoicePaymentUserDecision
    public let updatedAt: Date

    public init(
        key: InvoicePaymentDecisionKey,
        decision: InvoicePaymentUserDecision,
        updatedAt: Date
    ) {
        self.key = key
        self.decision = decision
        self.updatedAt = updatedAt
    }
}
