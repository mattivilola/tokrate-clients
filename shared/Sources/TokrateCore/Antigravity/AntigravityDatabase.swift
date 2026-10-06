import Foundation
import SQLite3

/// One conversation database opened read-only. Only the columns the metric contract allows are ever
/// selected: `steps(idx, has_subtrajectory, metadata)`, `executor_metadata(idx, data)`,
/// `gen_metadata(idx, data)` and the row count of `parent_references`. The payload, trajectory and
/// render columns (which hold prompts, responses and paths) are never read.
final class AntigravityDatabase {
    struct StepRow {
        let idx: Int64
        let hasSubtrajectory: Bool
        let metadata: Data
    }

    struct BlobRow {
        let idx: Int64
        let data: Data
    }

    enum DatabaseError: Error {
        case open(Int32)
        case statement(Int32)
    }

    /// A locked database is skipped for this poll, so waiting long would stall every other source.
    static let busyTimeoutMilliseconds: Int32 = 500
    /// A single blob larger than this is not metadata; it reads as missing.
    static let maximumBlobBytes = 32 * 1_024 * 1_024

    private var handle: OpaquePointer?

    /// Opens `url` read-only through a `file:` URI with `mode=ro`. Never `immutable=1`: that would
    /// ignore the write-ahead log, which holds the newest steps of an active conversation.
    init(url: URL) throws {
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
    /// while Antigravity is writing.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        defer { try? execute("COMMIT") }
        return try body()
    }

    func steps() throws -> [StepRow] {
        try rows("SELECT idx, has_subtrajectory, metadata FROM steps ORDER BY idx") { statement in
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  let metadata = Self.blob(statement, column: 2) else { return nil }
            return StepRow(
                idx: sqlite3_column_int64(statement, 0),
                hasSubtrajectory: sqlite3_column_int64(statement, 1) != 0,
                metadata: metadata
            )
        }
    }

    func executorMetadata() throws -> [BlobRow] {
        try rows("SELECT idx, data FROM executor_metadata ORDER BY idx") { statement in
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  let data = Self.blob(statement, column: 1) else { return nil }
            return BlobRow(idx: sqlite3_column_int64(statement, 0), data: data)
        }
    }

    /// One generation's blob, or `nil` when no such row exists (yet). A row with a NULL or oversized
    /// blob reads as empty data, which decodes to nothing. Generation rows can be large (megabytes),
    /// so callers fetch only the ones they need.
    func generationData(idx: Int64) throws -> Data? {
        var statement: OpaquePointer?
        try prepare("SELECT data FROM gen_metadata WHERE idx = ?1", &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, idx)
        let status = sqlite3_step(statement)
        switch status {
        case SQLITE_ROW: return Self.blob(statement, column: 0) ?? Data()
        case SQLITE_DONE: return nil
        default: throw DatabaseError.statement(status)
        }
    }

    func parentReferenceCount() throws -> Int {
        var statement: OpaquePointer?
        try prepare("SELECT COUNT(*) FROM parent_references", &statement)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else { throw DatabaseError.statement(status) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: SQLite plumbing

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

    /// Reads every row; a row `map` rejects (NULL key or blob) is skipped, as any other malformed record.
    private func rows<Row>(_ sql: String, map: (OpaquePointer?) -> Row?) throws -> [Row] {
        var statement: OpaquePointer?
        try prepare(sql, &statement)
        defer { sqlite3_finalize(statement) }
        var result: [Row] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw DatabaseError.statement(status) }
            if let row = map(statement) { result.append(row) }
        }
    }

    private static func blob(_ statement: OpaquePointer?, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximumBlobBytes else { return nil }
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
