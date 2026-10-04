import Foundation
import TokrateCore
import XCTest

final class JSONLFileReaderTests: XCTestCase {
    func testPartialLinesWaitForNewlineAndMalformedLinesAreSkipped() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let usage = #"{"type":"token_usage_record","payload":{"turn_id":"t","turn_token_usage":{"output_tokens":12}}}"#
        let complete = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t","started_at":"2026-10-03T10:00:00Z","completed_at":"2026-10-03T10:00:02Z","duration_ms":2000}}"#
        let started = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}"#
        try Data((started + "\n" + usage + "\n{broken}\n" + complete.prefix(40)).utf8).write(to: file)

        var reader = JSONLFileReader(url: file)
        XCTAssertTrue(try reader.poll().isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((complete.dropFirst(40) + "\n").utf8))
        try handle.close()
        let records = try reader.poll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outputTokens, 12)
    }

    func testTruncationResetsParserAndDropsOldPartialTurnState() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let state = #"{"type":"token_usage_record","payload":{"turn_id":"t","turn_token_usage":{"output_tokens":7}}}"#
        let oversizedPadding = String(repeating: "x", count: 300)
        try Data((state + "\n" + oversizedPadding + "\n").utf8).write(to: file)
        var reader = JSONLFileReader(url: file)
        XCTAssertTrue(try reader.poll().isEmpty)

        let completion = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t","started_at":"2026-10-03T10:00:00Z","completed_at":"2026-10-03T10:00:01Z","duration_ms":1000}}"#
        try Data((completion + "\n").utf8).write(to: file, options: .atomic)
        XCTAssertTrue(try reader.poll().isEmpty)
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("synthetic.jsonl")
        try Data().write(to: file)
        return file
    }
}
