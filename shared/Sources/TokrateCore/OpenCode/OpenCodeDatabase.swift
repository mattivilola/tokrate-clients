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

    /// Longest role, model, provider, variant, finish, error name, version or number read, in
    /// characters. Nothing legitimate is longer; longer text reads as absent (a number as invalid).
    static let maximumValueCharacters = 200
    /// Longest row id, session id or parent id read, in characters. A message or session with a longer
    /// one is skipped; a longer parent id never reads as "no parent", which would turn a subagent
    /// session into a primary one.
    static let maximumIdentifierCharacters = 512
    /// A read keeps only this many of the newest messages, full or incremental.
    static let maximumReadMessages = 100_000
    /// A read stops after this many bytes of values, keeping the newest messages like
    /// `maximumReadMessages` does.
    static let maximumReadBytes = 64 * 1_048_576
    /// Session rows one read may hold, read as ancestors of the messages' sessions.
    static let maximumReadSessions = 100_000
    /// How many generations of ancestors of a session are looked up (subagent chains are short).
    static let maximumAncestorRounds = 16
    private static let sessionChunk = 400
    private static let messageColumnCount: Int32 = 18

    /// The values of a message row. Each JSON path is extracted once, here, and bounded where the result
    /// is selected by `messageColumns`; the `data` text itself is never loaded.
    private static let messageFields = """
        m.id AS id, m.session_id AS session_id, m.time_created AS time_created, m.time_updated AS time_updated,
        json_extract(m.data, '$.role') AS role, json_extract(m.data, '$.parentID') AS parent_id,
        json_extract(m.data, '$.modelID') AS model, json_extract(m.data, '$.providerID') AS provider,
        json_extract(m.data, '$.variant') AS variant, json_extract(m.data, '$.finish') AS finish,
        json_extract(m.data, '$.error.name') AS error_name,
        json_extract(m.data, '$.time.created') AS created, json_extract(m.data, '$.time.completed') AS completed,
        json_extract(m.data, '$.tokens.output') AS output, json_extract(m.data, '$.tokens.reasoning') AS reasoning,
        json_extract(m.data, '$.tokens.input') AS input, json_extract(m.data, '$.tokens.cache.read') AS cache_read,
        json_extract(m.data, '$.tokens.cache.write') AS cache_write
        """

    /// The columns `messageRow` reads, each bounded: text is NULL when longer than
    /// `maximumValueCharacters` (a parent id: `maximumIdentifierCharacters`), and a number longer than
    /// that is an empty string, which is not a number, so a value too long to be one stays invalid
    /// instead of reading as absent.
    private static let messageColumns: String = {
        func text(_ column: String, _ maximum: Int) -> String { "CASE WHEN length(\(column)) <= \(maximum) THEN \(column) END" }
        func number(_ column: String) -> String {
            "CASE WHEN \(column) IS NULL OR length(\(column)) <= \(maximumValueCharacters) THEN \(column) ELSE '' END"
        }
        func integer(_ column: String) -> String { "CASE WHEN typeof(\(column)) = 'integer' THEN \(column) END" }
        return [
            "id", "session_id", integer("time_created"), integer("time_updated"),
            text("role", maximumValueCharacters), text("parent_id", maximumIdentifierCharacters),
            text("model", maximumValueCharacters), text("provider", maximumValueCharacters),
            text("variant", maximumValueCharacters), text("finish", maximumValueCharacters),
            // Only whether a non-empty name is present is used.
            "CASE WHEN typeof(error_name) = 'text' AND length(error_name) > 0 THEN 1 ELSE 0 END",
            number("created"), number("completed"), number("output"), number("reasoning"),
            number("input"), number("cache_read"), number("cache_write")
        ].joined(separator: ", ")
    }()

    /// Selected only for rows whose `data` is valid JSON (`json_valid` runs in SQL), so one corrupt row
    /// cannot fail the whole read, and whose ids are within bounds, newest created first.
    private static func messageSelect(filter: String, limit: Int) -> String {
        """
        SELECT \(messageColumns) FROM (
            SELECT \(messageFields) FROM message m
            WHERE \(filter) AND json_valid(m.data)
                AND length(m.id) <= \(maximumIdentifierCharacters) AND length(m.session_id) <= \(maximumIdentifierCharacters)
            ORDER BY m.time_created DESC, m.id LIMIT \(limit)
        ) ORDER BY time_created DESC, id
        """
    }

    private let database: ReadOnlySQLiteDatabase

    init(url: URL) throws {
        database = try ReadOnlySQLiteDatabase(url: url)
    }

    func close() { database.close() }

    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try database.readTransaction(body)
    }

    /// What one read may hold: values up to `bytes` in all (messages and sessions together), at most
    /// `messages` message rows and `sessions` session rows, whether found as the sessions of the
    /// messages or as their ancestors.
    struct Limits: Sendable {
        var bytes = OpenCodeDatabase.maximumReadBytes
        var messages = OpenCodeDatabase.maximumReadMessages
        var sessions = OpenCodeDatabase.maximumReadSessions
    }

    /// Which messages a read takes.
    enum Scope: Sendable {
        /// Everything created at or after this time (milliseconds since the epoch).
        case createdSince(Int64)
        /// Everything updated at or after `updated`, restricted to messages created at or after `created`.
        case updatedSince(Int64, createdSince: Int64)
    }

    /// What one read returned.
    struct Read: Sendable {
        var messages: [MessageRow] = []
        /// The sessions of the messages that `known` lacked, and their ancestors.
        var sessions: [SessionRow] = []
        /// Approximate bytes of values read.
        var bytesRead = 0
    }

    /// The newest messages of `scope` within `limits`, then the sessions they name that `known` lacks
    /// and those sessions' ancestors, until nothing is missing, `maximumAncestorRounds` rounds have
    /// passed or a limit is reached. One budget covers every round.
    func read(_ scope: Scope, known: Set<String> = [], limits: Limits = Limits()) throws -> Read {
        var read = Read()
        let (messages, bytes) = try readMessages(scope, limits: limits)
        read.messages = messages
        read.bytesRead = bytes
        // Every id asked for once is remembered, so a shared ancestor is asked for once.
        var asked = Set<String>()
        var wanted: [String] = []
        for message in messages where !known.contains(message.sessionID) && asked.insert(message.sessionID).inserted {
            wanted.append(message.sessionID)
        }
        for _ in 0..<Self.maximumAncestorRounds where !wanted.isEmpty {
            let firstNew = read.sessions.count
            try readSessions(ids: wanted, into: &read, limits: limits)
            wanted = read.sessions[firstNew...]
                .compactMap(\.parentID)
                .filter { !known.contains($0) && asked.insert($0).inserted }
                .sorted()
        }
        return read
    }

    /// The newest messages created at or after `milliseconds`, for a full read. More than `limit` in the
    /// window, or than `maximumBytes` of values, are not held in memory: the newest win.
    func messages(
        createdSince milliseconds: Int64, limit: Int = maximumReadMessages, maximumBytes: Int = maximumReadBytes
    ) throws -> [MessageRow] {
        try readMessages(.createdSince(milliseconds), limits: Limits(bytes: maximumBytes, messages: limit)).rows
    }

    /// The newest messages updated at or after `updated` and created at or after `created`, for an
    /// incremental read. Bounded like a full read, and the next full read applies the same bound.
    func messages(
        updatedSince updated: Int64, createdSince created: Int64, limit: Int = maximumReadMessages,
        maximumBytes: Int = maximumReadBytes
    ) throws -> [MessageRow] {
        try readMessages(.updatedSince(updated, createdSince: created), limits: Limits(bytes: maximumBytes, messages: limit)).rows
    }

    private func readMessages(_ scope: Scope, limits: Limits) throws -> (rows: [MessageRow], bytes: Int) {
        let sql: String, bindings: [SQLiteValue]
        switch scope {
        case .createdSince(let created):
            sql = Self.messageSelect(filter: "m.time_created >= ?1", limit: limits.messages)
            bindings = [.integer(created)]
        case .updatedSince(let updated, let created):
            sql = Self.messageSelect(filter: "m.time_updated >= ?1 AND m.time_created >= ?2", limit: limits.messages)
            bindings = [.integer(updated), .integer(created)]
        }
        var rows: [MessageRow] = []
        var bytes = 0
        try database.forEachRow(sql, bindings: bindings) { row in
            if rows.count >= limits.messages || bytes >= limits.bytes { return .stop }
            bytes += row.approximateBytes(columns: Self.messageColumnCount)
            if let message = Self.messageRow(row) { rows.append(message) }
            return .next
        }
        return (rows, bytes)
    }

    /// The sessions with these ids; ids that do not exist are simply absent from the result. A session
    /// whose id or parent id is too long is skipped, and so are its messages. A version that is too long
    /// reads as empty: the session stays in the tree but is not measured.
    func sessions(ids: [String]) throws -> [SessionRow] {
        var read = Read()
        try readSessions(ids: ids, into: &read, limits: Limits())
        return read.sessions
    }

    /// Appends the sessions with these ids to `read` until a limit is reached.
    private func readSessions(ids: [String], into read: inout Read, limits: Limits) throws {
        func exhausted(_ read: Read) -> Bool { read.sessions.count >= limits.sessions || read.bytesRead >= limits.bytes }
        for start in stride(from: 0, to: ids.count, by: Self.sessionChunk) {
            if exhausted(read) { return }
            let chunk = Array(ids[start..<min(start + Self.sessionChunk, ids.count)])
            let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ",")
            var found: [SessionRow] = []
            var bytes = read.bytesRead
            var count = read.sessions.count
            try database.forEachRow(
                """
                SELECT id, CASE WHEN typeof(parent_id) = 'text' THEN parent_id END,
                    CASE WHEN typeof(version) = 'text' THEN
                        CASE WHEN length(version) <= \(Self.maximumValueCharacters) THEN version ELSE '' END END
                FROM session WHERE typeof(id) = 'text' AND length(id) <= \(Self.maximumIdentifierCharacters)
                    AND (typeof(parent_id) != 'text' OR length(parent_id) <= \(Self.maximumIdentifierCharacters))
                    AND id IN (\(placeholders))
                """,
                bindings: chunk.map { .text($0) }
            ) { row in
                if count >= limits.sessions || bytes >= limits.bytes { return .stop }
                guard let id = row.text(0) else { return .next }
                // An empty parent id is no parent.
                let session = SessionRow(id: id, parentID: row.text(1).flatMap { $0.isEmpty ? nil : $0 }, version: row.text(2))
                bytes += id.utf8.count + (session.version?.utf8.count ?? 0) + 16
                count += 1
                found.append(session)
                return .next
            }
            read.sessions += found
            read.bytesRead = bytes
        }
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
