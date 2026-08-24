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
            let sourceRelativeIndexes = try connection.indexes(on: "document")
                .filter {
                    $0.isUnique
                        && $0.columns == ["sourceRootID", "relativePath"]
                }

            #expect(sourceRootExists)
            #expect(documentExists)
            #expect(sourceRelativeIndexes.count == 1)
            #expect(sourceRelativeIndexes.first?.origin == .uniqueConstraint)
        }
    }

    @Test func catalogMigrationRemovesRedundantSourceRelativeIndex() throws {
        let db = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(db, upTo: "v3_last_fingerprint_at")

        try db.read { connection in
            let sourceRelativeIndexes = try connection.indexes(on: "document")
                .filter {
                    $0.isUnique
                        && $0.columns == ["sourceRootID", "relativePath"]
                }
            #expect(sourceRelativeIndexes.count == 2)
            #expect(
                sourceRelativeIndexes.contains {
                    $0.name == "document_source_relative_unique"
                        && $0.origin == .createIndex
                }
            )
        }

        try AppDatabase.migrate(db)

        try db.read { connection in
            let sourceRelativeIndexes = try connection.indexes(on: "document")
                .filter {
                    $0.isUnique
                        && $0.columns == ["sourceRootID", "relativePath"]
                }
            #expect(sourceRelativeIndexes.count == 1)
            #expect(sourceRelativeIndexes.first?.origin == .uniqueConstraint)
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

    @Test func documentDNAMigrationCreatesVersionedSchema() throws {
        let db = try TestDatabase.make()
        try db.read { connection in
            let expectedTables = [
                "documentDNA",
                "documentDNAFinding",
                "documentDNAEvidence",
                "documentDNAAnalysisState",
            ]
            let tablesExist = try expectedTables.allSatisfy {
                try connection.tableExists($0)
            }

            #expect(tablesExist)
            guard tablesExist else { return }

            let findingIndexNames = Set(
                try connection.indexes(on: "documentDNAFinding").map(\.name)
            )
            #expect(findingIndexNames.contains("document_dna_finding_kind_value"))
            #expect(findingIndexNames.contains("document_dna_finding_document_kind"))
            #expect(findingIndexNames.contains("document_dna_one_classification"))

            let stateColumnNames = try connection
                .columns(in: "documentDNAAnalysisState")
                .map(\.name)
            #expect(stateColumnNames == [
                "documentID",
                "targetSchemaVersion",
                "targetAnalyzerIdentifier",
                "targetAnalyzerVersion",
                "inputContentHash",
                "inputExtractionVersion",
                "status",
                "failureCode",
                "updatedAt",
            ])
        }
    }

    @Test func documentDNAMigrationPreservesV4ExtractionData() throws {
        let db = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(db, upTo: "v4_remove_redundant_document_index")
        let sourceID = UUID()
        let documentID = UUID()
        let storedAt = Date(timeIntervalSince1970: 1_234)
        let pageText = "Existing extracted page"
        try db.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO sourceRoot
                        (id, displayName, pathHint, bookmarkData, createdAt, lastScanAt)
                    VALUES (?, 'Existing Source', '/Existing', ?, ?, ?)
                    """,
                arguments: [sourceID, Data([0x01, 0x02]), storedAt, storedAt]
            )
            try connection.execute(
                sql: """
                    INSERT INTO document
                        (id, sourceRootID, relativePath, contentHash, byteCount, modifiedAt,
                         mediaType, status, availability, pageCount, failureCode, lastSeenAt,
                         lastFingerprintAt)
                    VALUES (?, ?, 'existing.pdf', 'hash-existing', 42, ?, 'pdf', 'ready',
                            'available', 1, NULL, ?, ?)
                    """,
                arguments: [documentID, sourceID, storedAt, storedAt, storedAt]
            )
            try connection.execute(
                sql: """
                    INSERT INTO documentExtraction
                        (documentID, analysisVersion, method, joinedText, updatedAt)
                    VALUES (?, 'text-v1', 'embeddedPDFText', ?, ?)
                    """,
                arguments: [documentID, pageText, storedAt]
            )
            try connection.execute(
                sql: """
                    INSERT INTO extractedPage
                        (documentID, pageIndex, text, regionsJSON)
                    VALUES (?, 0, ?, ?)
                    """,
                arguments: [documentID, pageText, Data("[]".utf8)]
            )
            try connection.execute(
                sql: "INSERT INTO extractionFTS (documentID, joinedText) VALUES (?, ?)",
                arguments: [documentID, pageText]
            )
        }

        try AppDatabase.migrate(db)

        try db.read { connection in
            let dnaTableExists = try connection.tableExists("documentDNA")
            #expect(dnaTableExists)
            guard dnaTableExists else { return }

            let storedExtraction = try Row.fetchOne(
                connection,
                sql: """
                    SELECT analysisVersion, method, joinedText, updatedAt
                    FROM documentExtraction
                    WHERE documentID = ?
                    """,
                arguments: [documentID]
            )
            let storedPage = try Row.fetchOne(
                connection,
                sql: """
                    SELECT pageIndex, text, regionsJSON
                    FROM extractedPage
                    WHERE documentID = ?
                    """,
                arguments: [documentID]
            )
            let ftsText = try String.fetchOne(
                connection,
                sql: "SELECT joinedText FROM extractionFTS WHERE documentID = ?",
                arguments: [documentID]
            )
            let extraction = try #require(storedExtraction)
            let page = try #require(storedPage)

            #expect(extraction["analysisVersion"] as String == "text-v1")
            #expect(extraction["method"] as String == "embeddedPDFText")
            #expect(extraction["joinedText"] as String == pageText)
            #expect(extraction["updatedAt"] as Date == storedAt)
            #expect(page["pageIndex"] as Int == 0)
            #expect(page["text"] as String == pageText)
            #expect(page["regionsJSON"] as Data == Data("[]".utf8))
            #expect(ftsText == pageText)
        }
    }

    @Test func removingSourceCascadesDocumentDNAData() throws {
        let db = try TestDatabase.make()
        let dnaTableExists = try db.read {
            try $0.tableExists("documentDNA")
        }
        #expect(dnaTableExists)
        guard dnaTableExists else { return }

        let sourceID = UUID()
        let documentID = UUID()
        let storedAt = Date(timeIntervalSince1970: 2_345)
        try db.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO sourceRoot
                        (id, displayName, pathHint, bookmarkData, createdAt, lastScanAt)
                    VALUES (?, 'Synthetic Source', '/Synthetic', ?, ?, NULL)
                    """,
                arguments: [sourceID, Data([0x03]), storedAt]
            )
            try connection.execute(
                sql: """
                    INSERT INTO document
                        (id, sourceRootID, relativePath, contentHash, byteCount, modifiedAt,
                         mediaType, status, availability, pageCount, failureCode, lastSeenAt,
                         lastFingerprintAt)
                    VALUES (?, ?, 'invoice.pdf', 'hash-invoice', 64, ?, 'pdf', 'ready',
                            'available', 1, NULL, ?, ?)
                    """,
                arguments: [documentID, sourceID, storedAt, storedAt, storedAt]
            )
            try connection.execute(
                sql: """
                    INSERT INTO documentDNA
                        (documentID, schemaVersion, analyzerIdentifier, analyzerVersion,
                         inputContentHash, inputExtractionVersion, analyzedAt)
                    VALUES (?, 1, 'local-rules', '1', 'hash-invoice', 'text-v1', ?)
                    """,
                arguments: [documentID, storedAt]
            )
            try connection.execute(
                sql: """
                    INSERT INTO documentDNAFinding
                        (documentID, kind, qualifier, displayValue, normalizedValue,
                         secondaryNormalizedValue, confidence, sortOrder)
                    VALUES (?, 'documentType', NULL, 'invoice', 'invoice', NULL, 0.9, 0)
                    """,
                arguments: [documentID]
            )
            let findingID = connection.lastInsertedRowID
            try connection.execute(
                sql: """
                    INSERT INTO documentDNAEvidence
                        (findingID, evidenceOrder, pageIndex, startUTF16, lengthUTF16,
                         exactText, ocrRegionIndexesJSON)
                    VALUES (?, 0, 0, 0, 8, 'Rechnung', ?)
                    """,
                arguments: [findingID, Data("[]".utf8)]
            )
            try connection.execute(
                sql: """
                    INSERT INTO documentDNAAnalysisState
                        (documentID, targetSchemaVersion, targetAnalyzerIdentifier,
                         targetAnalyzerVersion, inputContentHash, inputExtractionVersion,
                         status, failureCode, updatedAt)
                    VALUES (?, 1, 'local-rules', '1', 'hash-invoice', 'text-v1',
                            'ready', NULL, ?)
                    """,
                arguments: [documentID, storedAt]
            )

            try connection.execute(
                sql: "DELETE FROM sourceRoot WHERE id = ?",
                arguments: [sourceID]
            )
        }

        try db.read { connection in
            let dnaCount = try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM documentDNA")
            let findingCount = try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM documentDNAFinding"
            )
            let evidenceCount = try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM documentDNAEvidence"
            )
            let stateCount = try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM documentDNAAnalysisState"
            )

            #expect(dnaCount == 0)
            #expect(findingCount == 0)
            #expect(evidenceCount == 0)
            #expect(stateCount == 0)
        }
    }
}
