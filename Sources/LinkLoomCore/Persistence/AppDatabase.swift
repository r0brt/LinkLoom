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
        try migrator.migrate(writer)
    }
}
