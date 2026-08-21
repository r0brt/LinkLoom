import CoreGraphics
import Foundation
import ImageIO

public struct CompositeTextExtractor: DocumentTextExtracting {
    private static let maximumDecodedImagePixelCount = 40_000_000

    private let pdfText: any DocumentTextExtracting
    private let pdfRenderer: any PDFPageRendering
    private let ocr: any ImageOCRRecognizing

    public init(
        pdfText: any DocumentTextExtracting = PDFEmbeddedTextExtractor(minimumCharacterCount: 1),
        pdfRenderer: any PDFPageRendering = PDFPageRenderer(dpi: 200),
        ocr: any ImageOCRRecognizing = VisionOCRRecognizer()
    ) {
        self.pdfText = pdfText
        self.pdfRenderer = pdfRenderer
        self.ocr = ocr
    }

    public func extract(
        from url: URL,
        mediaType: SupportedMediaType
    ) async throws -> ExtractedDocument {
        try Task.checkCancellation()
        switch mediaType {
        case .pdf:
            let embedded: ExtractedDocument
            do {
                embedded = try await pdfText.extract(from: url, mediaType: mediaType)
            } catch TextExtractionError.insufficientEmbeddedText {
                return try await extractImageOnlyPDF(from: url)
            }
            let emptyPagePositions = embedded.pages.indices.filter {
                embedded.pages[$0].text.allSatisfy(\.isWhitespace)
            }
            guard !emptyPagePositions.isEmpty else {
                return embedded
            }

            let pageSource = try pdfPageSource(at: url)
            guard pageSource.count == embedded.pages.count else {
                throw TextExtractionError.unreadableDocument
            }

            var pages = embedded.pages
            for pagePosition in emptyPagePositions {
                try Task.checkCancellation()
                let pageIndex = pages[pagePosition].pageIndex
                guard pageIndex >= 0, pageIndex < pageSource.count else {
                    throw TextExtractionError.unreadableDocument
                }
                do {
                    pages[pagePosition] = try await recognizePDFPage(
                        at: url,
                        pageIndex: pageIndex,
                        pageSource: pageSource
                    )
                } catch TextExtractionError.noRecognizedText {
                    pages[pagePosition] = ExtractedPage(
                        pageIndex: pageIndex,
                        text: "",
                        regions: []
                    )
                }
            }
            return ExtractedDocument(
                method: .hybridPDFTextAndOCR,
                pages: pages.sorted { $0.pageIndex < $1.pageIndex }
            )
        case .jpeg, .png, .heic:
            try Task.checkCancellation()
            let image = try Self.decodeImage(at: url)
            let page = try await ocr.recognize(cgImage: image, pageIndex: 0)
            return ExtractedDocument(method: .visionOCR, pages: [page])
        }
    }

    private func extractImageOnlyPDF(from url: URL) async throws -> ExtractedDocument {
        let pageSource = try pdfPageSource(at: url)
        guard pageSource.count > 0 else {
            throw TextExtractionError.unreadableDocument
        }
        var pages: [ExtractedPage] = []
        pages.reserveCapacity(pageSource.count)
        var recognizedAnyText = false
        for pageIndex in 0..<pageSource.count {
            try Task.checkCancellation()
            do {
                pages.append(try await recognizePDFPage(
                    at: url,
                    pageIndex: pageIndex,
                    pageSource: pageSource
                ))
                recognizedAnyText = true
            } catch TextExtractionError.noRecognizedText {
                pages.append(ExtractedPage(
                    pageIndex: pageIndex,
                    text: "",
                    regions: []
                ))
            }
        }
        guard recognizedAnyText else {
            throw TextExtractionError.noRecognizedText
        }
        return ExtractedDocument(method: .visionOCR, pages: pages)
    }

    private func pdfPageSource(at url: URL) throws -> PDFPageSource {
        do {
            if let pageRenderer = pdfRenderer as? any PDFPageAtATimeRendering {
                return .pageAtATime(
                    renderer: pageRenderer,
                    count: try pageRenderer.pageCount(at: url)
                )
            }
            return .rendered(try pdfRenderer.renderPages(at: url))
        } catch let error as CancellationError {
            throw error
        } catch {
            throw TextExtractionError.unreadableDocument
        }
    }

    private func recognizePDFPage(
        at url: URL,
        pageIndex: Int,
        pageSource: PDFPageSource
    ) async throws -> ExtractedPage {
        let image: CGImage
        do {
            image = try pageSource.renderPage(at: url, pageIndex: pageIndex)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw TextExtractionError.unreadableDocument
        }
        try Task.checkCancellation()
        return try await ocr.recognize(cgImage: image, pageIndex: pageIndex)
    }

    private static func decodeImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw TextExtractionError.unreadableDocument
        }
        let maximumDimension = try maximumDecodeDimension(
            width: width.doubleValue,
            height: height.doubleValue,
            pixelBudget: maximumDecodedImagePixelCount
        )
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              image.width > 0,
              image.height > 0,
              image.width <= maximumDecodedImagePixelCount / image.height
        else {
            throw TextExtractionError.unreadableDocument
        }
        return image
    }

    static func maximumDecodeDimension(
        width: Double,
        height: Double,
        pixelBudget: Int
    ) throws -> Int {
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              pixelBudget > 0
        else {
            throw TextExtractionError.unreadableDocument
        }
        let maximumSourceDimension = max(width, height)
        let sourcePixelCount = width * height
        let scale = sourcePixelCount <= Double(pixelBudget)
            ? 1
            : sqrt(Double(pixelBudget) / sourcePixelCount)
        let boundedDimension = floor(maximumSourceDimension * scale)
        guard boundedDimension.isFinite,
              boundedDimension >= 1,
              boundedDimension <= Double(Int.max)
        else {
            throw TextExtractionError.unreadableDocument
        }
        return Int(boundedDimension)
    }
}

private enum PDFPageSource {
    case pageAtATime(renderer: any PDFPageAtATimeRendering, count: Int)
    case rendered([CGImage])

    var count: Int {
        switch self {
        case let .pageAtATime(_, count):
            count
        case let .rendered(images):
            images.count
        }
    }

    func renderPage(at url: URL, pageIndex: Int) throws -> CGImage {
        switch self {
        case let .pageAtATime(renderer, _):
            return try renderer.renderPage(at: url, pageIndex: pageIndex)
        case let .rendered(images):
            guard images.indices.contains(pageIndex) else {
                throw TextExtractionError.unreadableDocument
            }
            return images[pageIndex]
        }
    }
}
