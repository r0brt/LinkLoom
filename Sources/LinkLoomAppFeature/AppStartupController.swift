import Combine

public enum AppStartupPhase: Sendable, Equatable {
    case idle
    case starting
    case ready
    case failed(AppStartupFailure)
}

public enum AppStartupFailure: String, Sendable, Equatable {
    case localCatalogUnavailable
}

@MainActor
public final class AppStartupController: ObservableObject {
    @Published public private(set) var phase: AppStartupPhase = .idle
    public private(set) var model: AppModel?

    private let start: @MainActor () async throws -> AppModel
    private let reportFailure: @MainActor (Error) -> Void

    public init(
        start: @escaping @MainActor () async throws -> AppModel,
        reportFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.start = start
        self.reportFailure = reportFailure
    }

    public func startIfNeeded() async {
        guard phase == .idle else { return }
        await attemptStart()
    }

    public func retry() async {
        guard case .failed = phase else { return }
        await attemptStart()
    }

    private func attemptStart() async {
        phase = .starting
        do {
            model = try await start()
            phase = .ready
        } catch {
            model = nil
            phase = .failed(.localCatalogUnavailable)
            reportFailure(error)
        }
    }
}
