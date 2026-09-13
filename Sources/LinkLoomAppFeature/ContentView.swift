import SwiftUI

public struct ContentView: View {
    @ObservedObject private var model: AppModel
    private let folderPicker: FolderPicker
    @State private var normalColumnVisibility: NavigationSplitViewVisibility = .all

    public init(model: AppModel, folderPicker: FolderPicker = FolderPicker()) {
        self.model = model
        self.folderPicker = folderPicker
    }

    public var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 980 && model.selectedDocumentID != nil {
                workspace(columnVisibility: .constant(.detailOnly))
            } else {
                workspace(columnVisibility: $normalColumnVisibility)
            }
        }
        .frame(minWidth: 900, idealWidth: 900, minHeight: 560)
    }

    private func workspace(columnVisibility: Binding<NavigationSplitViewVisibility>) -> some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            WorkspaceSidebar(model: model, folderPicker: folderPicker)
        } detail: {
            switch model.workspaceSelection {
            case .dossier:
                switch DossierWorkspaceViewKind(
                    selection: model.workspaceSelection,
                    detail: model.dossierDetailState,
                    personSummaries: model.personDossiers
                ) {
                case .costsAndPayments:
                    CostsAndPaymentsDossierView(model: model)
                case .personMatter:
                    PersonDossierView(model: model)
                }
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
    }
}
