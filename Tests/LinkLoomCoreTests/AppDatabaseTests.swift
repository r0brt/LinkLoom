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

    @Test func invoicePaymentDecisionMigrationCreatesConstrainedSchema() throws {
        let db = try TestDatabase.make()

        try db.read { connection in
            let tableExists = try connection.tableExists("invoicePaymentUserDecision")
            #expect(tableExists)
            guard tableExists else { return }

            #expect(try connection.columns(in: "invoicePaymentUserDecision").map(\.name) == [
                "relationshipType",
                "invoiceDocumentID",
                "paymentDocumentID",
                "invoiceContentHash",
                "paymentContentHash",
                "decision",
                "updatedAt",
            ])
            let indexes = try connection.indexes(on: "invoicePaymentUserDecision")
            let primaryKey = indexes.filter { $0.origin == .primaryKeyConstraint }.first
            #expect(primaryKey?.isUnique == true)
            #expect(primaryKey?.columns == [
                "relationshipType",
                "invoiceDocumentID",
                "paymentDocumentID",
                "invoiceContentHash",
                "paymentContentHash",
            ])
            #expect(indexes.contains {
                $0.name == "invoice_payment_decision_invoice_document"
                    && $0.columns == ["invoiceDocumentID"]
            })
            #expect(indexes.contains {
                $0.name == "invoice_payment_decision_payment_document"
                    && $0.columns == ["paymentDocumentID"]
            })
        }
    }

    @Test func invoicePaymentDecisionMigrationRejectsInvalidStoredValues() throws {
        let fixture = try DecisionMigrationFixture.make()

        try fixture.db.write { connection in
            #expect(throws: DatabaseError.self) {
                try fixture.insertDecision(
                    in: connection,
                    relationshipType: "unrelated",
                    decision: "confirmed"
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDecision(
                    in: connection,
                    decision: "pending",
                    invoiceContentHash: "invalid-decision"
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDecision(
                    in: connection,
                    paymentDocumentID: fixture.invoiceID,
                    invoiceContentHash: "self-pair"
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDecision(
                    in: connection,
                    invoiceContentHash: "",
                    paymentContentHash: "empty-hash"
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDecision(
                    in: connection,
                    invoiceContentHash: " \t\n",
                    paymentContentHash: "whitespace-invoice"
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDecision(
                    in: connection,
                    invoiceContentHash: "whitespace-payment",
                    paymentContentHash: "\r\n\t "
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDecision(
                    in: connection,
                    invoiceContentHash: "\u{00A0}",
                    paymentContentHash: "unicode-whitespace"
                )
            }
        }
    }

    @Test func deletingEitherDocumentCascadesInvoicePaymentDecision() throws {
        for deletedRole in [DecisionDocumentRole.invoice, .payment] {
            let fixture = try DecisionMigrationFixture.make()
            try fixture.db.write { connection in
                try fixture.insertDecision(in: connection)

                try connection.execute(
                    sql: "DELETE FROM document WHERE id = ?",
                    arguments: [
                        deletedRole == .invoice ? fixture.invoiceID : fixture.paymentID,
                    ]
                )

                #expect(try Int.fetchOne(
                    connection,
                    sql: "SELECT COUNT(*) FROM invoicePaymentUserDecision"
                ) == 0)
            }
        }
    }

    @Test func deletingSourceCascadesInvoicePaymentDecision() throws {
        let fixture = try DecisionMigrationFixture.make()
        try fixture.db.write { connection in
            try fixture.insertDecision(in: connection)

            try connection.execute(
                sql: "DELETE FROM sourceRoot WHERE id = ?",
                arguments: [fixture.sourceID]
            )

            #expect(try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM invoicePaymentUserDecision"
            ) == 0)
        }
    }

    @Test func invoicePaymentDecisionMigrationPreservesV5DNAWithoutBackfill() throws {
        let db = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(db, upTo: "v5_document_dna")
        let sourceID = UUID()
        let documentID = UUID()
        let storedAt = Date(timeIntervalSince1970: 4_567)
        try db.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO sourceRoot
                        (id, displayName, pathHint, bookmarkData, createdAt, lastScanAt)
                    VALUES (?, 'Existing v5 Source', '/Existing-v5', ?, ?, NULL)
                    """,
                arguments: [sourceID, Data([0x05]), storedAt]
            )
            try connection.execute(
                sql: """
                    INSERT INTO document
                        (id, sourceRootID, relativePath, contentHash, byteCount,
                         modifiedAt, mediaType, status, availability, pageCount,
                         failureCode, lastSeenAt, lastFingerprintAt)
                    VALUES (?, ?, 'existing-v5.pdf', 'hash-existing-v5', 64, ?,
                            'pdf', 'ready', 'available', 1, NULL, ?, ?)
                    """,
                arguments: [documentID, sourceID, storedAt, storedAt, storedAt]
            )
            try connection.execute(
                sql: """
                    INSERT INTO documentDNA
                        (documentID, schemaVersion, analyzerIdentifier, analyzerVersion,
                         inputContentHash, inputExtractionVersion, analyzedAt)
                    VALUES (?, 1, 'local-rules', '2', 'hash-existing-v5', 'text-v1', ?)
                    """,
                arguments: [documentID, storedAt]
            )
        }

        try AppDatabase.migrate(db)

        try db.read { connection in
            let storedDNA = try Row.fetchOne(
                connection,
                sql: """
                    SELECT schemaVersion, analyzerIdentifier, analyzerVersion,
                           inputContentHash, inputExtractionVersion, analyzedAt
                    FROM documentDNA WHERE documentID = ?
                    """,
                arguments: [documentID]
            )
            let dna = try #require(storedDNA)
            #expect(dna["schemaVersion"] as Int == 1)
            #expect(dna["analyzerIdentifier"] as String == "local-rules")
            #expect(dna["analyzerVersion"] as String == "2")
            #expect(dna["inputContentHash"] as String == "hash-existing-v5")
            #expect(dna["inputExtractionVersion"] as String == "text-v1")
            #expect(dna["analyzedAt"] as Date == storedAt)
            #expect(try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM invoicePaymentUserDecision"
            ) == 0)
        }
    }

    @Test func dossierMigrationCreatesConstrainedSchema() throws {
        let db = try TestDatabase.make()

        try db.read { connection in
            let dossierExists = try connection.tableExists("dossier")
            let exclusionsExist = try connection.tableExists("dossierMembershipExclusion")
            #expect(dossierExists)
            #expect(exclusionsExist)
            guard dossierExists && exclusionsExist else { return }

            #expect(try connection.columns(in: "dossier").map(\.name) == [
                "id",
                "kind",
                "displayName",
                "anchorDocumentID",
                "personAnchorID",
                "createdAt",
                "updatedAt",
            ])
            #expect(try connection.columns(in: "dossierMembershipExclusion").map(\.name) == [
                "dossierID",
                "documentID",
                "revisionID",
                "excludedAt",
            ])

            let dossierIndexes = try connection.indexes(on: "dossier")
            #expect(dossierIndexes.contains {
                $0.isUnique && $0.columns == ["anchorDocumentID"]
            })
            #expect(dossierIndexes.contains {
                $0.isUnique && $0.columns == ["personAnchorID"]
            })

            let exclusionIndexes = try connection.indexes(on: "dossierMembershipExclusion")
            let exclusionPrimaryKey = exclusionIndexes.first {
                $0.origin == .primaryKeyConstraint
            }
            #expect(exclusionPrimaryKey?.columns == ["dossierID", "documentID"])
            #expect(exclusionIndexes.contains {
                $0.isUnique && $0.columns == ["revisionID"]
            })
        }
    }

    @Test func dossierMigrationPreservesV6DataWithoutBackfill() throws {
        let db = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(db, upTo: "v6_invoice_payment_user_decisions")
        let sourceID = UUID()
        let invoiceID = UUID()
        let paymentID = UUID()
        let storedAt = Date(timeIntervalSince1970: 5_678)
        try db.write { connection in
            try insertDossierSource(
                in: connection,
                sourceID: sourceID,
                documentIDs: [invoiceID, paymentID],
                storedAt: storedAt
            )
            try connection.execute(
                sql: """
                    INSERT INTO invoicePaymentUserDecision
                        (relationshipType, invoiceDocumentID, paymentDocumentID,
                         invoiceContentHash, paymentContentHash, decision, updatedAt)
                    VALUES ('paymentSettlesInvoice', ?, ?, 'existing-invoice-hash',
                            'existing-payment-hash', 'confirmed', ?)
                    """,
                arguments: [invoiceID, paymentID, storedAt]
            )
        }

        try AppDatabase.migrate(db)

        try db.read { connection in
            let decision = try Row.fetchOne(
                connection,
                sql: """
                    SELECT relationshipType, invoiceDocumentID, paymentDocumentID,
                           invoiceContentHash, paymentContentHash, decision, updatedAt
                    FROM invoicePaymentUserDecision
                    """
            )
            let storedDecision = try #require(decision)
            #expect(storedDecision["relationshipType"] as String == "paymentSettlesInvoice")
            #expect(storedDecision["invoiceDocumentID"] as UUID == invoiceID)
            #expect(storedDecision["paymentDocumentID"] as UUID == paymentID)
            #expect(storedDecision["invoiceContentHash"] as String == "existing-invoice-hash")
            #expect(storedDecision["paymentContentHash"] as String == "existing-payment-hash")
            #expect(storedDecision["decision"] as String == "confirmed")
            #expect(storedDecision["updatedAt"] as Date == storedAt)
            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM dossier") == 0)
            #expect(try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM dossierMembershipExclusion"
            ) == 0)
        }
    }

    @Test func dossierMigrationRejectsDuplicateAnchorAndInvalidKind() throws {
        let fixture = try DossierMigrationFixture.make()

        try fixture.db.write { connection in
            try fixture.insertDossier(in: connection)

            #expect(throws: DatabaseError.self) {
                try fixture.insertDossier(
                    in: connection,
                    id: UUID(),
                    displayName: "Duplicate anchor"
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDossier(
                    in: connection,
                    id: UUID(),
                    kind: "other"
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDossier(
                    in: connection,
                    id: UUID(),
                    displayName: " ",
                    anchorDocumentID: fixture.excludedID
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDossier(
                    in: connection,
                    id: UUID(),
                    anchorDocumentID: fixture.excludedID,
                    createdAt: fixture.storedAt.addingTimeInterval(1),
                    updatedAt: fixture.storedAt
                )
            }
        }
    }

    @Test func deletingAnchorDocumentCascadesDossierAndExclusions() throws {
        let fixture = try DossierMigrationFixture.make()
        let dossierID = UUID()
        try fixture.db.write { connection in
            try fixture.insertDossier(in: connection, id: dossierID)
            try fixture.insertExclusion(in: connection, dossierID: dossierID)

            try connection.execute(
                sql: "DELETE FROM document WHERE id = ?",
                arguments: [fixture.anchorID]
            )

            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM dossier") == 0)
            #expect(try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM dossierMembershipExclusion"
            ) == 0)
        }
    }

    @Test func deletingExcludedDocumentCascadesOnlyItsExclusion() throws {
        let fixture = try DossierMigrationFixture.make()
        let dossierID = UUID()
        let remainingDocumentID = UUID()
        try fixture.db.write { connection in
            try fixture.insertDocument(
                in: connection,
                id: remainingDocumentID,
                relativePath: "remaining.pdf"
            )
            try fixture.insertDossier(in: connection, id: dossierID)
            try fixture.insertExclusion(in: connection, dossierID: dossierID)
            try fixture.insertExclusion(
                in: connection,
                dossierID: dossierID,
                documentID: remainingDocumentID,
                revisionID: UUID()
            )

            try connection.execute(
                sql: "DELETE FROM document WHERE id = ?",
                arguments: [fixture.excludedID]
            )

            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM dossier") == 1)
            #expect(try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM dossierMembershipExclusion"
            ) == 1)
            #expect(try UUID.fetchOne(
                connection,
                sql: "SELECT documentID FROM dossierMembershipExclusion WHERE dossierID = ?",
                arguments: [dossierID]
            ) == remainingDocumentID)
        }
    }

    @Test func personDossierMigrationCreatesConstrainedSchema() throws {
        let db = try TestDatabase.make()

        try db.read { connection in
            #expect(try connection.columns(in: "personDossierAnchor").map(\.name) == [
                "id", "displayName", "normalizedName", "primaryRole",
                "originDocumentID", "originContentHash", "originExtractionVersion",
                "originDNASchemaVersion", "originDNAAnalyzerIdentifier",
                "originDNAAnalyzerVersion", "originDNAAnalyzedAt",
                "birthDateDisplayValue", "birthDateNormalizedValue",
                "createdAt", "updatedAt",
            ])
            #expect(try connection.columns(in: "personDossierAnchorEvidence").map(\.name) == [
                "personAnchorID", "subject", "evidenceOrder", "pageIndex",
                "startUTF16", "lengthUTF16", "exactText", "ocrRegionIndexesJSON",
            ])
            #expect(try connection.columns(in: "dossier").map(\.name) == [
                "id", "kind", "displayName", "anchorDocumentID", "personAnchorID",
                "createdAt", "updatedAt",
            ])
            #expect(try connection.columns(in: "dossierMembershipConfirmation").map(\.name) == [
                "dossierID", "documentID", "revisionID", "confirmedAt",
                "candidateKind", "acceptedContentHash", "acceptedExtractionVersion",
                "acceptedDNASchemaVersion", "acceptedDNAAnalyzerIdentifier",
                "acceptedDNAAnalyzerVersion", "acceptedDNAAnalyzedAt",
                "acceptedRole", "acceptedNormalizedName",
            ])

            let personIndexes = try connection.indexes(on: "personDossierAnchor")
            #expect(personIndexes.contains {
                $0.isUnique
                    && $0.columns == ["originDocumentID", "primaryRole", "normalizedName"]
            })
            #expect(personIndexes.contains {
                $0.name == "person_dossier_anchor_normalized_name"
                    && !$0.isUnique
                    && $0.columns == ["normalizedName"]
            })

            let evidenceIndexes = try connection.indexes(on: "personDossierAnchorEvidence")
            #expect(evidenceIndexes.first { $0.origin == .primaryKeyConstraint }?.columns == [
                "personAnchorID", "subject", "evidenceOrder",
            ])

            let dossierIndexes = try connection.indexes(on: "dossier")
            #expect(dossierIndexes.contains {
                $0.isUnique && $0.columns == ["anchorDocumentID"]
            })
            #expect(dossierIndexes.contains {
                $0.isUnique && $0.columns == ["personAnchorID"]
            })

            let confirmationIndexes = try connection.indexes(on: "dossierMembershipConfirmation")
            #expect(confirmationIndexes.first { $0.origin == .primaryKeyConstraint }?.columns == [
                "dossierID", "documentID",
            ])
            #expect(confirmationIndexes.contains {
                $0.isUnique && $0.columns == ["revisionID"]
            })
            #expect(try Row.fetchAll(connection, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test func personDossierMigrationPreservesPopulatedV7RowsWithoutBackfill() throws {
        let db = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(db, upTo: "v7_costs_and_payments_dossiers")
        let sourceID = UUID()
        let dossierID = UUID()
        let anchorID = UUID()
        let excludedIDs = [UUID(), UUID()]
        let revisionIDs = [UUID(), UUID()]
        let createdAt = Date(timeIntervalSince1970: 7_001)
        let updatedAt = Date(timeIntervalSince1970: 7_002)
        let excludedAts = [Date(timeIntervalSince1970: 7_003), Date(timeIntervalSince1970: 7_004)]
        try db.write { connection in
            try insertDossierSource(
                in: connection,
                sourceID: sourceID,
                documentIDs: [anchorID] + excludedIDs,
                storedAt: createdAt
            )
            try connection.execute(
                sql: """
                    INSERT INTO dossier (id, kind, displayName, anchorDocumentID, createdAt, updatedAt)
                    VALUES (?, 'costsAndPayments', 'Existing costs', ?, ?, ?)
                    """,
                arguments: [dossierID, anchorID, createdAt, updatedAt]
            )
            for index in excludedIDs.indices {
                try connection.execute(
                    sql: """
                        INSERT INTO dossierMembershipExclusion
                            (dossierID, documentID, revisionID, excludedAt)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [dossierID, excludedIDs[index], revisionIDs[index], excludedAts[index]]
                )
            }
        }

        try AppDatabase.migrate(db)

        try db.read { connection in
            let storedDossier = try Row.fetchOne(
                connection,
                sql: """
                    SELECT id, kind, displayName, anchorDocumentID, personAnchorID, createdAt, updatedAt
                    FROM dossier WHERE id = ?
                    """,
                arguments: [dossierID]
            )
            let dossier = try #require(storedDossier)
            #expect(dossier["id"] as UUID == dossierID)
            #expect(dossier["kind"] as String == "costsAndPayments")
            #expect(dossier["displayName"] as String == "Existing costs")
            #expect(dossier["anchorDocumentID"] as UUID == anchorID)
            #expect(dossier["personAnchorID"] as UUID? == nil)
            #expect(dossier["createdAt"] as Date == createdAt)
            #expect(dossier["updatedAt"] as Date == updatedAt)

            let exclusions = try Row.fetchAll(
                connection,
                sql: """
                    SELECT dossierID, documentID, revisionID, excludedAt
                    FROM dossierMembershipExclusion ORDER BY excludedAt
                    """
            )
            #expect(exclusions.count == 2)
            for index in exclusions.indices {
                #expect(exclusions[index]["dossierID"] as UUID == dossierID)
                #expect(exclusions[index]["documentID"] as UUID == excludedIDs[index])
                #expect(exclusions[index]["revisionID"] as UUID == revisionIDs[index])
                #expect(exclusions[index]["excludedAt"] as Date == excludedAts[index])
            }
            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM personDossierAnchor") == 0)
            #expect(try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM personDossierAnchorEvidence"
            ) == 0)
            #expect(try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM dossierMembershipConfirmation"
            ) == 0)
        }
    }

    @Test func personDossierMigrationAllowsHomonymsButRejectsDuplicateOrigin() throws {
        let fixture = try PersonDossierMigrationFixture.make()
        let firstID = UUID()
        try fixture.db.write { connection in
            try fixture.insertPersonAnchor(
                in: connection,
                id: firstID,
                originDocumentID: fixture.originDocumentID
            )
            try fixture.insertPersonAnchor(
                in: connection,
                id: UUID(),
                originDocumentID: fixture.confirmedDocumentID
            )
            #expect(throws: DatabaseError.self) {
                try fixture.insertPersonAnchor(
                    in: connection,
                    id: UUID(),
                    originDocumentID: fixture.originDocumentID
                )
            }
        }
    }

    @Test func personDossierMigrationRejectsMismatchedTypedAnchors() throws {
        let fixture = try PersonDossierMigrationFixture.make()
        let personAnchorID = UUID()
        try fixture.db.write { connection in
            try fixture.insertPersonAnchor(in: connection, id: personAnchorID)
            try fixture.insertDossier(
                in: connection,
                kind: "costsAndPayments",
                anchorDocumentID: fixture.costDocumentID
            )
            try fixture.insertDossier(
                in: connection,
                kind: "personMatter",
                personAnchorID: personAnchorID
            )

            #expect(throws: DatabaseError.self) {
                try fixture.insertDossier(in: connection, kind: "costsAndPayments")
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDossier(
                    in: connection,
                    kind: "costsAndPayments",
                    anchorDocumentID: fixture.originDocumentID,
                    personAnchorID: personAnchorID
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDossier(
                    in: connection,
                    kind: "costsAndPayments",
                    personAnchorID: personAnchorID
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.insertDossier(
                    in: connection,
                    kind: "personMatter",
                    anchorDocumentID: fixture.originDocumentID
                )
            }
        }
    }

    @Test func deletingOriginDocumentPreservesPersonAnchorAndDossier() throws {
        let fixture = try PersonDossierMigrationFixture.make()
        let personAnchorID = UUID()
        try fixture.db.write { connection in
            try fixture.insertPersonAnchor(in: connection, id: personAnchorID)
            try fixture.insertDossier(
                in: connection,
                kind: "personMatter",
                personAnchorID: personAnchorID
            )
            try connection.execute(
                sql: "DELETE FROM document WHERE id = ?",
                arguments: [fixture.originDocumentID]
            )
            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM personDossierAnchor") == 1)
            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM dossier") == 1)
        }
    }

    @Test func deletingPersonAnchorCascadesDossierEvidenceCorrectionsAndConfirmations() throws {
        let fixture = try PersonDossierMigrationFixture.make()
        let personAnchorID = UUID()
        let dossierID = UUID()
        try fixture.db.write { connection in
            try fixture.insertPersonAnchor(in: connection, id: personAnchorID)
            try fixture.insertDossier(
                in: connection,
                id: dossierID,
                kind: "personMatter",
                personAnchorID: personAnchorID
            )
            try fixture.insertEvidence(in: connection, personAnchorID: personAnchorID)
            try fixture.insertExclusion(in: connection, dossierID: dossierID)
            try fixture.insertConfirmation(in: connection, dossierID: dossierID)

            try connection.execute(
                sql: "DELETE FROM personDossierAnchor WHERE id = ?",
                arguments: [personAnchorID]
            )

            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM personDossierAnchor") == 0)
            #expect(try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM personDossierAnchorEvidence"
            ) == 0)
            #expect(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM dossier") == 0)
            #expect(try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM dossierMembershipExclusion"
            ) == 0)
            #expect(try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM dossierMembershipConfirmation"
            ) == 0)
            #expect(try UUID.fetchOne(
                connection,
                sql: "SELECT id FROM document WHERE id = ?",
                arguments: [fixture.confirmedDocumentID]
            ) == fixture.confirmedDocumentID)
        }
    }

    @Test func v8MigrationFailureRollsBackTheCompleteV7Rebuild() throws {
        let db = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(db, upTo: "v7_costs_and_payments_dossiers")
        let sourceID = UUID()
        let documentID = UUID()
        let dossierID = UUID()
        let storedAt = Date(timeIntervalSince1970: 7_100)
        try db.write { connection in
            try insertDossierSource(
                in: connection,
                sourceID: sourceID,
                documentIDs: [documentID],
                storedAt: storedAt
            )
            try connection.execute(sql: "PRAGMA ignore_check_constraints = TRUE")
            try connection.execute(
                sql: """
                    INSERT INTO dossier (id, kind, displayName, anchorDocumentID, createdAt, updatedAt)
                    VALUES (?, 'unsupported', 'Malformed v7 dossier', ?, ?, ?)
                    """,
                arguments: [dossierID, documentID, storedAt, storedAt]
            )
            try connection.execute(sql: "PRAGMA ignore_check_constraints = FALSE")
        }

        #expect(throws: DatabaseError.self) {
            try AppDatabase.migrate(db)
        }

        try db.read { connection in
            let dossierColumns = try connection.columns(in: "dossier").map(\.name)
            let malformedKind = try String.fetchOne(
                connection,
                sql: "SELECT kind FROM dossier WHERE id = ?",
                arguments: [dossierID]
            )
            let exclusionsExist = try connection.tableExists("dossierMembershipExclusion")
            let personAnchorsExist = try connection.tableExists("personDossierAnchor")
            let evidenceExist = try connection.tableExists("personDossierAnchorEvidence")
            let confirmationsExist = try connection.tableExists("dossierMembershipConfirmation")
            let appliedV8Migrations = try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v8_person_anchored_dossiers'"
            )
            #expect(dossierColumns == [
                "id", "kind", "displayName", "anchorDocumentID", "createdAt", "updatedAt",
            ])
            #expect(malformedKind == "unsupported")
            #expect(exclusionsExist)
            #expect(!personAnchorsExist)
            #expect(!evidenceExist)
            #expect(!confirmationsExist)
            #expect(appliedV8Migrations == 0)
        }
    }
}

