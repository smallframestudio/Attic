import Foundation

// MARK: - Records

public struct ArchiveInfo: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let sourcePath: String
    public let importedAt: Date
    public let messageCount: Int
}

public struct FolderRecord: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let archiveID: Int64
    public let parentID: Int64?
    public let name: String
    public let messageCount: Int
}

public struct MessageRow: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let archiveID: Int64
    public let folderID: Int64
    public let subject: String
    public let sender: String
    public let recipients: String
    public let date: Date?
    public let snippet: String
    public let hasAttachments: Bool
}

/// One message ready to be written to the index.
public struct IndexedMessage: Sendable {
    public var folderID: Int64
    public var relativePath: String
    public var subject: String
    public var fromName: String
    public var fromAddress: String
    public var recipients: String
    public var date: Date?
    public var snippet: String
    public var hasAttachments: Bool
    public var size: Int
    public var bodyText: String
    public var attachmentText: String
}

public enum MessageSortOrder: String, Sendable, CaseIterable, Identifiable {
    case newest, oldest, relevance
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        case .relevance: return "Best Match"
        }
    }
}

public struct SearchRequest: Sendable, Equatable {
    public var text: String
    public var archiveID: Int64?
    public var folderIDs: [Int64]?
    public var sort: MessageSortOrder
    public var limit: Int

    public init(text: String, archiveID: Int64? = nil, folderIDs: [Int64]? = nil, sort: MessageSortOrder = .newest, limit: Int = 2000) {
        self.text = text
        self.archiveID = archiveID
        self.folderIDs = folderIDs
        self.sort = sort
        self.limit = limit
    }
}

public struct SearchResult: Sendable {
    public var rows: [MessageRow]
    public var total: Int
    public var errorMessage: String?
}

// MARK: - Library

