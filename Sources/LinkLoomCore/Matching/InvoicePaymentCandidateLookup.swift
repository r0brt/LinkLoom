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
        guard let snapshot = try await repository.currentSnapshot(
            documentID: documentID,
            target: target
        ) else {
            return []
        }

        let bootstrapReferences = Set(snapshot.findings.compactMap { finding in
            finding.kind == .referenceNumber ? finding.normalizedValue : nil
        }).sorted()
        var selected: CurrentDocumentDNA?
        for reference in bootstrapReferences {
            let matches = try await repository.currentSnapshotsMatchingReference(
                reference,
                target: target
            )
            if let match = matches.first(where: { $0.document.id == documentID }) {
                selected = match
                break
            }
        }
        guard let selected else { return [] }

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
