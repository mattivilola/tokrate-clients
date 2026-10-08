import Foundation

/// OpenCode's single SQLite database, opened read-only through the shared `ReadOnlySQLiteDatabase`.
///
/// The contract's column list is the whole of what is ever read: `session(id, parent_id, version,
/// time_created)` and, from `message`, its id, session id and two timestamps plus exactly the JSON
/// paths the contract names, extracted in SQL with `json_extract` so the message's `data` text is never
/// loaded. The `part` table (prompts, responses, tool output) and every other column are never touched.
final class OpenCodeDatabase {
    /// A JSON number extracted in SQL. Only an integer is a valid count or timestamp; anything else
    /// (a string, a fraction) is `invalid`, and an absent path is `absent`.
    enum JSONInteger: Sendable, Equatable {
        case absent
        case value(Int64)
        case invalid
    }

    struct SessionRow: Sendable {
        let id: String
        let parentID: String?
        let version: String?
    }

    struct MessageRow: Sendable {
        let id: String
        let sessionID: String
        let timeCreated: Int64
        let timeUpdated: Int64
        let role: String?
        let parentID: String?
        let modelID: String?
        let providerID: String?
        let variant: String?
        let finish: String?
        /// `error.name` is present.
        let hasErrorName: Bool
        let created: JSONInteger
        let completed: JSONInteger
        let output: JSONInteger
        let reasoning: JSONInteger
        let input: JSONInteger
        let cacheRead: JSONInteger
        let cacheWrite: JSONInteger
    }

    /// Strings are cut in SQL: ids and enums are short, and nothing longer is kept anyway.
    private static let maximumStringCharacters = 200
    /// A read keeps only this many of the newest messages, full or incremental.
    static let maximumReadMessages = 100_000
    private static let sessionChunk = 400

    private static func text(_ path: String) -> String {
        "substr(json_extract(data, '\(path)'), 1, \(maximumStringCharacters))"
    }

    /// Selected only for rows whose `data` is valid JSON (`json_valid` runs in SQL), so one corrupt row
    /// cannot fail the whole read.
    private static let messageSelect = """
        SELECT id, session_id, time_created, time_updated,
            \(text("$.role")), \(text("$.parentID")), \(text("$.modelID")), \(text("$.providerID")),
            \(text("$.variant")), \(text("$.finish")), json_extract(data, '$.error.name') IS NOT NULL,
            json_extract(data, '$.time.created'), json_extract(data, '$.time.completed'),
            json_extract(data, '$.tokens.output'), json_extract(data, '$.tokens.reasoning'),
            json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.cache.read'),
            json_extract(data, '$.tokens.cache.write')
        FROM message
        """

    private let database: ReadOnlySQLiteDatabase

    init(url: URL) throws {
        database = try ReadOnlySQLiteDatabase(url: url)
    }

    func close() { database.close() }

    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try database.readTransaction(body)
    }

    /// The newest messages created at or after `milliseconds`, for a full read. More than `limit` in the
    /// window are not held in memory: the newest win.
    func messages(createdSince milliseconds: Int64, limit: Int = maximumReadMessages) throws -> [MessageRow] {
        try database.query(
            Self.messageSelect + " WHERE time_created >= ?1 AND json_valid(data) ORDER BY time_created DESC, id LIMIT \(limit)",
            bindings: [.integer(milliseconds)], map: Self.messageRow
        )
    }

    /// The newest messages updated at or after `updated` and created at or after `created`, for an
    /// incremental read. Bounded like a full read: more than `limit` are not held in memory, the newest
    /// created win, and the next full read applies the same bound.
    func messages(updatedSince updated: Int64, createdSince created: Int64, limit: Int = maximumReadMessages) throws -> [MessageRow] {
        try database.query(
            Self.messageSelect + " WHERE time_updated >= ?1 AND time_created >= ?2 AND json_valid(data) ORDER BY time_created DESC, id LIMIT \(limit)",
            bindings: [.integer(updated), .integer(created)], map: Self.messageRow
        )
    }

    /// The sessions with these ids; ids that do not exist are simply absent from the result.
    func sessions(ids: [String]) throws -> [SessionRow] {
        var result: [SessionRow] = []
        for start in stride(from: 0, to: ids.count, by: Self.sessionChunk) {
            let chunk = Array(ids[start..<min(start + Self.sessionChunk, ids.count)])
            let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ",")
            result += try database.query(
                "SELECT id, parent_id, version FROM session WHERE id IN (\(placeholders))",
                bindings: chunk.map { .text($0) }
            ) { row in
                guard let id = row.text(0) else { return nil }
                return SessionRow(id: id, parentID: row.text(1), version: row.text(2))
            }
        }
        return result
    }

    // MARK: Row mapping

    private static func messageRow(_ row: SQLiteRow) -> MessageRow? {
        guard let id = row.text(0), let sessionID = row.text(1),
              let timeCreated = row.int64(2), let timeUpdated = row.int64(3) else { return nil }
        return MessageRow(
            id: id, sessionID: sessionID, timeCreated: timeCreated, timeUpdated: timeUpdated,
            role: row.text(4), parentID: row.text(5), modelID: row.text(6), providerID: row.text(7),
            variant: row.text(8), finish: row.text(9), hasErrorName: (row.int64(10) ?? 0) != 0,
            created: integer(row, 11), completed: integer(row, 12), output: integer(row, 13),
            reasoning: integer(row, 14), input: integer(row, 15), cacheRead: integer(row, 16),
            cacheWrite: integer(row, 17)
        )
    }

    private static func integer(_ row: SQLiteRow, _ column: Int32) -> JSONInteger {
        if row.isNull(column) { return .absent }
        return row.int64(column).map(JSONInteger.value) ?? .invalid
    }
}
