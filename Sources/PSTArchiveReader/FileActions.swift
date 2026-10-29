import AppKit
import PSTCore
import UniformTypeIdentifiers

/// Opening, saving and revealing attachments and message files.
@MainActor
enum FileActions {

    // MARK: Attachments

    static func open(_ attachment: MessageAttachment) {
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Attic/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(safeName(attachment.filename))
            try attachment.data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            showError(error)
        }
    }

    static func save(_ attachment: MessageAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeName(attachment.filename)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try attachment.data.write(to: url)
        } catch {
            showError(error)
        }
    }

    static func saveAll(_ attachments: [MessageAttachment]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for the \(attachments.count) attachments"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            for attachment in attachments {
                try attachment.data.write(to: uniqueURL(in: folder, name: safeName(attachment.filename)))
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            showError(error)
        }
    }

    static func icon(forFilename filename: String) -> NSImage {
        let ext = (filename as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }

    // MARK: Message files (.eml)

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func saveCopy(of url: URL, suggestedName: String) {
        let panel = NSSavePanel()
        let base = MIMEParser.sanitizeFilename(suggestedName)
        panel.nameFieldStringValue = (base.isEmpty ? "message" : base) + ".eml"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            showError(error)
        }
    }

    static func openEML(messageID: Int64, model: AppModel) async {
        if let url = await model.fileURL(forMessage: messageID) { open(url) }
    }

    static func revealEML(messageID: Int64, model: AppModel) async {
        if let url = await model.fileURL(forMessage: messageID) { reveal(url) }
    }

    static func saveEML(messageID: Int64, model: AppModel) async {
        guard let url = await model.fileURL(forMessage: messageID) else { return }
        let subject = model.results.first { $0.id == messageID }?.subject ?? "message"
        saveCopy(of: url, suggestedName: subject)
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Helpers

    private static func safeName(_ name: String) -> String {
        let cleaned = MIMEParser.sanitizeFilename(name)
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    private static func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private static func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
