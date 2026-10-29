import AppKit
import Observation
import AtticCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pst = UTType(filenameExtension: "pst") ?? .data
    static let ost = UTType(filenameExtension: "ost") ?? .data
}

enum SidebarItem: Hashable {
    case allArchives
    case archive(Int64)
    case folder(archive: Int64, folder: Int64)
}

struct FolderNode: Identifiable, Hashable {
    let id: Int64
    let archiveID: Int64
    let name: String
    let messageCount: Int
    let totalCount: Int
    var children: [FolderNode]?

    var subtreeIDs: [Int64] {
        [id] + (children ?? []).flatMap(\.subtreeIDs)
    }

    func find(_ folderID: Int64) -> FolderNode? {
        if id == folderID { return self }
        for child in children ?? [] {
            if let found = child.find(folderID) { return found }
        }
        return nil
    }

    static func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("inbox") { return "tray" }
        if n.contains("sent") { return "paperplane" }
        if n.contains("draft") { return "doc" }
        if n.contains("deleted") || n.contains("trash") { return "trash" }
        if n.contains("junk") || n.contains("spam") { return "xmark.bin" }
        if n.contains("outbox") { return "tray.and.arrow.up" }
        if n.contains("archive") { return "archivebox" }
        return "folder"
    }

    static func rank(_ name: String) -> Int {
        let n = name.lowercased()
        if n.contains("inbox") { return 0 }
        if n.contains("sent") { return 1 }
        if n.contains("draft") { return 2 }
        if n.contains("archive") { return 3 }
        if n.contains("deleted") || n.contains("trash") { return 5 }
        if n.contains("junk") || n.contains("spam") { return 6 }
        return 4
    }
}

enum ActiveSheet: String, Identifiable {
    case importProgress, readpstHelp, searchHelp
    var id: String { rawValue }
}

struct SearchScope: Identifiable {
    let item: SidebarItem
    let title: String
    var id: SidebarItem { item }
}

struct ImportStatus {
    var fileName: String
    var phase: ImportPhase = .starting
    var errorMessage: String?
}

struct LoadedMessage {
    let id: Int64
    let fileURL: URL
    let message: ParsedMessage
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var library: Library?
    var startupError: String?

    var archives: [ArchiveInfo] = []
    var folderTrees: [Int64: [FolderNode]] = [:]
    var sidebarSelection: SidebarItem? = .allArchives

    var searchText = ""
    /// Bumped to move keyboard focus to the search box (⌘F).
    var searchFocusRequest = 0
    var showAdvancedSearch = false
    var showDatePicker = false
    /// The advanced-search popover's fields, filled from the search box when it opens.
    var searchForm = SearchForm()
    var searchFormScope: SidebarItem = .allArchives
    var sortOrder: MessageSortOrder = .newest
    var results: [MessageRow] = []
    var totalResults = 0
    var searchError: String?
    var hasSearched = false
    var selectedMessageID: Int64?

    // Message pane state (kept here rather than in @State; see App.swift).
    var loadedMessage: LoadedMessage?
    var messageLoadFailed = false
    var showPlainText = false
    var allowRemoteContent = false

    var importStatus: ImportStatus?
    var readpstStillMissing = false
    var showFileImporter = false
    var showReadpstHelp = false
    var showSearchHelp = false
    var pendingImportURL: URL?
    var archivePendingRemoval: ArchiveInfo?

    /// Only one sheet can show at a time; import progress wins.
    var activeSheet: ActiveSheet? {
        if importStatus != nil { return .importProgress }
        if showReadpstHelp { return .readpstHelp }
        if showSearchHelp { return .searchHelp }
        return nil
    }

    func dismissSheet() {
        showReadpstHelp = false
        showSearchHelp = false
    }

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?

    init() {
        do {
            library = try Library()
        } catch {
            startupError = error.localizedDescription
        }
        Task { await self.initialLoad() }
    }

    private func initialLoad() async {
        try? await library?.removeIncompleteArchives()
        await reloadArchives()
        runSearch(debounce: false)
    }

    // MARK: Archives

    func reloadArchives() async {
        guard let library else { return }
        do {
            let loaded = try await library.archives()
            var trees: [Int64: [FolderNode]] = [:]
            for archive in loaded {
                trees[archive.id] = Self.buildTree(try await library.folders(archiveID: archive.id))
            }
            archives = loaded
            folderTrees = trees
        } catch {
            searchError = error.localizedDescription
        }

        // Keep the selection valid.
        switch sidebarSelection {
        case .archive(let id)?, .folder(let id, _)?:
            if !archives.contains(where: { $0.id == id }) { sidebarSelection = .allArchives }
        default:
            break
        }
        if archives.count == 1, sidebarSelection == .allArchives || sidebarSelection == nil {
            sidebarSelection = .archive(archives[0].id)
        }
    }

