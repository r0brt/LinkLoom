import CryptoKit
import Foundation

public struct FileFingerprint: Sendable, Equatable {
    public let sha256: String
    public let byteCount: Int64
}

public protocol FileFingerprinting: Sendable {
    func fingerprint(_ url: URL) async throws -> FileFingerprint
}

public struct SHA256FileFingerprinter: FileFingerprinting {
    public init() {}

    public func fingerprint(_ url: URL) async throws -> FileFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteCount += Int64(chunk.count)
        }
        let digest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return FileFingerprint(sha256: digest, byteCount: byteCount)
    }
}
