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
        try migrator.migrate(writer)
    }
}
