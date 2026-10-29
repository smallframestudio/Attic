import AppKit
import AtticCore
import SwiftUI

@main
struct AtticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // A plain constant rather than @State: the Command Line Tools lack the plugin that
    // @State needs in newer SDKs, and the model lives as long as the app anyway.
    private let model = AppModel.shared

    var body: some Scene {
        Window("Attic", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        // No title bar or toolbar: the folder name and search sit in the message list's own header,
        // and importing is in the sidebar. (The window buttons float over the sidebar.)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Import Outlook Archive…") { model.showFileImporter = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .textEditing) {
                Button("Search Mail") { model.searchFocusRequest += 1 }
                    .keyboardShortcut("f")
                Button("Advanced Search…") { model.openAdvancedSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Search Help") { model.showSearchHelp = true }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched straight from `swift run` rather than as a bundled .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 360)
        } content: {
            MessageListView()
                .navigationSplitViewColumnWidth(min: 340, ideal: 470)
        } detail: {
            if let id = model.selectedMessageID {
                MessageDetailView(messageID: id)
            } else {
                ContentUnavailableView("No Message Selected", systemImage: "envelope")
            }
        }
        .onChange(of: model.searchText) { model.runSearch() }
        .onChange(of: model.sortOrder) { model.runSearch(debounce: false) }
        // Hidden from the start (not merely empty), so it can't collapse and shift the layout.
        .toolbar(.hidden, for: .windowToolbar)
        .onChange(of: model.sidebarSelection) {
            model.selectedMessageID = nil
            model.runSearch(debounce: false)
        }
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.pst, .ost, .data]) { result in
            if case .success(let url) = result { model.requestImport(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { ["pst", "ost"].contains($0.pathExtension.lowercased()) }) else { return false }
            model.requestImport(url)
            return true
        }
        .sheet(item: Binding(get: { model.activeSheet }, set: { if $0 == nil { model.dismissSheet() } })) { sheet in
            switch sheet {
            case .importProgress:
                ImportProgressView()
                    .environment(model)
                    .interactiveDismissDisabled()
            case .readpstHelp:
                ReadpstHelpView()
                    .environment(model)
            case .searchHelp:
                SearchHelpView()
            }
        }
        .confirmationDialog(
            "Remove “\(model.archivePendingRemoval?.name ?? "")” from the library?",
            isPresented: Binding(get: { model.archivePendingRemoval != nil },
                                 set: { if !$0 { model.archivePendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let archive = model.archivePendingRemoval { model.removeArchive(archive) }
                model.archivePendingRemoval = nil
            }
        } message: {
            Text("This deletes the app's index and extracted copy. Your original .pst or .ost file is not touched.")
        }
    }
}
