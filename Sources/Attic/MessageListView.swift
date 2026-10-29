import AtticCore
import SwiftUI

struct MessageListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.library != nil, !model.archives.isEmpty {
                MessageListHeader()
                Divider()
            }
            Group {
                if model.library == nil {
                    ContentUnavailableView("Can’t Open the Library", systemImage: "exclamationmark.triangle",
                                           description: Text(model.startupError ?? ""))
                } else if model.archives.isEmpty {
                    ContentUnavailableView {
                        Label("No Archives Yet", systemImage: "archivebox")
                    } description: {
                        Text("Import an Outlook data file (.pst or .ost) to browse and search it. You can also drop one onto this window.")
                    } actions: {
                        Button("Import Outlook Archive…") { model.showFileImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    table
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Used for the window's name (Window menu, Mission Control); hidden in the toolbar.
        .navigationTitle(model.scopeTitle)
    }

    /// Every row is the same height, whether or not it has a preview line.
    static let rowHeight: CGFloat = 36

    private var table: some View {
        @Bindable var model = model

        return Table(model.results, selection: $model.selectedMessageID) {
            TableColumn("") { row in
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                    .opacity(row.hasAttachments ? 1 : 0)
                    .frame(height: Self.rowHeight)
            }
            .width(16)

            TableColumn("From") { row in
                Text(row.sender.isEmpty ? "(unknown)" : row.sender)
                    .lineLimit(1)
                    .frame(height: Self.rowHeight)
                    .help(row.recipients.isEmpty ? row.sender : "To: \(row.recipients)")
            }
            .width(min: 110, ideal: 160)

            TableColumn("Subject") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.subject.isEmpty ? "(No Subject)" : row.subject)
                        .lineLimit(1)
                    // Always present (a space when there's no preview) so rows never change height.
                    Text(Self.preview(row.snippet))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(height: Self.rowHeight, alignment: .leading)
            }
            .width(min: 180, ideal: 440)

            TableColumn("Date") { row in
                Text(row.date.map(Self.format) ?? "")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(height: Self.rowHeight)
            }
            // Fixed to fit the longest date format ("10/12/2019", "3:45 PM"), so spare width goes to Subject.
            .width(78)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first {
                Button("Open in Mail App") { Task { await FileActions.openEML(messageID: id, model: model) } }
                Button("Save as .eml…") { Task { await FileActions.saveEML(messageID: id, model: model) } }
                Button("Show File in Finder") { Task { await FileActions.revealEML(messageID: id, model: model) } }
            }
        }
        .overlay {
            if model.results.isEmpty, model.hasSearched {
                if let error = model.searchError {
                    ContentUnavailableView("Search Problem", systemImage: "exclamationmark.magnifyingglass",
                                           description: Text(error))
                } else if !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else {
                    ContentUnavailableView("No Messages", systemImage: "tray")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Text(countText)
            Spacer()
            Button {
                model.showSearchHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Search tips")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var countText: String {
        let total = model.totalResults
        let noun = total == 1 ? "message" : "messages"
        var text = "\(total.formatted()) \(noun)"
        if model.results.count < total {
            text += " · showing the first \(model.results.count.formatted())"
        }
        return text
    }

    /// Cleans previews stored by earlier imports, which could start with invisible padding.
    static func preview(_ snippet: String) -> String {
        let cleaned = TextDecoding.snippet(snippet)
        return cleaned.isEmpty ? " " : cleaned
    }

    private static let sameDayFormat = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let sameYearFormat = Date.FormatStyle().month(.abbreviated).day()
    private static let olderFormat = Date.FormatStyle(date: .numeric, time: .omitted)

    static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(sameDayFormat) }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { return date.formatted(sameYearFormat) }
        return date.formatted(olderFormat)
    }
}
