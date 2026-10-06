import Foundation
import SQLite3
import XCTest
@testable import TokrateCore

/// One synthetic `message` row. Times are offsets in seconds from `SyntheticOpenCodeDatabase.base`.
struct SyntheticOpenCodeMessage {
    var id: String
    var session: String
    var role = "assistant"
    var parentID: String?
    var created: Double
    var completed: Double?
    /// The `time_updated` column; by default one second after the database's latest update, as OpenCode's
    /// wall-clock `time_updated` only moves forward.
    var updated: Double?
    var output: Int?
    var reasoning: Int?
    var input: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
    var model: String? = "claude-sonnet-4-5"
    var provider: String? = "anthropic"
    var finish: String?
    var errorName: String?
    var variant: String?
    /// Replaces the encoded JSON (for malformed-row tests).
    var rawData: String?
    /// Extra top-level values, to prove nothing outside the contract's paths is read.
    var extra: [String: Any] = [:]

    /// A JSON number written as a fraction or a string, for malformed-count tests.
    var rawTokens: [String: Any]?

    var data: String {
        if let rawData { return rawData }
        var object: [String: Any] = ["role": role]
        if let parentID { object["parentID"] = parentID }
        var time: [String: Any] = ["created": SyntheticOpenCodeDatabase.milliseconds(created)]
        if let completed { time["completed"] = SyntheticOpenCodeDatabase.milliseconds(completed) }
        object["time"] = time
        if role == "assistant" {
            if let model { object["modelID"] = model }
            if let provider { object["providerID"] = provider }
            if let variant { object["variant"] = variant }
            if let finish { object["finish"] = finish }
            if let errorName { object["error"] = ["name": errorName, "data": ["message": SyntheticOpenCodeDatabase.privateText]] }
            var tokens: [String: Any] = rawTokens ?? [:]
            if let output { tokens["output"] = output }
            if let reasoning { tokens["reasoning"] = reasoning }
            if let input { tokens["input"] = input }
            var cache: [String: Any] = [:]
            if let cacheRead { cache["read"] = cacheRead }
            if let cacheWrite { cache["write"] = cacheWrite }
            if !cache.isEmpty { tokens["cache"] = cache }
            if !tokens.isEmpty { object["tokens"] = tokens }
            object["path"] = ["cwd": SyntheticOpenCodeDatabase.privateText, "root": "/"]
        } else {
            object["agent"] = "build"
            object["model"] = ["providerID": provider ?? "anthropic", "modelID": model ?? "m"]
            object["summary"] = ["title": SyntheticOpenCodeDatabase.privateText]
        }
        for (key, value) in extra { object[key] = value }
        let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

}

/// A synthetic `opencode.db` with the real Drizzle tables (`session`, `message`, `part`, `project`
/// copied from OpenCode 1.18.31 with `.schema`). Every operation opens and closes its own handle unless
/// the write-ahead log is kept alive.
final class SyntheticOpenCodeDatabase {
    static let base: Int64 = 1_790_000_000
    /// Text that must never be read: stored in `part`, in titles and in message JSON outside the contract's paths.
    static let privateText = "PRIVATE_PROMPT_TEXT"

    static func milliseconds(_ offset: Double) -> Int64 { base * 1_000 + Int64((offset * 1_000).rounded()) }
    static func date(_ offset: Double) -> Date { Date(timeIntervalSince1970: Double(milliseconds(offset)) / 1_000) }

    let url: URL
    private var held: OpaquePointer?

