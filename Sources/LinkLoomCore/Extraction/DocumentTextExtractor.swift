import Foundation

public enum TextExtractionError: Error, Equatable {
    case unsupportedMedia
    case unreadableDocument
    case passwordProtected
    case insufficientEmbeddedText
    case noRecognizedText
}

public protocol DocumentTextExtracting: Sendable {
    func extract(from url: URL, mediaType: SupportedMediaType) async throws -> ExtractedDocument
}
