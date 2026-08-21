import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import LinkLoomCore

@Suite("Composite text extraction")
struct CompositeTextExtractorTests {
    @Test func imageUsesVisionDirectly() async throws {
        let image = try makePixelImage()
        let imageURL = try writePNG(image)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let embedded = FakePDFTextExtractor(result: sampleEmbeddedDocument())
        let renderer = FakePDFPageRenderer(images: [])
        let ocr = FakeOCRRecognizer()
        let extractor = CompositeTextExtractor(
            pdfText: embedded,
            pdfRenderer: renderer,
            ocr: ocr
        )

        let result = try await extractor.extract(from: imageURL, mediaType: .png)

        #expect(result.method == .visionOCR)
        #expect(result.pages.map(\.pageIndex) == [0])
        #expect(await embedded.callCount == 0)
        #expect(renderer.callCount == 0)
        #expect(await ocr.pageIndices == [0])
    }

    @Test func textPDFUsesEmbeddedTextWithoutOCR() async throws {
        let expected = sampleEmbeddedDocument()
        let embedded = FakePDFTextExtractor(result: expected)
        let renderer = FakePDFPageRenderer(images: [])
        let ocr = FakeOCRRecognizer()
        let extractor = CompositeTextExtractor(
            pdfText: embedded,
            pdfRenderer: renderer,
            ocr: ocr
        )

        let result = try await extractor.extract(
            from: URL(fileURLWithPath: "/fixture/text.pdf"),
            mediaType: .pdf
        )

        #expect(result == expected)
        #expect(await embedded.callCount == 1)
        #expect(renderer.callCount == 0)
        #expect(await ocr.pageIndices.isEmpty)
    }

    @Test func mixedPDFRendersOnlyBlankPages() async throws {
        let image = try makePixelImage()
        let embedded = FakePDFTextExtractor(result: ExtractedDocument(
            method: .embeddedPDFText,
            pages: [
                ExtractedPage(pageIndex: 0, text: "Embedded contract text", regions: []),
                ExtractedPage(pageIndex: 1, text: "", regions: []),
            ]
        ))
        let renderer = FakePDFPageRenderer(images: [image, image])
        let ocr = FakeOCRRecognizer()
        let extractor = CompositeTextExtractor(
            pdfText: embedded,
            pdfRenderer: renderer,
            ocr: ocr
        )

        let result = try await extractor.extract(
            from: URL(fileURLWithPath: "/fixture/mixed.pdf"),
            mediaType: .pdf
        )

        #expect(result.method == .hybridPDFTextAndOCR)
        #expect(result.pages.map(\.pageIndex) == [0, 1])
        #expect(result.pages.map(\.text) == ["Embedded contract text", "page-1"])
        #expect(result.pages[0].regions.isEmpty)
        #expect(!result.pages[1].regions.isEmpty)
        #expect(renderer.renderedPageIndices == [1])
        #expect(await ocr.pageIndices == [1])
    }

