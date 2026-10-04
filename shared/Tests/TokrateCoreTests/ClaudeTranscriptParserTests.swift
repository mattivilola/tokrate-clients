import CryptoKit
import Foundation
import XCTest
@testable import TokrateCore

final class ClaudeTranscriptParserTests: XCTestCase {
    private let sessionID = "synthetic-session-v2"
    private let agentID = "a0123456789abcdef"
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testInterjectionContinuesTheTurnKeepingOriginalStartAndSummingTokens() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        XCTAssertNil(parser.consume(line: try user(at: 0, id: "prompt")))
        XCTAssertNil(parser.consume(line: try assistant(at: 5, id: "m1", output: 100, stop: "tool_use")))
        XCTAssertNil(parser.consume(line: try user(at: 20, id: "interjection")))
        XCTAssertNil(parser.consume(line: try toolResult(at: 21)))
        let metric = try XCTUnwrap(parser.consume(line: assistant(at: 40, id: "m2", output: 300, stop: "end_turn")))
        XCTAssertEqual(metric.durationSeconds, 40, accuracy: 0.001)
        XCTAssertEqual(metric.outputTokens, 400)
        XCTAssertEqual(metric.turnThroughputTPS, 10, accuracy: 0.001)
        XCTAssertEqual(metric.parserVersion, "claude-transcript-v2")
        XCTAssertEqual(metric.metricVersion, "claude-observed-turn-v1")
        XCTAssertEqual(metric.sourceKind, "primary")
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|prompt"), "turn identity stays the original prompt")
    }

    func testInterjectionAfterMoreThanThirtyMinutesOfInactivityStartsANewTurn() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "stale-prompt"))
        _ = parser.consume(line: try assistant(at: 10, id: "m-stale", output: 50, stop: "tool_use"))
        XCTAssertNil(parser.consume(line: try user(at: 10 + 1_801, id: "fresh-prompt")))
        let metric = try XCTUnwrap(parser.consume(line: assistant(at: 10 + 1_811, id: "m-fresh", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.durationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(metric.outputTokens, 100)
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|fresh-prompt"))

        var boundary = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = boundary.consume(line: try user(at: 0, id: "prompt"))
        _ = boundary.consume(line: try assistant(at: 10, id: "m1", output: 50, stop: "tool_use"))
        _ = boundary.consume(line: try user(at: 10 + 1_800, id: "exactly-thirty-minutes"))
        let continued = try XCTUnwrap(boundary.consume(line: assistant(at: 10 + 1_810, id: "m2", output: 50, stop: "end_turn")))
        XCTAssertEqual(continued.outputTokens, 100)
        XCTAssertEqual(continued.id, try expectedID("\(sessionID)|prompt"))
    }

    func testInterruptionMarkerDiscardsTheTurnAndDoesNotStartOne() throws {
        for content: Any in ["[Request interrupted by user]", [["type": "text", "text": "[Request interrupted by user for tool use]"]]] {
            var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
            _ = parser.consume(line: try user(at: 0, id: "prompt"))
            _ = parser.consume(line: try assistant(at: 5, id: "m1", output: 100, stop: "tool_use"))
            XCTAssertNil(parser.consume(line: try user(at: 6, id: "interrupt", content: content)))
            XCTAssertNil(parser.consume(line: try assistant(at: 7, id: "m-orphan", output: 100, stop: "end_turn")))

            _ = parser.consume(line: try user(at: 10, id: "next"))
            let metric = try XCTUnwrap(parser.consume(line: assistant(at: 20, id: "m-next", output: 100, stop: "end_turn")))
            XCTAssertEqual(metric.outputTokens, 100)
            XCTAssertEqual(metric.durationSeconds, 10, accuracy: 0.001)
        }
    }

    func testSyntheticAssistantMessageInvalidatesTheTurnWithoutAmbiguatingTheNextOne() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try assistant(at: 5, id: "m1", output: 100, stop: "tool_use"))
        XCTAssertNil(parser.consume(line: try assistant(at: 6, id: "m-synthetic", model: "<synthetic>", output: 0, stop: "stop_sequence")))
        _ = parser.consume(line: try user(at: 10, id: "next"))
        let metric = try XCTUnwrap(parser.consume(line: assistant(at: 20, id: "m-next", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.model, "claude-sonnet-5-5")

        var withoutTerminal = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = withoutTerminal.consume(line: try user(at: 0, id: "prompt"))
        _ = withoutTerminal.consume(line: try assistant(at: 1, id: "m-synthetic", model: "<synthetic>", output: nil, stop: nil))
        XCTAssertNil(withoutTerminal.consume(line: try assistant(at: 5, id: "m-final", output: 100, stop: "end_turn")))
    }

    func testMetaUserRecordsAreIgnored() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        XCTAssertNil(parser.consume(line: try user(at: 0, id: "meta-start", meta: true)))
        XCTAssertNil(parser.consume(line: try assistant(at: 5, id: "m-orphan", output: 100, stop: "end_turn")))

        _ = parser.consume(line: try user(at: 10, id: "prompt"))
        _ = parser.consume(line: try assistant(at: 15, id: "m1", output: 100, stop: "tool_use"))
        // A meta record far beyond the gap neither restarts nor continues the turn.
        XCTAssertNil(parser.consume(line: try user(at: 15 + 7_200, id: "meta-late", meta: true)))
        let metric = try XCTUnwrap(parser.consume(line: assistant(at: 30, id: "m2", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.durationSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|prompt"))
    }

    func testSubagentTranscriptEmitsSubagentMetricWithDistinctIdentityAndSeparateFollowUpTurn() throws {
        var subagent = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: .subagent)
        XCTAssertNil(subagent.consume(line: try user(at: 0, id: "task", sidechain: true)))
        XCTAssertNil(subagent.consume(line: try assistant(at: 4, id: "s1", output: 60, stop: "tool_use", sidechain: true)))
        XCTAssertNil(subagent.consume(line: try toolResult(at: 5, sidechain: true)))
        let first = try XCTUnwrap(subagent.consume(line: assistant(at: 10, id: "s2", output: 140, stop: "end_turn", sidechain: true)))
        XCTAssertEqual(first.client, "claude-code")
        XCTAssertEqual(first.parserVersion, "claude-transcript-v2")
        XCTAssertEqual(first.metricVersion, "claude-observed-subagent-turn-v1")
        XCTAssertEqual(first.sourceKind, "subagent")
        XCTAssertEqual(first.provider, "unknown")
        XCTAssertNil(first.codexTTFTSeconds)
        XCTAssertEqual(first.outputTokens, 200)
        XCTAssertEqual(first.durationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(first.throughputLabel, "Subagent turn speed")
        XCTAssertEqual(first.throughputExplanation, "Subagent task prompt to final answer, including tools and waiting.")
        XCTAssertTrue(first.isSupportedSourceTuple)
        XCTAssertEqual(first.id, try expectedID("\(sessionID)|\(agentID)|task"))
        XCTAssertNotEqual(first.id, try expectedID("\(sessionID)|task"))

        XCTAssertNil(subagent.consume(line: try user(at: 100, id: "follow-up", sidechain: true)))
        let second = try XCTUnwrap(subagent.consume(line: assistant(at: 104, id: "s3", output: 40, stop: "end_turn", sidechain: true)))
        XCTAssertEqual(second.outputTokens, 40)
        XCTAssertEqual(second.durationSeconds, 4, accuracy: 0.001)
        XCTAssertNotEqual(second.id, first.id)

        // Predicates are scope-specific: a sidechain record is invisible to the primary parser and vice versa.
        var primary = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = primary.consume(line: try user(at: 0, id: "task", sidechain: true))
        XCTAssertNil(primary.consume(line: try assistant(at: 10, id: "s1", output: 100, stop: "end_turn", sidechain: true)))
        var subagentOnly = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: .subagent)
        _ = subagentOnly.consume(line: try user(at: 0, id: "primary-prompt"))
        XCTAssertNil(subagentOnly.consume(line: try assistant(at: 10, id: "m1", output: 100, stop: "end_turn")))
    }

    func testSubagentSharingPayloadContainsOnlyAllowlistedKeys() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: .subagent)
        _ = parser.consume(line: try user(at: 0, id: "task", sidechain: true))
        let metric = try XCTUnwrap(parser.consume(line: assistant(at: 10, id: "s1", output: 200, stop: "end_turn", sidechain: true)))
        let sample = try XCTUnwrap(SharedSample(metric))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["sampleId", "observedAt", "client", "clientVersion", "appVersion", "parserVersion", "metricVersion", "model", "provider", "reasoningEffort", "sourceKind", "outputTokens", "reasoningOutputTokens", "durationMs", "ttftMs"])
        XCTAssertEqual(json["sourceKind"] as? String, "subagent")
        XCTAssertEqual(json["metricVersion"] as? String, "claude-observed-subagent-turn-v1")
        XCTAssertEqual(json["parserVersion"] as? String, "claude-transcript-v2")
        XCTAssertEqual(json["appVersion"] as? String, "0.1.12")
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5-5")
        XCTAssertTrue(json["ttftMs"] is NSNull)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(sample), as: UTF8.self).contains("PRIVATE"))
    }

    func testMonitorReadsSubagentFilesSeparatelyWithoutDoubleCountingPrimaryTurns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("synthetic-project", isDirectory: true)
        let subagents = project.appendingPathComponent("\(sessionID)/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let start = Date.now.addingTimeInterval(-60)
        let primaryLines = [
            try user(at: 0, id: "prompt", origin: start),
            try assistant(at: 5, id: "m1", output: 100, stop: "end_turn", origin: start)
        ]
        let subagentLines = [
            try user(at: 1, id: "task", sidechain: true, origin: start),
            try assistant(at: 4, id: "s1", output: 90, stop: "end_turn", sidechain: true, origin: start)
        ]
        try write(primaryLines, to: project.appendingPathComponent("\(sessionID).jsonl"))
        try write(subagentLines, to: subagents.appendingPathComponent("agent-\(agentID).jsonl"))
        try Data("{\"agentType\":\"general-purpose\"}".utf8).write(to: subagents.appendingPathComponent("agent-\(agentID).meta.json"))

        let monitor = ClaudeSessionMonitor(root: root)
        var collected: [String: TurnMetric] = [:]
        for step in 0..<4 {
            for record in try await monitor.poll(now: Date.now.addingTimeInterval(Double(step) * 11)) { collected[record.id] = record }
        }
        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(Set(collected.values.map(\.sourceKind)), ["primary", "subagent"])
        let primary = try XCTUnwrap(collected.values.first { $0.sourceKind == "primary" })
        let subagent = try XCTUnwrap(collected.values.first { $0.sourceKind == "subagent" })
        XCTAssertEqual(primary.outputTokens, 100)
        XCTAssertEqual(primary.metricVersion, "claude-observed-turn-v1")
        XCTAssertEqual(subagent.outputTokens, 90)
        XCTAssertEqual(subagent.metricVersion, "claude-observed-subagent-turn-v1")
        let status = await monitor.status()
        XCTAssertTrue(status.rootAvailable)
        XCTAssertEqual(status.files, 2)
    }

    // MARK: Synthetic fixtures

    private func timestamp(_ seconds: Double, origin: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: origin.addingTimeInterval(seconds))
    }

    private func envelope(sidechain: Bool) -> [String: Any] {
        var value: [String: Any] = ["sessionId": sessionID, "isSidechain": sidechain, "userType": "external", "version": "2.1.37"]
        if sidechain { value["agentId"] = agentID }
        return value
    }

    private func user(at seconds: Double, id: String, sidechain: Bool = false, meta: Bool = false, content: Any = "PRIVATE_PROMPT", origin: Date? = nil) throws -> Data {
        var value = envelope(sidechain: sidechain)
        value["type"] = "user"
        value["uuid"] = id
        value["timestamp"] = timestamp(seconds, origin: origin ?? base)
        value["message"] = ["role": "user", "content": content]
        if meta { value["isMeta"] = true }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func toolResult(at seconds: Double, sidechain: Bool = false) throws -> Data {
        try user(at: seconds, id: "tool-result-\(Int(seconds))", sidechain: sidechain, content: [["type": "tool_result", "content": "PRIVATE_RESPONSE"]])
    }

    private func assistant(
        at seconds: Double, id: String, model: String = "claude-sonnet-5-5", output: Int?, stop: String?,
        sidechain: Bool = false, origin: Date? = nil
    ) throws -> Data {
        var value = envelope(sidechain: sidechain)
        var usage: [String: Any] = [:]
        if let output { usage["output_tokens"] = output }
        value["type"] = "assistant"
        value["uuid"] = "record-\(id)"
        value["timestamp"] = timestamp(seconds, origin: origin ?? base)
        value["message"] = ["id": id, "role": "assistant", "model": model, "content": "PRIVATE_RESPONSE", "stop_reason": stop ?? NSNull(), "usage": usage]
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func write(_ lines: [Data], to url: URL) throws {
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        try data.write(to: url)
    }

    private func expectedID(_ material: String) throws -> String {
        SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
