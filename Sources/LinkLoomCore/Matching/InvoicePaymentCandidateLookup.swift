import Foundation

/// Resolves the current invoice/payment candidates involving one selected document.
public struct InvoicePaymentCandidateLookup: Sendable {
    private let repository: DocumentDNARepository
    private let target: DocumentDNAAnalysisTarget
    private let projector: InvoicePaymentCandidateProjector

    public init(
        repository: DocumentDNARepository,
        target: DocumentDNAAnalysisTarget,
        resolver: InvoicePaymentCandidateResolver = InvoicePaymentCandidateResolver()
    ) {
        self.repository = repository
        self.target = target
        projector = InvoicePaymentCandidateProjector(resolver: resolver)
    }

    public func candidates(involving documentID: UUID) async throws
        -> [InvoicePaymentCandidate]
    {
        guard let selected = try await repository.currentDocumentSnapshot(
            documentID: documentID,
            target: target
        ) else {
            return []
        }

        var matchesByNormalizedReference: [String: [CurrentDocumentDNA]] = [:]
        for reference in projector.normalizedReferences(in: selected) {
            matchesByNormalizedReference[reference] = try await repository
                .currentSnapshotsMatchingReference(reference, target: target)
        }
        return projector.candidates(from: InvoicePaymentCandidateProjectionInput(
            selected: selected,
            matchesByNormalizedReference: matchesByNormalizedReference
        ))
    }
}
