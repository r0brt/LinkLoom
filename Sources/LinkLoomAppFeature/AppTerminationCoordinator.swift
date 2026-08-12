import Foundation

@MainActor
public final class AppTerminationCoordinator {
    public enum Decision: Sendable, Equatable {
        case terminateLater
    }

    private let stopWatching: @MainActor @Sendable () async -> Void
    private var terminationTask: Task<Void, Never>?

    public init(
        stopWatching: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.stopWatching = stopWatching
    }

    public func requestTermination(
        reply: @escaping @MainActor @Sendable (Bool) async -> Void
    ) -> Decision {
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { [stopWatching] in
            await stopWatching()
            await reply(true)
        }
        return .terminateLater
    }
}
