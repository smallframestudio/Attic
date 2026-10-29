import AtticCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.sidebarSelection) {
            if model.archives.count > 1 {
                Label("All Archives", systemImage: "tray.2")
                    .tag(SidebarItem.allArchives)
            }
            ForEach(model.archives) { archive in
                Section {
                    Label("All Messages", systemImage: "tray.full")
                        .badge(archive.messageCount)
                        .tag(SidebarItem.archive(archive.id))
                        .contextMenu { removeButton(archive) }

                    OutlineGroup(model.folderTrees[archive.id] ?? [], children: \.children) { node in
                        Label(node.name, systemImage: FolderNode.icon(for: node.name))
                            .badge(node.messageCount)
                            .tag(SidebarItem.folder(archive: archive.id, folder: node.id))
                            .help("\(node.totalCount) messages including subfolders")
                    }
                } header: {
                    Text(archive.name)
                        .contextMenu { removeButton(archive) }
                        .help(archive.sourcePath)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.showFileImporter = true
            } label: {
                Label("Import Archive…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func removeButton(_ archive: ArchiveInfo) -> some View {
        Button("Remove Archive…", role: .destructive) {
            model.archivePendingRemoval = archive
        }
    }
}
