import Foundation

public struct DirectoryChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case contentChanged
        case rootUnavailable
        case rootAvailable
    }

    public let sourceRootID: UUID
    public let kind: Kind

    public init(sourceRootID: UUID, kind: Kind) {
        self.sourceRootID = sourceRootID
        self.kind = kind
    }
}

public protocol DirectoryWatching: Sendable {
    func events(
        for sourceRootID: UUID,
        url: URL
    ) -> AsyncThrowingStream<DirectoryChange, Error>
}

public protocol SourceRescanning: Sendable {
    func rescan(source: SourceRootRecord) async
}

public protocol SourceWatchScheduling: Sendable {
    var changes: AsyncStream<DirectoryChange> { get }

    func start(source: SourceRootRecord, url: URL) async
    func isWatching(sourceID: UUID) async -> Bool
    func stop(sourceID: UUID) async
    func stopAll() async
}
