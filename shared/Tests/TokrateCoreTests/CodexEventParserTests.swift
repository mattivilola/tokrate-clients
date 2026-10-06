import Foundation
@testable import TokrateCore
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

    // MARK: Per-response timing (response-v1)

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double, _ type: String, _ payload: [String: Any]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = ["timestamp": formatter.string(from: epoch.addingTimeInterval(seconds)), "type": type, "payload": payload]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func item(_ seconds: Double, _ type: String, role: String? = nil) throws -> Data {
        var payload: [String: Any] = ["type": type]
        if let role { payload["role"] = role }
        return try at(seconds, "response_item", payload)
    }

    private func responseUsage(
        _ seconds: Double, response: String?, output: Int, cumulative: Int, turn: String = "turn-1"
    ) throws -> Data {
        var payload: [String: Any] = [
            "thread_id": "thread", "turn_id": turn, "session_id": "session",
            "usage": ["input_tokens": 1, "cached_input_tokens": 0, "output_tokens": output, "reasoning_output_tokens": 0, "total_tokens": output + 1],
            "turn_token_usage": ["input_tokens": 1, "output_tokens": cumulative, "reasoning_output_tokens": 0, "total_tokens": cumulative + 1]
        ]
        if let response { payload["response_id"] = response }
        return try at(seconds, "token_usage_record", payload)
    }

    private func begin(_ parser: inout CodexEventParser, session: String = "synthetic-session", turn: String = "turn-1", model: String? = "gpt-test", at seconds: Double = 0) throws {
        _ = parser.consume(line: try event(type: "session_meta", payload: ["id": session, "source": "vscode", "model_provider": "openai"]))
        _ = parser.consume(line: try at(seconds, "event_msg", ["type": "task_started", "turn_id": turn]))
        if let model {
            _ = parser.consume(line: try at(seconds, "turn_context", ["turn_id": turn, "model": model, "effort": "high"]))
        }
    }

    private func complete(_ parser: inout CodexEventParser, at seconds: Double, turn: String = "turn-1") throws -> TurnMetric? {
        parser.consume(line: try at(seconds, "event_msg", ["type": "task_complete", "turn_id": turn, "duration_ms": seconds * 1_000]))
    }

    func testResponseTimingFollowsTriggersAndSkipsShortLongAndDuplicateResponses() throws {
        var parser = CodexEventParser(sourceIdentity: "/private/rollout.jsonl")
        try begin(&parser)
        let lines: [Data] = [
            try item(1, "message", role: "user"),
            try item(3, "reasoning"), try item(8, "function_call"),
            try responseUsage(11, response: "resp-1", output: 341, cumulative: 341),
            // Tool loop: the function_call_output is the next trigger.
            try item(13, "function_call_output"), try item(14, "reasoning"), try item(20, "message", role: "assistant"),
            try responseUsage(23, response: "resp-2", output: 118, cumulative: 459),
            try item(25, "function_call_output"),
            try item(25.5, "message", role: "developer"),
            try item(26, "message", role: "assistant"),
            try responseUsage(33, response: "resp-3", output: 400, cumulative: 859),
            try responseUsage(34, response: "resp-3", output: 400, cumulative: 859),
            // 601 s from its trigger: stalled, not one response.
            try item(40, "custom_tool_call_output"), try item(41, "reasoning"),
            try responseUsage(641, response: "resp-4", output: 350, cumulative: 1_209),
            // Exactly 600 s still counts.
            try item(700, "function_call_output"), try item(701, "reasoning"),
            try responseUsage(1_300, response: "resp-5", output: 300, cumulative: 1_509),
            // A message from another agent is a trigger too.
            try item(1_310, "agent_message"), try item(1_311, "message", role: "assistant"),
            try responseUsage(1_318, response: "resp-6", output: 250, cumulative: 1_759)
        ]
        for line in lines { XCTAssertNil(parser.consume(line: line)) }
        let metric = try XCTUnwrap(complete(&parser, at: 1_320))

        XCTAssertEqual(metric.parserVersion, "codex-rollout-v2")
        XCTAssertEqual(metric.outputTokens, 1_759)
        XCTAssertEqual(metric.responseOutputTokens, 341 + 400 + 300 + 250)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 10 + 8 + 600 + 8, accuracy: 0.001)
        XCTAssertEqual(metric.responseCount, 4)
        XCTAssertEqual(try XCTUnwrap(metric.responseSpeedTPS), 1_291.0 / 626.0, accuracy: 0.001)
        XCTAssertNil(metric.providerRegion)

        let responses = parser.drainCompletedResponses()
        XCTAssertEqual(responses.map(\.id), ["synthetic-session|resp-1", "synthetic-session|resp-3", "synthetic-session|resp-5", "synthetic-session|resp-6"])
        XCTAssertEqual(responses.map(\.outputTokens), [341, 400, 300, 250])
        XCTAssertEqual(responses.map(\.durationSeconds), [10, 8, 600, 8])
        XCTAssertEqual(responses.map(\.completedAt), [11, 33, 1_300, 1_318].map { epoch.addingTimeInterval($0) })
        XCTAssertEqual(Set(responses.map(\.model)), ["gpt-test"])
        XCTAssertEqual(Set(responses.map(\.provider)), ["openai"])
        XCTAssertEqual(Set(responses.map(\.client)), ["codex"])
        XCTAssertEqual(Set(responses.map(\.sourceKind)), ["primary"])
        XCTAssertEqual(Set(responses.map(\.metricVersion)), ["turn-v1"])
        XCTAssertEqual(Set(responses.map(\.reasoningEffort)), ["high"])
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty, "a drained response is not reported again")
    }

    func testFirstResponseStartsAtTaskStartedWhenNothingElseTriggersIt() throws {
        var parser = CodexEventParser(sourceIdentity: "file")
        try begin(&parser, at: 5)
        _ = parser.consume(line: try item(7, "reasoning"))
        _ = parser.consume(line: try responseUsage(17, response: "resp-1", output: 300, cumulative: 300))
        let metric = try XCTUnwrap(complete(&parser, at: 20))
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 12, accuracy: 0.001)
        XCTAssertEqual(parser.drainCompletedResponses().map(\.durationSeconds), [12])
    }

    func testDeveloperMessagesAndOutputItemsDoNotMoveTheTrigger() throws {
        var parser = CodexEventParser(sourceIdentity: "file")
        try begin(&parser)
        _ = parser.consume(line: try item(1, "message", role: "user"))
        // Developer context is neither a trigger nor an output; later output items keep the first start.
        _ = parser.consume(line: try item(2, "message", role: "developer"))
        _ = parser.consume(line: try item(4, "reasoning"))
        _ = parser.consume(line: try item(9, "function_call"))
        _ = parser.consume(line: try responseUsage(11, response: "resp-1", output: 500, cumulative: 500))
        XCTAssertEqual(parser.drainCompletedResponses().map(\.durationSeconds), [10])
    }

    func testTurnWithoutUsableResponsesHasNilResponseFieldsAndStillEmits() throws {
        var parser = CodexEventParser(sourceIdentity: "file")
        try begin(&parser)
        _ = parser.consume(line: try item(1, "message", role: "user"))
        _ = parser.consume(line: try item(2, "reasoning"))
        _ = parser.consume(line: try responseUsage(9, response: "resp-short", output: 118, cumulative: 118))
        // Records without a response identifier or response usage carry no measurable response.
        _ = parser.consume(line: try item(10, "function_call_output"))
        _ = parser.consume(line: try item(11, "reasoning"))
        _ = parser.consume(line: try responseUsage(20, response: nil, output: 500, cumulative: 618))
        _ = parser.consume(line: try at(21, "token_usage_record", ["turn_id": "turn-1", "response_id": "no-usage", "turn_token_usage": ["output_tokens": 700]]))
        let metric = try XCTUnwrap(complete(&parser, at: 30))
        XCTAssertEqual(metric.outputTokens, 700)
        XCTAssertNil(metric.responseOutputTokens)
        XCTAssertNil(metric.responseDurationSeconds)
        XCTAssertNil(metric.responseCount)
        XCTAssertNil(metric.responseSpeedTPS)
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty)
    }

    func testAgentSessionResponsesAreNeverDrainedOrEmitted() throws {
        var parser = CodexEventParser(sourceIdentity: "agent-file")
        _ = parser.consume(line: try event(type: "session_meta", payload: ["id": "agent", "agent_path": ["subagent"]]))
        _ = parser.consume(line: try at(0, "event_msg", ["type": "task_started", "turn_id": "turn-1"]))
        _ = parser.consume(line: try at(0, "turn_context", ["turn_id": "turn-1", "model": "gpt-test"]))
        _ = parser.consume(line: try item(1, "reasoning"))
        _ = parser.consume(line: try responseUsage(11, response: "resp-1", output: 500, cumulative: 500))
        XCTAssertNil(try complete(&parser, at: 12))
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty)
    }

    func testResponsesNeedAKnownModelToReachTheLiveStreamButStillCountInTheTurn() throws {
        var unknown = CodexEventParser(sourceIdentity: "file")
        try begin(&unknown, model: nil)
        _ = unknown.consume(line: try item(1, "reasoning"))
        _ = unknown.consume(line: try responseUsage(11, response: "resp-1", output: 500, cumulative: 500))
        XCTAssertTrue(unknown.drainCompletedResponses().isEmpty)
        let metric = try XCTUnwrap(complete(&unknown, at: 12))
        XCTAssertNil(metric.model)
        XCTAssertEqual(metric.responseOutputTokens, 500)

        var ambiguous = CodexEventParser(sourceIdentity: "file")
        try begin(&ambiguous)
        _ = ambiguous.consume(line: try at(0, "turn_context", ["turn_id": "turn-1", "model": "other-model"]))
        _ = ambiguous.consume(line: try item(1, "reasoning"))
        _ = ambiguous.consume(line: try responseUsage(11, response: "resp-1", output: 500, cumulative: 500))
        XCTAssertTrue(ambiguous.drainCompletedResponses().isEmpty)
    }

    func testResetClearsResponseStateAndDedupeIsPerTurn() throws {
        var parser = CodexEventParser(sourceIdentity: "file")
        try begin(&parser)
        _ = parser.consume(line: try item(1, "reasoning"))
        _ = parser.consume(line: try responseUsage(11, response: "resp-1", output: 500, cumulative: 500))
        parser.reset(sourceIdentity: "file")
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty)

        // The same response identifier in another turn is a different response.
        var twoTurns = CodexEventParser(sourceIdentity: "file")
        try begin(&twoTurns, turn: "a")
        _ = twoTurns.consume(line: try item(1, "reasoning"))
        _ = twoTurns.consume(line: try responseUsage(11, response: "resp", output: 500, cumulative: 500, turn: "a"))
        _ = twoTurns.consume(line: try at(20, "event_msg", ["type": "task_started", "turn_id": "b"]))
        _ = twoTurns.consume(line: try at(20, "turn_context", ["turn_id": "b", "model": "gpt-test"]))
        _ = twoTurns.consume(line: try item(21, "reasoning"))
        _ = twoTurns.consume(line: try responseUsage(31, response: "resp", output: 500, cumulative: 500, turn: "b"))
        XCTAssertEqual(twoTurns.drainCompletedResponses().count, 2)
    }

    private func completedMetric(originator: Any?) throws -> TurnMetric {
        var parser = CodexEventParser(sourceIdentity: "session-file")
        var meta: [String: Any] = ["id": "session-1", "source": "vscode"]
        if let originator { meta["originator"] = originator }
        _ = parser.consume(line: try event(type: "session_meta", payload: meta))
        _ = parser.consume(line: try started("turn-1"))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: [
            "turn_id": "turn-1", "turn_token_usage": ["output_tokens": 50]
        ]))
        return try XCTUnwrap(parser.consume(line: try event(type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "turn-1", "started_at": "2026-10-03T10:00:00Z",
            "completed_at": "2026-10-03T10:00:05Z", "duration_ms": 5_000
        ])))
    }

    func testSurfaceComesFromTheSessionOriginatorNotTheSource() throws {
        // The source says "vscode" for every fixture; only the originator decides.
        XCTAssertEqual(try completedMetric(originator: "Codex Desktop").surface, .desktop)
        XCTAssertEqual(try completedMetric(originator: "codex_cli_rs").surface, .cli)
        XCTAssertEqual(try completedMetric(originator: "codex_vscode").surface, .ide)
        XCTAssertEqual(try completedMetric(originator: "codex_exec").surface, .sdk)
        XCTAssertEqual(try completedMetric(originator: "buzz-acp").surface, .other)
        XCTAssertNil(try completedMetric(originator: nil).surface)
        XCTAssertNil(try completedMetric(originator: "").surface)
        XCTAssertNil(try completedMetric(originator: 42).surface)
    }

    func testTheRawOriginatorIsNeverPersistedAndResetClearsTheSurface() throws {
        let metric = try completedMetric(originator: "vibe-codex-executor")
        XCTAssertEqual(metric.surface, .other)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(metric), as: UTF8.self).contains("vibe-codex-executor"))

        var parser = CodexEventParser(sourceIdentity: "a")
        _ = parser.consume(line: try event(type: "session_meta", payload: ["id": "s", "originator": "codex_exec"]))
        parser.reset(sourceIdentity: "b")
        _ = parser.consume(line: try started("turn-2"))
        _ = parser.consume(line: try event(type: "token_usage_record", payload: ["turn_id": "turn-2", "turn_token_usage": ["output_tokens": 50]]))
        let after = try XCTUnwrap(parser.consume(line: try event(type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "turn-2", "started_at": "2026-10-03T10:00:00Z",
            "completed_at": "2026-10-03T10:00:05Z", "duration_ms": 5_000
        ])))
        XCTAssertNil(after.surface)
    }

    private func started(_ turnID: String) throws -> Data {
        try event(type: "event_msg", payload: ["type": "task_started", "turn_id": turnID])
    }

    private func event(type: String, payload: [String: Any]) throws -> Data {
        let object: [String: Any] = ["timestamp": "2026-10-03T10:00:00Z", "type": type, "payload": payload]
        return try JSONSerialization.data(withJSONObject: object)
    }
}
