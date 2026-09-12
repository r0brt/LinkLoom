import SwiftUI

public struct WorkspaceSidebar: View {
    @ObservedObject private var model: AppModel
    private let folderPicker: FolderPicker

    public init(model: AppModel, folderPicker: FolderPicker) {
        self.model = model
        self.folderPicker = folderPicker
    }

    public var body: some View {
        List(selection: selection) {
            Section {
                ForEach(WorkspaceDossierSidebarItem.items(
                    costs: model.dossiers,
                    people: model.personDossiers
                )) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(item.dossier.displayName, systemImage: "folder")
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(AppWorkspaceSelection.dossier(item.id))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.dossier.displayName). \(item.subtitle)")
                    .accessibilityIdentifier(
                        DossierAccessibilityIdentifier.row(item.id)
                    )
                }
            } header: {
                Text("Dossiers")
                    .accessibilityIdentifier("dossier.sidebar")
            }

            Section("Quellen") {
                ForEach(model.sources) { source in
                    Label(
                        source.displayName,
                        systemImage: model.unavailableSourceIDs.contains(source.id)
                            ? "externaldrive.badge.exclamationmark"
                            : "folder"
                    )
                    .tag(AppWorkspaceSelection.source(source.id))
                    .accessibilityIdentifier("source.row.\(source.id.uuidString)")
                    .contextMenu {
                        Button("Quelle entfernen", role: .destructive) {
                            Task { await model.removeSource(source) }
                        }
                        .disabled(model.scanState != .idle)
                    }
                }
            }
        }
        .navigationTitle("LinkLoom")
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
            .accessibilityIdentifier("source.add")
            .padding()
        }
    }

    private var selection: Binding<AppWorkspaceSelection?> {
        Binding(
            get: { model.workspaceSelection },
            set: { workspace in
                Task {
                    switch workspace {
                    case .source(let sourceID):
                        await model.selectSource(id: sourceID)
                    case .dossier(let dossierID):
                        await model.selectDossier(id: dossierID)
                    case nil:
                        await model.selectSource(id: nil)
                    }
                }
            }
        )
    }
}
