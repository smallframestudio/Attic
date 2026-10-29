import Foundation

public enum ImportPhase: Sendable, Equatable {
    case starting
    case extracting(messagesFound: Int)
    /// `slowMessage` names a message that has been processing for a while, if any.
    case indexing(done: Int, total: Int, slowMessage: String?)
    case finishing
}

public enum ImportError: LocalizedError {
    case readpstFailed(String)
    case noMessages
    case notOutlookFile

    public var errorDescription: String? {
        switch self {
        case .readpstFailed(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "readpst could not read this file." + (trimmed.isEmpty ? "" : "\n\n" + String(trimmed.prefix(1500)))
        case .noMessages:
            return "No email messages were found in this archive."
        case .notOutlookFile:
            return "This isn’t an Outlook data file. Attic can open .pst and .ost files from Outlook for Windows."
        }
    }
}

/// Finds the `readpst` command-line tool from libpst (install with `brew install libpst`).
public enum ReadPST {
    public static let userDefaultsKey = "readpstPath"

    public static func locate() -> URL? {
        var candidates: [String] = []
        if let custom = UserDefaults.standard.string(forKey: userDefaultsKey) { candidates.append(custom) }
        candidates += ["/opt/homebrew/bin/readpst", "/usr/local/bin/readpst", "/opt/local/bin/readpst"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

/// Imports a .pst or .ost (the two share one file format): readpst extracts every message to an .eml file, then each file is parsed
/// (in parallel) and written to the full-text index.
public final class ArchiveImporter: @unchecked Sendable {
    private let library: Library
    private let readpstURL: URL
    private let lock = NSLock()
    private var process: Process?

    public init(library: Library, readpstURL: URL) {
        self.library = library
        self.readpstURL = readpstURL
    }

    /// Runs the import and returns the new archive's id. Cancel the calling Task to stop it;
    /// a cancelled or failed import leaves nothing behind.
    public func run(pstURL: URL, progress: @escaping @Sendable (ImportPhase) -> Void) async throws -> Int64 {
        guard OutlookDataFile.isOutlookFile(pstURL) else { throw ImportError.notOutlookFile }
        let name = pstURL.deletingPathExtension().lastPathComponent
        let (archiveID, mailDirectory) = try await library.createArchive(name: name, sourcePath: pstURL.path)
        do {
            progress(.extracting(messagesFound: 0))
            try await extract(pstURL, into: mailDirectory, progress: progress)
            try Task.checkCancellation()
            try await index(archiveID: archiveID, archiveName: name, mailDirectory: mailDirectory, progress: progress)
            try Task.checkCancellation()
            progress(.finishing)
            try await library.finishArchive(id: archiveID)
            return archiveID
        } catch {
            try? await library.deleteArchive(id: archiveID)
            throw error
        }
    }

    // MARK: Extraction

    private func extract(_ pstURL: URL, into directory: URL, progress: @escaping @Sendable (ImportPhase) -> Void) async throws {
        let process = Process()
        process.executableURL = readpstURL
        let jobs = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        // -e: one .eml file per message, in a folder tree mirroring the PST
        // -8: UTF-8 bodies   -b: skip RTF body copies   -q: quiet   -t e: email only
        process.arguments = ["-e", "-8", "-b", "-q", "-t", "e", "-j", String(jobs),
                             "-o", directory.path, pstURL.path]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let errorOutput = LockedData()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errorOutput.append(chunk) }
        }

        let poller = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                progress(.extracting(messagesFound: ArchiveImporter.countMessages(in: directory)))
            }
        }
        defer {
            poller.cancel()
            errorPipe.fileHandleForReading.readabilityHandler = nil
            setProcess(nil)
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    setProcess(process)
                    if Task.isCancelled { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ImportError.readpstFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            self.terminateProcess()
        }

        try Task.checkCancellation()
        if status != 0, ArchiveImporter.countMessages(in: directory) == 0 {
            throw ImportError.readpstFailed(errorOutput.string)
        }
    }

    private func setProcess(_ p: Process?) {
        lock.lock(); defer { lock.unlock() }
        process = p
    }

    private func terminateProcess() {
        lock.lock(); defer { lock.unlock() }
        if let process, process.isRunning { process.terminate() }
    }

