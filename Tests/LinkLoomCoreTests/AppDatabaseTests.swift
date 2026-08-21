import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("App database")
struct AppDatabaseTests {
    @Test func initialMigrationCreatesCatalogTables() throws {
        let db = try TestDatabase.make()
        try db.read { connection in
            let sourceRootExists = try connection.tableExists("sourceRoot")
            let documentExists = try connection.tableExists("document")
            let hasSourceRelativeIndex = try connection.indexes(on: "document")
                .contains { $0.name == "document_source_relative_unique" }

            #expect(sourceRootExists)
            #expect(documentExists)
            #expect(hasSourceRelativeIndex)
        }
    }

    @Test func catalogMigrationAddsAndBackfillsLastFingerprintDate() throws {
        let db = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(db, upTo: "v2_extraction")
        let sourceID = UUID()
        let documentID = UUID()
        let lastSeenAt = Date(timeIntervalSince1970: 123)
        try db.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO sourceRoot
                        (id, displayName, pathHint, bookmarkData, createdAt, lastScanAt)
                    VALUES (?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [sourceID, "Source", "/Source", Data(), lastSeenAt]
            )
            try connection.execute(
                sql: """
                    INSERT INTO document
                        (id, sourceRootID, relativePath, contentHash, byteCount, modifiedAt,
                         mediaType, status, availability, pageCount, failureCode, lastSeenAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)
                    """,
                arguments: [
                    documentID,
                    sourceID,
                    "a.pdf",
                    "hash-a",
                    4,
                    lastSeenAt,
                    SupportedMediaType.pdf,
                    DocumentStatus.ready,
                    DocumentAvailability.available,
                    lastSeenAt,
                ]
            )
        }

        try AppDatabase.migrate(db)

        try db.read { connection in
            let columns = try connection.columns(in: "document")
            let stored = try DocumentRecord.fetchOne(connection, key: documentID)
            #expect(columns.contains { $0.name == "lastFingerprintAt" })
            #expect(stored?.lastFingerprintAt == lastSeenAt)
        }
    }
}
