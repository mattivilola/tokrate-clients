import Foundation
import SQLite3
import XCTest
@testable import TokrateCore

/// A tiny protobuf encoder for building synthetic Antigravity blobs. Test-only: Tokrate itself only reads.
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    var data: Data { Data(bytes) }

    private mutating func rawVarint(_ value: UInt64) {
        var rest = value
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
    }

    private mutating func key(_ field: Int, wireType: UInt64) { rawVarint(UInt64(field) << 3 | wireType) }

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        rawVarint(value)
    }

    /// proto3 omits zero values: so does this.
    mutating func proto3Varint(_ field: Int, _ value: UInt64) {
        if value != 0 { varint(field, value) }
    }

    mutating func fixed32(_ field: Int, _ value: UInt32) {
        key(field, wireType: 5)
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    mutating func fixed64(_ field: Int, _ value: UInt64) {
        key(field, wireType: 1)
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
    }

    mutating func bytes(_ field: Int, _ payload: Data) {
        key(field, wireType: 2)
        rawVarint(UInt64(payload.count))
        bytes.append(contentsOf: payload)
    }

    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        build(&nested)
        bytes(field, nested.data)
    }

    /// A raw tag with an arbitrary wire type, for building invalid input.
    mutating func rawKey(_ field: Int, wireType: UInt64) { key(field, wireType: wireType) }
    mutating func rawBytes(_ raw: [UInt8]) { bytes.append(contentsOf: raw) }
}

/// An instant for synthetic data: whole seconds from a base plus a fraction.
struct SyntheticTime {
    static let base: Int64 = 1_790_000_000
    var seconds: Int64
    var nanos: UInt64 = 0

    init(_ offset: Double) {
        let whole = Int64(offset.rounded(.down))
        seconds = Self.base + whole
        nanos = UInt64(((offset - Double(whole)) * 1_000_000_000).rounded())
    }

    var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000) }

    func encode(_ field: Int, into writer: inout ProtoWriter) {
        writer.message(field) { message in
            message.proto3Varint(1, UInt64(seconds))
            message.proto3Varint(2, nanos)
        }
    }
}

/// One synthetic `steps` row. A step with `output` is a model call (it carries the usage message).
struct SyntheticStep {
    var execution: String?
    var created: Double?
    var completed: Double?
    var output: UInt64?
    var thinking: UInt64 = 0
    var input: UInt64 = 1_000
    var cacheRead: UInt64 = 10
    /// `nil` omits field 20 entirely, as Antigravity does for generation 0.
    var generation: UInt64?
    var hasSubtrajectory = false
    /// Replaces the encoded metadata (for malformed-blob tests).
    var rawMetadata: Data?

    var metadata: Data {
        if let rawMetadata { return rawMetadata }
        var writer = ProtoWriter()
        if let created { SyntheticTime(created).encode(1, into: &writer) }
        if let completed { SyntheticTime(completed).encode(7, into: &writer) }
        if let output {
            writer.message(9) { usage in
                usage.proto3Varint(2, input)
                usage.proto3Varint(3, output)
                usage.proto3Varint(5, cacheRead)
                usage.proto3Varint(9, thinking)
            }
        }
        if let execution { writer.string(12, execution) }
        if let generation {
            writer.message(20) { $0.proto3Varint(3, generation) }
        }
        return writer.data
    }
}

/// A synthetic conversation database with the real table layout. Every operation opens and closes its own
/// handle unless `keepOpen` is set (needed to keep a write-ahead log alive).
final class SyntheticAntigravityDatabase {
    let url: URL
    private var held: OpaquePointer?

    static let schema = [
        "CREATE TABLE `trajectory_meta` (`trajectory_id` text,`cascade_id` text,`trajectory_type` integer,`source` integer,PRIMARY KEY (`trajectory_id`))",
        "CREATE TABLE `steps` (`idx` integer,`step_type` integer NOT NULL DEFAULT 0,`status` integer NOT NULL DEFAULT 0,`has_subtrajectory` numeric NOT NULL DEFAULT false,`metadata` blob,`error_details` blob,`permissions` blob,`task_details` blob,`render_info` blob,`step_payload` blob,`step_format` integer NOT NULL DEFAULT 0,PRIMARY KEY (`idx`))",
        "CREATE TABLE `gen_metadata` (`idx` integer,`data` blob,`size` integer NOT NULL DEFAULT 0,PRIMARY KEY (`idx`))",
        "CREATE TABLE `executor_metadata` (`idx` integer,`data` blob,PRIMARY KEY (`idx`))",
        "CREATE TABLE `parent_references` (`idx` integer,`data` blob,PRIMARY KEY (`idx`))",
        "CREATE TABLE `trajectory_metadata_blob` (`id` text DEFAULT \"main\",`data` blob,PRIMARY KEY (`id`))",
        "CREATE TABLE `battle_mode_infos` (`idx` integer,`data` blob,PRIMARY KEY (`idx`))"
    ]

