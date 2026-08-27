import Foundation

public enum DocumentDNAAnalysisPhase: Sendable, Equatable {
    case pending
    case analyzing
    case ready
    case failed(DocumentDNAAnalysisFailureCode)
}

public struct DocumentDNAAnalysisStatus: Sendable, Equatable {
    public let documentID: UUID
    public let phase: DocumentDNAAnalysisPhase

    public init(documentID: UUID, phase: DocumentDNAAnalysisPhase) {
        self.documentID = documentID
        self.phase = phase
    }
}
