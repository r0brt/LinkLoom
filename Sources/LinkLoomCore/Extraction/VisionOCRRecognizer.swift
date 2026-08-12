import CoreGraphics
import Foundation
import Vision

public protocol ImageOCRRecognizing: Sendable {
    func recognize(cgImage: CGImage, pageIndex: Int) async throws -> ExtractedPage
}

protocol VisionRecognitionPerforming: Sendable {
    func perform() throws -> [TextRegion]
    func cancel()
}

public struct VisionOCRRecognizer: ImageOCRRecognizing {
    private let makeWork: @Sendable (CGImage) -> any VisionRecognitionPerforming

    public init() {
        makeWork = { VisionRecognitionWork(cgImage: $0) }
    }

    init(_ makeWork: @escaping @Sendable (CGImage) -> any VisionRecognitionPerforming) {
        self.makeWork = makeWork
    }

    public func recognize(
        cgImage: CGImage,
        pageIndex: Int
    ) async throws -> ExtractedPage {
        try Task.checkCancellation()
        let work = makeWork(cgImage)
        let regions: [TextRegion]
        do {
            regions = try await withTaskCancellationHandler {
                try await VisionRecognitionExecutor.perform(work)
            } onCancel: {
                work.cancel()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        guard !regions.isEmpty else {
            throw TextExtractionError.noRecognizedText
        }
        let ordered = Self.orderedRegions(regions)
        return ExtractedPage(
            pageIndex: pageIndex,
            text: ordered.map(\.text).joined(separator: "\n"),
            regions: ordered
        )
    }

    static func orderedRegions(_ regions: [TextRegion]) -> [TextRegion] {
        let topToBottom = regions.enumerated().sorted { lhs, rhs in
            let lhsMidY = lhs.element.boundingBox.midY
            let rhsMidY = rhs.element.boundingBox.midY
            if lhsMidY != rhsMidY {
                return lhsMidY > rhsMidY
            }
            let lhsMinX = lhs.element.boundingBox.minX
            let rhsMinX = rhs.element.boundingBox.minX
            if lhsMinX != rhsMinX {
                return lhsMinX < rhsMinX
            }
            return lhs.offset < rhs.offset
        }

        var lines: [[(offset: Int, element: TextRegion)]] = []
        var lineAnchor: CGFloat?
        for region in topToBottom {
            if let lineAnchor, abs(region.element.boundingBox.midY - lineAnchor) <= 0.02 {
                lines[lines.count - 1].append(region)
            } else {
                lines.append([region])
                lineAnchor = region.element.boundingBox.midY
            }
        }

        return lines.flatMap { line in
            line.sorted { lhs, rhs in
                let lhsMinX = lhs.element.boundingBox.minX
                let rhsMinX = rhs.element.boundingBox.minX
                if lhsMinX != rhsMinX {
                    return lhsMinX < rhsMinX
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }
}

private enum VisionRecognitionExecutor {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "LinkLoom.VisionRecognition"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func perform(
        _ work: any VisionRecognitionPerforming
    ) async throws -> [TextRegion] {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do {
                    continuation.resume(returning: try work.perform())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class VisionRecognitionWork: VisionRecognitionPerforming, @unchecked Sendable {
    private let request: VNRecognizeTextRequest
    private let handler: VNImageRequestHandler

    init(cgImage: CGImage) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "fr-FR", "en-US"]
        self.request = request
        handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    }

    func perform() throws -> [TextRegion] {
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation -> TextRegion? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            return TextRegion(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox
            )
        }
    }

    func cancel() {
        request.cancel()
    }
}