    /// The text that must never be read: stored in the columns Tokrate does not select.
    static let privateText = "PRIVATE_PROMPT_TEXT"

    private var nextStep = 0
    private var nextExecutor = 0
    private var nextParent = 0

    init(url: URL, writeAheadLog: Bool = false) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withConnection { database in
            if writeAheadLog { try Self.run(database, "PRAGMA journal_mode=WAL") }
            for statement in Self.schema { try Self.run(database, statement) }
            try Self.run(database, "INSERT INTO trajectory_metadata_blob (id, data) VALUES ('main', x'\(Data(Self.privateText.utf8).map { String(format: "%02x", $0) }.joined())')")
        }
        if writeAheadLog { held = try Self.open(url) }
    }

    deinit { if let held { sqlite3_close(held) } }

    func addStep(_ step: SyntheticStep) throws {
        let index = nextStep
        nextStep += 1
        try withConnection { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO steps (idx, has_subtrajectory, metadata, step_payload) VALUES (?1, ?2, ?3, ?4)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(index))
            sqlite3_bind_int(statement, 2, step.hasSubtrajectory ? 1 : 0)
            Self.bind(statement, 3, step.metadata)
            Self.bind(statement, 4, Data(Self.privateText.utf8))
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }

    func addExecutor(id: String, state: UInt64, variant: String?) throws {
        try addExecutorBlob(Self.executorBlob(id: id, state: state, variant: variant))
    }

    func addExecutorBlob(_ blob: Data) throws {
        let index = nextExecutor
        nextExecutor += 1
        try insert("INSERT INTO executor_metadata (idx, data) VALUES (?1, ?2)", Int64(index), blob)
    }

    func setExecutor(id: String, state: UInt64, variant: String?, at index: Int = 0) throws {
        try insert("REPLACE INTO executor_metadata (idx, data) VALUES (?1, ?2)", Int64(index), Self.executorBlob(id: id, state: state, variant: variant))
    }

    /// `nonGemini` nil omits the key/value pair.
    func addGeneration(index: Int64, model: String, nonGemini: String? = "false") throws {
        try insert("REPLACE INTO gen_metadata (idx, data, size) VALUES (?1, ?2, 0)", index, Self.generationBlob(model: model, nonGemini: nonGemini))
    }

    func addGenerationBlob(index: Int64, _ blob: Data) throws {
        try insert("REPLACE INTO gen_metadata (idx, data, size) VALUES (?1, ?2, 0)", index, blob)
    }

    func addParentReference() throws {
        let index = nextParent
        nextParent += 1
        try insert("INSERT INTO parent_references (idx, data) VALUES (?1, ?2)", Int64(index), Data([0x0A, 0x01, 0x41]))
    }

    /// Rewrites one step's metadata, as Antigravity does when a step completes.
    func replaceStep(at index: Int, with step: SyntheticStep) throws {
        try withConnection { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "UPDATE steps SET metadata = ?2, has_subtrajectory = ?3 WHERE idx = ?1", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(index))
            Self.bind(statement, 2, step.metadata)
            sqlite3_bind_int(statement, 3, step.hasSubtrajectory ? 1 : 0)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }

    // MARK: Blobs

    static func executorBlob(id: String, state: UInt64, variant: String?) -> Data {
        var writer = ProtoWriter()
        writer.proto3Varint(1, state)
        writer.string(9, id)
        if let variant {
            writer.message(10) { selection in
                selection.message(1) { $0.string(28, variant) }
            }
        }
        writer.string(7, Self.privateText)
        return writer.data
    }

    static func generationBlob(model: String, nonGemini: String?) -> Data {
        var writer = ProtoWriter()
        writer.message(1) { generation in
            generation.string(19, model)
            generation.message(20) { pair in
                pair.string(1, "some_other_key")
                pair.string(2, "value")
            }
            if let nonGemini {
                generation.message(20) { pair in
                    pair.string(1, "used_non_gemini_model")
                    pair.string(2, nonGemini)
                }
            }
        }
        return writer.data
    }

    // MARK: SQLite plumbing

    private func insert(_ sql: String, _ index: Int64, _ blob: Data) throws {
        try withConnection { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, index)
            Self.bind(statement, 2, blob)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }

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

    private static func bind(_ statement: OpaquePointer?, _ position: Int32, _ data: Data) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
    }
}
