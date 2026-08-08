import Foundation

public struct ResolvedSource: Sendable {
    public let url: URL
    public let bookmarkWasStale: Bool
}

public protocol SourceAccessing: Sendable {
    func createBookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> ResolvedSource
    func withAccess<T: Sendable>(
        to bookmark: Data,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T
}
