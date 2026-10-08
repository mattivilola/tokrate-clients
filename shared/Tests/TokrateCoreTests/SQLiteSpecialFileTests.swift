import Foundation
import XCTest
@testable import TokrateCore

/// SQLite opens a database and its `-wal` itself, blocking, so a FIFO with either name must be refused
/// before SQLite sees it: otherwise the poll stalls and every source behind it with it.
final class SQLiteSpecialFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tokrate-sqlite-special-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFIFO(_ url: URL) {
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
    }

    func testADatabaseOrLogThatIsNotARegularFileIsRefusedWithoutBeingOpened() throws {
        let url = root.appendingPathComponent("plain.db")
        _ = try SyntheticOpenCodeDatabase(url: url)
        XCTAssertNoThrow(try ReadOnlySQLiteDatabase(url: url).close())

        let log = URL(fileURLWithPath: url.path + "-wal")
        makeFIFO(log)
        XCTAssertThrowsError(try ReadOnlySQLiteDatabase(url: url)) { error in
            guard case ReadOnlySQLiteDatabase.DatabaseError.notRegularFile = error else { return XCTFail("\(error)") }
        }
        try FileManager.default.removeItem(at: log)
        // A directory named like the log is refused too; an absent log is fine.
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ReadOnlySQLiteDatabase(url: url))
        try FileManager.default.removeItem(at: log)
        XCTAssertNoThrow(try ReadOnlySQLiteDatabase(url: url).close())

        let fifoDatabase = root.appendingPathComponent("fifo.db")
        makeFIFO(fifoDatabase)
        XCTAssertThrowsError(try ReadOnlySQLiteDatabase(url: fifoDatabase))
        XCTAssertThrowsError(try ReadOnlySQLiteDatabase(url: root.appendingPathComponent("missing.db")))
    }

    func testASymbolicLinkToARegularDatabaseIsFollowed() throws {
        let url = root.appendingPathComponent("real.db")
        _ = try SyntheticOpenCodeDatabase(url: url)
        let link = root.appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertNoThrow(try ReadOnlySQLiteDatabase(url: link).close())
    }

    func testOpenCodeSkipsADatabaseWhoseLogIsAFIFOAndReadsItOnceARegularFileReplacesIt() async throws {
        let database = try SyntheticOpenCodeDatabase(url: OpenCodeMonitor.databaseURL(root: root))
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        let log = URL(fileURLWithPath: OpenCodeMonitor.databaseURL(root: root).path + "-wal")
        makeFIFO(log)

        let monitor = OpenCodeMonitor(root: root)
        let start = SyntheticOpenCodeDatabase.date(100)
        // Would block forever if SQLite were to open the FIFO.
        let update = await monitor.poll(now: start)
        XCTAssertTrue(update.metrics.isEmpty)
        let failed = await monitor.nextPollDeadline(now: start)
        XCTAssertNotNil(failed, "the database is unread and waits for its retry")

        try FileManager.default.removeItem(at: log)
        try Data().write(to: log)
        // Once the retry time has passed the replaced log is a change and the database is read.
        _ = await monitor.poll(now: start.addingTimeInterval(20))
        let recovered = await monitor.nextPollDeadline(now: start.addingTimeInterval(20))
        XCTAssertNil(recovered, "the database was read")
        let reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 2)
    }

    func testAntigravitySkipsADatabaseWhoseLogIsAFIFOAndReadsItOnceARegularFileReplacesIt() async throws {
        let url = root.appendingPathComponent("antigravity/conversations/11111111-2222-3333-4444-555555555555.db")
        let database = try SyntheticAntigravityDatabase(url: url)
        try database.addStep(SyntheticStep(execution: "exec", created: 1, completed: 2))
        let log = URL(fileURLWithPath: url.path + "-wal")
        makeFIFO(log)

        let monitor = AntigravityConversationMonitor(root: root)
        let start = Date.now
        let update = await monitor.poll(now: start)
        XCTAssertTrue(update.metrics.isEmpty)
        let failed = await monitor.nextPollDeadline(now: start)
        XCTAssertNotNil(failed, "the database is unread and waits for its retry")

        try FileManager.default.removeItem(at: log)
        try Data().write(to: log)
        _ = await monitor.poll(now: start.addingTimeInterval(20))
        let recovered = await monitor.nextPollDeadline(now: start.addingTimeInterval(20))
        XCTAssertNil(recovered, "the database was read")
        let reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 2)
    }
}
