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
            WorkspaceSidebar(model: model, folderPicker: folderPicker)
        } detail: {
            switch model.workspaceSelection {
            case .dossier:
                CostsAndPaymentsDossierView(model: model)
            case .source, nil:
                ScanDashboard(model: model)
            }
        }
        .inspector(isPresented: Binding(
            get: { model.selectedDocumentID != nil },
            set: { shown in
                guard !shown else { return }
                Task { await model.selectDocument(id: nil) }
            }
        )) {
            DocumentDNAInspector(
                model: model,
                document: model.documents.first { $0.id == model.selectedDocumentID }
            )
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