    static func buildTree(_ records: [FolderRecord]) -> [FolderNode] {
        let byParent = Dictionary(grouping: records, by: { $0.parentID ?? -1 })

        func build(_ parentID: Int64) -> [FolderNode] {
            let nodes: [FolderNode] = (byParent[parentID] ?? []).compactMap { record in
                let children = build(record.id)
                let total = record.messageCount + children.reduce(0) { $0 + $1.totalCount }
                guard total > 0 else { return nil }
                return FolderNode(id: record.id, archiveID: record.archiveID, name: record.name,
                                  messageCount: record.messageCount, totalCount: total,
                                  children: children.isEmpty ? nil : children)
            }
            return nodes.sorted {
                let (a, b) = (FolderNode.rank($0.name), FolderNode.rank($1.name))
                return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }

        var roots = build(-1)
        // readpst puts everything under one top folder ("Personal Folders", "Top of Outlook data file"…);
        // skip it so the real folders show at the top level.
        while roots.count == 1, roots[0].messageCount == 0, let children = roots[0].children {
            roots = children
        }
        return roots
    }

    func removeArchive(_ archive: ArchiveInfo) {
        guard let library else { return }
        Task {
            try? await library.deleteArchive(id: archive.id)
            await reloadArchives()
            runSearch(debounce: false)
        }
    }

    // MARK: Search

    var scopeTitle: String {
        switch sidebarSelection {
        case .archive(let id)?:
            return archives.first { $0.id == id }?.name ?? "Messages"
        case .folder(let archiveID, let folderID)?:
            for root in folderTrees[archiveID] ?? [] {
                if let node = root.find(folderID) { return node.name }
            }
            return "Messages"
        default:
            return "All Archives"
        }
    }

    private func currentRequest() -> SearchRequest {
        var request = SearchRequest(text: searchText, sort: sortOrder)
        switch sidebarSelection {
        case .archive(let id)?:
            request.archiveID = id
        case .folder(let archiveID, let folderID)?:
            request.archiveID = archiveID
            var ids = [folderID]
            for root in folderTrees[archiveID] ?? [] {
                if let node = root.find(folderID) { ids = node.subtreeIDs; break }
            }
            request.folderIDs = ids
        default:
            break
        }
        return request
    }

    // MARK: Advanced search

    func openAdvancedSearch() {
        searchForm = SearchForm(parsing: searchText)
        searchFormScope = sidebarSelection ?? .allArchives
        showAdvancedSearch = true
    }

    func applySearchForm() {
        showAdvancedSearch = false
        if sidebarSelection != searchFormScope { sidebarSelection = searchFormScope }
        searchText = searchForm.queryString
        runSearch(debounce: false)
    }

    func clearSearchForm() {
        searchForm = SearchForm()
    }

    /// Where a search can look: everything, a whole archive, or one folder (and its subfolders).
    var searchScopes: [SearchScope] {
        var scopes: [SearchScope] = []
        if archives.count != 1 { scopes.append(SearchScope(item: .allArchives, title: "All Archives")) }
        for archive in archives {
            scopes.append(SearchScope(item: .archive(archive.id),
                                      title: archives.count == 1 ? "All Mail" : "\(archive.name) — All Mail"))
            func add(_ nodes: [FolderNode], depth: Int) {
                for node in nodes {
                    let indent = String(repeating: "    ", count: depth + 1)
                    scopes.append(SearchScope(item: .folder(archive: archive.id, folder: node.id), title: indent + node.name))
                    add(node.children ?? [], depth: depth + 1)
                }
            }
            add(folderTrees[archive.id] ?? [], depth: 0)
        }
        return scopes
    }

    func runSearch(debounce: Bool = true) {
        guard let library else { return }
        searchTask?.cancel()
        let request = currentRequest()
        searchTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
            }
            let result = await library.search(request)
            if Task.isCancelled { return }
            results = result.rows
            totalResults = result.total
            searchError = result.errorMessage
            hasSearched = true
            if let selected = selectedMessageID, !result.rows.contains(where: { $0.id == selected }) {
                selectedMessageID = nil
            }
        }
    }

    // MARK: Messages

    func loadMessage(_ id: Int64) async -> LoadedMessage? {
        guard let library, let url = try? await library.fileURL(forMessage: id) else { return nil }
        let parsed = await Task.detached(priority: .userInitiated) { () -> ParsedMessage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return MIMEParser.parse(data)
        }.value
        guard let parsed else { return nil }
        return LoadedMessage(id: id, fileURL: url, message: parsed)
    }

    /// Loads the message shown in the detail pane.
    func showMessage(_ id: Int64) async {
        messageLoadFailed = false
        allowRemoteContent = false
        let result = await loadMessage(id)
        guard selectedMessageID == id else { return }  // selection moved on meanwhile
        loadedMessage = result
        messageLoadFailed = result == nil
    }

    func fileURL(forMessage id: Int64) async -> URL? {
        try? await library?.fileURL(forMessage: id)
    }

    // MARK: Import

    func requestImport(_ url: URL) {
        guard importStatus == nil else { return }
        guard let readpst = ReadPST.locate() else {
            pendingImportURL = url
            readpstStillMissing = false
            showReadpstHelp = true
            return
        }
        startImport(url, readpst: readpst)
    }

    /// Called from the "install readpst" sheet. Returns false if readpst still can't be found.
    @discardableResult
    func retryPendingImport() -> Bool {
        guard let readpst = ReadPST.locate() else { return false }
        showReadpstHelp = false
        if let url = pendingImportURL {
            pendingImportURL = nil
            startImport(url, readpst: readpst)
        }
        return true
    }

    func chooseReadpstManually() {
        let panel = NSOpenPanel()
        panel.message = "Choose the readpst program (usually in /opt/homebrew/bin or /usr/local/bin)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: ReadPST.userDefaultsKey)
        retryPendingImport()
    }

    private func startImport(_ url: URL, readpst: URL) {
        guard let library else { return }
        importStatus = ImportStatus(fileName: url.lastPathComponent)
        let importer = ArchiveImporter(library: library, readpstURL: readpst)

        importTask = Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let archiveID = try await importer.run(pstURL: url) { phase in
                    Task { @MainActor in
                        guard self.importStatus?.errorMessage == nil else { return }
                        self.importStatus?.phase = phase
                    }
                }
                await reloadArchives()
                sidebarSelection = .archive(archiveID)
                importStatus = nil
                runSearch(debounce: false)
            } catch is CancellationError {
                importStatus = nil
            } catch {
                importStatus?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }
}
