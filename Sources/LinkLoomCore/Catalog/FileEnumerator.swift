import Foundation

public struct FileCandidate: Sendable, Equatable {
    public let url: URL
    public let relativePath: String
    public let mediaType: SupportedMediaType
    public let byteCount: Int64
    public let modifiedAt: Date
}

public protocol FileEnumerating: Sendable {
    func files(in root: URL) throws -> [FileCandidate]
}

public struct DefaultFileEnumerator: FileEnumerating {
    private let resourceValuesOperation: @Sendable (
        URL,
        Set<URLResourceKey>
    ) throws -> URLResourceValues

    public init() {
        resourceValuesOperation = { url, keys in
            try url.resourceValues(forKeys: keys)
        }
    }

    init(
        resourceValues: @escaping @Sendable (
            URL,
            Set<URLResourceKey>
        ) throws -> URLResourceValues
    ) {
        resourceValuesOperation = resourceValues
    }

    public func files(in root: URL) throws -> [FileCandidate] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        let iterator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        )
        var files: [FileCandidate] = []
        while let url = iterator?.nextObject() as? URL {
            guard let values = try? resourceValuesOperation(url, keys) else {
                continue
            }
            guard values.isRegularFile == true,
                  let mediaType = SupportedMediaType.detect(url),
                  let relativePath = Self.relativePath(for: url, under: root)
            else {
                continue
            }
            files.append(FileCandidate(
                url: url,
                relativePath: relativePath,
                mediaType: mediaType,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        return files.sorted {
            $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }
    }

    static func relativePath(for file: URL, under root: URL) -> String? {
        let rootPath = root.resolvingSymlinksInPath().path
        let filePath = file.resolvingSymlinksInPath().path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard filePath.hasPrefix(prefix) else {
            return nil
        }
        let relativePath = String(filePath.dropFirst(prefix.count))
        return relativePath.isEmpty ? nil : relativePath
    }
}

public extension SupportedMediaType {
    static func detect(_ url: URL) -> SupportedMediaType? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return .pdf
        case "jpg", "jpeg":
            return .jpeg
        case "png":
            return .png
        case "heic":
            return .heic
        default:
            return nil
        }
    }
}
