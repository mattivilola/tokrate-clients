import Foundation
import XCTest
@testable import TokrateCore

/// Files written by other tools are opened without blocking or following links, and only regular files are read.
final class RegularFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tokrate-regular-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeFIFO(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        return url
    }

    func testARegularFileIsReadInFull() throws {
        let url = folder.appendingPathComponent("usage.json")
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(try RegularFile.read(url, maximumBytes: 2), Data("{}".utf8), "a file exactly at the cap is read")
    }

    func testAFileAboveTheCapIsRefusedAfterReadingAtMostOneByteMore() throws {
        let url = folder.appendingPathComponent("usage.json")
        try Data(repeating: 0x61, count: 11).write(to: url)
        XCTAssertThrowsError(try RegularFile.read(url, maximumBytes: 10)) { XCTAssertEqual($0 as? RegularFile.Failure, .tooLarge) }
    }

    func testAFIFOIsRefusedInsteadOfBlockingTheReader() throws {
        let url = try makeFIFO("events.jsonl")
        XCTAssertThrowsError(try RegularFile.open(url)) { XCTAssertEqual($0 as? RegularFile.Failure, .notRegular) }
        XCTAssertThrowsError(try RegularFile.read(url, maximumBytes: 10)) { XCTAssertEqual($0 as? RegularFile.Failure, .notRegular) }
    }

    func testASymbolicLinkToARegularFileIsFollowed() throws {
        let target = folder.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = folder.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(try RegularFile.read(link, maximumBytes: 10), Data("{}".utf8))
    }

    func testASymbolicLinkToAFIFOOrADirectoryAndADirectoryItselfAreRefused() throws {
        let fifo = try makeFIFO("target.fifo")
        let fifoLink = folder.appendingPathComponent("fifo-link")
        try FileManager.default.createSymbolicLink(at: fifoLink, withDestinationURL: fifo)
        let directoryLink = folder.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: folder)
        for url in [fifoLink, directoryLink, try XCTUnwrap(folder)] {
            XCTAssertThrowsError(try RegularFile.open(url)) { XCTAssertEqual($0 as? RegularFile.Failure, .notRegular) }
        }
    }

    func testADanglingSymbolicLinkReadsAsVanished() throws {
        let link = folder.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("gone"))
        XCTAssertThrowsError(try RegularFile.open(link)) { XCTAssertTrue($0.isMissingFile) }
    }

    func testAMissingFileReadsAsVanishedAndAnUnreadableOneAsAnError() throws {
        XCTAssertThrowsError(try RegularFile.open(folder.appendingPathComponent("gone"))) { XCTAssertTrue($0.isMissingFile) }
        let locked = folder.appendingPathComponent("locked")
        try Data("x".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        if getuid() != 0 {
            XCTAssertThrowsError(try RegularFile.open(locked)) { error in
                XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission)
                XCTAssertFalse(error.isMissingFile)
            }
        }
    }

    func testAJSONLReaderDoesNotBlockOnAFileSwappedForAFIFO() throws {
        let url = folder.appendingPathComponent("rollout.jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{}}\n".utf8).write(to: url)
        var reader = JSONLFileReader(url: url)
        _ = try reader.poll()
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        // The swapped file has a new identity: the reader starts over and must not open the FIFO blocking.
        _ = try? reader.poll()
    }

    func testTheGrokMonitorSkipsAUsageLedgerAndSummaryThatAreFIFOsAndReadsThemOnceTheyAreRealFiles() async throws {
        let session = "grok-session-1"
        let events = [
            ["type": "turn_started", "ts": "2026-10-03T20:00:00Z", "session_id": session, "turn_number": 0, "session_relationship": "primary", "schema_version": "1.0"],
            ["type": "turn_ended", "ts": "2026-10-03T20:00:05Z", "outcome": "completed"]
        ].map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        let eventsURL = folder.appendingPathComponent("events.jsonl")
        try Data(events.utf8).write(to: eventsURL)
        let usageURL = try makeFIFO("usage.json")
        _ = try makeFIFO("summary.json")

        let monitor = GrokSessionMonitor(root: folder)
        let start = Date.now
        // Would block forever on a plain open of either FIFO.
        var records = try await monitor.poll(now: start)
        records += try await monitor.poll(now: start.addingTimeInterval(7))
        XCTAssertTrue(records.isEmpty, "a FIFO holds no usage ledger")

        try FileManager.default.removeItem(at: usageURL)
        let ledger: [String: Any] = [
            "sessionId": session, "updatedAt": "2026-10-03T20:00:06Z",
            "turns": [["turnNumber": 1, "endedAt": "2026-10-03T20:00:05.020Z", "outputTokens": 50, "reasoningTokens": 10, "modelCalls": 1, "turnCount": 1, "usageIsIncomplete": false, "modelUsage": ["grok-4": ["outputTokens": 50]]]]
        ]
        try JSONSerialization.data(withJSONObject: ledger).write(to: usageURL)
        await monitor.noteChanges(SessionFolderChange(paths: [usageURL.standardizedFileURL.path]))
        records += try await monitor.poll(now: start.addingTimeInterval(8))
        records += try await monitor.poll(now: start.addingTimeInterval(13))
        XCTAssertEqual(records.map(\.outputTokens), [50])
    }

    func testTheGrokMonitorIgnoresAUsageLedgerAboveItsCap() async throws {
        let session = "grok-session-2"
        let events = [
            ["type": "turn_started", "ts": "2026-10-03T20:00:00Z", "session_id": session, "turn_number": 0, "session_relationship": "primary", "schema_version": "1.0"],
            ["type": "turn_ended", "ts": "2026-10-03T20:00:05Z", "outcome": "completed"]
        ].map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(events.utf8).write(to: folder.appendingPathComponent("events.jsonl"))
        try Data(repeating: 0x20, count: 262_145).write(to: folder.appendingPathComponent("usage.json"))
        let monitor = GrokSessionMonitor(root: folder)
        let start = Date.now
        var records = try await monitor.poll(now: start)
        records += try await monitor.poll(now: start.addingTimeInterval(7))
        XCTAssertTrue(records.isEmpty)
    }
}
