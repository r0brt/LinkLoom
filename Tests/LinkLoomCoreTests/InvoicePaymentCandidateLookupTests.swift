import Foundation
import GRDB
import Testing
@testable import LinkLoomCore

@Suite("Invoice payment candidate lookup")
struct InvoicePaymentCandidateLookupTests {
    @Test func lookupReturnsTheSameCurrentCandidateForEitherDocument() async throws {
        let fixture = try await InvoicePaymentCandidateLookupFixture.make()
        let invoice = try await fixture.addDocument(
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag"
        )
        let payment = try await fixture.addDocument(
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )

        let invoiceCandidates = try await fixture.lookup.candidates(involving: invoice.id)
        let paymentCandidates = try await fixture.lookup.candidates(involving: payment.id)

        let invoiceCandidate = try #require(invoiceCandidates.only)
        let paymentCandidate = try #require(paymentCandidates.only)
        #expect(invoiceCandidate.invoice.document.id == invoice.id)
        #expect(invoiceCandidate.payment.document.id == payment.id)
        #expect(invoiceCandidate.disposition == .automatic)
        #expect(invoiceCandidate.signals.map(\.kind) == [
            .referenceNumber, .monetaryAmount, .organization,
        ])
        #expect(paymentCandidate == invoiceCandidate)
    }

    @Test func lookupExcludesAStaleCounterpart() async throws {
        let fixture = try await InvoicePaymentCandidateLookupFixture.make()
        let invoice = try await fixture.addDocument(
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag"
        )
        let currentPayment = try await fixture.addDocument(
            path: "a-current-payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )
        let stalePayment = try await fixture.addDocument(
            path: "b-stale-payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV/42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )
        try await fixture.database.write { db in
            try db.execute(
                sql: "UPDATE document SET contentHash = ? WHERE id = ?",
                arguments: ["changed-hash", stalePayment.id]
            )
        }

        let candidates = try await fixture.lookup.candidates(involving: invoice.id)

        let candidate = try #require(candidates.only)
        #expect(candidate.payment.document.id == currentPayment.id)
    }

    @Test func lookupDemotesStrongCounterpartsAcrossDifferentReferences() async throws {
        let fixture = try await InvoicePaymentCandidateLookupFixture.make()
        let invoice = try await fixture.addDocument(
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag",
            additionalReference: (.invoiceNumber, "INV-43", "INV43")
        )
        _ = try await fixture.addDocument(
            path: "a-payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )
        _ = try await fixture.addDocument(
            path: "b-payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 43",
            referenceValue: "INV43",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )

        let candidates = try await fixture.lookup.candidates(involving: invoice.id)

        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.disposition == .suggestion })
    }

    @Test func lookupDeduplicatesDuplicateNormalizedReferences() async throws {
        let fixture = try await InvoicePaymentCandidateLookupFixture.make()
        let invoice = try await fixture.addDocument(
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag",
            additionalReference: (.invoiceNumber, "INV 42", "INV42")
        )
        let firstPayment = try await fixture.addDocument(
            path: "a-payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV-42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )
        let secondPayment = try await fixture.addDocument(
            path: "b-payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )

        let candidates = try await fixture.lookup.candidates(involving: invoice.id)

        #expect(candidates.map {
            "\($0.invoice.document.id.uuidString)/\($0.payment.document.id.uuidString)"
        } == [
            "\(invoice.id.uuidString)/\(firstPayment.id.uuidString)",
            "\(invoice.id.uuidString)/\(secondPayment.id.uuidString)",
        ])
        #expect(candidates.allSatisfy { $0.disposition == .suggestion })
    }

    @Test func lookupLoadsOnlyQualifierSelectedReferenceCohortsOnce() async throws {
        let fixture = try await InvoicePaymentCandidateLookupFixture.make()
        let invoice = try await fixture.addDocument(
            path: "invoice.pdf",
            type: .invoice,
            referenceQualifier: .invoiceNumber,
            referenceDisplay: "INV-42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "issuer",
            organization: "alpha ag",
            additionalReference: (.paymentReference, "ignored", "AAAA")
        )
        _ = try await fixture.addDocument(
            path: "payment.pdf",
            type: .paymentConfirmation,
            referenceQualifier: .paymentReference,
            referenceDisplay: "INV 42",
            amount: "1250",
            currency: "CHF",
            organizationQualifier: "payee",
            organization: "alpha ag"
        )
        let counter = CandidateLookupReferenceReadCounter()
        try await fixture.database.write { db in
            db.trace(options: .statement) { event in
                counter.record(event)
            }
        }
        counter.reset()

        _ = try await fixture.lookup.candidates(involving: invoice.id)
        let readCount = counter.value
        try await fixture.database.write { db in
            db.trace(options: [])
        }

        #expect(readCount == 1)
    }
}

