import CoreGraphics
import Foundation
import PDFKit

public protocol PDFPageRendering: Sendable {
    func renderPages(at url: URL) throws -> [CGImage]
}

public protocol PDFPageAtATimeRendering: PDFPageRendering {
    func pageCount(at url: URL) throws -> Int
    func renderPage(at url: URL, pageIndex: Int) throws -> CGImage
}

public extension PDFPageAtATimeRendering {
    func renderPages(at url: URL) throws -> [CGImage] {
        let pageCount = try pageCount(at: url)
        var images: [CGImage] = []
        images.reserveCapacity(pageCount)
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            images.append(try renderPage(at: url, pageIndex: pageIndex))
        }
        return images
    }
}

public struct PDFPageRenderer: PDFPageAtATimeRendering {
    private static let defaultMaximumPagePixelCount = 100_000_000

    public let dpi: CGFloat
    private let maximumPagePixelCount: Int

    public init(dpi: CGFloat = 200) {
        self.dpi = dpi
        maximumPagePixelCount = Self.defaultMaximumPagePixelCount
    }

    init(dpi: CGFloat, maximumPagePixelCount: Int) {
        self.dpi = dpi
        self.maximumPagePixelCount = maximumPagePixelCount
    }

    public func pageCount(at url: URL) throws -> Int {
        try validatedDocument(at: url).pageCount
    }

    public func renderPage(at url: URL, pageIndex: Int) throws -> CGImage {
        let document = try validatedDocument(at: url)
        try Task.checkCancellation()
        guard document.pageCount > pageIndex,
              pageIndex >= 0,
              let page = document.page(at: pageIndex)
        else {
            throw TextExtractionError.unreadableDocument
        }
        let scale = dpi / 72
        let bounds = page.bounds(for: .cropBox)
        let normalizedRotation = ((page.rotation % 360) + 360) % 360
        let swapsDimensions = normalizedRotation == 90 || normalizedRotation == 270
        let pointWidth = swapsDimensions ? bounds.height : bounds.width
        let pointHeight = swapsDimensions ? bounds.width : bounds.height
        let pixelWidth = ceil(pointWidth * scale)
        let pixelHeight = ceil(pointHeight * scale)
        let pixelCount = pixelWidth * pixelHeight
        guard bounds.minX.isFinite,
              bounds.minY.isFinite,
              pointWidth.isFinite,
              pointHeight.isFinite,
              pixelWidth.isFinite,
              pixelHeight.isFinite,
              pixelCount.isFinite,
              pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= CGFloat(Int.max),
              pixelHeight <= CGFloat(Int.max),
              pixelCount <= CGFloat(maximumPagePixelCount)
        else {
            throw TextExtractionError.unreadableDocument
        }
        let width = Int(pixelWidth)
        let height = Int(pixelHeight)
        guard let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw TextExtractionError.unreadableDocument
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        try Task.checkCancellation()
        guard let image = context.makeImage() else {
            throw TextExtractionError.unreadableDocument
        }
        return image
    }

    private func validatedDocument(at url: URL) throws -> PDFDocument {
        try Task.checkCancellation()
        guard dpi.isFinite,
              dpi > 0,
              maximumPagePixelCount > 0,
              let document = PDFDocument(url: url),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw TextExtractionError.unreadableDocument
        }
        return document
    }
}
