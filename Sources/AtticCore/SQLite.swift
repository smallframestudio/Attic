import Foundation
import SQLite3

/// A value bound to, or read from, a SQLite statement.
public enum SQLValue: Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

public struct SQLiteError: LocalizedError, Sendable {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { "Database error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal wrapper around a single SQLite connection. Not thread-safe on its own;
/// the `Library` actor serialises all access to it.
final class Database {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            sqlite3_close_v2(handle)
            handle = nil
            throw SQLiteError(code: rc, message: message)
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    var changes: Int {
        Int(sqlite3_changes(handle))
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError(code: rc, message: errorMessage)
        }
        return Statement(stmt: stmt, db: self)
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let stmt = try prepare(sql)
        try stmt.run(values)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    let stmt: OpaquePointer
    private unowned let db: Database

    init(stmt: OpaquePointer, db: Database) {
        self.stmt = stmt
        self.db = db
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .int(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            case .null: rc = sqlite3_bind_null(stmt, index)
            }
            if rc != SQLITE_OK {
                throw SQLiteError(code: rc, message: db.errorMessage)
            }
        }
    }

    /// Advances to the next row. Returns false when there are no more rows.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: rc, message: db.errorMessage)
        }
    }

    func run(_ values: [SQLValue]) throws {
        try bind(values)
        while try step() {}
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(stmt, column)
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, column))
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(stmt, column)
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(stmt, column) == SQLITE_NULL
    }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: pointer)
    }
}
