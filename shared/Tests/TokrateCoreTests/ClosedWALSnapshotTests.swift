import Foundation
import SQLite3
import XCTest
@testable import TokrateCore

final class ClosedWALSnapshotTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func idleDatabase() throws -> URL {
        let path = root.appendingPathComponent("idle.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE counts(n INTEGER); INSERT INTO counts VALUES(42)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        // Some system SQLite builds persist empty sidecars. This fixture represents T3's closed
        // store after its own sidecar cleanup; remove only these task-owned fixture artifacts.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: path.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
        return path
    }
    func testIdleDatabaseUsesReadOnlyMemoryWithoutSourceArtifacts() throws {
        let path = try idleDatabase()
        let original = try Data(contentsOf: path)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let memory = try XCTUnwrap(ClosedWALSnapshot.open(path))
        defer { sqlite3_close(memory) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(memory, "SELECT n FROM counts", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), 42)
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_exec(memory, "INSERT INTO counts VALUES(9)", nil, nil, nil), SQLITE_READONLY)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), names)
    }
    func testAnySidecarIncludingDanglingSymlinksRejectsFallback() throws {
        let path = try idleDatabase()
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: path.path + suffix)
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: root.appendingPathComponent("missing"))
            XCTAssertNil(try ClosedWALSnapshot.open(path))
            try FileManager.default.removeItem(at: sidecar)
        }
    }
    func testMalformedAndOversizedFilesAreRefused() throws {
        let path = root.appendingPathComponent("invalid.db")
        try Data(repeating: 0, count: 200).write(to: path)
        XCTAssertNil(try ClosedWALSnapshot.open(path))
        let file = try FileHandle(forWritingTo: path)
        try file.truncate(atOffset: UInt64(ClosedWALSnapshot.maximumBytes + 1)); try file.close()
        XCTAssertNil(try ClosedWALSnapshot.open(path))
    }
}
