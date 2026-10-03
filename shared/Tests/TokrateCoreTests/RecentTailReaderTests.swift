import Foundation
import TokrateCore
import XCTest

final class RecentTailReaderTests: XCTestCase {
    func testTailAlignmentCannotTreatFragmentAsUsageAndWaitsForCompleteLine() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let metadata = #"{"type":"session_meta","payload":{"id":"s","source":"vscode","model_provider":"openai"}}"# + "\n"
        let usage = #"{"type":"token_usage_record","payload":{"turn_id":"t","turn_token_usage":{"output_tokens":42}}}"# + "\n"
        let complete = #"{"timestamp":"2026-10-03T20:00:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t","duration_ms":1000}}"#
        // The tail begins inside a discarded line that happens to end in syntactically valid JSON.
        let fake = String(repeating: "x", count: 2_000) + usage
        try Data((metadata + fake + complete + "\n").utf8).write(to: file)
        var reader = JSONLFileReader(url: file, startPosition: .recentTail(maximumBytes: usage.utf8.count + complete.utf8.count + 1))
        for _ in 0..<10 { XCTAssertTrue(try reader.poll(maxBytes: 256).isEmpty) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((usage + complete).utf8))
        XCTAssertTrue(try reader.poll().isEmpty, "A completion without its newline is still partial")
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        let records = try reader.poll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outputTokens, 42)
        XCTAssertEqual(records.first?.sourceKind, "primary")
    }

    func testResetRestoresTailPositionAndCounters() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let metadata = #"{"type":"session_meta","payload":{"id":"s","source":"vscode","model_provider":"openai"}}"# + "\n"
        let usage = #"{"type":"token_usage_record","payload":{"turn_id":"t","turn_token_usage":{"output_tokens":42}}}"# + "\n"
        let complete = #"{"timestamp":"2026-10-03T20:00:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t","duration_ms":1000}}"# + "\n"
        try Data((metadata + String(repeating: " ", count: 2_097_152) + "\n" + usage + complete).utf8).write(to: file)
        var reader = JSONLFileReader(url: file, startPosition: .recentTail(maximumBytes: 512))
        var first: [TurnMetric] = []
        for _ in 0..<4 { first += try reader.poll(maxBytes: 256) }
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(reader.isCaughtUp)
        reader.reset()
        XCTAssertFalse(reader.isCaughtUp)
        XCTAssertEqual(reader.bytesReadLastPoll, 0)
        var second: [TurnMetric] = []
        for _ in 0..<4 { second += try reader.poll(maxBytes: 256) }
        XCTAssertEqual(second.map(\.id), first.map(\.id))
        XCTAssertEqual(second.first?.provider, "openai")
    }

    func testTailMetadataExcludesSubagentsAndDoesNotBorrowSkippedUsage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let complete = #"{"timestamp":"2026-10-03T20:00:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t","duration_ms":1000}}"# + "\n"
        let usage = #"{"type":"token_usage_record","payload":{"turn_id":"t","turn_token_usage":{"output_tokens":42}}}"# + "\n"
        let primary = #"{"type":"session_meta","payload":{"source":"vscode"}}"# + "\n"
        try Data((primary + usage + String(repeating: " ", count: 4_000) + "\n" + complete).utf8).write(to: file)
        var reader = JSONLFileReader(url: file, startPosition: .recentTail(maximumBytes: 512))
        for _ in 0..<8 { XCTAssertTrue(try reader.poll(maxBytes: 256).isEmpty) }
        let agent = #"{"type":"session_meta","payload":{"source":{"subagent":{}}}}"# + "\n"
        try Data((agent + usage + complete).utf8).write(to: file, options: .atomic)
        for _ in 0..<8 { XCTAssertTrue(try reader.poll(maxBytes: 256).isEmpty) }
    }
}