    static func countMessages(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { return 0 }
        var count = 0
        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".eml") { count += 1 }
        }
        return count
    }

    // MARK: Indexing

    private func index(archiveID: Int64, archiveName: String, mailDirectory: URL,
                       progress: @escaping @Sendable (ImportPhase) -> Void) async throws {
        var directories: [String] = []
        var files: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: mailDirectory.path) {
            while let path = enumerator.nextObject() as? String {
                let type = enumerator.fileAttributes?[.type] as? FileAttributeType
                if type == .typeDirectory {
                    directories.append(path)
                } else if path.lowercased().hasSuffix(".eml") {
                    files.append(path)
                }
            }
        }
        guard !files.isEmpty else { throw ImportError.noMessages }

        // Folders, parents before children.
        func depth(_ path: String) -> Int { path.split(separator: "/").count }
        directories.sort { depth($0) != depth($1) ? depth($0) < depth($1) : $0 < $1 }
        var folderIDs: [String: Int64] = [:]
        for path in directories {
            let parentPath = (path as NSString).deletingLastPathComponent
            let parentID = parentPath.isEmpty ? nil : folderIDs[parentPath]
            folderIDs[path] = try await library.addFolder(
                archiveID: archiveID, parentID: parentID,
                name: (path as NSString).lastPathComponent, relativePath: path)
        }
        if files.contains(where: { !$0.contains("/") }) {
            folderIDs[""] = try await library.addFolder(archiveID: archiveID, parentID: nil, name: archiveName, relativePath: "")
        }

        let total = files.count
        progress(.indexing(done: 0, total: total, slowMessage: nil))

        // Reports progress every second, and notes any message that is taking unusually long
        // (in the progress window and in slow-messages.log next to the extracted mail).
        let tracker = ProgressTracker()
        let logURL = mailDirectory.deletingLastPathComponent().appendingPathComponent("slow-messages.log")
        let reporter = Task.detached {
            var logged = Set<String>()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                let slowest = tracker.slowest()
                let slow = slowest.flatMap { $0.seconds >= 10 ? $0.path : nil }
                progress(.indexing(done: tracker.completed, total: total, slowMessage: slow))
                if let slowest, slowest.seconds >= 30, !logged.contains(slowest.path) {
                    logged.insert(slowest.path)
                    ArchiveImporter.appendLog("still working after 30 s: \(slowest.path)", to: logURL)
                }
            }
        }
        defer { reporter.cancel() }

        let batchSize = 200
        var start = 0
        while start < total {
            try Task.checkCancellation()
            let batch = Array(files[start..<min(start + batchSize, total)])
            let parsed = ArchiveImporter.parseBatch(batch, mailDirectory: mailDirectory, folderIDs: folderIDs,
                                                    tracker: tracker, logURL: logURL)
            try await library.insert(parsed, archiveID: archiveID)
            start += batch.count
        }
        progress(.indexing(done: total, total: total, slowMessage: nil))
    }

    static func appendLog(_ line: String, to url: URL) {
        let stamped = ISO8601DateFormatter().string(from: Date()) + "  " + line + "\n"
        guard let data = stamped.data(using: .utf8) else { return }
        logLock.lock()
        defer { logLock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func parseBatch(_ paths: [String], mailDirectory: URL, folderIDs: [String: Int64],
                           tracker: ProgressTracker? = nil, logURL: URL? = nil) -> [IndexedMessage] {
        var results = [IndexedMessage?](repeating: nil, count: paths.count)
        results.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                withAutoreleasePool {
                    let path = paths[i]
                    tracker?.begin(path)
                    let started = Date()
                    defer {
                        tracker?.end(path)
                        let seconds = Date().timeIntervalSince(started)
                        if seconds >= 5, let logURL {
                            appendLog(String(format: "%.1f s: %@", seconds, path), to: logURL)
                        }
                    }
                    let folderPath = (path as NSString).deletingLastPathComponent
                    guard let folderID = folderIDs[folderPath] else { return }
                    base[i] = indexMessage(at: mailDirectory.appendingPathComponent(path),
                                           relativePath: path, folderID: folderID)
                }
            }
        }
        return results.compactMap { $0 }
    }

    static let maxBodyCharacters = 300_000
    private static let logLock = NSLock()
    static let maxAttachmentCharacters = 150_000

    public static func indexMessage(at url: URL, relativePath: String, folderID: Int64) -> IndexedMessage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let message = MIMEParser.parse(data)

        var body = message.plainText
        if body.utf16.count > maxBodyCharacters { body = String(body.prefix(maxBodyCharacters)) }

        var attachmentText = message.attachments.map(\.filename).joined(separator: "\n")
        for attachment in message.attachments {
            if let text = extractText(from: attachment), !text.isEmpty {
                attachmentText += "\n" + text
            }
        }

        let recipients = (message.to + message.cc).map(\.full).joined(separator: ", ")
        return IndexedMessage(
            folderID: folderID,
            relativePath: relativePath,
            subject: message.subject,
            fromName: message.from?.name ?? "",
            fromAddress: message.from?.address ?? "",
            recipients: recipients,
            date: message.date,
            snippet: TextDecoding.snippet(body),
            hasAttachments: !message.attachments.isEmpty,
            size: data.count,
            bodyText: body,
            attachmentText: attachmentText)
    }

    /// Searchable text inside PDF and plain-text attachments.
    static func extractText(from attachment: MessageAttachment) -> String? {
        let name = attachment.filename.lowercased()
        let type = attachment.mimeType

        if type == "application/pdf" || name.hasSuffix(".pdf") {
            guard attachment.size < 30_000_000 else { return nil }
            return PDFTextExtractor.text(of: attachment.data)
        }

        let textExtensions = [".txt", ".csv", ".md", ".log", ".json", ".xml", ".tsv"]
        if (type.hasPrefix("text/") && type != "text/html") || textExtensions.contains(where: { name.hasSuffix($0) }) {
            guard attachment.size < 5_000_000 else { return nil }
            return String(TextDecoding.decode(attachment.data, charset: nil).prefix(maxAttachmentCharacters))
        }
        return nil
    }
}

