import AppKit
import AtticCore
import SwiftUI

struct ImportProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let status = model.importStatus {
                Label("Importing “\(status.fileName)”", systemImage: "archivebox")
                    .font(.headline)

                if let error = status.errorMessage {
                    Text("The import didn’t finish.")
                    ScrollView {
                        Text(error)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    HStack {
                        Spacer()
                        Button("Close") { model.importStatus = nil }
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    progress(for: status.phase)
                    Text("Large archives can take a while. Your original file is only read, never changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { model.cancelImport() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private func progress(for phase: ImportPhase) -> some View {
        switch phase {
        case .starting:
            ProgressView().progressViewStyle(.linear)
            Text("Starting…").foregroundStyle(.secondary)
        case .extracting(let found):
            ProgressView().progressViewStyle(.linear)
            Text(found == 0 ? "Extracting messages from the archive…"
                            : "Extracting messages from the archive… \(found.formatted()) so far")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .indexing(let done, let total, let slowMessage):
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text("Indexing \(done.formatted()) of \(total.formatted()) messages")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let slowMessage {
                Text("Working on a large message (\(slowMessage))…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .finishing:
            ProgressView().progressViewStyle(.linear)
            Text("Optimizing the search index…").foregroundStyle(.secondary)
        }
    }
}

struct ReadpstHelpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let command = "brew install libpst"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("One-time setup: install readpst", systemImage: "wrench.and.screwdriver")
                .font(.headline)

            Text("Outlook for Windows stores mail in proprietary .pst and .ost files. This app uses **readpst**, a free, open-source tool from the libpst project, to unpack it. Install it once with Homebrew by running this in Terminal:")
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                Button("Copy") { FileActions.copyToPasteboard(command) }
            }

            Text("No Homebrew yet? Get it from [brew.sh](https://brew.sh), then run the command above.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.readpstStillMissing {
                Text("readpst still isn’t in /opt/homebrew/bin or /usr/local/bin. If it’s installed elsewhere, use “Locate readpst…”.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Locate readpst…") { model.chooseReadpstManually() }
                Spacer()
                Button("Cancel") {
                    model.pendingImportURL = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("I’ve Installed It") {
                    model.readpstStillMissing = !model.retryPendingImport()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

struct SearchHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let examples: [(String, String)] = [
        ("budget meeting", "Messages containing both words (prefixes match too: “budg” finds “budget”)"),
        ("\"quarterly report\"", "An exact phrase"),
        ("-newsletter", "Leave out messages containing a word"),
        ("from:smith", "Sender name or address"),
        ("to:alice  cc:bob", "Recipients"),
        ("subject:invoice", "Words in the subject"),
        ("attachment:pdf", "Attachment names, and the text inside PDF and text attachments"),
        ("has:attachment", "Only messages with attachments"),
        ("larger:5MB  smaller:200KB", "Message size"),
        ("after:2019-03-01  before:2019-04-01", "A date range (a year or year-month also works: after:2018)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search Tips").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(examples.indices, id: \.self) { index in
                    let example = examples[index]
                    GridRow {
                        Text(example.0)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text(example.1)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Combine any of these, or use the options button at the right of the search box (⌥⌘F) to fill them in for you. Searches cover whatever is selected in the sidebar.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
