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

    private let makeModel: @MainActor () throws -> AppModel
    private let prepareModel: @MainActor (AppModel) async throws -> Void
    private let reportFailure: @MainActor (Error) -> Void

    public init(
        makeModel: @escaping @MainActor () throws -> AppModel,
        prepareModel: @escaping @MainActor (AppModel) async throws -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.makeModel = makeModel
        self.prepareModel = prepareModel
        self.reportFailure = reportFailure
    }

    public func startIfNeeded(
        registerModel: @MainActor (AppModel) -> Void = { _ in }
    ) async {
        guard phase == .idle else { return }
        await attemptStart(registerModel: registerModel)
    }

    public func retry(
        registerModel: @MainActor (AppModel) -> Void = { _ in }
    ) async {
        guard case .failed = phase else { return }
        await attemptStart(registerModel: registerModel)
    }

    private func attemptStart(
        registerModel: @MainActor (AppModel) -> Void
    ) async {
        phase = .starting
        do {
            let model = try makeModel()
            self.model = model
            registerModel(model)
            try await prepareModel(model)
            phase = .ready
        } catch {
            model = nil
            phase = .failed(.localCatalogUnavailable)
            reportFailure(error)
        }
    }
}
