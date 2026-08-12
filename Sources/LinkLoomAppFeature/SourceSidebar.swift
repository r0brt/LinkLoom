import SwiftUI

public struct SourceSidebar: View {
    @ObservedObject private var model: AppModel
    private let folderPicker: FolderPicker

    public init(model: AppModel, folderPicker: FolderPicker) {
        self.model = model
        self.folderPicker = folderPicker
    }

    public var body: some View {
        List(selection: selection) {
            ForEach(model.sources) { source in
                Label(
                    source.displayName,
                    systemImage: model.unavailableSourceIDs.contains(source.id)
                        ? "externaldrive.badge.exclamationmark"
                        : "folder"
                )
                    .tag(source.id)
                    .contextMenu {
                        Button("Quelle entfernen", role: .destructive) {
                            Task { await model.removeSource(source) }
                        }
                        .disabled(model.scanState != .idle)
                    }
            }
        }
        .navigationTitle("Quellen")
        .safeAreaInset(edge: .bottom) {
            Button {
                let urls = folderPicker.selectFolders()
                Task {
                    for url in urls {
                        await model.addSource(url)
                    }
                }
            } label: {
                Label("Ordner hinzufügen", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.scanState != .idle)
            .padding()
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedSourceID },
            set: { id in Task { await model.selectSource(id: id) } }
        )
    }
}
