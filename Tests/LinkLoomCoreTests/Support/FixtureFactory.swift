import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct AcceptanceSource {
    let directory: TemporaryDirectory
    let includesHEIC: Bool

    var rootURL: URL { directory.url }
}

struct CatalogBenchmarkSource {
    let directory: TemporaryDirectory

    var rootURL: URL { directory.url }
}

enum FixtureFactory {
    static func makeCatalogBenchmarkSource(
        documentCount: Int
    ) throws -> CatalogBenchmarkSource {
        let directory = try TemporaryDirectory()
        for index in 0..<documentCount {
            let name = String(format: "document-%05d.pdf", index)
            let bytes = Data("LinkLoom catalog fixture \(index)".utf8)
            try bytes.write(to: directory.url.appendingPathComponent(name))
        }
        return CatalogBenchmarkSource(directory: directory)
    }

    static func makeAcceptanceSource() throws -> AcceptanceSource {
        let directory = try TemporaryDirectory()
        let selectablePDF = try makeTextPDF(pages: ["Selectable LinkLoom acceptance text"])
        defer { try? FileManager.default.removeItem(at: selectablePDF) }
        let imageOnlyPDF = try makeImageOnlyPDF(text: "Scanned LinkLoom PDF 2026")
        defer { try? FileManager.default.removeItem(at: imageOnlyPDF) }
        guard PDFDocument(url: selectablePDF)?.pageCount == 1,
              PDFDocument(url: imageOnlyPDF)?.pageCount == 1
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try directory.write("selectable.pdf", bytes: Data(contentsOf: selectablePDF))
        try directory.write("scan.pdf", bytes: Data(contentsOf: imageOnlyPDF))

        let scan = try makeAcceptanceImage("LinkLoom Scan 2026")
        try write(scan, to: directory.url.appendingPathComponent("scan.jpg"), type: .jpeg)
        try write(scan, to: directory.url.appendingPathComponent("scan.png"), type: .png)

        let heicIdentifier = UTType.heic.identifier
        let encodableTypes = CGImageDestinationCopyTypeIdentifiers() as NSArray
        let includesHEIC = encodableTypes.contains(heicIdentifier)
        if includesHEIC {
            try write(scan, to: directory.url.appendingPathComponent("scan.heic"), type: .heic)
        }

        try directory.write("corrupt.pdf", bytes: Data("%PDF-1.7\ncorrupt".utf8))
        try directory.write("unsupported.txt", bytes: Data("not catalogued".utf8))
        return AcceptanceSource(directory: directory, includesHEIC: includesHEIC)
    }

    static func makeTextPDF(pages: [String]) throws -> URL {
        let url = temporaryPDFURL()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for text in pages {
            context.beginPDFPage(nil)
            draw(text, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    static func makeImageOnlyPDF(text: String) throws -> URL {
        let width = 612
        let height = 792
        guard let bitmap = CGContext(
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
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(text, in: bitmap)
        guard let image = bitmap.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }

        let url = temporaryPDFURL()
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        guard let pdf = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: mediaBox)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    private static func temporaryPDFURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
    }

    private static func makeAcceptanceImage(_ text: String) throws -> CGImage {
        let width = 1_600
        let height = 300
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
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString,
                82,
                nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 0,
                alpha: 1
            ),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        context.textPosition = CGPoint(x: 40, y: 105)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let appKitImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        guard let normalized = appKitImage.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return normalized
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let properties: CFDictionary? = type == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func draw(_ text: String, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString,
                24,
                nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 0,
                alpha: 1
            ),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
    }
}