/// The on-disk store: one SQLite database (metadata + FTS5 index) and, per archive,
/// a folder of the .eml files extracted from the PST that message bodies are read from.
public actor Library {
    public nonisolated let rootURL: URL
    private let db: Database

    public static var defaultRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Attic", isDirectory: true)
    }

    public init(rootURL: URL = Library.defaultRootURL) throws {
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("archives"), withIntermediateDirectories: true)
        self.rootURL = rootURL
        let database = try Database(path: rootURL.appendingPathComponent("library.sqlite").path)
        try Library.createSchema(database)
        self.db = database
    }

    private static func createSchema(_ db: Database) throws {
        try db.execute("""
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS archives (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            source_path TEXT NOT NULL,
            storage_dir TEXT NOT NULL,
            imported_at REAL NOT NULL,
            message_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'importing'
        );
        CREATE TABLE IF NOT EXISTS folders (
            id INTEGER PRIMARY KEY,
            archive_id INTEGER NOT NULL REFERENCES archives(id) ON DELETE CASCADE,
            parent_id INTEGER,
            name TEXT NOT NULL,
            rel_path TEXT NOT NULL,
            message_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY,
            archive_id INTEGER NOT NULL REFERENCES archives(id) ON DELETE CASCADE,
            folder_id INTEGER NOT NULL,
            rel_path TEXT NOT NULL,
            subject TEXT NOT NULL,
            from_name TEXT NOT NULL,
            from_addr TEXT NOT NULL,
            recipients TEXT NOT NULL,
            date REAL,
            snippet TEXT NOT NULL,
            has_attachments INTEGER NOT NULL,
            size INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS messages_by_folder ON messages(folder_id, date);
        CREATE INDEX IF NOT EXISTS messages_by_archive ON messages(archive_id, date);
        CREATE INDEX IF NOT EXISTS messages_by_date ON messages(date);
        CREATE INDEX IF NOT EXISTS folders_by_archive ON folders(archive_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            subject, sender, recipients, body, attachments,
            tokenize = 'unicode61 remove_diacritics 2',
            prefix = '2 3'
        );
        """)
    }

    // MARK: Archives and folders

    public func archives() throws -> [ArchiveInfo] {
        let stmt = try db.prepare("""
            SELECT id, name, source_path, imported_at, message_count FROM archives
            WHERE status = 'ready' ORDER BY imported_at
            """)
        try stmt.bind([])
        var result: [ArchiveInfo] = []
        while try stmt.step() {
            result.append(ArchiveInfo(
                id: stmt.int64(0), name: stmt.text(1), sourcePath: stmt.text(2),
                importedAt: Date(timeIntervalSince1970: stmt.double(3)), messageCount: stmt.int(4)))
        }
        return result
    }

    public func folders(archiveID: Int64) throws -> [FolderRecord] {
        let stmt = try db.prepare("""
            SELECT id, parent_id, name, message_count FROM folders WHERE archive_id = ? ORDER BY name COLLATE NOCASE
            """)
        try stmt.bind([.int(archiveID)])
        var result: [FolderRecord] = []
        while try stmt.step() {
            result.append(FolderRecord(
                id: stmt.int64(0), archiveID: archiveID,
                parentID: stmt.isNull(1) ? nil : stmt.int64(1),
                name: stmt.text(2), messageCount: stmt.int(3)))
        }
        return result
    }

    /// Creates an archive row in the "importing" state and returns its id and the directory
    /// that readpst should extract into.
    public func createArchive(name: String, sourcePath: String) throws -> (id: Int64, mailDirectory: URL) {
        let storage = UUID().uuidString
        let mailDirectory = rootURL.appendingPathComponent("archives/\(storage)/mail", isDirectory: true)
        try FileManager.default.createDirectory(at: mailDirectory, withIntermediateDirectories: true)
        try db.run("""
            INSERT INTO archives (name, source_path, storage_dir, imported_at, status) VALUES (?, ?, ?, ?, 'importing')
            """, [.text(name), .text(sourcePath), .text(storage), .double(Date().timeIntervalSince1970)])
        return (db.lastInsertRowID, mailDirectory)
    }

    public func addFolder(archiveID: Int64, parentID: Int64?, name: String, relativePath: String) throws -> Int64 {
        try db.run("INSERT INTO folders (archive_id, parent_id, name, rel_path) VALUES (?, ?, ?, ?)",
                   [.int(archiveID), parentID.map(SQLValue.int) ?? .null, .text(name), .text(relativePath)])
        return db.lastInsertRowID
    }

    public func insert(_ messages: [IndexedMessage], archiveID: Int64) throws {
        guard !messages.isEmpty else { return }
        let insertMessage = try db.prepare("""
            INSERT INTO messages (archive_id, folder_id, rel_path, subject, from_name, from_addr, recipients,
                                  date, snippet, has_attachments, size)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        let insertText = try db.prepare("""
            INSERT INTO messages_fts (rowid, subject, sender, recipients, body, attachments) VALUES (?, ?, ?, ?, ?, ?)
            """)
        try db.transaction {
            for m in messages {
                try insertMessage.run([
                    .int(archiveID), .int(m.folderID), .text(m.relativePath), .text(m.subject),
                    .text(m.fromName), .text(m.fromAddress), .text(m.recipients),
                    m.date.map { SQLValue.double($0.timeIntervalSince1970) } ?? SQLValue.null,
                    .text(m.snippet), .int(m.hasAttachments ? 1 : 0), .int(Int64(m.size)),
                ])
                let rowID = db.lastInsertRowID
                try insertText.run([
                    .int(rowID), .text(m.subject), .text("\(m.fromName) \(m.fromAddress)"),
                    .text(m.recipients), .text(m.bodyText), .text(m.attachmentText),
                ])
            }
        }
    }

    public func finishArchive(id: Int64) throws {
        try db.transaction {
            try db.run("""
                UPDATE folders SET message_count = (SELECT COUNT(*) FROM messages WHERE messages.folder_id = folders.id)
                WHERE archive_id = ?
                """, [.int(id)])
            try db.run("""
                UPDATE archives SET status = 'ready',
                    message_count = (SELECT COUNT(*) FROM messages WHERE archive_id = ?)
                WHERE id = ?
                """, [.int(id), .int(id)])
        }
        try? db.execute("INSERT INTO messages_fts(messages_fts) VALUES('optimize')")
    }

    public func renameArchive(id: Int64, to name: String) throws {
        try db.run("UPDATE archives SET name = ? WHERE id = ?", [.text(name), .int(id)])
    }

    /// Removes an archive's rows, its index entries and its extracted files.
    public func deleteArchive(id: Int64) throws {
        let stmt = try db.prepare("SELECT storage_dir FROM archives WHERE id = ?")
        try stmt.bind([.int(id)])
        let storage = try stmt.step() ? stmt.text(0) : nil

        try db.transaction {
            try db.run("DELETE FROM messages_fts WHERE rowid IN (SELECT id FROM messages WHERE archive_id = ?)", [.int(id)])
            try db.run("DELETE FROM messages WHERE archive_id = ?", [.int(id)])
            try db.run("DELETE FROM folders WHERE archive_id = ?", [.int(id)])
            try db.run("DELETE FROM archives WHERE id = ?", [.int(id)])
        }
        if let storage, !storage.isEmpty {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent("archives/\(storage)"))
        }
    }

    /// Cleans up imports that were interrupted (app quit or crashed mid-import).
    public func removeIncompleteArchives() throws {
        let stmt = try db.prepare("SELECT id FROM archives WHERE status != 'ready'")
        try stmt.bind([])
        var ids: [Int64] = []
        while try stmt.step() { ids.append(stmt.int64(0)) }
        for id in ids { try deleteArchive(id: id) }
    }

    // MARK: Messages

    public func fileURL(forMessage id: Int64) throws -> URL? {
        let stmt = try db.prepare("""
            SELECT a.storage_dir, m.rel_path FROM messages m JOIN archives a ON a.id = m.archive_id WHERE m.id = ?
            """)
        try stmt.bind([.int(id)])
        guard try stmt.step() else { return nil }
        return rootURL
            .appendingPathComponent("archives/\(stmt.text(0))/mail", isDirectory: true)
            .appendingPathComponent(stmt.text(1))
    }

    // MARK: Search

    /// Never throws: a malformed query comes back as an empty result with an error message.
    public func search(_ request: SearchRequest) -> SearchResult {
        do {
            return try runSearch(request)
        } catch {
            return SearchResult(rows: [], total: 0, errorMessage: (error as? SQLiteError)?.message ?? error.localizedDescription)
        }
    }

    private func runSearch(_ request: SearchRequest) throws -> SearchResult {
        let query = SearchQuery(parsing: request.text)
        var conditions: [String] = []
        var values: [SQLValue] = []

        let from: String
        if let match = query.matchExpression {
            from = "messages_fts JOIN messages m ON m.id = messages_fts.rowid"
            conditions.append("messages_fts MATCH ?")
            values.append(.text(match))
        } else {
            from = "messages m"
        }
        if let exclude = query.excludeExpression {
            conditions.append("m.id NOT IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)")
            values.append(.text(exclude))
        }
        if let archiveID = request.archiveID {
            conditions.append("m.archive_id = ?")
            values.append(.int(archiveID))
        }
        if let folderIDs = request.folderIDs {
            // Integers only, so inlining them is safe and avoids SQLite's bound-parameter limit.
            conditions.append(folderIDs.isEmpty ? "0" : "m.folder_id IN (\(folderIDs.map(String.init).joined(separator: ",")))")
        }
        if let after = query.after {
            conditions.append("m.date >= ?")
            values.append(.double(after.timeIntervalSince1970))
        }
        if let before = query.before {
            conditions.append("m.date < ?")
            values.append(.double(before.timeIntervalSince1970))
        }
        if query.requiresAttachment {
            conditions.append("m.has_attachments = 1")
        }
        if let larger = query.largerThan {
            conditions.append("m.size > ?")
            values.append(.int(Int64(larger)))
        }
        if let smaller = query.smallerThan {
            conditions.append("m.size < ?")
            values.append(.int(Int64(smaller)))
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let order: String
        switch request.sort {
        case .relevance where query.matchExpression != nil:
            // Weights: subject, sender, recipients, body, attachments.
            order = "bm25(messages_fts, 8.0, 4.0, 2.0, 1.0, 1.0), m.date DESC"
        case .oldest:
            order = "m.date IS NULL, m.date ASC"
        default:
            order = "m.date IS NULL, m.date DESC"
        }

        let rowsStatement = try db.prepare("""
            SELECT m.id, m.archive_id, m.folder_id, m.subject, m.from_name, m.from_addr, m.recipients,
                   m.date, m.snippet, m.has_attachments
            FROM \(from) \(whereClause) ORDER BY \(order) LIMIT \(max(1, request.limit))
            """)
        try rowsStatement.bind(values)
        var rows: [MessageRow] = []
        while try rowsStatement.step() {
            let name = rowsStatement.text(4)
            let address = rowsStatement.text(5)
            rows.append(MessageRow(
                id: rowsStatement.int64(0),
                archiveID: rowsStatement.int64(1),
                folderID: rowsStatement.int64(2),
                subject: rowsStatement.text(3),
                sender: EmailAddress(name: name, address: address).display,
                recipients: rowsStatement.text(6),
                date: rowsStatement.isNull(7) ? nil : Date(timeIntervalSince1970: rowsStatement.double(7)),
                snippet: rowsStatement.text(8),
                hasAttachments: rowsStatement.int(9) != 0))
        }

        var total = rows.count
        if rows.count >= request.limit {
            let countStatement = try db.prepare("SELECT COUNT(*) FROM \(from) \(whereClause)")
            try countStatement.bind(values)
            if try countStatement.step() { total = countStatement.int(0) }
        }
        return SearchResult(rows: rows, total: total, errorMessage: nil)
    }
}