    static let schema = [
        """
        CREATE TABLE `session` (
        \t`id` text PRIMARY KEY,
        \t`project_id` text NOT NULL,
        \t`parent_id` text,
        \t`slug` text NOT NULL,
        \t`directory` text NOT NULL,
        \t`title` text NOT NULL,
        \t`version` text NOT NULL,
        \t`share_url` text,
        \t`summary_additions` integer,
        \t`summary_deletions` integer,
        \t`summary_files` integer,
        \t`summary_diffs` text,
        \t`revert` text,
        \t`permission` text,
        \t`time_created` integer NOT NULL,
        \t`time_updated` integer NOT NULL,
        \t`time_compacting` integer,
        \t`time_archived` integer, `workspace_id` text, `path` text, `agent` text, `model` text, `cost` real DEFAULT 0 NOT NULL, `tokens_input` integer DEFAULT 0 NOT NULL, `tokens_output` integer DEFAULT 0 NOT NULL, `tokens_reasoning` integer DEFAULT 0 NOT NULL, `tokens_cache_read` integer DEFAULT 0 NOT NULL, `tokens_cache_write` integer DEFAULT 0 NOT NULL, `metadata` text,
        \tCONSTRAINT `fk_session_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX `session_project_idx` ON `session` (`project_id`)",
        "CREATE INDEX `session_parent_idx` ON `session` (`parent_id`)",
        "CREATE INDEX `session_workspace_idx` ON `session` (`workspace_id`)",
        """
        CREATE TABLE `message` (
        \t`id` text PRIMARY KEY,
        \t`session_id` text NOT NULL,
        \t`time_created` integer NOT NULL,
        \t`time_updated` integer NOT NULL,
        \t`data` text NOT NULL,
        \tCONSTRAINT `fk_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX `message_session_time_created_id_idx` ON `message` (`session_id`,`time_created`,`id`)",
        """
        CREATE TABLE `part` (
        \t`id` text PRIMARY KEY,
        \t`message_id` text NOT NULL,
        \t`session_id` text NOT NULL,
        \t`time_created` integer NOT NULL,
        \t`time_updated` integer NOT NULL,
        \t`data` text NOT NULL,
        \tCONSTRAINT `fk_part_message_id_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `message`(`id`) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX `part_session_idx` ON `part` (`session_id`)",
        "CREATE INDEX `part_message_id_id_idx` ON `part` (`message_id`,`id`)",
        """
        CREATE TABLE `project` (
        \t`id` text PRIMARY KEY,
        \t`worktree` text NOT NULL,
        \t`vcs` text,
        \t`name` text,
        \t`icon_url` text,
        \t`icon_color` text,
        \t`time_created` integer NOT NULL,
        \t`time_updated` integer NOT NULL,
        \t`time_initialized` integer,
        \t`sandboxes` text NOT NULL
        , `commands` text, `icon_url_override` text)
        """
    ]

    private var partCount = 0
    /// The latest `time_updated` written, in offset seconds.
    private var clock: Double = 0

    init(url: URL, writeAheadLog: Bool = false) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withConnection { database in
            if writeAheadLog { try Self.run(database, "PRAGMA journal_mode=WAL") }
            for statement in Self.schema { try Self.run(database, statement) }
            try Self.run(database, "INSERT INTO project (id, worktree, time_created, time_updated, sandboxes) VALUES ('proj', '/tmp/\(Self.privateText)', 0, 0, '[]')")
        }
        if writeAheadLog { held = try Self.open(url) }
    }

    deinit { if let held { sqlite3_close(held) } }

    func addSession(_ id: String, parent: String? = nil, version: String = "1.18.31", created: Double = 0) throws {
        try withConnection { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated) VALUES (?1, 'proj', ?2, 'slug', ?3, ?3, ?4, ?5, ?5)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            Self.bindText(statement, 1, id)
            if let parent { Self.bindText(statement, 2, parent) } else { sqlite3_bind_null(statement, 2) }
            Self.bindText(statement, 3, Self.privateText)
            Self.bindText(statement, 4, version)
            sqlite3_bind_int64(statement, 5, Self.milliseconds(created))
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }

    func setSessionVersion(_ id: String, _ version: String) throws {
        try execute("UPDATE session SET version = '\(version)' WHERE id = '\(id)'")
    }

    /// Inserts or replaces a message; a replacement is how OpenCode updates a message as it streams.
    func put(_ message: SyntheticOpenCodeMessage) throws {
        try withConnection { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data) VALUES (?1, ?2, ?3, ?4, ?5)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            Self.bindText(statement, 1, message.id)
            Self.bindText(statement, 2, message.session)
            sqlite3_bind_int64(statement, 3, SyntheticOpenCodeDatabase.milliseconds(message.created))
            let updated = message.updated ?? max(clock, message.completed ?? message.created) + 1
            clock = max(clock, updated)
            sqlite3_bind_int64(statement, 4, SyntheticOpenCodeDatabase.milliseconds(updated))
            Self.bindText(statement, 5, message.data)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        partCount += 1
        try execute("INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_\(partCount)', '\(message.id)', '\(message.session)', 0, 0, '{\"text\":\"\(Self.privateText)\"}')")
    }

    func deleteMessage(_ id: String) throws {
        try execute("DELETE FROM message WHERE id = '\(id)'")
    }

    func execute(_ sql: String) throws {
        try withConnection { try Self.run($0, sql) }
    }

    // MARK: Convenience builders

    func user(_ id: String, session: String, at created: Double) throws {
        try put(SyntheticOpenCodeMessage(id: id, session: session, role: "user", created: created, completed: nil, updated: created))
    }

    // MARK: SQLite plumbing

    private func withConnection(_ body: (OpaquePointer) throws -> Void) throws {
        if let held { try body(held); return }
        let database = try Self.open(url)
        defer { sqlite3_close(database) }
        try body(database)
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        return database
    }

    private static func run(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func bindText(_ statement: OpaquePointer?, _ position: Int32, _ text: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, position, text, -1, transient)
    }
}