    @Test func mixedPDFPropagatesNonBlankOCRError() async throws {
        let image = try makePixelImage()
        let ocr = FakeOCRRecognizer(error: .insufficientEmbeddedText)
        let extractor = CompositeTextExtractor(
            pdfText: FakePDFTextExtractor(result: ExtractedDocument(
                method: .embeddedPDFText,
                pages: [
                    ExtractedPage(pageIndex: 0, text: "Embedded contract text", regions: []),
                    ExtractedPage(pageIndex: 1, text: "", regions: []),
                ]
            )),
            pdfRenderer: FakePDFPageRenderer(images: [image, image]),
            ocr: ocr
        )

        await #expect(throws: TextExtractionError.insufficientEmbeddedText) {
            try await extractor.extract(
                from: URL(fileURLWithPath: "/fixture/mixed.pdf"),
                mediaType: .pdf
            )
        }
        #expect(await ocr.pageIndices == [1])
    }

    @Test func imageOnlyPDFRendersEachPageForOCR() async throws {
        let image = try makePixelImage()
        let embedded = FakePDFTextExtractor(error: .insufficientEmbeddedText)
        let renderer = FakePDFPageRenderer(images: [image, image])
        let ocr = FakeOCRRecognizer()
        let extractor = CompositeTextExtractor(
            pdfText: embedded,
            pdfRenderer: renderer,
            ocr: ocr
        )

        let result = try await extractor.extract(
            from: URL(fileURLWithPath: "/fixture/scan.pdf"),
            mediaType: .pdf
        )

        #expect(result.method == .visionOCR)
        #expect(result.pages.map(\.pageIndex) == [0, 1])
        #expect(result.pages.map(\.text) == ["page-0", "page-1"])
        #expect(renderer.callCount == 2)
        #expect(await ocr.pageIndices == [0, 1])
    }

    @Test func imageOnlyPDFDoesNotRenderSecondPageBeforeFirstOCRCompletes() async throws {
        let image = try makePixelImage()
        let renderer = FakePDFPageRenderer(images: [image, image])
        let firstOCRGate = FirstOCRGate()
        let extractor = CompositeTextExtractor(
            pdfText: FakePDFTextExtractor(error: .insufficientEmbeddedText),
            pdfRenderer: renderer,
            ocr: FakeOCRRecognizer(firstOCRGate: firstOCRGate)
        )
        let extraction = Task {
            try await extractor.extract(
                from: URL(fileURLWithPath: "/fixture/scan.pdf"),
                mediaType: .pdf
            )
        }

        await firstOCRGate.waitUntilPaused()
        #expect(renderer.renderedPageIndices == [0])
        await firstOCRGate.release()

        let result = try await extraction.value
        #expect(result.pages.map(\.pageIndex) == [0, 1])
        #expect(renderer.renderedPageIndices == [0, 1])
    }

    @Test func rendererCancellationPropagates() async throws {
        let embedded = FakePDFTextExtractor(error: .insufficientEmbeddedText)
        let renderer = FakePDFPageRenderer(cancels: true)
        let extractor = CompositeTextExtractor(
            pdfText: embedded,
            pdfRenderer: renderer,
            ocr: FakeOCRRecognizer()
        )

        await #expect(throws: CancellationError.self) {
            try await extractor.extract(
                from: URL(fileURLWithPath: "/fixture/scan.pdf"),
                mediaType: .pdf
            )
        }
    }

    @Test func emptyRenderedPDFIsUnreadable() async throws {
        let embedded = FakePDFTextExtractor(error: .insufficientEmbeddedText)
        let extractor = CompositeTextExtractor(
            pdfText: embedded,
            pdfRenderer: FakePDFPageRenderer(images: []),
            ocr: FakeOCRRecognizer()
        )

        await #expect(throws: TextExtractionError.unreadableDocument) {
            try await extractor.extract(
                from: URL(fileURLWithPath: "/fixture/empty.pdf"),
                mediaType: .pdf
            )
        }
    }

    @Test func cancellationStopsBeforeSecondOCRPage() async throws {
        let image = try makePixelImage()
        let ocr = FakeOCRRecognizer(cancelAfterFirstPage: true)
        let extractor = CompositeTextExtractor(
            pdfText: FakePDFTextExtractor(error: .insufficientEmbeddedText),
            pdfRenderer: FakePDFPageRenderer(images: [image, image]),
            ocr: ocr
        )
        let extraction = Task {
            try await extractor.extract(
                from: URL(fileURLWithPath: "/fixture/scan.pdf"),
                mediaType: .pdf
            )
        }

        await #expect(throws: CancellationError.self) {
            try await extraction.value
        }
        #expect(await ocr.pageIndices == [0])
    }

    @Test func preCancelledImageExtractionDoesNotDecodeOrOCR() async throws {
        let image = try makePixelImage()
        let imageURL = try writePNG(image)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let gate = CompositeStartGate()
        let ocr = FakeOCRRecognizer()
        let extractor = CompositeTextExtractor(
            pdfText: FakePDFTextExtractor(result: sampleEmbeddedDocument()),
            pdfRenderer: FakePDFPageRenderer(images: []),
            ocr: ocr
        )
        let extraction = Task {
            await gate.waitUntilReleased()
            return try await extractor.extract(from: imageURL, mediaType: .png)
        }
        await gate.waitUntilArrival()

        extraction.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            try await extraction.value
        }
        #expect(await ocr.pageIndices.isEmpty)
    }

    @Test func passwordProtectedPDFDoesNotFallBackToOCR() async throws {
        let embedded = FakePDFTextExtractor(error: .passwordProtected)
        let renderer = FakePDFPageRenderer(images: [])
        let extractor = CompositeTextExtractor(
            pdfText: embedded,
            pdfRenderer: renderer,
            ocr: FakeOCRRecognizer()
        )

        await #expect(throws: TextExtractionError.passwordProtected) {
            try await extractor.extract(
                from: URL(fileURLWithPath: "/fixture/locked.pdf"),
                mediaType: .pdf
            )
        }
        #expect(renderer.callCount == 0)
    }

    @Test func jpegOrientationIsAppliedBeforeOCR() async throws {
        let image = try makePixelImage(width: 2, height: 3)
        let imageURL = try writeJPEG(image, orientation: 6)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let ocr = FakeOCRRecognizer()
        let extractor = CompositeTextExtractor(ocr: ocr)

        _ = try await extractor.extract(from: imageURL, mediaType: .jpeg)

        #expect(await ocr.imageSizes == [CGSize(width: 3, height: 2)])
    }

    @Test func invalidJPEGIsUnreadableBeforeOCR() async throws {
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: invalidURL) }
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x01, 0x02])
            .write(to: invalidURL)
        let ocr = FakeOCRRecognizer()
        let extractor = CompositeTextExtractor(ocr: ocr)

        await #expect(throws: TextExtractionError.unreadableDocument) {
            try await extractor.extract(from: invalidURL, mediaType: .jpeg)
        }
        #expect(await ocr.pageIndices.isEmpty)
    }

    @Test func limitsStandaloneImageDecodeToPixelBudget() throws {
        let maximumDimension = try CompositeTextExtractor.maximumDecodeDimension(
            width: 100_000,
            height: 100_000,
            pixelBudget: 1_000_000
        )

        #expect(maximumDimension == 1_000)
    }

    @Test func rejectsInvalidStandaloneImageDimensions() {
        #expect(throws: TextExtractionError.unreadableDocument) {
            try CompositeTextExtractor.maximumDecodeDimension(
                width: .infinity,
                height: 100,
                pixelBudget: 1_000_000
            )
        }
    }

    @Test func blankPDFPagePreservesPageIndexWhenAnotherPageHasText() async throws {
        let image = try makePixelImage()
        let ocr = FakeOCRRecognizer(blankPageIndices: [0])
        let extractor = CompositeTextExtractor(
            pdfText: FakePDFTextExtractor(error: .insufficientEmbeddedText),
            pdfRenderer: FakePDFPageRenderer(images: [image, image]),
            ocr: ocr
        )

        let result = try await extractor.extract(
            from: URL(fileURLWithPath: "/fixture/partial-blank.pdf"),
            mediaType: .pdf
        )

        #expect(result.pages.map(\.pageIndex) == [0, 1])
        #expect(result.pages.map(\.text) == ["", "page-1"])
        #expect(result.pages[0].regions.isEmpty)
    }

    @Test func entirelyBlankPDFHasNoRecognizedText() async throws {
        let image = try makePixelImage()
        let extractor = CompositeTextExtractor(
            pdfText: FakePDFTextExtractor(error: .insufficientEmbeddedText),
            pdfRenderer: FakePDFPageRenderer(images: [image, image]),
            ocr: FakeOCRRecognizer(blankPageIndices: [0, 1])
        )

        await #expect(throws: TextExtractionError.noRecognizedText) {
            try await extractor.extract(
                from: URL(fileURLWithPath: "/fixture/blank.pdf"),
                mediaType: .pdf
            )
        }
    }
}

