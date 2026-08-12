import SwiftUI

public struct ContentView: View {
    @ObservedObject private var model: AppModel
    private let folderPicker: FolderPicker

    public init(model: AppModel, folderPicker: FolderPicker = FolderPicker()) {
        self.model = model
        self.folderPicker = folderPicker
    }

    public var body: some View {
        NavigationSplitView {
            SourceSidebar(model: model, folderPicker: folderPicker)
        } detail: {
            ScanDashboard(model: model)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
