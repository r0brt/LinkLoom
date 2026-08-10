import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Vision OCR")
struct VisionOCRRecognizerTests {
    @Test func ordersRegionsUsingStableLineClusters() {
        let regions = [
            TextRegion(
                text: "A",
                confidence: 1,
                boundingBox: CGRect(x: 0.8, y: 0.89, width: 0.1, height: 0.02)
            ),
            TextRegion(
                text: "B",
                confidence: 1,
                boundingBox: CGRect(x: 0.1, y: 0.88, width: 0.1, height: 0.02)
            ),
            TextRegion(
                text: "C",
                confidence: 1,
                boundingBox: CGRect(x: 0.2, y: 0.86, width: 0.1, height: 0.02)
            ),
        ]

        let ordered = VisionOCRRecognizer.orderedRegions(regions)

        #expect(ordered.map(\.text) == ["B", "A", "C"])
    }

    @Test func recognizesHighContrastTextWithPageProvenance() async throws {
        let image = try makeTextImage("Rechnung Juli 2026 CHF 7840")

        let page = try await VisionOCRRecognizer().recognize(cgImage: image, pageIndex: 0)

        #expect(page.pageIndex == 0)
        #expect(page.text.contains("Rechnung"))
        #expect(page.text.contains("2026"))
        #expect(page.regions.contains { $0.confidence > 0 })
    }

    @Test func preCancelledRecognitionDoesNotStartVision() async throws {
        let image = try makeTextImage("must not be recognized")
        let gate = VisionStartGate()
        let recognition = Task {
            await gate.waitUntilReleased()
            return try await VisionOCRRecognizer().recognize(cgImage: image, pageIndex: 0)
        }
        await gate.waitUntilArrival()

        recognition.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            try await recognition.value
        }
    }

    @Test func cancellationStopsInFlightVisionWork() async throws {
        let work = BlockingVisionRecognitionWork()
        let recognizer = VisionOCRRecognizer { _ in work }
        let image = try makeTextImage("cancel in flight")
        let recognition = Task {
            try await recognizer.recognize(cgImage: image, pageIndex: 0)
        }
        await Task.detached {
            work.waitUntilStarted()
        }.value

        recognition.cancel()

        await #expect(throws: CancellationError.self) {
            try await recognition.value
        }
        #expect(work.wasCancelled)
    }

    @Test func runsBlockingVisionOutsideCooperativeTaskExecutor() async throws {
        let work = TaskContextVisionRecognitionWork()
        let recognizer = VisionOCRRecognizer { _ in work }
        let image = try makeTextImage("blocking executor")

        _ = try await recognizer.recognize(cgImage: image, pageIndex: 0)

        #expect(!work.ranInsideSwiftTask)
    }
}

private final class TaskContextVisionRecognitionWork: VisionRecognitionPerforming,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedRanInsideSwiftTask = false

    var ranInsideSwiftTask: Bool {
        lock.withLock { storedRanInsideSwiftTask }
    }

    func perform() throws -> [TextRegion] {
        let isInsideTask = withUnsafeCurrentTask { $0 != nil }
        lock.withLock {
            storedRanInsideSwiftTask = isInsideTask
        }
        return [TextRegion(
            text: "recognized",
            confidence: 1,
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1)
        )]
    }

    func cancel() {}
}

private final class BlockingVisionRecognitionWork: VisionRecognitionPerforming, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var cancelled = false

    var wasCancelled: Bool {
        condition.withLock { cancelled }
    }

    func perform() throws -> [TextRegion] {
        condition.lock()
        started = true
        condition.broadcast()
        while !cancelled {
            condition.wait()
        }
        condition.unlock()
        throw CancellationError()
    }

    func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    func waitUntilStarted() {
        condition.lock()
        while !started {
            condition.wait()
        }
        condition.unlock()
    }
}

private actor VisionStartGate {
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        arrived = true
        for waiter in arrivalWaiters {
            waiter.resume()
        }
        arrivalWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilArrival() async {
        if arrived { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func makeTextImage(_ text: String) throws -> CGImage {
    let width = 1_600
    let height = 300
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
            "Helvetica" as CFString,
            82,
            nil
        ),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
            gray: 0,
            alpha: 1
        ),
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes)
    )
    context.textPosition = CGPoint(x: 40, y: 105)
    CTLineDraw(line, context)
    guard let image = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }
    return image
}
