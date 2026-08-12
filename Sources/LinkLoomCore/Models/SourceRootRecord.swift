import Foundation
import GRDB

public struct SourceRootRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "sourceRoot"

    public var id: UUID
    public var displayName: String
    public var pathHint: String
    public var bookmarkData: Data
    public var createdAt: Date
    public var lastScanAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        pathHint: String,
        bookmarkData: Data,
        createdAt: Date = .now,
        lastScanAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.pathHint = pathHint
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.lastScanAt = lastScanAt
    }
}
