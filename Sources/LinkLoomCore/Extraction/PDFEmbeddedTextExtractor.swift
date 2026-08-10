import Foundation
import PDFKit

public struct PDFEmbeddedTextExtractor: DocumentTextExtracting {
    public let minimumCharacterCount: Int

    public init(minimumCharacterCount: Int = 40) {
        self.minimumCharacterCount = minimumCharacterCount
    }

    public func extract(
        from url: URL,
        mediaType: SupportedMediaType
    ) async throws -> ExtractedDocument {
        try Task.checkCancellation()
        guard mediaType == .pdf else {
            throw TextExtractionError.unsupportedMedia
        }
        guard let document = PDFDocument(url: url) else {
            throw TextExtractionError.unreadableDocument
        }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw TextExtractionError.passwordProtected
        }
        var pages: [ExtractedPage] = []
        var characterCount = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let text = document.page(at: index)?.string ?? ""
            pages.append(ExtractedPage(
                pageIndex: index,
                text: text,
                regions: []
            ))
            characterCount += text.filter { !$0.isWhitespace }.count
        }
        try Task.checkCancellation()
        guard characterCount >= max(1, minimumCharacterCount) else {
            throw TextExtractionError.insufficientEmbeddedText
        }
        return ExtractedDocument(method: .embeddedPDFText, pages: pages)
    }
}