private final class CandidateLookupReferenceReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func reset() {
        lock.withLock { count = 0 }
    }

    func record(_ event: Database.TraceEvent) {
        guard case let .statement(statement) = event,
              statement.sql.contains("FROM documentDNAFinding AS finding")
        else {
            return
        }
        lock.withLock { count += 1 }
    }
}

private struct InvoicePaymentCandidateLookupFixture {
    let database: DatabaseQueue
    let source: SourceRootRecord
    let repository: DocumentDNARepository
    let extractionRepository: ExtractionRepository
    let target: DocumentDNAAnalysisTarget
    let lookup: InvoicePaymentCandidateLookup
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func make() async throws -> Self {
        let database = try TestDatabase.make()
        let source = SourceRootRecord(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
            displayName: "Candidate lookup",
            pathHint: "/synthetic/candidate-lookup",
            bookmarkData: Data("candidate-lookup-bookmark".utf8),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await database.write { db in try source.insert(db) }
        let repository = DocumentDNARepository(dbWriter: database)
        let extractionRepository = ExtractionRepository(dbWriter: database)
        let target = try DocumentDNAAnalysisTarget(
            schemaVersion: 1,
            analyzerIdentifier: "local-rules",
            analyzerVersion: "2"
        )
        return Self(
            database: database,
            source: source,
            repository: repository,
            extractionRepository: extractionRepository,
            target: target,
            lookup: InvoicePaymentCandidateLookup(repository: repository, target: target)
        )
    }

    func addDocument(
        path: String,
        type: DocumentType,
        referenceQualifier: DocumentDNAReferenceNumberKind,
        referenceDisplay: String,
        referenceValue: String = "INV42",
        amount: String,
        currency: String,
        organizationQualifier: String,
        organization: String,
        additionalReference: (
            DocumentDNAReferenceNumberKind,
            String,
            String
        )? = nil
    ) async throws -> DocumentRecord {
        let document = DocumentRecord(
            id: UUID(),
            sourceRootID: source.id,
            relativePath: path,
            contentHash: "hash-\(path)",
            byteCount: 1,
            modifiedAt: date,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: date,
            lastFingerprintAt: date
        )
        try await database.write { db in try document.insert(db) }
        try await extractionRepository.replace(
            documentID: document.id,
            analysisVersion: "text-v1",
            extraction: ExtractedDocument(
                method: .embeddedPDFText,
                pages: [ExtractedPage(pageIndex: 0, text: "x", regions: [])]
            ),
            at: date
        )
        var findings = [
            try finding(
                kind: .documentType,
                qualifier: nil,
                displayValue: type.rawValue,
                normalizedValue: type.rawValue
            ),
            try finding(
                kind: .referenceNumber,
                qualifier: referenceQualifier.rawValue,
                displayValue: referenceDisplay,
                normalizedValue: referenceValue
            ),
            try finding(
                kind: .monetaryAmount,
                qualifier: currency,
                displayValue: "\(currency) \(amount)",
                normalizedValue: amount
            ),
            try finding(
                kind: .organization,
                qualifier: organizationQualifier,
                displayValue: organization,
                normalizedValue: organization
            ),
        ]
        if let additionalReference {
            findings.append(try finding(
                kind: .referenceNumber,
                qualifier: additionalReference.0.rawValue,
                displayValue: additionalReference.1,
                normalizedValue: additionalReference.2
            ))
        }
        try await repository.replace(try DocumentDNA(
            documentID: document.id,
            schemaVersion: target.schemaVersion,
            analyzerIdentifier: target.analyzerIdentifier,
            analyzerVersion: target.analyzerVersion,
            inputContentHash: document.contentHash,
            inputExtractionVersion: "text-v1",
            findings: findings,
            analyzedAt: date
        ))
        return document
    }

    private func finding(
        kind: DocumentDNAFindingKind,
        qualifier: String?,
        displayValue: String,
        normalizedValue: String
    ) throws -> DocumentDNAFinding {
        try DocumentDNAFinding(
            kind: kind,
            qualifier: qualifier,
            displayValue: displayValue,
            normalizedValue: normalizedValue,
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: [try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 0,
                lengthUTF16: 1,
                exactText: "x",
                ocrRegionIndexes: []
            )]
        )
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
