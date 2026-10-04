import Foundation
import TokrateCore
import XCTest

final class CodexEventParserTests: XCTestCase {
    func testNullTimingUsesWholeTurnDatesAndLeavesTTFTUnavailable() throws {
        var parser = CodexEventParser(sourceIdentity: "/private/sessions/secret.jsonl")
        _ = parser.consume(line: try event(type: "session_meta", payload: ["id": "private-session-id"]))
        _ = parser.consume(line: try started("private-turn-id"))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: [
            "turn_id": "private-turn-id",
            "turn_token_usage": ["output_tokens": 200]
        ]))

        let completion = try event(type: "event_msg", payload: [
            "type": "task_complete",
            "turn_id": "private-turn-id",
            "started_at": "2026-10-03T10:00:00Z",
            "completed_at": "2026-10-03T10:00:10Z",
            "duration_ms": NSNull(),
            "time_to_first_token_ms": NSNull(),
            "last_agent_message": "private response text"
        ])
        let metric = try XCTUnwrap(parser.consume(line: completion))

        XCTAssertEqual(metric.outputTokens, 200)
        XCTAssertEqual(metric.durationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(metric.turnThroughputTPS, 20, accuracy: 0.001)
        XCTAssertNil(metric.codexTTFTSeconds)
        XCTAssertNil(metric.streamingTPS)
    }

    func testUsageTotalsReplaceAndDuplicateCompletionIsIdempotent() throws {
        var parser = CodexEventParser(sourceIdentity: "session-file")
        _ = parser.consume(line: try started("turn-1"))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: [
            "turn_id": "turn-1", "turn_token_usage": ["output_tokens": 8]
        ]))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: [
            "turn_id": "turn-1", "turn_token_usage": ["output_tokens": 13]
        ]))
        let complete = try event(type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "turn-1", "started_at": "2026-10-03T10:00:00Z",
            "completed_at": "2026-10-03T10:00:02Z", "duration_ms": 2_000
        ])

        XCTAssertEqual(parser.consume(line: complete)?.outputTokens, 13)
        XCTAssertNil(parser.consume(line: complete))
    }

    func testInterleavedTurnsKeepTheirOwnModelAndTiming() throws {
        var parser = CodexEventParser(sourceIdentity: "session-file")
        _ = parser.consume(line: try started("a"))
        _ = parser.consume(line: try started("b"))
        _ = parser.consume(line: try event(type: "turn_context", payload: ["turn_id": "a", "model": "model-a", "effort": "xhigh"]))
        _ = parser.consume(line: try event(type: "turn_context", payload: ["turn_id": "b", "model": "model-b", "effort": "high"]))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "a", "turn_token_usage": ["output_tokens": 10]]))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "b", "turn_token_usage": ["output_tokens": 90]]))

        let second = try event(type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "b", "started_at": "2026-10-03T10:00:00Z",
            "completed_at": "2026-10-03T10:00:03Z", "duration_ms": 3_000
        ])
        let first = try event(type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "a", "started_at": "2026-10-03T10:00:00Z",
            "completed_at": "2026-10-03T10:00:10Z", "duration_ms": 10_000
        ])

        let metricB = try XCTUnwrap(parser.consume(line: second))
        let metricA = try XCTUnwrap(parser.consume(line: first))
        XCTAssertEqual(metricB.model, "model-b")
        XCTAssertEqual(metricB.reasoningEffort, "high")
        XCTAssertEqual(metricB.turnThroughputTPS, 30, accuracy: 0.001)
        XCTAssertEqual(metricA.model, "model-a")
        XCTAssertEqual(metricA.reasoningEffort, "xhigh")
        XCTAssertEqual(metricA.turnThroughputTPS, 1, accuracy: 0.001)
    }

    func testReasoningEffortUsesOnlyConsistentAllowlistedTurnContexts() throws {
        XCTAssertTrue(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].allSatisfy(ReportedReasoningEffort.isAllowed))
        XCTAssertFalse(ReportedReasoningEffort.isAllowed("automatic"))

        var parser = CodexEventParser(sourceIdentity: "file")
        _ = parser.consume(line: try event(type: "session_meta", payload: ["effort": "ultra"]))
        _ = parser.consume(line: try started("consistent"))
        _ = parser.consume(line: try event(type: "turn_context", payload: ["turn_id": "consistent", "effort": "medium"]))
        _ = parser.consume(line: try event(type: "turn_context", payload: ["turn_id": "consistent", "effort": "medium"]))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "consistent", "turn_token_usage": ["output_tokens": 8, "reasoning_output_tokens": 3, "effort": "max"]]))
        let complete: (String) throws -> Data = { id in
            try self.event(type: "event_msg", payload: ["type": "task_complete", "turn_id": id, "started_at": "2026-10-03T10:00:00Z", "completed_at": "2026-10-03T10:00:01Z", "duration_ms": 1_000])
        }
        XCTAssertEqual(try parser.consume(line: complete("consistent"))?.reasoningEffort, "medium")

        var conflictParser = CodexEventParser(sourceIdentity: "conflict")
        _ = conflictParser.consume(line: try started("t"))
        _ = conflictParser.consume(line: try event(type: "turn_context", payload: ["turn_id": "t", "effort": "high"]))
        _ = conflictParser.consume(line: try event(type: "turn_context", payload: ["turn_id": "t", "effort": "low"]))
        _ = conflictParser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "t", "turn_token_usage": ["output_tokens": 5]]))
        XCTAssertNil(conflictParser.consume(line: try complete("t"))?.reasoningEffort)

        var invalidParser = CodexEventParser(sourceIdentity: "invalid")
        _ = invalidParser.consume(line: try started("t"))
        _ = invalidParser.consume(line: try event(type: "turn_context", payload: ["turn_id": "t", "effort": "automatic"]))
        _ = invalidParser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "t", "turn_token_usage": ["output_tokens": 5]]))
        XCTAssertNil(invalidParser.consume(line: try complete("t"))?.reasoningEffort)

        var missingParser = CodexEventParser(sourceIdentity: "missing")
        _ = missingParser.consume(line: try started("t"))
        _ = missingParser.consume(line: try event(type: "turn_context", payload: ["turn_id": "t", "model": "reported-model"]))
        _ = missingParser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "t", "turn_token_usage": ["output_tokens": 5]]))
        XCTAssertNil(missingParser.consume(line: try complete("t"))?.reasoningEffort)

        var noContextParser = CodexEventParser(sourceIdentity: "no-context")
        _ = noContextParser.consume(line: try event(type: "session_meta", payload: ["effort": "high"]))
        _ = noContextParser.consume(line: try started("t"))
        _ = noContextParser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "t", "turn_token_usage": ["output_tokens": 5, "reasoning_output_tokens": 4]]))
        XCTAssertNil(noContextParser.consume(line: try complete("t"))?.reasoningEffort)
    }

    func testCompletionWithoutAnObservedStartEmitsNothing() throws {
        // A reader that began mid-turn sees usage and completion but never task_started or turn_context.
        var parser = CodexEventParser(sourceIdentity: "mid-turn")
        _ = parser.consume(line: try event(type: "session_meta", payload: ["source": "vscode", "model_provider": "openai"]))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "t", "turn_token_usage": ["output_tokens": 22_789]]))
        let completion = try event(type: "event_msg", payload: ["type": "task_complete", "turn_id": "t", "duration_ms": 64_000])
        XCTAssertNil(parser.consume(line: completion))

        // The next turn, whose start is observed, is measured normally.
        _ = parser.consume(line: try started("next"))
        _ = parser.consume(line: try event(type: "turn_context", payload: ["turn_id": "next", "model": "gpt-test"]))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "next", "turn_token_usage": ["output_tokens": 10]]))
        let metric = try XCTUnwrap(parser.consume(line: event(type: "event_msg", payload: ["type": "task_complete", "turn_id": "next", "duration_ms": 1_000])))
        XCTAssertEqual(metric.model, "gpt-test")
    }

    func testTurnMetricDecodesRecordsWithoutReasoningEffort() throws {
        let metric = TurnMetric(id: "id", completedAt: Date(timeIntervalSince1970: 10), model: "gpt-test", outputTokens: 5, durationSeconds: 1, codexTTFTSeconds: nil, turnThroughputTPS: 5, reasoningEffort: "high")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metric)) as? [String: Any])
        object.removeValue(forKey: "reasoningEffort")
        let legacy = try JSONDecoder().decode(TurnMetric.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.reasoningEffort)
        XCTAssertEqual(try JSONDecoder().decode(TurnMetric.self, from: JSONEncoder().encode(metric)).reasoningEffort, "high")
    }

    func testMalformedMissingAndUnsafeCountersAreIgnored() throws {
        var parser = CodexEventParser(sourceIdentity: "session-file")
        _ = parser.consume(line: try started("bad"))
        XCTAssertNil(parser.consume(line: Data("{not-json}".utf8)))
        XCTAssertNil(parser.consume(line: Data("\"null\"".utf8)))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: [
            "turn_id": "bad", "turn_token_usage": ["output_tokens": -1]
        ]))
        let completion = try event(type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "bad", "started_at": "2026-10-03T10:00:00Z",
            "completed_at": "2026-10-03T10:00:01Z", "duration_ms": 1_000
        ])
        XCTAssertNil(parser.consume(line: completion))
    }

    func testModelChangeMakesTurnModelUnknownAndAgentSessionsAreExcluded() throws {
        var parser = CodexEventParser(sourceIdentity: "file")
        _ = parser.consume(line: try started("turn"))
        _ = parser.consume(line: try event(type: "turn_context", payload: ["turn_id": "turn", "model": "one"]))
        _ = parser.consume(line: try event(type: "turn_context", payload: ["turn_id": "turn", "model": "two"]))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "turn", "turn_token_usage": ["output_tokens": 1]]))
        let completion = try event(type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "turn", "started_at": "2026-10-03T10:00:00Z",
            "completed_at": "2026-10-03T10:00:01Z", "duration_ms": 1_000
        ])
        XCTAssertNil(try XCTUnwrap(parser.consume(line: completion)).model)

        var agentParser = CodexEventParser(sourceIdentity: "agent-file")
        _ = agentParser.consume(line: try event(type: "session_meta", payload: ["agent_path": ["subagent"]]))
        _ = agentParser.consume(line: try started("agent-turn"))
        _ = agentParser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "agent-turn", "turn_token_usage": ["output_tokens": 4]]))
        let agentCompletion = try event(type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "agent-turn", "started_at": "2026-10-03T10:00:00Z",
            "completed_at": "2026-10-03T10:00:01Z", "duration_ms": 1_000
        ])
        XCTAssertNil(agentParser.consume(line: agentCompletion))
    }

    func testMetricJSONContainsOnlyDerivedFieldsAndPseudonymousID() throws {
        var parser = CodexEventParser(sourceIdentity: "/Users/example/private/session.jsonl")
        _ = parser.consume(line: try event(type: "session_meta", payload: ["id": "sensitive-session-id", "account_id": "account-secret"]))
        _ = parser.consume(line: try started("sensitive-turn-id"))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "sensitive-turn-id", "turn_token_usage": ["output_tokens": 5]]))
        let completion = try event(type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "sensitive-turn-id", "started_at": "2026-10-03T10:00:00Z",
            "completed_at": "2026-10-03T10:00:01Z", "duration_ms": 1_000,
            "last_agent_message": "sensitive prompt and response"
        ])
        let metric = try XCTUnwrap(parser.consume(line: completion))
        let json = String(decoding: try JSONEncoder().encode(metric), as: UTF8.self)

        XCTAssertEqual(metric.id.count, 64)
        XCTAssertFalse(json.contains("session.jsonl"))
        XCTAssertFalse(json.contains("sensitive-session-id"))
        XCTAssertFalse(json.contains("account-secret"))
        XCTAssertFalse(json.contains("sensitive-turn-id"))
        XCTAssertFalse(json.contains("sensitive prompt"))
        XCTAssertTrue(json.contains("turnThroughputTPS"))
    }

    func testDesktopSourceAndProviderAreReportedWithoutSessionMetadata() throws {
        var parser = CodexEventParser(sourceIdentity: "private-path")
        _ = parser.consume(line: try event(type: "session_meta", payload: ["source": "vscode", "model_provider": "openai", "cli_version": "0.159.2", "id": "private-session"]))
        _ = parser.consume(line: try started("t"))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "t", "turn_token_usage": ["output_tokens": 20, "reasoning_output_tokens": 5]]))
        let metric = try XCTUnwrap(parser.consume(line: event(type: "event_msg", payload: ["type": "task_complete", "turn_id": "t", "duration_ms": 1000])))
        XCTAssertEqual(metric.sourceKind, "primary")
        XCTAssertEqual(metric.provider, "openai")
        XCTAssertEqual(metric.clientVersion, "0.159.2")
        XCTAssertEqual(metric.reasoningOutputTokens, 5)
    }

    func testStructuredSubagentSourceIsExcludedEvenWithoutParentID() throws {
        var parser = CodexEventParser(sourceIdentity: "private-path")
        _ = parser.consume(line: try event(type: "session_meta", payload: ["source": ["subagent": [:]]]))
        _ = parser.consume(line: try started("t"))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "t", "turn_token_usage": ["output_tokens": 20]]))
        XCTAssertNil(parser.consume(line: try event(type: "event_msg", payload: ["type": "task_complete", "turn_id": "t", "duration_ms": 1000])))
    }

    private func started(_ turnID: String) throws -> Data {
        try event(type: "event_msg", payload: ["type": "task_started", "turn_id": turnID])
    }

    private func event(type: String, payload: [String: Any]) throws -> Data {
        let object: [String: Any] = ["timestamp": "2026-10-03T10:00:00Z", "type": type, "payload": payload]
        return try JSONSerialization.data(withJSONObject: object)
    }
}
