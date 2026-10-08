import Foundation
import XCTest
@testable import TokrateCore

/// The row, value and byte bounds of one OpenCode read (`OpenCodeDatabase`), the same as the
/// Windows/Linux core's.
final class OpenCodeDatabaseBoundsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tokrate-opencode-bounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDatabase() throws -> SyntheticOpenCodeDatabase {
        try SyntheticOpenCodeDatabase(url: OpenCodeMonitor.databaseURL(root: root))
    }

    private func reader() throws -> OpenCodeDatabase { try OpenCodeDatabase(url: OpenCodeMonitor.databaseURL(root: root)) }
    private func long(_ length: Int) -> String { String(repeating: "x", count: length) }

    private func assistant(_ id: String, session: String = "ses_primary", _ configure: (inout SyntheticOpenCodeMessage) -> Void = { _ in }) -> SyntheticOpenCodeMessage {
        var message = SyntheticOpenCodeMessage(id: id, session: session, parentID: "msg_user", created: 1, completed: 5, output: 10, input: 100, cacheRead: 0, cacheWrite: 0, finish: "stop")
        configure(&message)
        return message
    }

    func testTheBoundsMatchTheWindowsAndLinuxCore() {
        XCTAssertEqual(OpenCodeDatabase.maximumIdentifierCharacters, 512)
        XCTAssertEqual(OpenCodeDatabase.maximumValueCharacters, 200)
        XCTAssertEqual(OpenCodeDatabase.maximumReadBytes, 64 * 1_048_576)
    }

    func testIdsAndValuesOverTheirLimitNeverLeaveSQLite() throws {
        let database = try makeDatabase()
        try database.addSession("ses_primary")
        try database.addSession(long(513))
        try database.addSession("ses_long_parent", parent: long(513))
        try database.addSession("ses_long_version", parent: "ses_primary", version: long(201))
        try database.addSession("ses_edge", parent: long(512), version: long(200))
        try database.addSession("ses_empty_parent")
        try database.execute("UPDATE session SET parent_id = '' WHERE id = 'ses_empty_parent'")

        try database.put(assistant("msg_ok"))
        try database.put(assistant(long(513)))
        try database.put(assistant(long(512)))
        try database.put(assistant("msg_session", session: long(513)))
        try database.put(assistant("msg_values") {
            $0.parentID = long(513)
            $0.model = long(201)
            $0.provider = long(201)
            $0.variant = long(201)
            $0.finish = long(201)
        })
        try database.put(assistant("msg_edge") { $0.model = long(200); $0.parentID = long(512) })
        try database.put(assistant("msg_error") { $0.errorName = long(201) })
        try database.put(assistant("msg_unnamed_error") { $0.extra = ["error": ["name": ""]] })
        try database.put(assistant("msg_count") { $0.rawTokens = ["output": long(201), "reasoning": 0]; $0.output = nil })
        try database.put(assistant("msg_role") { $0.rawData = "{\"role\":\"\(long(201))\"}" })

        let reader = try reader()
        defer { reader.close() }
        let messages = try reader.messages(createdSince: 0)
        func message(_ id: String) -> OpenCodeDatabase.MessageRow? { messages.first { $0.id == id } }

        XCTAssertNotNil(message("msg_ok"))
        XCTAssertNotNil(message(long(512)))
        XCTAssertNil(message(long(513)))
        XCTAssertNil(message("msg_session"), "a message of a session whose id is too long is skipped")
        // Over-long text is absent, an over-long count is invalid rather than zero.
        let values = try XCTUnwrap(message("msg_values"))
        XCTAssertNil(values.parentID)
        XCTAssertNil(values.modelID)
        XCTAssertNil(values.providerID)
        XCTAssertNil(values.variant)
        XCTAssertNil(values.finish)
        let edge = try XCTUnwrap(message("msg_edge"))
        XCTAssertEqual(edge.modelID?.count, 200)
        XCTAssertEqual(edge.parentID?.count, 512)
        XCTAssertTrue(try XCTUnwrap(message("msg_error")).hasErrorName, "an over-long error name still marks the message failed")
        XCTAssertFalse(try XCTUnwrap(message("msg_unnamed_error")).hasErrorName)
        XCTAssertEqual(try XCTUnwrap(message("msg_count")).output, .invalid)
        XCTAssertNil(message("msg_role")?.role, "an over-long role reads as absent")

        let sessions = try reader.sessions(ids: [
            "ses_primary", long(513), "ses_long_parent", "ses_long_version", "ses_edge", "ses_empty_parent"
        ])
        XCTAssertEqual(sessions.map(\.id).sorted(), ["ses_edge", "ses_empty_parent", "ses_long_version", "ses_primary"],
                       "a session with an over-long id or parent id is skipped")
        func session(_ id: String) throws -> OpenCodeDatabase.SessionRow { try XCTUnwrap(sessions.first { $0.id == id }) }
        XCTAssertEqual(try session("ses_long_version").version, "", "an over-long version is only empty")
        XCTAssertEqual(try session("ses_edge").version?.count, 200)
        XCTAssertEqual(try session("ses_edge").parentID?.count, 512)
        XCTAssertNil(try session("ses_empty_parent").parentID, "an empty parent id is no parent")
    }

    func testAReadStopsAtItsByteBudgetAndKeepsTheNewestMessages() throws {
        let database = try makeDatabase()
        try database.addSession("ses_primary")
        for index in 0..<100 {
            try database.put(assistant(String(format: "msg_%03d", index)) {
                $0.created = Double(index)
                $0.completed = Double(index) + 1
                $0.model = String(format: "model-%03d", index)
            })
        }
        let reader = try reader()
        defer { reader.close() }
        let since = SyntheticOpenCodeDatabase.milliseconds(0)
        XCTAssertEqual(try reader.messages(createdSince: since).count, 100)
        let small = try reader.messages(createdSince: since, maximumBytes: 1_000)
        let larger = try reader.messages(createdSince: since, maximumBytes: 2_000)
        XCTAssertGreaterThan(small.count, 1)
        XCTAssertLessThan(small.count, 100)
        XCTAssertGreaterThan(larger.count, small.count)
        // The newest are kept.
        XCTAssertEqual(small.first?.id, "msg_099")
        XCTAssertEqual(small.map(\.id), (0..<small.count).map { String(format: "msg_%03d", 99 - $0) })
        XCTAssertEqual(try reader.messages(createdSince: since, maximumBytes: 0).count, 0)
        XCTAssertEqual(
            try reader.messages(updatedSince: 0, createdSince: since, maximumBytes: 1_000).map(\.id), small.map(\.id),
            "an incremental read has the same budget"
        )
    }
}
