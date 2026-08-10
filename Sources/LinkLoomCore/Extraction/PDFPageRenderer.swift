import CoreGraphics
import Foundation
import PDFKit

public protocol PDFPageRendering: Sendable {
    func renderPages(at url: URL) throws -> [CGImage]
}

public struct PDFPageRenderer: PDFPageRendering {
    private static let defaultMaximumTotalPixelCount = 100_000_000

    public let dpi: CGFloat
    private let maximumTotalPixelCount: Int

    public init(dpi: CGFloat = 200) {
        self.dpi = dpi
        maximumTotalPixelCount = Self.defaultMaximumTotalPixelCount
    }

    init(dpi: CGFloat, maximumTotalPixelCount: Int) {
        self.dpi = dpi
        self.maximumTotalPixelCount = maximumTotalPixelCount
    }

    public func renderPages(at url: URL) throws -> [CGImage] {
        try Task.checkCancellation()
        guard dpi.isFinite,
              dpi > 0,
              maximumTotalPixelCount > 0,
              let document = PDFDocument(url: url),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw TextExtractionError.unreadableDocument
        }
        let scale = dpi / 72
        var totalPixelCount = 0
        var images: [CGImage] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw TextExtractionError.unreadableDocument
            }
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
                  pixelCount <= CGFloat(maximumTotalPixelCount - totalPixelCount)
            else {
                throw TextExtractionError.unreadableDocument
            }
            let width = Int(pixelWidth)
            let height = Int(pixelHeight)
            totalPixelCount += width * height
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
            guard let image = context.makeImage() else {
                throw TextExtractionError.unreadableDocument
            }
            images.append(image)
        }
        return images
    }
}
