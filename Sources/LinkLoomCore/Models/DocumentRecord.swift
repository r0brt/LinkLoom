import Foundation
import GRDB

public enum SupportedMediaType: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case pdf
    case jpeg
    case png
    case heic
}

public enum DocumentStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case discovered
    case extracting
    case ready
    case failed
}

public enum DocumentAvailability: String, Codable, DatabaseValueConvertible, Sendable {
    case available
    case unavailable
    case missing
}

public struct DocumentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "document"

    public static func databaseDateEncodingStrategy(
        for column: String
    ) -> DatabaseDateEncodingStrategy {
        column == "modifiedAt" ? .timeIntervalSinceReferenceDate : .deferredToDate
    }

    public static func databaseDateDecodingStrategy(
        for column: String
    ) -> DatabaseDateDecodingStrategy {
        guard column == "modifiedAt" else { return .deferredToDate }
        return .custom { databaseValue in
            if let seconds = Double.fromDatabaseValue(databaseValue) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            return Date.fromDatabaseValue(databaseValue)
        }
    }

    public var id: UUID
    public var sourceRootID: UUID
    public var relativePath: String
    public var contentHash: String
    public var byteCount: Int64
    public var modifiedAt: Date
    public var mediaType: SupportedMediaType
    public var status: DocumentStatus
    public var availability: DocumentAvailability
    public var pageCount: Int?
    public var failureCode: String?
    public var lastSeenAt: Date

    public init(
        id: UUID = UUID(),
        sourceRootID: UUID,
        relativePath: String,
        contentHash: String,
        byteCount: Int64,
        modifiedAt: Date,
        mediaType: SupportedMediaType,
        status: DocumentStatus = .discovered,
        availability: DocumentAvailability = .available,
        pageCount: Int? = nil,
        failureCode: String? = nil,
        lastSeenAt: Date = .now
    ) {
        self.id = id
        self.sourceRootID = sourceRootID
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.mediaType = mediaType
        self.status = status
        self.availability = availability
        self.pageCount = pageCount
        self.failureCode = failureCode
        self.lastSeenAt = lastSeenAt
    }
}
