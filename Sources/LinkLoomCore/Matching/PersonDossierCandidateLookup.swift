import Foundation

/// Resolves complete, current snapshots for one exact normalized person name.
public struct PersonDossierCandidateLookup: Sendable {
    private let repository: DocumentDNARepository
    private let target: DocumentDNAAnalysisTarget

    public init(repository: DocumentDNARepository, target: DocumentDNAAnalysisTarget) {
        self.repository = repository
        self.target = target
    }

    public func currentDocuments(
        matchingNormalizedName normalizedName: String
    ) async throws -> [CurrentDocumentDNA] {
        try await repository.currentSnapshotsMatchingPerson(normalizedName, target: target)
    }
}
