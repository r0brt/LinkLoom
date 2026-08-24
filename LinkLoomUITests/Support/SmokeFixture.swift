import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum SourceEntryKind: Equatable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

struct SourceFileSnapshot: Equatable {
    let relativePath: String
    let kind: SourceEntryKind
    let sha256: String?
    let byteCount: Int64?
    let modificationDate: Date?
    let posixMode: Int
    let symbolicLinkDestination: String?
}

struct SmokeFixture {
    let rootURL: URL
    let sourceURL: URL
    let databaseURL: URL

    init() throws {
        try self.init(prepareSource: Self.prepareDefaultSource)
    }

    init(prepareSource: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkLoomUISmoke-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        rootURL = root
        sourceURL = source
        databaseURL = root.appendingPathComponent("linkloom.sqlite", isDirectory: false)

        try prepareSource(source)
    }

    private static func prepareDefaultSource(_ source: URL) throws {
        let selectablePDF = source.appendingPathComponent("selectable.pdf", isDirectory: false)
        try Self.writeTextPDF("Selectable LinkLoom smoke text", to: selectablePDF)

        let scanImage = source.appendingPathComponent("scan.png", isDirectory: false)
        try Self.writeScanImage("Scanned LinkLoom smoke 2026", to: scanImage)

        try Data("%PDF-1.7\ncorrupt".utf8).write(
            to: source.appendingPathComponent("corrupt.pdf", isDirectory: false)
        )
        try Data("This file type is intentionally unsupported.".utf8).write(
            to: source.appendingPathComponent("unsupported.txt", isDirectory: false)
        )

        guard PDFDocument(url: selectablePDF)?.pageCount == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func snapshot() throws -> [SourceFileSnapshot] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var snapshots: [SourceFileSnapshot] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate
            else {
                continue
            }
            let path = fileURL.standardizedFileURL.path
            let prefix = sourceURL.standardizedFileURL.path + "/"
            guard path.hasPrefix(prefix) else {
                throw CocoaError(.fileReadNoPermission)
            }
            let data = try Data(contentsOf: fileURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            snapshots.append(SourceFileSnapshot(
                relativePath: String(path.dropFirst(prefix.count)),
                kind: .regularFile,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                byteCount: Int64(values.fileSize ?? data.count),
                modificationDate: modificationDate,
                posixMode: mode,
                symbolicLinkDestination: nil
            ))
        }
        return snapshots.sorted { $0.relativePath < $1.relativePath }
    }

    func remove() throws {
        let root = rootURL.standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        guard root.deletingLastPathComponent() == temporaryDirectory,
              root.lastPathComponent.hasPrefix("LinkLoomUISmoke-")
        else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private static func writeTextPDF(_ text: String, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        draw(text, fontSize: 24, at: CGPoint(x: 72, y: 700), in: context)
        context.endPDFPage()
        context.closePDF()
    }

    private static func writeScanImage(_ text: String, to url: URL) throws {
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
        draw(text, fontSize: 82, at: CGPoint(x: 40, y: 105), in: context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func draw(
        _ text: String,
        fontSize: CGFloat,
        at point: CGPoint,
        in context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString,
                fontSize,
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
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
