import LinkLoomCore

public enum AppRuntimeFailureCategory: String, Sendable, Equatable {
    case reload
    case sourceAdd
    case scan
    case ingestion
    case refresh
    case sourceRemove
    case documentLoad
    case documentDNADetailLoad
    case documentDNARetry
    case watcherStart
    case incrementalRefresh
}

public enum AppRuntimeFailureReason: String, Sendable, Equatable {
    case cancelled
    case sourceAccess
    case pendingQuery
    case persistence
    case staleDocument
    case unexpected
}

public struct AppRuntimeDiagnostic: Sendable, Equatable {
    public let category: AppRuntimeFailureCategory
    public let reason: AppRuntimeFailureReason

    init(category: AppRuntimeFailureCategory, error: any Error) {
        self.category = category
        reason = Self.reason(for: error)
    }

    private static func reason(for error: any Error) -> AppRuntimeFailureReason {
        if error is CancellationError {
            return .cancelled
        }
        if let dnaError = error as? DocumentDNAAnalysisRunError {
            switch dnaError.reason {
            case .cancelled:
                return .cancelled
            case .pendingQuery:
                return .pendingQuery
            case .persistence:
                return .persistence
            case .staleInput:
                return .staleDocument
            }
        }
        guard let ingestionError = error as? IngestionRunError else {
            return .unexpected
        }
        switch ingestionError.reason {
        case .cancelled:
            return .cancelled
        case .sourceAccess:
            return .sourceAccess
        case .pendingQuery:
            return .pendingQuery
        case .persistence:
            return .persistence
        case .staleDocument:
            return .staleDocument
        }
    }
}
