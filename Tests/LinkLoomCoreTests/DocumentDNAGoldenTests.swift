import CoreGraphics
import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Document DNA synthetic goldens")
struct DocumentDNAGoldenTests {
    private let fixtureNames = [
        "care-home-contract",
        "care-home-invoice",
        "payment-confirmation",
        "insurance-statement",
        "power-of-attorney",
        "ocr-invoice",
        "misleading-negative",
        "ambiguous-correspondence",
    ]

    @Test func allFixturesMatchCompleteVersionedSnapshots() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fixtureName in fixtureNames {
            guard let url = Bundle.module.url(
                forResource: fixtureName,
                withExtension: "json"
            ) else {
                Issue.record("Missing synthetic golden fixture: \(fixtureName)")
                continue
            }
            let fixture = try decoder.decode(
                DocumentDNAGoldenFixture.self,
                from: Data(contentsOf: url)
            )
            try verifyExpectedEvidence(in: fixture)

            let pages = fixture.pages.map { page in
                ExtractedPage(
                    pageIndex: page.pageIndex,
                    text: page.text,
                    regions: page.regions.map { region in
                        TextRegion(
                            text: region.text,
                            confidence: region.confidence,
                            boundingBox: CGRect(
                                x: region.boundingBox.x,
                                y: region.boundingBox.y,
                                width: region.boundingBox.width,
                                height: region.boundingBox.height
                            )
                        )
                    }
                )
            }
            let actual = try LocalRulesDocumentDNAAnalyzer().analyze(
                documentID: fixture.documentID,
                contentHash: fixture.contentHash,
                extraction: StoredExtraction(
                    documentID: fixture.documentID,
                    analysisVersion: fixture.extractionVersion,
                    extraction: ExtractedDocument(
                        method: fixture.extractionMethod,
                        pages: pages
                    ),
                    updatedAt: fixture.analyzedAt
                ),
                analyzedAt: fixture.analyzedAt
            )

            #expect(
                actual == fixture.expected,
                "Complete snapshot mismatch for \(fixture.name)"
            )
        }
    }

    private func verifyExpectedEvidence(in fixture: DocumentDNAGoldenFixture) throws {
        let pages = Dictionary(
            uniqueKeysWithValues: fixture.pages.map { ($0.pageIndex, $0) }
        )
        for finding in fixture.expected.findings {
            for evidence in finding.evidence {
                let page = try #require(
                    pages[evidence.pageIndex],
                    "Missing expected page \(evidence.pageIndex) in \(fixture.name)"
                )
                let source = page.text as NSString
                let range = NSRange(
                    location: evidence.startUTF16,
                    length: evidence.lengthUTF16
                )
                #expect(NSMaxRange(range) <= source.length)
                guard NSMaxRange(range) <= source.length else {
                    continue
                }
                #expect(source.substring(with: range) == evidence.exactText)
                #expect(evidence.ocrRegionIndexes.allSatisfy {
                    page.regions.indices.contains($0)
                })
            }
        }
    }
}

private struct DocumentDNAGoldenFixture: Decodable {
    let name: String
    let documentID: UUID
    let contentHash: String
    let extractionVersion: String
    let extractionMethod: ExtractionMethod
    let pages: [GoldenPage]
    let analyzedAt: Date
    let expected: DocumentDNA
}

private struct GoldenPage: Decodable {
    let pageIndex: Int
    let text: String
    let regions: [GoldenRegion]
}

private struct GoldenRegion: Decodable {
    let text: String
    let confidence: Float
    let boundingBox: GoldenBoundingBox
}

private struct GoldenBoundingBox: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
