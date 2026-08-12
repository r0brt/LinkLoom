import Foundation
import Testing
@testable import LinkLoomCore

@Suite("File enumeration")
struct FileEnumeratorTests {
    @Test func returnsOnlyVisibleSupportedFilesInRelativePathOrder() throws {
        let directory = try TemporaryDirectory()
        try directory.write("a.pdf", bytes: Data("pdf".utf8))
        try directory.write("b.JPG", bytes: Data("jpeg".utf8))
        try directory.write("c.png", bytes: Data("png".utf8))
        try directory.write("d.heic", bytes: Data("heic".utf8))
        try directory.write("e.JPEG", bytes: Data("jpeg alias".utf8))
        try directory.write(".hidden.pdf", bytes: Data("hidden".utf8))
        try directory.write(".hidden/inside.pdf", bytes: Data("hidden descendant".utf8))
        try directory.write("notes.txt", bytes: Data("unsupported".utf8))
        try directory.write("Ignored.app/inside.pdf", bytes: Data("package descendant".utf8))

        let files = try DefaultFileEnumerator().files(in: directory.url)

        #expect(files.map(\.relativePath) == ["a.pdf", "b.JPG", "c.png", "d.heic", "e.JPEG"])
        #expect(files.map(\.mediaType) == [.pdf, .jpeg, .png, .heic, .jpeg])
    }

    @Test func throwsWhenSupportedFileMetadataBecomesUnavailable() throws {
        let directory = try TemporaryDirectory()
        try directory.write("unavailable.pdf", bytes: Data("pdf".utf8))
        let enumerator = DefaultFileEnumerator { url, keys in
            if url.lastPathComponent == "unavailable.pdf" {
                throw MetadataProbeError()
            }
            return try url.resourceValues(forKeys: keys)
        }

        #expect(throws: MetadataProbeError.self) {
            try enumerator.files(in: directory.url)
        }
    }

    @Test func throwsWhenSupportedFileRegularityMetadataIsMissing() throws {
        let directory = try TemporaryDirectory()
        try directory.write("incomplete.pdf", bytes: Data("pdf".utf8))
        let enumerator = DefaultFileEnumerator { url, _ in
            try url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
            ])
        }

        #expect(throws: FileEnumerationError.self) {
            try enumerator.files(in: directory.url)
        }
    }

    @Test func throwsWhenSupportedFileSizeMetadataIsMissing() throws {
        let directory = try TemporaryDirectory()
        try directory.write("incomplete.pdf", bytes: Data("pdf".utf8))
        let enumerator = DefaultFileEnumerator { url, _ in
            try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
            ])
        }

        #expect(throws: FileEnumerationError.self) {
            try enumerator.files(in: directory.url)
        }
    }

    @Test func throwsWhenSupportedFileModificationDateMetadataIsMissing() throws {
        let directory = try TemporaryDirectory()
        try directory.write("incomplete.pdf", bytes: Data("pdf".utf8))
        let enumerator = DefaultFileEnumerator { url, _ in
            try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
            ])
        }

        #expect(throws: FileEnumerationError.self) {
            try enumerator.files(in: directory.url)
        }
    }

    @Test func unsupportedFileDoesNotRequireMetadata() throws {
        let directory = try TemporaryDirectory()
        try directory.write("notes.txt", bytes: Data("ignored".utf8))
        let enumerator = DefaultFileEnumerator { _, _ in
            throw MetadataProbeError()
        }

        #expect(try enumerator.files(in: directory.url).isEmpty)
    }

    @Test func ignoresSupportedExtensionEntryKnownNotToBeARegularFile() throws {
        let directory = try TemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory.url.appendingPathComponent("folder.pdf"),
            withIntermediateDirectories: false
        )

        #expect(try DefaultFileEnumerator().files(in: directory.url).isEmpty)
    }

    @Test func throwsWhenRootCannotBeEnumerated() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        #expect(throws: FileEnumerationError.self) {
            try DefaultFileEnumerator().files(in: missingRoot)
        }
    }

    @Test func throwsWhenTraversalReportsSubtreeError() throws {
        let directory = try TemporaryDirectory()
        let error = MetadataProbeError()
        let enumerator = DefaultFileEnumerator(
            resourceValues: { url, keys in try url.resourceValues(forKeys: keys) },
            directoryEnumerator: { root, keys, options, errorHandler in
                _ = errorHandler(root.appendingPathComponent("offline"), error)
                return FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: options
                )
            }
        )

        #expect(throws: FileEnumerationError.self) {
            try enumerator.files(in: directory.url)
        }
    }

    @Test func sortsPathsByLocaleIndependentUTF8Order() throws {
        let directory = try TemporaryDirectory()
        try directory.write("file2.pdf", bytes: Data("two".utf8))
        try directory.write("file10.pdf", bytes: Data("ten".utf8))

        let files = try DefaultFileEnumerator().files(in: directory.url)

        #expect(files.map(\.relativePath) == ["file10.pdf", "file2.pdf"])
    }

    @Test func relativePathRejectsSymlinkOutsideRoot() throws {
        let root = try TemporaryDirectory()
        let external = try TemporaryDirectory()
        let target = try external.write("outside.pdf", bytes: Data("outside".utf8))
        let link = root.url.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let relativePath = DefaultFileEnumerator.relativePath(for: link, under: root.url)

        #expect(relativePath == nil)
    }

    @Test func relativePathRejectsSiblingWithCommonPrefix() {
        let root = URL(fileURLWithPath: "/tmp/source")
        let siblingFile = URL(fileURLWithPath: "/tmp/source-other/file.pdf")

        let relativePath = DefaultFileEnumerator.relativePath(for: siblingFile, under: root)

        #expect(relativePath == nil)
    }

    @Test func relativePathSupportsFilesystemRoot() {
        let root = URL(fileURLWithPath: "/")
        let file = URL(fileURLWithPath: "/tmp/file.pdf")

        let relativePath = DefaultFileEnumerator.relativePath(for: file, under: root)

        #expect(relativePath == "tmp/file.pdf")
    }
}

private struct MetadataProbeError: Error {}
