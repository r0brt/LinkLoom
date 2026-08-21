import AppKit
import Foundation

@MainActor
public struct FolderPicker {
    private let selection: @MainActor () -> [URL]

    public init() {
        selection = {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.canDownloadUbiquitousContents = false
            return panel.runModal() == .OK ? panel.urls : []
        }
    }

    public init(
        selectFolders: @escaping @MainActor () -> [URL]
    ) {
        selection = selectFolders
    }

    public func selectFolders() -> [URL] {
        selection()
    }
}
