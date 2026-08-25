import Foundation

public protocol DocumentDNAAnalyzing: Sendable {
    func analyze(
        documentID: UUID,
        contentHash: String,
        extraction: StoredExtraction,
        analyzedAt: Date
    ) throws -> DocumentDNA
}