private func insertDossierSource(
    in connection: Database,
    sourceID: UUID,
    documentIDs: [UUID],
    storedAt: Date
) throws {
    try connection.execute(
        sql: """
            INSERT INTO sourceRoot
                (id, displayName, pathHint, bookmarkData, createdAt, lastScanAt)
            VALUES (?, 'Dossier Source', '/Dossier', ?, ?, NULL)
            """,
        arguments: [sourceID, Data([0x06]), storedAt]
    )
    for (index, documentID) in documentIDs.enumerated() {
        try connection.execute(
            sql: """
                INSERT INTO document
                    (id, sourceRootID, relativePath, contentHash, byteCount,
                     modifiedAt, mediaType, status, availability, pageCount,
                     failureCode, lastSeenAt, lastFingerprintAt)
                VALUES (?, ?, ?, ?, 64, ?, 'pdf', 'ready', 'available', 1,
                        NULL, ?, ?)
                """,
            arguments: [
                documentID,
                sourceID,
                "dossier-\(index).pdf",
                "dossier-hash-\(index)",
                storedAt,
                storedAt,
                storedAt,
            ]
        )
    }
}

private enum DecisionDocumentRole {
    case invoice
    case payment
}

private struct DossierMigrationFixture {
    let db: DatabaseQueue
    let sourceID: UUID
    let anchorID: UUID
    let excludedID: UUID
    let storedAt: Date

