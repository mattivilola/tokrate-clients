import Foundation
import TokrateCore
import XCTest

@MainActor
final class CodexSessionMonitorTests: XCTestCase {
    func testFreshTurnBypassesLargeArchiveWithinSixPollsAndHonorsByteBudget() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date.now
        for index in 0..<40 {
            let file = directory.appendingPathComponent(String(format: "old-%03d.jsonl", index))
            try (metadata(id: "old-\(index)") + padding(bytes: 524_288)).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: file.path)
        }
        let fresh = directory.appendingPathComponent("zzz-fresh.jsonl")
        try (metadata(id: "fresh") + padding(bytes: 8_388_608) + turn(id: "new", tokens: 777)).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
        let monitor = CodexSessionMonitor(root: directory)
        var found: [TurnMetric] = []
        for _ in 0..<6 {
            found += try await monitor.poll(now: now).metrics
            let bytes = await monitor.bytesReadLastPoll
            XCTAssertLessThanOrEqual(bytes, CodexSessionMonitor.maximumPollBytes)
        }
        XCTAssertEqual(found.filter { $0.outputTokens == 777 }.count, 1)
        XCTAssertEqual(found.first?.sourceKind, "primary")
        XCTAssertEqual(found.first?.provider, "openai")
    }

    func testArchiveReplayDoesNotSkipFourOfEveryTwentyReaders() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date.now
        for index in 0..<40 {
            let file = directory.appendingPathComponent(String(format: "%03d.jsonl", index))
            // Historical measurements fall before the live tail and require a second archive read.
            try (metadata(id: "session-\(index)") + padding(bytes: 70_000)
                + turn(id: "historical", tokens: index + 1) + padding(bytes: 400_000)).write(to: file)
        }
        let monitor = CodexSessionMonitor(root: directory)
        var seen = Set<Int>()
        for _ in 0..<80 {
            let records = try await monitor.poll(now: now).metrics
            seen.formUnion(records.map(\.outputTokens))
            let bytes = await monitor.bytesReadLastPoll
            XCTAssertLessThanOrEqual(bytes, CodexSessionMonitor.maximumPollBytes)
            if seen.count == 40 { break }
        }
        XCTAssertEqual(seen, Set(1...40))
    }

    func testRecentlyModifiedFileCapturesPostStartUsageAndCompletion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("active.jsonl")
        try (metadata(id: "active") + padding(bytes: 2_097_152)).write(to: file)
        let now = Date.now
        let monitor = CodexSessionMonitor(root: directory)
        for _ in 0..<7 { _ = try await monitor.poll(now: now) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: turn(id: "completed-after-monitoring-start", tokens: 123))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(11)], ofItemAtPath: file.path)
        let records = try await monitor.poll(now: now.addingTimeInterval(11)).metrics
        XCTAssertEqual(records.filter { $0.outputTokens == 123 }.count, 1)
    }

    func testPartialTailCannotReplaceEarlierArchiveModelMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("overlap.jsonl")
        let context = Data(#"{"type":"turn_context","payload":{"turn_id":"t","model":"reported-model"}}"#.utf8) + Data([0x0A])
        try (metadata(id: "overlap") + context + padding(bytes: 40_000)
            + turn(id: "t", tokens: 314) + padding(bytes: 250_000)).write(to: file)
        let monitor = CodexSessionMonitor(root: directory)
        var history = MetricHistory()
        let now = ISO8601DateFormatter().date(from: "2026-10-03T20:10:00Z")!
        for _ in 0..<10 {
            for record in try await monitor.poll().metrics { history.upsert(record, now: now) }
        }
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.model, "reported-model")
    }

    func testTailCompletionWithoutObservedStartIsSkippedAndArchiveEmitsTheWholeTurn() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mid-turn.jsonl")
        let begin = Data(#"{"timestamp":"2026-10-03T19:59:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"mid"}}"#.utf8) + Data([0x0A])
        let context = Data(#"{"type":"turn_context","payload":{"turn_id":"mid","model":"reported-model"}}"#.utf8) + Data([0x0A])
        let usage = Data(#"{"type":"token_usage_record","payload":{"turn_id":"mid","turn_token_usage":{"output_tokens":555}}}"#.utf8) + Data([0x0A])
        let complete = Data(#"{"timestamp":"2026-10-03T20:00:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"mid","duration_ms":60000}}"#.utf8) + Data([0x0A])
        try (metadata(id: "mid-turn") + begin + context + padding(bytes: CodexSessionMonitor.recentTailBytes + 4_096) + usage + complete).write(to: file)
        let monitor = CodexSessionMonitor(root: directory)
        var emitted: [TurnMetric] = []
        for _ in 0..<10 { emitted += try await monitor.poll().metrics }
        XCTAssertEqual(emitted.count, 1, "the live tail emitted nothing; only the archive reader measured the turn")
        XCTAssertEqual(emitted.first?.model, "reported-model")
        XCTAssertEqual(emitted.first?.outputTokens, 555)
    }

    func testResponsesAreLiveOnlyAfterTheMonitorStartedAndAreNotReturnedTwice() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let liveSince = Date.now
        let file = directory.appendingPathComponent("live.jsonl")
        try (metadata(id: "mon-session")
            + timedTurn(id: "before", start: -100, usageAt: -90, response: "resp-before", tokens: 400, liveSince: liveSince)
            + timedTurn(id: "after", start: 10, usageAt: 21, response: "resp-after", tokens: 500, liveSince: liveSince)).write(to: file)

        let monitor = CodexSessionMonitor(root: directory, liveSince: liveSince)
        var metrics: [TurnMetric] = []
        var responses: [LiveResponse] = []
        for step in 0..<4 {
            let update = try await monitor.poll(now: liveSince.addingTimeInterval(Double(step) * 11))
            metrics += update.metrics
            responses += update.responses
        }
        XCTAssertEqual(Set(metrics.map(\.outputTokens)), [400, 500], "both turns are history and reach the metrics")
        XCTAssertEqual(metrics.first { $0.outputTokens == 400 }?.responseOutputTokens, 400)
        XCTAssertEqual(metrics.first { $0.outputTokens == 400 }?.parserVersion, "codex-rollout-v2")
        // resp-before completed 90 s before liveSince and is filtered; resp-after is live exactly once.
        XCTAssertEqual(responses.map(\.id), ["mon-session|resp-after"])
        XCTAssertEqual(responses.first?.outputTokens, 500)
        XCTAssertEqual(responses.first?.durationSeconds ?? 0, 11, accuracy: 0.001, "from task_started to the usage record")
        XCTAssertEqual(responses.first?.model, "gpt-test")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: timedTurn(id: "later", start: 30, usageAt: 40, response: "resp-later", tokens: 600, liveSince: liveSince))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: liveSince.addingTimeInterval(55)], ofItemAtPath: file.path)
        var laterMetrics: [TurnMetric] = []
        var laterResponses: [LiveResponse] = []
        for step in 0..<3 {
            let update = try await monitor.poll(now: liveSince.addingTimeInterval(55 + Double(step) * 11))
            laterMetrics += update.metrics
            laterResponses += update.responses
        }
        XCTAssertEqual(laterMetrics.map(\.outputTokens), [600])
        XCTAssertEqual(laterResponses.map(\.id), ["mon-session|resp-later"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func metadata(id: String) -> Data {
        Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"source\":\"vscode\",\"model_provider\":\"openai\"}}\n".utf8)
    }
    /// One turn with a single response, timed relative to `liveSince`.
    private func timedTurn(id: String, start: Double, usageAt: Double, response: String, tokens: Int, liveSince: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ seconds: Double, _ type: String, _ payload: [String: Any]) -> String {
            let object: [String: Any] = ["timestamp": formatter.string(from: liveSince.addingTimeInterval(seconds)), "type": type, "payload": payload]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
        }
        let usage: [String: Any] = ["turn_id": id, "response_id": response, "usage": ["output_tokens": tokens], "turn_token_usage": ["output_tokens": tokens]]
        return Data([
            line(start, "event_msg", ["type": "task_started", "turn_id": id]),
            line(start, "turn_context", ["turn_id": id, "model": "gpt-test"]),
            line(start + 1, "response_item", ["type": "reasoning"]),
            line(usageAt, "token_usage_record", usage),
            line(usageAt + 1, "event_msg", ["type": "task_complete", "turn_id": id, "duration_ms": (usageAt + 1 - start) * 1_000])
        ].joined().utf8)
    }
    private func padding(bytes: Int) -> Data { Data(repeating: 0x20, count: bytes) + Data([0x0A]) }
    private func turn(id: String, tokens: Int) -> Data {
        Data("{\"timestamp\":\"2026-10-03T19:59:59Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"\(id)\"}}\n{\"type\":\"token_usage_record\",\"payload\":{\"turn_id\":\"\(id)\",\"turn_token_usage\":{\"output_tokens\":\(tokens)}}}\n{\"timestamp\":\"2026-10-03T20:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(id)\",\"duration_ms\":1000}}\n".utf8)
    }
}