@Suite("PDF page rendering")
struct PDFPageRendererTests {
    @Test func usesRotatedCropBoxDimensionsAtRequestedDPI() throws {
        for rotation in [90, 270] {
            let pdf = try makeRotatedCroppedPDF(rotation: rotation)
            defer { try? FileManager.default.removeItem(at: pdf) }

            let renderer = PDFPageRenderer(dpi: 72)
            let image = try renderer.renderPage(at: pdf, pageIndex: 0)

            #expect(try renderer.pageCount(at: pdf) == 1)
            #expect(image.width == 40)
            #expect(image.height == 80)
        }
    }

    @Test func rejectsDocumentWhoseRenderedPixelsExceedBudget() throws {
        let pdf = try makeRotatedCroppedPDF(rotation: 0)
        defer { try? FileManager.default.removeItem(at: pdf) }
        let renderer = PDFPageRenderer(dpi: 72, maximumPagePixelCount: 1_000)

        #expect(throws: TextExtractionError.unreadableDocument) {
            try renderer.renderPage(at: pdf, pageIndex: 0)
        }
    }

    @Test func appliesPixelBudgetToEachPageIndependently() throws {
        let pdf = try FixtureFactory.makeTextPDF(pages: ["First", "Second"])
        defer { try? FileManager.default.removeItem(at: pdf) }
        let renderer = PDFPageRenderer(dpi: 72, maximumPagePixelCount: 500_000)

        #expect(try renderer.pageCount(at: pdf) == 2)
        _ = try renderer.renderPage(at: pdf, pageIndex: 0)
        _ = try renderer.renderPage(at: pdf, pageIndex: 1)
    }
}

