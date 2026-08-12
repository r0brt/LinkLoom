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

enum FileEnumerationError: Error {
    case rootUnavailable
    case incompleteTraversal(URL, any Error)
}

public struct DefaultFileEnumerator: FileEnumerating {
    private let resourceValuesOperation: @Sendable (
        URL,
        Set<URLResourceKey>
    ) throws -> URLResourceValues
    private let directoryEnumeratorOperation: @Sendable (
        URL,
        [URLResourceKey],
        FileManager.DirectoryEnumerationOptions,
        @escaping (URL, any Error) -> Bool
    ) -> FileManager.DirectoryEnumerator?

    public init() {
        resourceValuesOperation = { url, keys in
            try url.resourceValues(forKeys: keys)
        }
        directoryEnumeratorOperation = { root, keys, options, errorHandler in
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: errorHandler
            )
        }
    }

    init(
        resourceValues: @escaping @Sendable (
            URL,
            Set<URLResourceKey>
        ) throws -> URLResourceValues
    ) {
        resourceValuesOperation = resourceValues
        directoryEnumeratorOperation = { root, keys, options, errorHandler in
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: errorHandler
            )
        }
    }

    init(
        resourceValues: @escaping @Sendable (
            URL,
            Set<URLResourceKey>
        ) throws -> URLResourceValues,
        directoryEnumerator: @escaping @Sendable (
            URL,
            [URLResourceKey],
            FileManager.DirectoryEnumerationOptions,
            @escaping (URL, any Error) -> Bool
        ) -> FileManager.DirectoryEnumerator?
    ) {
        resourceValuesOperation = resourceValues
        directoryEnumeratorOperation = directoryEnumerator
    }

    public func files(in root: URL) throws -> [FileCandidate] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        var traversalError: (URL, any Error)?
        let iterator = directoryEnumeratorOperation(
            root,
            Array(keys),
            [.skipsHiddenFiles, .skipsPackageDescendants],
            { url, error in
                if traversalError == nil {
                    traversalError = (url, error)
                }
                return false
            }
        )
        guard let iterator else {
            throw FileEnumerationError.rootUnavailable
        }
        var files: [FileCandidate] = []
        while let url = iterator.nextObject() as? URL {
            guard let mediaType = SupportedMediaType.detect(url) else {
                continue
            }
            let values = try resourceValuesOperation(url, keys)
            guard values.isRegularFile == true,
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
        if let traversalError {
            throw FileEnumerationError.incompleteTraversal(
                traversalError.0,
                traversalError.1
            )
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
