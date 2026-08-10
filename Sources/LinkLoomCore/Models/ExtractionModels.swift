import CoreGraphics
import Foundation

public enum ExtractionMethod: String, Codable, Sendable {
    case embeddedPDFText
    case visionOCR
}

public struct TextRegion: Codable, Sendable, Equatable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect
}

public struct ExtractedPage: Codable, Sendable, Equatable {
    public let pageIndex: Int
    public let text: String
    public let regions: [TextRegion]
}

public struct ExtractedDocument: Codable, Sendable, Equatable {
    public let method: ExtractionMethod
    public let pages: [ExtractedPage]
    public var joinedText: String { pages.map(\.text).joined(separator: "\n\n") }
}
