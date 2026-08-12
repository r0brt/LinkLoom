import Foundation
import Testing
@testable import LinkLoomCore

@Suite("File fingerprints")
struct FileFingerprinterTests {
    @Test func fingerprintDependsOnContentNotPath() async throws {
        let directory = try TemporaryDirectory()
        let first = try directory.write("first.pdf", bytes: Data("same".utf8))
        let second = try directory.write("second.pdf", bytes: Data("same".utf8))
        let changed = try directory.write("changed.pdf", bytes: Data("changed".utf8))
        let fingerprinter = SHA256FileFingerprinter()

        let firstHash = try await fingerprinter.fingerprint(first).sha256
        let secondHash = try await fingerprinter.fingerprint(second).sha256
        let changedHash = try await fingerprinter.fingerprint(changed).sha256

        #expect(firstHash == "0967115f2813a3541eaef77de9d9d5773f1c0c04314b0bbfe4ff3b3b1c55b5d5")
        #expect(firstHash == secondHash)
        #expect(changedHash == "d67e2e944994496c8d8ec76eed0cf9f09679448d584b532bebf941852a37f5ed")
    }

    @Test func fingerprintReportsBytesRead() async throws {
        let directory = try TemporaryDirectory()
        let file = try directory.write("payload.pdf", bytes: Data("payload".utf8))

        let fingerprint = try await SHA256FileFingerprinter().fingerprint(file)

        #expect(fingerprint.byteCount == 7)
    }

    @Test func fingerprintReadsPastChunkBoundary() async throws {
        let directory = try TemporaryDirectory()
        let bytes = Data(repeating: 0x61, count: 1_048_577)
        let file = try directory.write("large.pdf", bytes: bytes)

        let fingerprint = try await SHA256FileFingerprinter().fingerprint(file)

        #expect(fingerprint.sha256 == "4a3f0c0c213adea174f9a3d4c13177315b588bdb2e9c1012d3d0bf0453ca0f6a")
        #expect(fingerprint.byteCount == 1_048_577)
    }
}
