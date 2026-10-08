import Foundation
import SQLite3

/// A SQLite value read from, or bound to, a statement.
enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// One result row, valid only inside the `query` callback that receives it. Accessors are strict: a
/// column of another storage class reads as `nil` rather than being coerced, so a source that changes
/// a type is treated as malformed instead of guessed at.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer?

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    func int64(_ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_INTEGER ? sqlite3_column_int64(statement, column) : nil
    }

    /// A text column; `nil` when it is another type, not valid UTF-8, or longer than the database allows.
    func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= ReadOnlySQLiteDatabase.maximumValueBytes else { return nil }
        guard count > 0, let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(
            data: Data(bytes: bytes, count: count), encoding: .utf8
        )
    }

    /// A real column; `nil` when it is another type.
    func double(_ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_FLOAT ? sqlite3_column_double(statement, column) : nil
    }

    /// The bytes the first `columns` columns of this row hold in memory, roughly: text and blob length,
    /// 8 for a number, 0 for NULL. What a read budget counts.
    func approximateBytes(columns: Int32) -> Int {
        (0..<columns).reduce(0) { total, column in
            switch sqlite3_column_type(statement, column) {
            case SQLITE_TEXT, SQLITE_BLOB: total + Int(sqlite3_column_bytes(statement, column))
            case SQLITE_INTEGER, SQLITE_FLOAT: total + 8
            default: total
            }
        }
    }

    /// A blob column; `nil` when it is another type or larger than the database allows.
    func blob(_ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= ReadOnlySQLiteDatabase.maximumValueBytes else { return nil }
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// A SQLite database opened strictly read-only through the system `SQLite3` module: the access both
/// local-database sources (Antigravity, OpenCode) share. Only the SQL and the row mapping are specific
/// to a source.
///
/// It opens a `file:` URI with `mode=ro` and never `immutable=1` (which would ignore the write-ahead
/// log, where an active session's newest rows live), waits at most `busyTimeoutMilliseconds` for a
/// lock and closes its handle on `close()` or deinit.
final class ReadOnlySQLiteDatabase {
    enum DatabaseError: Error {
        case open(Int32)
        case statement(Int32)
        /// The database, or its write-ahead log, exists but is not a regular file.
        case notRegularFile
    }

    /// Whether a row-by-row read goes on.
    enum RowFlow {
        case next
        case stop
    }

    /// A locked database is skipped for this poll, so waiting long would stall every other source.
    static let busyTimeoutMilliseconds: Int32 = 500
    /// A single blob or text value larger than this is not metadata; it reads as missing.
    static let maximumValueBytes = 32 * 1_024 * 1_024

    private var handle: OpaquePointer?

    init(url: URL) throws {
        try Self.requireRegularFiles(of: url)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(Self.readOnlyURI(for: url), &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw DatabaseError.open(status)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
    }

    deinit { close() }

    /// SQLite opens the database and its `-wal` itself and blocking, so a FIFO, socket or device with
    /// either name would stall the poll that opens it (and every source behind it). Both must be
    /// regular files (a symbolic link is followed, like every other source file) or, for the log,
    /// absent. `stat` never opens the file.
    private static func requireRegularFiles(of url: URL) throws {
        var database = stat()
        guard stat(url.path, &database) == 0, database.st_mode & S_IFMT == S_IFREG else { throw DatabaseError.notRegularFile }
        var log = stat()
        if stat(url.path + "-wal", &log) == 0, log.st_mode & S_IFMT != S_IFREG { throw DatabaseError.notRegularFile }
    }

    func close() {
        guard let handle else { return }
        sqlite3_close(handle)
        self.handle = nil
    }

    /// The `file:` URI of an absolute path. Everything outside the URI-unreserved set is percent-encoded
    /// (so `?`, `#`, `%` and spaces in a folder name cannot change the meaning), except `/`.
    static func readOnlyURI(for url: URL) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        let path = url.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path
        return "file:\(path)?mode=ro"
    }

    /// Runs `body` inside one read transaction, so every table is read from the same snapshot even
    /// while the source is writing.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        defer { try? execute("COMMIT") }
        return try body()
    }

    /// Runs one statement and maps each row; a row `map` rejects (returns `nil`) is skipped, as any
    /// other malformed record.
    func query<Row>(_ sql: String, bindings: [SQLiteValue] = [], map: (SQLiteRow) -> Row?) throws -> [Row] {
        var result: [Row] = []
        try forEachRow(sql, bindings: bindings) { row in
            if let mapped = map(row) { result.append(mapped) }
            return .next
        }
        return result
    }

    /// Runs one statement and hands each row to `body` until it returns `.stop`, so a read that has
    /// reached its budget leaves the rest of the result unread.
    func forEachRow(_ sql: String, bindings: [SQLiteValue] = [], _ body: (SQLiteRow) -> RowFlow) throws {
        var statement: OpaquePointer?
        try prepare(sql, &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw DatabaseError.statement(status) }
            if body(SQLiteRow(statement: statement)) == .stop { return }
        }
    }

    /// The first row's mapping, or `nil` when there is no row or `map` rejects it.
    func queryFirst<Row>(_ sql: String, bindings: [SQLiteValue] = [], map: (SQLiteRow) -> Row?) throws -> Row? {
        try query(sql, bindings: bindings, map: map).first
    }

    // MARK: Plumbing

    private func execute(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw DatabaseError.statement(status) }
    }

    private func prepare(_ sql: String, _ statement: inout OpaquePointer?) throws {
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            sqlite3_finalize(statement)
            statement = nil
            throw DatabaseError.statement(status)
        }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let position = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(statement, position)
            case .integer(let number): status = sqlite3_bind_int64(statement, position, number)
            case .real(let number): status = sqlite3_bind_double(statement, position, number)
            case .text(let text): status = sqlite3_bind_text(statement, position, text, -1, transient)
            case .blob(let data):
                status = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
            }
            guard status == SQLITE_OK else { throw DatabaseError.statement(status) }
        }
    }
}
