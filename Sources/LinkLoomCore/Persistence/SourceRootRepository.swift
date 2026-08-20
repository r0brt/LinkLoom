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
        let canonicalPath = Self.canonicalPath(url)
        return try await dbWriter.write { db in
            let sources = try SourceRootRecord.fetchAll(db)
            if var existing = sources.first(where: { source in
                let existingURL = (try? sourceAccess.resolve(source.bookmarkData).url)
                    ?? URL(fileURLWithPath: source.pathHint, isDirectory: true)
                return Self.canonicalPath(existingURL) == canonicalPath
            }) {
                existing.displayName = url.lastPathComponent
                existing.pathHint = url.path
                existing.bookmarkData = bookmark
                try existing.update(db)
                return existing
            }

            let record = SourceRootRecord(
                displayName: url.lastPathComponent,
                pathHint: url.path,
                bookmarkData: bookmark,
                createdAt: now
            )
            try record.insert(db)
            return record
        }
    }

    public func all() async throws -> [SourceRootRecord] {
        try await dbWriter.read { db in
            try SourceRootRecord.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func renewBookmarkIfStale(
        _ source: SourceRootRecord,
        sourceAccess: any SourceAccessing
    ) async throws -> SourceRootRecord {
        let resolved = try sourceAccess.resolve(source.bookmarkData)
        guard resolved.bookmarkWasStale else { return source }

        let (url, bookmark) = try await sourceAccess.withAccess(
            to: source.bookmarkData
        ) { url in
            (url, try sourceAccess.createBookmark(for: url))
        }
        return try await dbWriter.write { db in
            guard var stored = try SourceRootRecord.fetchOne(
                db,
                key: source.id
            ) else {
                throw SourceRootRepositoryError.sourceNotFound
            }
            guard stored.bookmarkData == source.bookmarkData else { return stored }
            stored.displayName = url.lastPathComponent
            stored.pathHint = url.path
            stored.bookmarkData = bookmark
            try stored.update(db)
            return stored
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

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private enum SourceRootRepositoryError: Error {
    case sourceNotFound
}
