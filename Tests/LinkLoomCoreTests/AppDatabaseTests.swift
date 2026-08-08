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
}
