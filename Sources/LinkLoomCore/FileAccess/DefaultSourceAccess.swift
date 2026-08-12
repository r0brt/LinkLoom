import Foundation

public struct DefaultSourceAccess: SourceAccessing {
    private let resolveBookmarkOperation: @Sendable (Data) throws -> ResolvedSource
    private let startAccessingOperation: @Sendable (URL) -> Bool
    private let stopAccessingOperation: @Sendable (URL) -> Void

    public init() {
        resolveBookmarkOperation = { bookmark in
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return ResolvedSource(url: url, bookmarkWasStale: stale)
        }
        startAccessingOperation = { url in
            url.startAccessingSecurityScopedResource()
        }
        stopAccessingOperation = { url in
            url.stopAccessingSecurityScopedResource()
        }
    }

    init(
        resolveBookmark: @escaping @Sendable (Data) throws -> ResolvedSource,
        startAccessing: @escaping @Sendable (URL) -> Bool,
        stopAccessing: @escaping @Sendable (URL) -> Void
    ) {
        resolveBookmarkOperation = resolveBookmark
        startAccessingOperation = startAccessing
        stopAccessingOperation = stopAccessing
    }

    public func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolve(_ bookmark: Data) throws -> ResolvedSource {
        try resolveBookmarkOperation(bookmark)
    }

    public func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let resolved = try resolve(bookmark)
        let started = startAccessingOperation(resolved.url)
        defer {
            if started {
                stopAccessingOperation(resolved.url)
            }
        }
        return try await operation(resolved.url)
    }
}
