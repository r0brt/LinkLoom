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

            let pageCount = try pdfPageCount(at: url)
            guard pageCount == embedded.pages.count else {
                throw TextExtractionError.unreadableDocument
            }

            var pages = embedded.pages
            for pagePosition in emptyPagePositions {
                try Task.checkCancellation()
                let pageIndex = pages[pagePosition].pageIndex
                guard pageIndex >= 0, pageIndex < pageCount else {
                    throw TextExtractionError.unreadableDocument
                }
                do {
                    pages[pagePosition] = try await recognizePDFPage(
                        at: url,
                        pageIndex: pageIndex
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
        let pageCount = try pdfPageCount(at: url)
        guard pageCount > 0 else {
            throw TextExtractionError.unreadableDocument
        }
        var pages: [ExtractedPage] = []
        pages.reserveCapacity(pageCount)
        var recognizedAnyText = false
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            do {
                pages.append(try await recognizePDFPage(at: url, pageIndex: pageIndex))
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

    private func pdfPageCount(at url: URL) throws -> Int {
        do {
            return try pdfRenderer.pageCount(at: url)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw TextExtractionError.unreadableDocument
        }
    }

    private func recognizePDFPage(
        at url: URL,
        pageIndex: Int
    ) async throws -> ExtractedPage {
        let image: CGImage
        do {
            image = try pdfRenderer.renderPage(at: url, pageIndex: pageIndex)
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
