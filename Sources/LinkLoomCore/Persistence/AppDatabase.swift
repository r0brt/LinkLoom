import Foundation
import GRDB

public enum AppDatabase {
    public static func makeQueue(at url: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: url.path)
        try migrate(queue)
        return queue
    }

    public static func migrate(_ writer: any DatabaseWriter) throws {
        try makeMigrator().migrate(writer)
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_catalog") { db in
            try db.create(table: "sourceRoot") { table in
                table.column("id", .text).primaryKey()
                table.column("displayName", .text).notNull()
                table.column("pathHint", .text).notNull()
                table.column("bookmarkData", .blob).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("lastScanAt", .datetime)
            }
            try db.create(table: "document") { table in
                table.column("id", .text).primaryKey()
                table.column("sourceRootID", .text).notNull()
                    .references("sourceRoot", onDelete: .cascade)
                table.column("relativePath", .text).notNull()
                table.column("contentHash", .text).notNull()
                table.column("byteCount", .integer).notNull()
                table.column("modifiedAt", .datetime).notNull()
                table.column("mediaType", .text).notNull()
                table.column("status", .text).notNull()
                table.column("availability", .text).notNull()
                table.column("pageCount", .integer)
                table.column("failureCode", .text)
                table.column("lastSeenAt", .datetime).notNull()
                table.uniqueKey(["sourceRootID", "relativePath"])
            }
            try db.create(
                index: "document_source_relative_unique",
                on: "document",
                columns: ["sourceRootID", "relativePath"],
                unique: true
            )
            try db.create(index: "document_content_hash", on: "document", columns: ["contentHash"])
            try db.create(index: "document_status", on: "document", columns: ["status"])
        }
        migrator.registerMigration("v2_extraction") { db in
            try db.create(table: "documentExtraction") { table in
                table.column("documentID", .text).primaryKey()
                    .references("document", onDelete: .cascade)
                table.column("analysisVersion", .text).notNull()
                table.column("method", .text).notNull()
                table.column("joinedText", .text).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "extractedPage") { table in
                table.column("documentID", .text).notNull()
                    .references("document", onDelete: .cascade)
                table.column("pageIndex", .integer).notNull()
                table.column("text", .text).notNull()
                table.column("regionsJSON", .blob).notNull()
                table.primaryKey(["documentID", "pageIndex"])
            }
            try db.create(virtualTable: "extractionFTS", using: FTS5()) { table in
                table.column("documentID").notIndexed()
                table.column("joinedText")
                table.tokenizer = .unicode61()
            }
            try db.execute(sql: """
                CREATE TRIGGER documentExtraction_delete_fts
                AFTER DELETE ON documentExtraction
                BEGIN
                    DELETE FROM extractionFTS WHERE documentID = OLD.documentID;
                END
                """)
        }
        migrator.registerMigration("v3_last_fingerprint_at") { db in
            try db.alter(table: "document") { table in
                table.add(column: "lastFingerprintAt", .datetime)
            }
            try db.execute(sql: "UPDATE document SET lastFingerprintAt = lastSeenAt")
        }
        migrator.registerMigration("v4_remove_redundant_document_index") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS document_source_relative_unique")
        }
        migrator.registerMigration("v5_document_dna") { db in
            try db.create(table: "documentDNA") { table in
                table.column("documentID", .text).primaryKey()
                    .references("document", onDelete: .cascade)
                table.column("schemaVersion", .integer).notNull()
                    .check(sql: "schemaVersion > 0")
                table.column("analyzerIdentifier", .text).notNull()
                    .check(sql: "length(analyzerIdentifier) > 0")
                table.column("analyzerVersion", .text).notNull()
                    .check(sql: "length(analyzerVersion) > 0")
                table.column("inputContentHash", .text).notNull()
                    .check(sql: "length(inputContentHash) > 0")
                table.column("inputExtractionVersion", .text).notNull()
                    .check(sql: "length(inputExtractionVersion) > 0")
                table.column("analyzedAt", .datetime).notNull()
            }
            try db.create(table: "documentDNAFinding") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("documentID", .text).notNull()
                    .references("documentDNA", onDelete: .cascade)
                table.column("kind", .text).notNull()
                    .check(sql: "length(kind) > 0")
                table.column("qualifier", .text)
                table.column("displayValue", .text).notNull()
                table.column("normalizedValue", .text).notNull()
                    .check(sql: "length(normalizedValue) > 0")
                table.column("secondaryNormalizedValue", .text)
                table.column("confidence", .double).notNull()
                    .check(sql: "confidence >= 0 AND confidence <= 1")
                table.column("sortOrder", .integer).notNull()
                    .check(sql: "sortOrder >= 0")
                table.uniqueKey(["documentID", "sortOrder"])
            }
            try db.create(table: "documentDNAEvidence") { table in
                table.column("findingID", .integer).notNull()
                    .references("documentDNAFinding", onDelete: .cascade)
                table.column("evidenceOrder", .integer).notNull()
                    .check(sql: "evidenceOrder >= 0")
                table.column("pageIndex", .integer).notNull()
                    .check(sql: "pageIndex >= 0")
                table.column("startUTF16", .integer).notNull()
                    .check(sql: "startUTF16 >= 0")
                table.column("lengthUTF16", .integer).notNull()
                    .check(sql: "lengthUTF16 > 0")
                table.column("exactText", .text).notNull()
                    .check(sql: "length(exactText) > 0")
                table.column("ocrRegionIndexesJSON", .blob).notNull()
                table.primaryKey(["findingID", "evidenceOrder"])
            }
            try db.create(table: "documentDNAAnalysisState") { table in
                table.column("documentID", .text).primaryKey()
                    .references("document", onDelete: .cascade)
                table.column("targetSchemaVersion", .integer).notNull()
                    .check(sql: "targetSchemaVersion > 0")
                table.column("targetAnalyzerIdentifier", .text).notNull()
                    .check(sql: "length(targetAnalyzerIdentifier) > 0")
                table.column("targetAnalyzerVersion", .text).notNull()
                    .check(sql: "length(targetAnalyzerVersion) > 0")
                table.column("inputContentHash", .text).notNull()
                    .check(sql: "length(inputContentHash) > 0")
                table.column("inputExtractionVersion", .text).notNull()
                    .check(sql: "length(inputExtractionVersion) > 0")
                table.column("status", .text).notNull()
                    .check(sql: "status IN ('analyzing', 'ready', 'failed')")
                table.column("failureCode", .text)
                table.column("updatedAt", .datetime).notNull()
                table.check(sql: """
                    (status = 'failed' AND failureCode IS NOT NULL AND length(failureCode) > 0)
                    OR (status <> 'failed' AND failureCode IS NULL)
                    """)
            }
            try db.create(
                index: "document_dna_finding_kind_value",
                on: "documentDNAFinding",
                columns: ["kind", "normalizedValue"]
            )
            try db.create(
                index: "document_dna_finding_document_kind",
                on: "documentDNAFinding",
                columns: ["documentID", "kind"]
            )
            try db.create(
                index: "document_dna_one_classification",
                on: "documentDNAFinding",
                columns: ["documentID"],
                unique: true,
                condition: Column("kind") == "documentType"
            )
        }
        migrator.registerMigration("v6_invoice_payment_user_decisions") { db in
            try db.create(table: "invoicePaymentUserDecision") { table in
                table.column("relationshipType", .text).notNull()
                    .check(sql: "relationshipType = 'paymentSettlesInvoice'")
                table.column("invoiceDocumentID", .text).notNull()
                    .references("document", onDelete: .cascade)
                table.column("paymentDocumentID", .text).notNull()
                    .references("document", onDelete: .cascade)
                table.column("invoiceContentHash", .text).notNull()
                    .check(sql: "length(invoiceContentHash) > 0")
                table.column("paymentContentHash", .text).notNull()
                    .check(sql: "length(paymentContentHash) > 0")
                table.column("decision", .text).notNull()
                    .check(sql: "decision IN ('confirmed', 'excluded')")
                table.column("updatedAt", .datetime).notNull()
                table.primaryKey([
                    "relationshipType",
                    "invoiceDocumentID",
                    "paymentDocumentID",
                    "invoiceContentHash",
                    "paymentContentHash",
                ])
                table.check(sql: "invoiceDocumentID <> paymentDocumentID")
            }
            try db.create(
                index: "invoice_payment_decision_invoice_document",
                on: "invoicePaymentUserDecision",
                columns: ["invoiceDocumentID"]
            )
            try db.create(
                index: "invoice_payment_decision_payment_document",
                on: "invoicePaymentUserDecision",
                columns: ["paymentDocumentID"]
            )
        }
        return migrator
    }
}
