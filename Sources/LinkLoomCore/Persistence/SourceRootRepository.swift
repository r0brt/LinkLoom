import Foundation
import GRDB

public actor SourceRootRepository {
    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func add(
        url: URL,
        sourceAccess: any SourceAccessing,
        now: Date = .now
    ) async throws -> SourceRootRecord {
        let bookmark = try sourceAccess.createBookmark(for: url)
        let record = SourceRootRecord(
            displayName: url.lastPathComponent,
            pathHint: url.path,
            bookmarkData: bookmark,
            createdAt: now
        )
        try await dbWriter.write { db in
            try record.insert(db)
        }
        return record
    }

    public func all() async throws -> [SourceRootRecord] {
        try await dbWriter.read { db in
            try SourceRootRecord.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func updateLastScan(id: UUID, at date: Date) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE sourceRoot SET lastScanAt = ? WHERE id = ?",
                arguments: [date, id]
            )
        }
    }

    public func remove(id: UUID) async throws {
        try await dbWriter.write { db in
            _ = try SourceRootRecord.deleteOne(db, key: id)
        }
    }
}