private enum FakePDFTextBehavior: Sendable {
    case result(ExtractedDocument)
    case error(TextExtractionError)
}

private func makeRotatedCroppedPDF(rotation: Int) throws -> URL {
    let sourceURL = try FixtureFactory.makeTextPDF(pages: ["Crop and rotate"])
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    guard let document = PDFDocument(url: sourceURL),
          let page = document.page(at: 0)
    else {
        throw CocoaError(.fileReadCorruptFile)
    }
    page.setBounds(CGRect(x: 10, y: 20, width: 200, height: 100), for: .mediaBox)
    page.setBounds(CGRect(x: 50, y: 40, width: 80, height: 40), for: .cropBox)
    page.rotation = rotation
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("pdf")
    guard document.write(to: outputURL) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return outputURL
}

private actor FakePDFTextExtractor: DocumentTextExtracting {
    private let behavior: FakePDFTextBehavior
    private(set) var callCount = 0

    init(result: ExtractedDocument) {
        behavior = .result(result)
    }

    init(error: TextExtractionError) {
        behavior = .error(error)
    }

    func extract(
        from url: URL,
        mediaType: SupportedMediaType
    ) async throws -> ExtractedDocument {
        callCount += 1
        switch behavior {
        case let .result(document):
            return document
        case let .error(error):
            throw error
        }
    }
}

private final class FakePDFPageRenderer: PDFPageRendering, @unchecked Sendable {
    private let lock = NSLock()
    private let images: [CGImage]
    private let cancels: Bool
    private var storedCallCount = 0
    private var storedRenderedPageIndices: [Int] = []

    init(images: [CGImage]) {
        self.images = images
        cancels = false
    }

    init(cancels: Bool) {
        images = []
        self.cancels = cancels
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    var renderedPageIndices: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storedRenderedPageIndices
    }

    func pageCount(at url: URL) throws -> Int {
        if cancels {
            throw CancellationError()
        }
        return images.count
    }

    func renderPage(at url: URL, pageIndex: Int) throws -> CGImage {
        lock.lock()
        storedCallCount += 1
        storedRenderedPageIndices.append(pageIndex)
        lock.unlock()
        if cancels {
            throw CancellationError()
        }
        guard images.indices.contains(pageIndex) else {
            throw TextExtractionError.unreadableDocument
        }
        return images[pageIndex]
    }
}

private actor FakeOCRRecognizer: ImageOCRRecognizing {
    private let cancelAfterFirstPage: Bool
    private let blankPageIndices: Set<Int>
    private let error: TextExtractionError?
    private let firstOCRGate: FirstOCRGate?
    private(set) var pageIndices: [Int] = []
    private(set) var imageSizes: [CGSize] = []

    init(
        cancelAfterFirstPage: Bool = false,
        blankPageIndices: Set<Int> = [],
        error: TextExtractionError? = nil,
        firstOCRGate: FirstOCRGate? = nil
    ) {
        self.cancelAfterFirstPage = cancelAfterFirstPage
        self.blankPageIndices = blankPageIndices
        self.error = error
        self.firstOCRGate = firstOCRGate
    }

    func recognize(cgImage: CGImage, pageIndex: Int) async throws -> ExtractedPage {
        pageIndices.append(pageIndex)
        imageSizes.append(CGSize(width: cgImage.width, height: cgImage.height))
        if pageIndices.count == 1 {
            await firstOCRGate?.pause()
        }
        if cancelAfterFirstPage && pageIndices.count == 1 {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        if blankPageIndices.contains(pageIndex) {
            throw TextExtractionError.noRecognizedText
        }
        if let error {
            throw error
        }
        let text = "page-\(pageIndex)"
        return ExtractedPage(
            pageIndex: pageIndex,
            text: text,
            regions: [TextRegion(
                text: text,
                confidence: 0.99,
                boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
            )]
        )
    }
}

private actor FirstOCRGate {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        for waiter in pauseWaiters {
            waiter.resume()
        }
        pauseWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CompositeStartGate {
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

private func sampleEmbeddedDocument() -> ExtractedDocument {
    ExtractedDocument(
        method: .embeddedPDFText,
        pages: [ExtractedPage(pageIndex: 0, text: "embedded", regions: [])]
    )
}

private func makePixelImage(width: Int = 2, height: Int = 2) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }
    return image
}

private func writeJPEG(_ image: CGImage, orientation: UInt32) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jpg")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.jpeg" as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let properties = [kCGImagePropertyOrientation: orientation] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return url
}

private func writePNG(_ image: CGImage) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return url
}