    static func make() throws -> Self {
        let db = try TestDatabase.make()
        let sourceID = UUID()
        let anchorID = UUID()
        let excludedID = UUID()
        let storedAt = Date(timeIntervalSince1970: 6_789)
        try db.write { connection in
            try insertDossierSource(
                in: connection,
                sourceID: sourceID,
                documentIDs: [anchorID, excludedID],
                storedAt: storedAt
            )
        }
        return Self(
            db: db,
            sourceID: sourceID,
            anchorID: anchorID,
            excludedID: excludedID,
            storedAt: storedAt
        )
    }

    func insertDocument(
        in connection: Database,
        id: UUID,
        relativePath: String
    ) throws {
        try connection.execute(
            sql: """
                INSERT INTO document
                    (id, sourceRootID, relativePath, contentHash, byteCount,
                     modifiedAt, mediaType, status, availability, pageCount,
                     failureCode, lastSeenAt, lastFingerprintAt)
                VALUES (?, ?, ?, ?, 64, ?, 'pdf', 'ready', 'available', 1,
                        NULL, ?, ?)
                """,
            arguments: [
                id,
                sourceID,
                relativePath,
                "hash-\(relativePath)",
                storedAt,
                storedAt,
                storedAt,
            ]
        )
    }

    func insertDossier(
        in connection: Database,
        id: UUID = UUID(),
        kind: String = "costsAndPayments",
        displayName: String = "Costs and payments",
        anchorDocumentID: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) throws {
        try connection.execute(
            sql: """
                INSERT INTO dossier
                    (id, kind, displayName, anchorDocumentID, personAnchorID, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, NULL, ?, ?)
                """,
            arguments: [
                id,
                kind,
                displayName,
                anchorDocumentID ?? anchorID,
                createdAt ?? storedAt,
                updatedAt ?? storedAt,
            ]
        )
    }

