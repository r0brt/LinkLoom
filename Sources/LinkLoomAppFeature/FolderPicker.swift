import AppKit
import Foundation

@MainActor
public struct FolderPicker {
    public init() {}

    public func selectFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canDownloadUbiquitousContents = false
        return panel.runModal() == .OK ? panel.urls : []
    }
}
