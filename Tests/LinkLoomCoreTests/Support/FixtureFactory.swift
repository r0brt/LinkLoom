import CoreGraphics
import CoreText
import Foundation

enum FixtureFactory {
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