@inline(__always)
private func withAutoreleasePool(_ body: () -> Void) {
    #if canImport(Darwin)
    autoreleasepool(invoking: body)
    #else
    body()
    #endif
}

/// Reads PDF text through the `attic-pdftext` helper, in its own process with a time limit.
/// Apple's PDF text extraction can hang indefinitely (and use tens of GB) on some PDFs; a
/// separate process can simply be killed, so one bad attachment can't stall an import.
enum PDFTextExtractor {
    static let timeout: TimeInterval = 15
    private static let slots = DispatchSemaphore(value: max(1, min(ProcessInfo.processInfo.activeProcessorCount / 2, 4)))

    /// The helper ships in Attic.app/Contents/Helpers. (Not Contents/MacOS: anything run from there
    /// counts as another copy of the app and gets its own Dock icon.) The executable's own folder is
    /// the fallback for unbundled development builds.
    static let helperURL: URL? = {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/attic-pdftext"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("attic-pdftext"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    static func text(of pdf: Data) -> String? {
        guard let helper = helperURL else { return nil }
        slots.wait()
        defer { slots.signal() }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-\(UUID().uuidString).pdf")
        guard (try? pdf.write(to: file)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = helper
        process.arguments = [file.path, "40", String(ArchiveImporter.maxAttachmentCharacters)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        // Drain stdout on another thread so a full pipe can't block the helper.
        var collected = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected = output.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            _ = drained.wait(timeout: .now() + 2)
            return nil
        }
        _ = drained.wait(timeout: .now() + 5)
        let text = String(decoding: collected, as: UTF8.self)
        return text.isEmpty ? nil : String(text.prefix(ArchiveImporter.maxAttachmentCharacters))
    }
}

/// Every .pst and .ost begins with the bytes "!BDN"; the next two bytes say which it is
/// ("SM" for a .pst, "SO" for an .ost).
public enum OutlookDataFile {
    public static func isOutlookFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 4)) ?? Data()
        return header == Data("!BDN".utf8)
    }
}

/// Tracks which messages are being parsed right now, and how many are finished.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: [String: Date] = [:]
    private var done = 0

    func begin(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight[path] = Date()
    }

    func end(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight[path] = nil
        done += 1
    }

    var completed: Int {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    func slowest() -> (path: String, seconds: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard let oldest = inFlight.min(by: { $0.value < $1.value }) else { return nil }
        return (oldest.key, Date().timeIntervalSince(oldest.value))
    }
}

/// Thread-safe accumulator for readpst's error output.
final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
