import CoreGraphics
import Foundation
import ImageIO

public struct CompositeTextExtractor: DocumentTextExtracting {
    private static let maximumDecodedImagePixelCount = 40_000_000

    private let pdfText: any DocumentTextExtracting
    private let pdfRenderer: any PDFPageRendering
    private let ocr: any ImageOCRRecognizing

    public init(
        pdfText: any DocumentTextExtracting = PDFEmbeddedTextExtractor(),
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
            do {
                return try await pdfText.extract(from: url, mediaType: mediaType)
            } catch TextExtractionError.insufficientEmbeddedText {
                try Task.checkCancellation()
                let images: [CGImage]
                do {
                    images = try pdfRenderer.renderPages(at: url)
                } catch let error as CancellationError {
                    throw error
                } catch {
                    throw TextExtractionError.unreadableDocument
                }
                try Task.checkCancellation()
                guard !images.isEmpty else {
                    throw TextExtractionError.unreadableDocument
                }
                var pages: [ExtractedPage] = []
                var recognizedAnyText = false
                for (pageIndex, image) in images.enumerated() {
                    try Task.checkCancellation()
                    do {
                        pages.append(try await ocr.recognize(
                            cgImage: image,
                            pageIndex: pageIndex
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
        case .jpeg, .png, .heic:
            try Task.checkCancellation()
            let image = try Self.decodeImage(at: url)
            let page = try await ocr.recognize(cgImage: image, pageIndex: 0)
            return ExtractedDocument(method: .visionOCR, pages: [page])
        }
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
