import CoreGraphics
import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Local rules Document DNA analyzer")
struct LocalRulesDocumentDNAAnalyzerTests {
    @Test func classifiesOnlyUniqueSupportedHighPrecisionMarkers() throws {
        let cases: [(String, DocumentType)] = [
            ("Pflegevertrag", .contract),
            ("Rechnung", .invoice),
            ("Zahlungsbestätigung", .paymentConfirmation),
            ("Leistungsabrechnung", .insuranceStatement),
            ("Pflegedokumentation", .medicalOrCareDocument),
            ("Vollmacht", .powerOfAttorney),
            ("Korrespondenz", .correspondence),
            ("RECHNUNG", .invoice),
            ("Notiz zum Vorgang", .unknown),
        ]

        for (text, expected) in cases {
            let finding = try #require(
                analyze(text).findings.first { $0.kind == .documentType }
            )
            #expect(finding.normalizedValue == expected.rawValue)
            if expected == .unknown {
                #expect(finding.confidence == 0)
                #expect(finding.evidence.isEmpty)
            } else {
                #expect(finding.confidence == 1)
                #expect(finding.evidence.map(\.exactText) == [text])
            }
        }
    }

    @Test func tiedClassificationScoresRemainUnknown() throws {
        let result = try analyze("Vertrag\nRechnung")
        let classification = try #require(
            result.findings.first { $0.kind == .documentType }
        )

        #expect(classification.normalizedValue == "unknown")
        #expect(classification.evidence.isEmpty)
    }

    @Test func extractsOnlyLabelledPeopleAndSupportedOrganizations() throws {
        let text = """
            Pflegevertrag
            Bewohnerin: E\u{301}lise   Muster
            Anbieter: Pflegezentrum Sonnenrain AG
            Stiftung Abendrot
            Unbeteiligte Person
            """

        let result = try analyze(text)
        let people = result.findings.filter { $0.kind == .person }
        let organizations = result.findings.filter { $0.kind == .organization }

        #expect(people.count == 1)
        #expect(people[0].qualifier == "resident")
        #expect(people[0].displayValue == "E\u{301}lise   Muster")
        #expect(people[0].normalizedValue == "élise muster")
        #expect(organizations.map(\.displayValue) == [
            "Pflegezentrum Sonnenrain AG",
            "Stiftung Abendrot",
        ])
        #expect(organizations.map(\.normalizedValue) == [
            "pflegezentrum sonnenrain ag",
            "stiftung abendrot",
        ])
        #expect(!people.contains { $0.displayValue == "Unbeteiligte Person" })
    }

    @Test func extractsValidLabelledAndUnlabelledCivilDates() throws {
        let text = """
            Rechnung
            Rechnungsdatum: 01.08.2026
            Leistungszeitraum: 01.07.2026 - 31.07.2026
            Termin 2026-08-03
            Ungültig 31.02.2026
            Jahreszahl 2026
            """

        let dates = try analyze(text).findings.filter { $0.kind == .date }

        #expect(dates.map(\.qualifier) == ["issueDate", "servicePeriod", "unknown"])
        #expect(dates.map(\.normalizedValue) == [
            "2026-08-01",
            "2026-07-01",
            "2026-08-03",
        ])
        #expect(dates.map(\.secondaryNormalizedValue) == [nil, "2026-07-31", nil])
        #expect(!dates.contains { $0.displayValue.contains("31.02.2026") })
    }

    @Test func extractsOnlyAmountsWithExplicitSupportedCurrencies() throws {
        let text = """
            Rechnung
            Total: CHF 1'250.00
            Rückerstattung: 300,50 EUR
            Zuschlag: Fr. 75.00
            Ohne Währung: 999.00
            """

        let amounts = try analyze(text).findings.filter { $0.kind == .monetaryAmount }

        #expect(amounts.map(\.qualifier) == ["CHF", "EUR", "CHF"])
        #expect(amounts.map(\.normalizedValue) == ["1250", "300.5", "75"])
        #expect(amounts.map(\.displayValue) == [
            "CHF 1'250.00",
            "300,50 EUR",
            "Fr. 75.00",
        ])
    }

    @Test func acceptsOneDecimalDigitAndRejectsMalformedAmountGrouping() throws {
        let text = """
            Rechnung
            Rundung: CHF 10,5
            Standard DE: CHF 1.250,00
            Standard EN: EUR 1,250.00
            Invalid: CHF 1,23,456
            """

        let amounts = try analyze(text).findings.filter { $0.kind == .monetaryAmount }

        #expect(amounts.map(\.normalizedValue) == ["10.5", "1250", "1250"])
    }

    @Test func referenceEmbeddedISODateIsNotAnUnlabelledDate() throws {
        let result = try analyze("Rechnung\nRechnungsnummer: INV-2026-08-03")

        #expect(result.findings.filter { $0.kind == .date }.isEmpty)
        #expect(result.findings.filter { $0.kind == .referenceNumber }.map(\.normalizedValue) == [
            "INV20260803",
        ])
    }

    @Test func extractsEverySupportedLabelledReferenceKind() throws {
        let text = """
            Rechnung
            Vertragsnummer: ver 2026-01
            Rechnungsnummer: inv-0042
            Policennummer: pol 77 88
            Schadennummer: clm-9
            Kundennummer: kd 123
            Zahlungsreferenz: qrr 000 111
            Referenz: sonst-5
            Telefon: 044 555 12 12
            8000 Zürich
            """

        let references = try analyze(text).findings.filter { $0.kind == .referenceNumber }

        #expect(references.map(\.qualifier) == [
            "contractNumber",
            "invoiceNumber",
            "policyNumber",
            "claimNumber",
            "customerNumber",
            "paymentReference",
            "other",
        ])
        #expect(references.map(\.normalizedValue) == [
            "VER202601",
            "INV0042",
            "POL7788",
            "CLM9",
            "KD123",
            "QRR000111",
            "SONST5",
        ])
        #expect(!references.contains { $0.displayValue.contains("044") })
        #expect(!references.contains { $0.displayValue.contains("8000") })
    }

    @Test func normalizesEquivalentReferenceSeparatorsAndUnicodeWhitespace() throws {
        let nonBreakingHyphen = "\u{2011}"
        let nonBreakingSpace = "\u{00A0}"
        let narrowNoBreakSpace = "\u{202F}"
        let fullwidthSlash = "\u{FF0F}"
        let fullwidthFullStop = "\u{FF0E}"
        let text = """
            Rechnung
            Rechnungsnummer: inv-2026-0042
            Rechnungsnummer: INV 2026 0042
            Rechnungsnummer: INV/2026.0042
            Rechnungsnummer: INV\(nonBreakingHyphen)2026\(nonBreakingHyphen)0042
            Rechnungsnummer: INV\(nonBreakingSpace)2026\(narrowNoBreakSpace)0042
            Rechnungsnummer: INV\(fullwidthSlash)2026\(fullwidthFullStop)0042
            """

        let references = try analyze(text).findings.filter {
            $0.kind == .referenceNumber
        }

        #expect(references.count == 1)
        #expect(references[0].qualifier == "invoiceNumber")
        #expect(references[0].normalizedValue == "INV20260042")
        #expect(references[0].displayValue == "inv-2026-0042")
        #expect(references[0].evidence.count == 6)
    }

    @Test func rejectsCharactersOutsideTheV2ReferenceAlphabet() throws {
        let zeroWidthSpace = "\u{200B}"
        let text = """
            Rechnung
            Rechnungsnummer: INV_2026_0042
            Rechnungsnummer: INV+2026+0042
            Rechnungsnummer: INV\(zeroWidthSpace)20260042
            Rechnungsnummer: ＩＮＶ-2026-0042
            Rechnungsnummer: INV-２０２６-0042
            """

        #expect(try analyze(text).findings.filter {
            $0.kind == .referenceNumber
        }.isEmpty)
    }

    @Test func preservesLeadingZerosAndCheckDigitsWithoutValidation() throws {
        let text = """
            Zahlungsbestätigung
            Zahlungsreferenz: 21 00000 00003 13947 14300 09017
            Zahlungsreferenz: 21-00000-00003-13947-14300-09018
            """

        let references = try analyze(text).findings.filter {
            $0.kind == .referenceNumber
        }

        #expect(references.map(\.normalizedValue) == [
            "210000000003139471430009017",
            "210000000003139471430009018",
        ])
    }

    @Test func separatorCollisionCollapsesOnlyWithinTheSameQualifier() throws {
        let text = """
            Rechnung
            Rechnungsnummer: AB-12
            Rechnungsnummer: A-B12
            Kundennummer: AB-12
            """

        let references = try analyze(text).findings.filter {
            $0.kind == .referenceNumber
        }

        #expect(references.map(\.qualifier) == [
            "invoiceNumber",
            "customerNumber",
        ])
        #expect(references.map(\.normalizedValue) == ["AB12", "AB12"])
        #expect(references[0].evidence.count == 2)
        #expect(references[1].evidence.count == 1)
    }

    @Test func collapsesEquivalentFindingsAndRetainsDistinctEvidence() throws {
        let text = """
            Pflegevertrag
            Bewohnerin: Elise Muster
            Bewohnerin: Elise Muster
            """

        let people = try analyze(text).findings.filter { $0.kind == .person }

        #expect(people.count == 1)
        #expect(people[0].normalizedValue == "elise muster")
        #expect(people[0].evidence.count == 2)
        #expect(people[0].evidence.map(\.startUTF16) == [26, 51])
    }

    @Test func mapsUTF16EvidenceToIntersectingOCRRegions() throws {
        let texts = [
            "📄",
            "Rechnung",
            "Rechnung an: Élise Muster",
            "Total: CHF 10.00",
        ]
        let page = ExtractedPage(
            pageIndex: 0,
            text: texts.joined(separator: "\n"),
            regions: texts.map {
                TextRegion(
                    text: $0,
                    confidence: 0.95,
                    boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1)
                )
            }
        )

        let result = try analyze(pages: [page])
        let person = try #require(result.findings.first { $0.kind == .person })
        let amount = try #require(result.findings.first { $0.kind == .monetaryAmount })

        #expect(person.evidence == [
            try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 25,
                lengthUTF16: 12,
                exactText: "Élise Muster",
                ocrRegionIndexes: [2]
            ),
        ])
        #expect(amount.evidence == [
            try DocumentDNAEvidence(
                pageIndex: 0,
                startUTF16: 45,
                lengthUTF16: 9,
                exactText: "CHF 10.00",
                ocrRegionIndexes: [3]
            ),
        ])
    }

    @Test func sortsFindingsByPageThenSpanBeforeCollapsing() throws {
        let result = try analyze(pages: [
            ExtractedPage(
                pageIndex: 1,
                text: "Kundennummer: B-2",
                regions: []
            ),
            ExtractedPage(
                pageIndex: 0,
                text: "Rechnung\nRechnung an: Elise Muster\nKundennummer: A-1",
                regions: []
            ),
        ])

        #expect(result.findings.map { "\($0.kind.rawValue):\($0.normalizedValue)" } == [
            "documentType:invoice",
            "person:elise muster",
            "referenceNumber:A1",
            "referenceNumber:B2",
        ])
    }

    private func analyze(_ text: String) throws -> DocumentDNA {
        try analyze(pages: [ExtractedPage(pageIndex: 0, text: text, regions: [])])
    }

    private func analyze(pages: [ExtractedPage]) throws -> DocumentDNA {
        let documentID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        return try LocalRulesDocumentDNAAnalyzer().analyze(
            documentID: documentID,
            contentHash: "hash-local-rules",
            extraction: StoredExtraction(
                documentID: documentID,
                analysisVersion: "text-v1",
                extraction: ExtractedDocument(
                    method: pages.contains { !$0.regions.isEmpty }
                        ? .visionOCR
                        : .embeddedPDFText,
                    pages: pages
                ),
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            analyzedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    }
}