    func insertExclusion(
        in connection: Database,
        dossierID: UUID,
        documentID: UUID? = nil,
        revisionID: UUID = UUID()
    ) throws {
        try connection.execute(
            sql: """
                INSERT INTO dossierMembershipExclusion
                    (dossierID, documentID, revisionID, excludedAt)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [dossierID, documentID ?? excludedID, revisionID, storedAt]
        )
    }
}

private struct PersonDossierMigrationFixture {
    let db: DatabaseQueue
    let sourceID: UUID
    let originDocumentID: UUID
    let confirmedDocumentID: UUID
    let costDocumentID: UUID
    let storedAt: Date

    static func make() throws -> Self {
        let db = try TestDatabase.make()
        let sourceID = UUID()
        let originDocumentID = UUID()
        let confirmedDocumentID = UUID()
        let costDocumentID = UUID()
        let storedAt = Date(timeIntervalSince1970: 7_200)
        try db.write { connection in
            try insertDossierSource(
                in: connection,
                sourceID: sourceID,
                documentIDs: [originDocumentID, confirmedDocumentID, costDocumentID],
                storedAt: storedAt
            )
        }
        return Self(
            db: db,
            sourceID: sourceID,
            originDocumentID: originDocumentID,
            confirmedDocumentID: confirmedDocumentID,
            costDocumentID: costDocumentID,
            storedAt: storedAt
        )
    }

    func insertPersonAnchor(
        in connection: Database,
        id: UUID = UUID(),
        originDocumentID: UUID? = nil,
        normalizedName: String = "elise muster"
    ) throws {
        try connection.execute(
            sql: """
                INSERT INTO personDossierAnchor (
                    id, displayName, normalizedName, primaryRole,
                    originDocumentID, originContentHash, originExtractionVersion,
                    originDNASchemaVersion, originDNAAnalyzerIdentifier,
                    originDNAAnalyzerVersion, originDNAAnalyzedAt,
                    birthDateDisplayValue, birthDateNormalizedValue, createdAt, updatedAt
                ) VALUES (?, 'Elise Muster', ?, 'resident', ?, 'origin-hash', 'text-v1',
                          1, 'local-rules', '1', ?, NULL, NULL, ?, ?)
                """,
            arguments: [
                id,
                normalizedName,
                originDocumentID ?? self.originDocumentID,
                storedAt,
                storedAt,
                storedAt,
            ]
        )
    }

    func insertDossier(
        in connection: Database,
        id: UUID = UUID(),
        kind: String,
        anchorDocumentID: UUID? = nil,
        personAnchorID: UUID? = nil
    ) throws {
        try connection.execute(
            sql: """
                INSERT INTO dossier
                    (id, kind, displayName, anchorDocumentID, personAnchorID, createdAt, updatedAt)
                VALUES (?, ?, 'Test dossier', ?, ?, ?, ?)
                """,
            arguments: [id, kind, anchorDocumentID, personAnchorID, storedAt, storedAt]
        )
    }

    func insertEvidence(in connection: Database, personAnchorID: UUID) throws {
        try connection.execute(
            sql: """
                INSERT INTO personDossierAnchorEvidence (
                    personAnchorID, subject, evidenceOrder, pageIndex, startUTF16,
                    lengthUTF16, exactText, ocrRegionIndexesJSON
                ) VALUES (?, 'person', 0, 0, 0, 11, 'Elise Muster', ?)
                """,
            arguments: [personAnchorID, Data("[]".utf8)]
        )
    }

    func insertExclusion(in connection: Database, dossierID: UUID) throws {
        try connection.execute(
            sql: """
                INSERT INTO dossierMembershipExclusion
                    (dossierID, documentID, revisionID, excludedAt)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [dossierID, costDocumentID, UUID(), storedAt]
        )
    }

