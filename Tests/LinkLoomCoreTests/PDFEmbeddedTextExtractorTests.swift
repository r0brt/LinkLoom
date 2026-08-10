import Foundation
import Testing
@testable import LinkLoomCore

@Suite("PDF embedded text extraction")
struct PDFEmbeddedTextExtractorTests {
    @Test func extractsTextPerPage() async throws {
        let pdf = try FixtureFactory.makeTextPDF(
            pages: ["Heimvertrag 2026", "Tarif CHF 7'840"]
        )
        defer { try? FileManager.default.removeItem(at: pdf) }

        let result = try await PDFEmbeddedTextExtractor(minimumCharacterCount: 1)
            .extract(from: pdf, mediaType: .pdf)

        #expect(result.method == .embeddedPDFText)
        #expect(result.pages.map(\.pageIndex) == [0, 1])
        #expect(result.pages[0].text.contains("Heimvertrag"))
        #expect(result.pages[1].text.contains("7'840"))
    }

    @Test func rejectsImageOnlyPDFForOCRFallback() async throws {
        let pdf = try FixtureFactory.makeImageOnlyPDF(text: "Rechnung")
        defer { try? FileManager.default.removeItem(at: pdf) }

        await #expect(throws: TextExtractionError.insufficientEmbeddedText) {
            try await PDFEmbeddedTextExtractor().extract(from: pdf, mediaType: .pdf)
        }
    }

    @Test func rejectsDocumentsWithoutNonWhitespaceTextAtZeroThreshold() async throws {
        let imageOnly = try FixtureFactory.makeImageOnlyPDF(text: "Rechnung")
        let whitespaceOnly = try FixtureFactory.makeTextPDF(pages: ["   "])
        defer {
            try? FileManager.default.removeItem(at: imageOnly)
            try? FileManager.default.removeItem(at: whitespaceOnly)
        }

        for pdf in [imageOnly, whitespaceOnly] {
            await #expect(throws: TextExtractionError.insufficientEmbeddedText) {
                try await PDFEmbeddedTextExtractor(minimumCharacterCount: 0)
                    .extract(from: pdf, mediaType: .pdf)
            }
        }
    }

    @Test func preCancelledExtractionDoesNotOpenOrReadPDF() async throws {
        let pdf = try FixtureFactory.makeTextPDF(pages: ["Heimvertrag 2026"])
        defer { try? FileManager.default.removeItem(at: pdf) }
        let gate = ExtractionStartGate()
        let extraction = Task {
            await gate.waitUntilReleased()
            return try await PDFEmbeddedTextExtractor(minimumCharacterCount: 1)
                .extract(from: pdf, mediaType: .pdf)
        }
        await gate.waitUntilArrival()

        extraction.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            try await extraction.value
        }
    }
}

private actor ExtractionStartGate {
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        arrived = true
        for waiter in arrivalWaiters {
            waiter.resume()
        }
        arrivalWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilArrival() async {
        if arrived { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
