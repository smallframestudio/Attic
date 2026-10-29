import PSTCore
import SwiftUI

struct MessageDetailView: View {
    let messageID: Int64

    @Environment(AppModel.self) private var model

    var body: some View {
        // The GeometryReader takes exactly the space the window gives this pane, so no message
        // (a huge recipient list, a long unbroken subject, odd HTML) can make the pane demand more
        // height than the window has. That used to enlarge the whole layout and push the top of
        // every column up under the title bar.
        GeometryReader { geometry in
            Group {
                if let loaded = model.loadedMessage, loaded.id == messageID {
                    content(loaded)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if model.messageLoadFailed {
                    ContentUnavailableView("Couldn’t Open This Message", systemImage: "exclamationmark.triangle",
                                           description: Text("The extracted message file may have been moved or deleted."))
                } else {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        .task(id: messageID) {
            await model.showMessage(messageID)
        }
    }

    @ViewBuilder
    private func content(_ item: LoadedMessage) -> some View {
        @Bindable var model = model
        let message = item.message
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                MessageHeaderView(message: message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions(item)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if !message.attachments.isEmpty {
                AttachmentBar(attachments: message.attachments)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
            }
            if model.showPlainText || message.htmlBody == nil {
                ScrollView {
                    Text(message.plainText.isEmpty ? "(This message has no text.)" : message.plainText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                HTMLView(html: MessageHTML.document(for: message, allowRemoteContent: model.allowRemoteContent))
            }
        }
    }

    /// Message buttons, kept in the message pane's own top-right corner.
    private func actions(_ item: LoadedMessage) -> some View {
        @Bindable var model = model
        let message = item.message
        return HStack(spacing: 10) {
                if message.htmlBody != nil {
                    if !model.showPlainText, !model.allowRemoteContent, MessageHTML.hasRemoteContent(message) {
                        Button {
                            model.allowRemoteContent = true
                        } label: {
                            Image(systemName: "photo.badge.arrow.down")
                        }
                        .help("This message references images on the internet. They are blocked until you load them.")
                        .accessibilityLabel("Load remote images")
                    }
                    Toggle(isOn: $model.showPlainText) {
                        Image(systemName: "text.alignleft")
                    }
                    .toggleStyle(.button)
                    .help("Show the message as plain text")
                    .accessibilityLabel("Plain text")
                }
                Menu {
                    Button("Open in Mail App") { FileActions.open(item.fileURL) }
                    Button("Save as .eml…") { FileActions.saveCopy(of: item.fileURL, suggestedName: message.subject) }
                    Button("Show File in Finder") { FileActions.reveal(item.fileURL) }
                    Divider()
                    Button("Copy Raw Headers") {
                        let raw = message.headers.fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
                        FileActions.copyToPasteboard(raw)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
            .buttonStyle(.borderless)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }
}

private struct MessageHeaderView: View {
    let message: ParsedMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.subject.isEmpty ? "(No Subject)" : message.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(3)
                .help(message.subject)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                if let from = message.from {
                    row("From", from.full)
                }
                if !message.to.isEmpty {
                    row("To", message.to.map(\.full).joined(separator: ", "))
                }
                if !message.cc.isEmpty {
                    row("Cc", message.cc.map(\.full).joined(separator: ", "))
                }
                if !message.bcc.isEmpty {
                    row("Bcc", message.bcc.map(\.full).joined(separator: ", "))
                }
                if let date = message.date {
                    row("Date", date.formatted(date: .complete, time: .shortened))
                }
            }
            .font(.callout)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.tail)
                .help(value)
        }
    }
}

private struct AttachmentBar: View {
    let attachments: [MessageAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Button {
                        FileActions.open(attachment)
                    } label: {
                        HStack(spacing: 6) {
                            Image(nsImage: FileActions.icon(forFilename: attachment.filename))
                                .resizable()
                                .frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(attachment.filename)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: 240, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Click to open. Right-click to save.")
                    .contextMenu {
                        Button("Open") { FileActions.open(attachment) }
                        Button("Save As…") { FileActions.save(attachment) }
                    }
                }
                if attachments.count > 1 {
                    Button("Save All…") { FileActions.saveAll(attachments) }
                        .buttonStyle(.link)
                }
            }
        }
    }
}