    func insertConfirmation(in connection: Database, dossierID: UUID) throws {
        try connection.execute(
            sql: """
                INSERT INTO dossierMembershipConfirmation (
                    dossierID, documentID, revisionID, confirmedAt, candidateKind,
                    acceptedContentHash, acceptedExtractionVersion, acceptedDNASchemaVersion,
                    acceptedDNAAnalyzerIdentifier, acceptedDNAAnalyzerVersion,
                    acceptedDNAAnalyzedAt, acceptedRole, acceptedNormalizedName
                ) VALUES (?, ?, ?, ?, 'secondaryRole', 'confirmed-hash', 'text-v1', 1,
                          'local-rules', '1', ?, 'authorizedPerson', 'elise muster')
                """,
            arguments: [dossierID, confirmedDocumentID, UUID(), storedAt, storedAt]
        )
    }
}

private struct DecisionMigrationFixture {
    let db: DatabaseQueue
    let sourceID: UUID
    let invoiceID: UUID
    let paymentID: UUID
    let storedAt: Date

    static func make() throws -> Self {
        let db = try TestDatabase.make()
        let sourceID = UUID()
        let invoiceID = UUID()
        let paymentID = UUID()
        let storedAt = Date(timeIntervalSince1970: 3_456)
        try db.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO sourceRoot
                        (id, displayName, pathHint, bookmarkData, createdAt, lastScanAt)
                    VALUES (?, 'Decision Source', '/Decision', ?, ?, NULL)
                    """,
                arguments: [sourceID, Data([0x04]), storedAt]
            )
            for (id, path, hash) in [
                (invoiceID, "invoice.pdf", "hash-invoice"),
                (paymentID, "payment.pdf", "hash-payment"),
            ] {
                try connection.execute(
                    sql: """
                        INSERT INTO document
                            (id, sourceRootID, relativePath, contentHash, byteCount,
                             modifiedAt, mediaType, status, availability, pageCount,
                             failureCode, lastSeenAt, lastFingerprintAt)
                        VALUES (?, ?, ?, ?, 64, ?, 'pdf', 'ready', 'available', 1,
                                NULL, ?, ?)
                        """,
                    arguments: [id, sourceID, path, hash, storedAt, storedAt, storedAt]
                )
            }
        }
        return Self(
            db: db,
            sourceID: sourceID,
            invoiceID: invoiceID,
            paymentID: paymentID,
            storedAt: storedAt
        )
    }

    func insertDecision(
        in connection: Database,
        relationshipType: String = "paymentSettlesInvoice",
        decision: String = "confirmed",
        invoiceDocumentID: UUID? = nil,
        paymentDocumentID: UUID? = nil,
        invoiceContentHash: String = "hash-invoice",
        paymentContentHash: String = "hash-payment"
    ) throws {
        try connection.execute(
            sql: """
                INSERT INTO invoicePaymentUserDecision
                    (relationshipType, invoiceDocumentID, paymentDocumentID,
                     invoiceContentHash, paymentContentHash, decision, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                relationshipType,
                invoiceDocumentID ?? invoiceID,
                paymentDocumentID ?? paymentID,
                invoiceContentHash,
                paymentContentHash,
                decision,
                storedAt,
            ]
        )
    }
}
