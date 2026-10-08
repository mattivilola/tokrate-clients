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
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 40, id: "m2", output: 300, stop: "end_turn")))
        XCTAssertEqual(metric.durationSeconds, 40, accuracy: 0.001)
        XCTAssertEqual(metric.outputTokens, 400)
        XCTAssertEqual(metric.turnThroughputTPS, 10, accuracy: 0.001)
        XCTAssertEqual(metric.parserVersion, "claude-transcript-v4")
        XCTAssertEqual(metric.metricVersion, "claude-observed-turn-v1")
        XCTAssertEqual(metric.sourceKind, "primary")
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|prompt"), "turn identity stays the original prompt")
    }

    func testInterjectionAfterMoreThanThirtyMinutesOfInactivityStartsANewTurn() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "stale-prompt"))
        _ = parser.consume(line: try assistant(at: 10, id: "m-stale", output: 50, stop: "tool_use"))
        XCTAssertNil(parser.consume(line: try user(at: 10 + 1_801, id: "fresh-prompt")))
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 10 + 1_811, id: "m-fresh", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.durationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(metric.outputTokens, 100)
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|fresh-prompt"))

        var boundary = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = boundary.consume(line: try user(at: 0, id: "prompt"))
        _ = boundary.consume(line: try assistant(at: 10, id: "m1", output: 50, stop: "tool_use"))
        _ = boundary.consume(line: try user(at: 10 + 1_800, id: "exactly-thirty-minutes"))
        let continued = try XCTUnwrap(terminal(&boundary, assistant(at: 10 + 1_810, id: "m2", output: 50, stop: "end_turn")))
        XCTAssertEqual(continued.outputTokens, 100)
        XCTAssertEqual(continued.id, try expectedID("\(sessionID)|prompt"))
    }

    func testInterruptionMarkerDiscardsTheTurnAndDoesNotStartOne() throws {
        for content: Any in ["[Request interrupted by user]", [["type": "text", "text": "[Request interrupted by user for tool use]"]]] {
            var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
            _ = parser.consume(line: try user(at: 0, id: "prompt"))
            _ = parser.consume(line: try assistant(at: 5, id: "m1", output: 100, stop: "tool_use"))
            XCTAssertNil(parser.consume(line: try user(at: 6, id: "interrupt", content: content)))
            XCTAssertNil(terminal(&parser, try assistant(at: 7, id: "m-orphan", output: 100, stop: "end_turn")))

            _ = parser.consume(line: try user(at: 10, id: "next"))
            let metric = try XCTUnwrap(terminal(&parser, assistant(at: 20, id: "m-next", output: 100, stop: "end_turn")))
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
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 20, id: "m-next", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.model, "claude-sonnet-5-5")

        var withoutTerminal = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = withoutTerminal.consume(line: try user(at: 0, id: "prompt"))
        _ = withoutTerminal.consume(line: try assistant(at: 1, id: "m-synthetic", model: "<synthetic>", output: nil, stop: nil))
        XCTAssertNil(terminal(&withoutTerminal, try assistant(at: 5, id: "m-final", output: 100, stop: "end_turn")))
    }

    func testStreamingResponseCutOffByAnInterruptionIsNeverDrained() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try assistant(at: 10, id: "m-cut", output: 500, stop: nil))
        _ = parser.consume(line: try user(at: 11, id: "interrupt", content: "[Request interrupted by user]"))
        _ = parser.consume(line: try assistant(at: 30, id: "m-next", output: 900, stop: "tool_use"))
        _ = parser.pollEnded(now: base, isFinal: false)
        let drained = parser.drainCompletedResponses()
        XCTAssertEqual(drained.count, 1, "only the complete response after the interruption")
        XCTAssertEqual(drained.first?.outputTokens, 900)
        XCTAssertEqual(try XCTUnwrap(drained.first).durationSeconds, 19, accuracy: 0.001, "timed from the interruption record")
    }

    /// The live-response id of `identity`: a digest, so no session, agent or message id leaves the parser.
    private func liveDigest(_ identity: String) -> String {
        SHA256.hash(data: Data("response|\(identity)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testLiveResponseIdsAreDigestsOfTheSessionAgentAndMessageNotThePathOrIdentifiers() throws {
        func liveID(sidechain: Bool, source: String = "/Users/private/transcript-secret.jsonl", message: String = "m1") throws -> String {
            var parser = ClaudeTranscriptParser(sourceIdentity: source, scope: sidechain ? .subagent : .primary)
            _ = parser.consume(line: try user(at: 0, id: "prompt", sidechain: sidechain, rootPrompt: true))
            _ = parser.consume(line: try assistant(at: 10, id: message, output: 500, stop: "end_turn", sidechain: sidechain))
            _ = parser.pollEnded(now: base, isFinal: true)
            return try XCTUnwrap(parser.drainCompletedResponses().first).id
        }
        let primary = try liveID(sidechain: false)
        XCTAssertEqual(primary, liveDigest("\(sessionID)||m1"))
        let subagent = try liveID(sidechain: true)
        XCTAssertEqual(subagent, liveDigest("\(sessionID)|\(agentID)|m1"))
        for id in [primary, subagent] {
            XCTAssertNotNil(id.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
            XCTAssertFalse(id.contains(sessionID) || id.contains("private") || id.contains("|"))
        }
        XCTAssertNotEqual(primary, subagent)
        XCTAssertNotEqual(primary, try liveID(sidechain: false, message: "m2"))
    }

    func testParentRecordSetsTheResponseStartAndMidResponseRecordsDoNotMoveIt() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        // The attachment written just before the request is the assistant record's parent.
        _ = parser.consume(line: try attachment(at: 4, id: "attach-1"))
        _ = parser.consume(line: try assistant(at: 10, id: "m1", output: 600, stop: nil, blocks: ["thinking"], parent: "attach-1"))
        // A notification user record written while the response streams does not move the start.
        _ = parser.consume(line: try user(at: 12, id: "notification", kind: "task-notification"))
        _ = parser.consume(line: try assistant(at: 14, id: "m1", output: 600, stop: "end_turn", blocks: ["text"], parent: "record-m1"))
        let metric = try XCTUnwrap(terminal(&parser, Data()))
        XCTAssertEqual(metric.responseCount, 1)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 10, accuracy: 0.001, "start 4 s (parent) to end 14 s")
        let drained = parser.drainCompletedResponses()
        XCTAssertEqual(try XCTUnwrap(drained.first).durationSeconds, 10, accuracy: 0.001)
    }

    func testMissingOrLaterParentFallsBackToTheLatestUserRecord() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try toolResult(at: 5))
        // Unknown parent: latest user-type record (the tool result at 5 s).
        _ = parser.consume(line: try assistant(at: 15, id: "m1", output: 500, stop: "tool_use", parent: "never-seen"))
        _ = parser.consume(line: try attachment(at: 30, id: "late-attach"))
        // The parent was written after the response's own record: ignored.
        _ = parser.consume(line: try assistant(at: 20, id: "m2", output: 400, stop: "tool_use", parent: "late-attach"))
        _ = parser.consume(line: try toolResult(at: 21))
        _ = parser.consume(line: try assistant(at: 40, id: "m3", output: 300, stop: "end_turn"))
        let metric = try XCTUnwrap(terminal(&parser, Data()))
        let responses = parser.drainCompletedResponses().sorted { $0.completedAt < $1.completedAt }
        XCTAssertEqual(responses.map(\.durationSeconds), [10, 15, 19])
        XCTAssertEqual(metric.responseCount, 3)
    }

    /// Real shape: Claude Code writes `deferred_tools_record` when the response arrives, in the same
    /// millisecond as the response's first assistant record, which names it as its parent.
    func testDeferredToolsRecordIsNotARequestTrigger() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try toolResult(at: 10.262))
        _ = parser.consume(line: try attachment(at: 10.266, id: "reminder", type: "total_tokens_reminder", parent: "tool-result-10"))
        _ = parser.consume(line: try attachment(at: 14.257, id: "deferred", type: "deferred_tools_record", parent: "reminder"))
        _ = parser.consume(line: try assistant(at: 14.257, id: "X", output: 336, stop: "end_turn", blocks: ["thinking"], parent: "deferred"))
        _ = parser.consume(line: try assistant(at: 14.259, id: "X", output: 336, stop: "end_turn", blocks: ["text"], parent: "record-X"))
        let metric = try XCTUnwrap(terminal(&parser, Data()))
        XCTAssertEqual(metric.responseCount, 1)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 3.993, accuracy: 0.001, "start is the reminder, not the deferred record")
        XCTAssertEqual(try XCTUnwrap(metric.responseSpeedTPS), 336 / 3.993, accuracy: 0.1)
        let live = try XCTUnwrap(parser.drainCompletedResponses().first)
        XCTAssertEqual(live.durationSeconds, 3.993, accuracy: 0.001, "the live stream shares the corrected start")
    }

    func testDeferredToolsRecordWithAnUnknownParentFallsBackToTheLatestUserRecord() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try toolResult(at: 5))
        _ = parser.consume(line: try attachment(at: 14, id: "deferred", type: "deferred_tools_record", parent: "never-seen"))
        _ = parser.consume(line: try assistant(at: 14, id: "m1", output: 300, stop: "end_turn", parent: "deferred"))
        let metric = try XCTUnwrap(terminal(&parser, Data()))
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 9, accuracy: 0.001, "timed from the tool result")
    }

    func testChainedDeferredToolsRecordsInheritTheFirstRealTrigger() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try attachment(at: 4, id: "reminder", type: "total_tokens_reminder"))
        _ = parser.consume(line: try attachment(at: 12, id: "deferred-1", type: "deferred_tools_record", parent: "reminder"))
        _ = parser.consume(line: try attachment(at: 12.001, id: "deferred-2", type: "deferred_tools_record", parent: "deferred-1"))
        _ = parser.consume(line: try assistant(at: 12.002, id: "m1", output: 400, stop: "end_turn", parent: "deferred-2"))
        let metric = try XCTUnwrap(terminal(&parser, Data()))
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 8.002, accuracy: 0.001)
    }

    func testSubagentResponsesIgnoreDeferredToolsRecordsToo() throws {
        var parser = ClaudeSubagentTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "task", sidechain: true))
        _ = parser.consume(line: try toolResult(at: 10, sidechain: true))
        _ = parser.consume(line: try attachment(at: 15, id: "deferred", type: "deferred_tools_record", parent: "tool-result-10", sidechain: true))
        _ = parser.consume(line: try assistant(at: 15, id: "s1", output: 500, stop: "end_turn", sidechain: true, parent: "deferred"))
        let metric = try XCTUnwrap(parser.pollEnded(now: base, isFinal: false))
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(parser.drainCompletedResponses().first).durationSeconds, 5, accuracy: 0.001)
    }

    func testResponseFasterThanTheSpeedBoundNeverQualifiesAndSuchATurnIsNotEmitted() throws {
        XCTAssertFalse(ResponseSpeed.qualifies(outputTokens: 2_001, durationSeconds: 1))
        XCTAssertTrue(ResponseSpeed.qualifies(outputTokens: 2_000, durationSeconds: 1))
        XCTAssertFalse(ResponseSpeed.qualifies(outputTokens: 336, durationSeconds: 0.002))
        XCTAssertFalse(ResponseSpeed.isPlausibleTurnThroughput(outputTokens: 2_001, durationSeconds: 1))
        XCTAssertTrue(ResponseSpeed.isPlausibleTurnThroughput(outputTokens: 2_000, durationSeconds: 1))
        XCTAssertFalse(ResponseSpeed.isPlausibleTurnThroughput(outputTokens: 10, durationSeconds: 0))

        // A fast response inside a slow turn is left out of the response totals; the turn is kept.
        var slowTurn = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = slowTurn.consume(line: try user(at: 0, id: "prompt"))
        _ = slowTurn.consume(line: try toolResult(at: 9.9))
        let kept = try XCTUnwrap(terminal(&slowTurn, assistant(at: 10, id: "m1", output: 300, stop: "end_turn")))
        XCTAssertNil(kept.responseCount)
        XCTAssertTrue(slowTurn.drainCompletedResponses().isEmpty)

        // A whole turn above the bound is a measurement error: no record.
        var fastTurn = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = fastTurn.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(terminal(&fastTurn, try assistant(at: 0.1, id: "m1", output: 500, stop: "end_turn")))
    }

    func testRememberedRecordsAreBoundedAndResetOnReplacement() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try attachment(at: 1, id: "first-attach"))
        for index in 0..<ClaudeTranscriptParser.maximumRememberedRecords {
            _ = parser.consume(line: try attachment(at: 2, id: "filler-\(index)"))
        }
        // The oldest record has been forgotten: fall back to the latest user-type record (the prompt, 0 s).
        _ = parser.consume(line: try assistant(at: 10, id: "m1", output: 500, stop: "tool_use", parent: "first-attach"))
        _ = parser.consume(line: try assistant(at: 20, id: "m2", output: 500, stop: "tool_use"))
        let drained = parser.drainCompletedResponses()
        XCTAssertEqual(try XCTUnwrap(drained.first).durationSeconds, 10, accuracy: 0.001)
        parser.reset(sourceIdentity: "other")
        _ = parser.consume(line: try user(at: 100, id: "prompt-2"))
        _ = parser.consume(line: try assistant(at: 110, id: "m9", output: 500, stop: "tool_use", parent: "filler-4000"))
        _ = parser.consume(line: try assistant(at: 120, id: "m10", output: 500, stop: "tool_use"))
        XCTAssertEqual(try XCTUnwrap(parser.drainCompletedResponses().first).durationSeconds, 10, accuracy: 0.001, "the map was cleared by reset")
    }

    func testMetaUserRecordsAreIgnored() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        XCTAssertNil(parser.consume(line: try user(at: 0, id: "meta-start", meta: true)))
        XCTAssertNil(terminal(&parser, try assistant(at: 5, id: "m-orphan", output: 100, stop: "end_turn")))

        _ = parser.consume(line: try user(at: 10, id: "prompt"))
        _ = parser.consume(line: try assistant(at: 15, id: "m1", output: 100, stop: "tool_use"))
        // A meta record far beyond the gap neither restarts nor continues the turn.
        XCTAssertNil(parser.consume(line: try user(at: 15 + 7_200, id: "meta-late", meta: true)))
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 30, id: "m2", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.durationSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|prompt"))
    }

    func testSubagentTranscriptEmitsSubagentMetricWithDistinctIdentityAndSeparateFollowUpTurn() throws {
        var subagent = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: .subagent)
        XCTAssertNil(subagent.consume(line: try user(at: 0, id: "task", sidechain: true)))
        XCTAssertNil(subagent.consume(line: try assistant(at: 4, id: "s1", output: 60, stop: "tool_use", sidechain: true)))
        XCTAssertNil(subagent.consume(line: try toolResult(at: 5, sidechain: true)))
        let first = try XCTUnwrap(terminal(&subagent, assistant(at: 10, id: "s2", output: 140, stop: "end_turn", sidechain: true)))
        XCTAssertEqual(first.client, "claude-code")
        XCTAssertEqual(first.parserVersion, "claude-transcript-v4")
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
        let second = try XCTUnwrap(terminal(&subagent, assistant(at: 104, id: "s3", output: 40, stop: "end_turn", sidechain: true)))
        XCTAssertEqual(second.outputTokens, 40)
        XCTAssertEqual(second.durationSeconds, 4, accuracy: 0.001)
        XCTAssertNotEqual(second.id, first.id)

        // Predicates are scope-specific: a sidechain record is invisible to the primary parser and vice versa.
        var primary = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = primary.consume(line: try user(at: 0, id: "task", sidechain: true))
        XCTAssertNil(terminal(&primary, try assistant(at: 10, id: "s1", output: 100, stop: "end_turn", sidechain: true)))
        var subagentOnly = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: .subagent)
        _ = subagentOnly.consume(line: try user(at: 0, id: "primary-prompt"))
        XCTAssertNil(terminal(&subagentOnly, try assistant(at: 10, id: "m1", output: 100, stop: "end_turn")))
    }

    func testSubagentSharingPayloadContainsOnlyAllowlistedKeys() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: .subagent)
        _ = parser.consume(line: try user(at: 0, id: "task", sidechain: true))
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 10, id: "s1", output: 200, stop: "end_turn", sidechain: true)))
        let sample = try XCTUnwrap(SharedSample(metric))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["sampleId", "observedAt", "client", "clientVersion", "appVersion", "parserVersion", "metricVersion", "model", "provider", "reasoningEffort", "sourceKind", "outputTokens", "reasoningOutputTokens", "durationMs", "ttftMs", "responseOutputTokens", "responseDurationMs", "responseCount", "providerRegion", "delegatedOutputTokens", "surface", "inputTokens", "cacheReadInputTokens", "cacheWriteInputTokens"])
        XCTAssertEqual(json["sourceKind"] as? String, "subagent")
        XCTAssertEqual(json["metricVersion"] as? String, "claude-observed-subagent-turn-v1")
        XCTAssertEqual(json["parserVersion"] as? String, "claude-transcript-v4")
        XCTAssertEqual(json["appVersion"] as? String, "0.1.19")
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5-5")
        XCTAssertTrue(json["ttftMs"] is NSNull)
        // The only response (200 tokens in 10 s from the task prompt) qualifies.
        XCTAssertEqual(json["responseOutputTokens"] as? Int, 200)
        XCTAssertEqual(try XCTUnwrap(json["responseDurationMs"] as? Double), 10_000, accuracy: 0.001)
        XCTAssertEqual(json["responseCount"] as? Int, 1)
        XCTAssertTrue(json["providerRegion"] is NSNull)
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
            for record in try await monitor.poll(now: Date.now.addingTimeInterval(Double(step) * 11)).metrics { collected[record.id] = record }
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

    // MARK: Live responses through the monitor

    private func append(_ lines: [Data], to url: URL, modified: Date) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        for line in lines { try handle.write(contentsOf: line); try handle.write(contentsOf: Data([0x0A])) }
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testMonitorReturnsOnlyResponsesCompletedSinceItStartedAndNeverTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("synthetic-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let liveSince = Date.now
        let file = project.appendingPathComponent("\(sessionID).jsonl")
        let result = [
            try user(at: -100, id: "prompt", origin: liveSince),
            try assistant(at: -90, id: "m1", output: 500, stop: "tool_use", origin: liveSince),
            try user(at: -89, id: "tool-result", content: [["type": "tool_result", "content": "PRIVATE_RESPONSE"]], origin: liveSince),
            try assistant(at: 10, id: "m2", output: 600, stop: "end_turn", origin: liveSince)
        ]
        try write(result, to: file)

        let monitor = ClaudeSessionMonitor(root: root, liveSince: liveSince)
        let first = try await monitor.poll(now: liveSince)
        // The terminal turn of a text-last message is emitted by the poll that read it.
        XCTAssertEqual(first.metrics.count, 1)
        let turn = try XCTUnwrap(first.metrics.first)
        XCTAssertEqual(turn.outputTokens, 1_100)
        XCTAssertEqual(turn.responseCount, 2, "the turn counts both responses, including the one before liveSince")
        XCTAssertEqual(turn.responseOutputTokens, 1_100)
        XCTAssertEqual(try XCTUnwrap(turn.responseDurationSeconds), 109, accuracy: 0.001)
        // m1 completed 90 s before the monitor started, so it is history, not live.
        XCTAssertEqual(first.responses.map(\.outputTokens), [600])
        XCTAssertEqual(try XCTUnwrap(first.responses.first).completedAt.timeIntervalSince(liveSince), 10, accuracy: 0.01)
        XCTAssertEqual(first.responses.first?.durationSeconds ?? 0, 99, accuracy: 0.001)

        // Nothing new: neither the turn nor the response is reported again.
        let idle = try await monitor.poll(now: liveSince.addingTimeInterval(11))
        XCTAssertTrue(idle.metrics.isEmpty)
        XCTAssertTrue(idle.responses.isEmpty)

        try append([
            try user(at: 20, id: "second-prompt", origin: liveSince),
            try assistant(at: 30, id: "m3", output: 300, stop: "end_turn", origin: liveSince)
        ], to: file, modified: liveSince.addingTimeInterval(22))
        await monitor.noteChanges(SessionFolderChange(paths: [file.standardizedFileURL.path]))
        let second = try await monitor.poll(now: liveSince.addingTimeInterval(22))
        XCTAssertEqual(second.metrics.map(\.outputTokens), [300])
        XCTAssertEqual(second.responses.map(\.outputTokens), [300])
        XCTAssertEqual(second.responses.first?.durationSeconds ?? 0, 10, accuracy: 0.001)
        let after = try await monitor.poll(now: liveSince.addingTimeInterval(33))
        XCTAssertTrue(after.metrics.isEmpty)
        XCTAssertTrue(after.responses.isEmpty)
    }

    func testNotedAppendAndNewFileAreReadWithoutWaitingForDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("synthetic-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let liveSince = Date.now
        let file = project.appendingPathComponent("\(sessionID).jsonl")
        try write([
            try user(at: 1, id: "prompt", origin: liveSince),
            try assistant(at: 5, id: "m1", output: 100, stop: "end_turn", origin: liveSince)
        ], to: file)
        let monitor = ClaudeSessionMonitor(root: root, liveSince: liveSince)
        let first = try await monitor.poll(now: liveSince)
        XCTAssertEqual(first.metrics.map(\.outputTokens), [100])

        try append([
            try user(at: 10, id: "second-prompt", origin: liveSince),
            try assistant(at: 14, id: "m2", output: 200, stop: "end_turn", origin: liveSince)
        ], to: file, modified: liveSince.addingTimeInterval(2))
        let silent = try await monitor.poll(now: liveSince.addingTimeInterval(2))
        XCTAssertTrue(silent.metrics.isEmpty, "the caught-up file is only re-read once a modification is known")
        let noted = await monitor.noteChanges(SessionFolderChange(paths: [file.standardizedFileURL.path]))
        XCTAssertTrue(noted)
        let pending = await monitor.nextPollDeadline(now: liveSince.addingTimeInterval(2))
        XCTAssertEqual(pending, liveSince.addingTimeInterval(2))
        let second = try await monitor.poll(now: liveSince.addingTimeInterval(4))
        XCTAssertEqual(second.metrics.filter { $0.outputTokens == 200 }.count, 1)
        XCTAssertEqual(second.responses.map(\.outputTokens), [200])

        let other = project.appendingPathComponent("another-session.jsonl")
        try write([
            try user(at: 20, id: "other-prompt", origin: liveSince),
            try assistant(at: 24, id: "m3", output: 300, stop: "end_turn", origin: liveSince)
        ], to: other)
        let unseen = try await monitor.poll(now: liveSince.addingTimeInterval(6))
        XCTAssertTrue(unseen.metrics.isEmpty, "a new file waits for discovery unless it is reported")
        let unrelated = await monitor.noteChanges(SessionFolderChange(paths: [project.appendingPathComponent("notes.md").path]))
        XCTAssertFalse(unrelated)
        await monitor.noteChanges(SessionFolderChange(paths: [other.standardizedFileURL.path]))
        let third = try await monitor.poll(now: liveSince.addingTimeInterval(8))
        XCTAssertEqual(third.metrics.filter { $0.outputTokens == 300 }.count, 1)
    }

    func testMonitorHoldsAThinkingLastTerminalTurnUntilThirtySecondsOfPollClock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("synthetic-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let start = Date.now
        try write([
            try user(at: 0, id: "prompt", origin: start),
            try assistant(at: 10, id: "m1", output: 300, stop: "end_turn", origin: start, blocks: ["thinking"])
        ], to: project.appendingPathComponent("\(sessionID).jsonl"))
        let monitor = ClaudeSessionMonitor(root: root, liveSince: start)
        let first = try await monitor.poll(now: start)
        XCTAssertTrue(first.metrics.isEmpty, "the text block may still follow")
        XCTAssertTrue(first.responses.isEmpty)
        let second = try await monitor.poll(now: start.addingTimeInterval(11))
        XCTAssertTrue(second.metrics.isEmpty)
        let third = try await monitor.poll(now: start.addingTimeInterval(31))
        XCTAssertEqual(third.metrics.map(\.outputTokens), [300])
        XCTAssertEqual(third.responses.map(\.outputTokens), [300])
        XCTAssertNil(third.metrics.first?.delegatedOutputTokens, "emitted at once; the delegated total settles later")
        let fourth = try await monitor.poll(now: start.addingTimeInterval(42))
        XCTAssertEqual(fourth.metrics.map(\.id), third.metrics.map(\.id), "the settled re-emission replaces the record")
        XCTAssertEqual(fourth.metrics.first?.delegatedOutputTokens, 0)
        XCTAssertTrue(fourth.responses.isEmpty)
        let fifth = try await monitor.poll(now: start.addingTimeInterval(53))
        XCTAssertTrue(fifth.metrics.isEmpty)
        XCTAssertTrue(fifth.responses.isEmpty)
    }

    // MARK: Origin-aware prompts (claude-transcript-v3)

    func testBackgroundNotificationAfterTheTerminalMessageStartsNoTurn() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt", kind: "human"))
        XCTAssertNil(parser.consume(line: try assistant(at: 5, id: "m1", output: 100, stop: "end_turn")), "a terminal turn waits for the next record")
        // The notification is the first record after the terminal message, so it closes that turn.
        XCTAssertNotNil(parser.consume(line: try user(at: 20, id: "notification", kind: "task-notification")))
        XCTAssertNil(parser.consume(line: try assistant(at: 25, id: "m-reaction", output: 50, stop: "tool_use")))
        XCTAssertNil(terminal(&parser, try assistant(at: 30, id: "m-reaction-final", output: 50, stop: "end_turn")))
        _ = parser.consume(line: try user(at: 100, id: "next", kind: "human"))
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 110, id: "m-next", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|next"))
        XCTAssertEqual(metric.durationSeconds, 10, accuracy: 0.001)
    }

    func testBackgroundNotificationMidTurnIsActivityOnly() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt", kind: "human"))
        _ = parser.consume(line: try assistant(at: 5, id: "m1", output: 100, stop: "tool_use"))
        // Neither continues nor restarts the turn, but keeps it alive for a later human message.
        XCTAssertNil(parser.consume(line: try user(at: 1_500, id: "notification", kind: "task-notification")))
        XCTAssertNil(parser.consume(line: try user(at: 3_000, id: "interjection", kind: "human")))
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 3_010, id: "m2", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|prompt"))
        XCTAssertEqual(metric.outputTokens, 200)
        XCTAssertEqual(metric.durationSeconds, 3_010, accuracy: 0.001)

        // A notification never starts a turn on its own, even from an idle parser.
        var idle = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        XCTAssertNil(idle.consume(line: try user(at: 0, id: "notification", kind: "task-notification")))
        XCTAssertNil(terminal(&idle, try assistant(at: 5, id: "m1", output: 10, stop: "end_turn")))
        // An origin object without a human kind is not a prompt either.
        XCTAssertNil(idle.consume(line: try user(at: 10, id: "other", kind: "something-new")))
        XCTAssertNil(terminal(&idle, try assistant(at: 15, id: "m2", output: 10, stop: "end_turn")))
    }

    func testRecordsWithoutOriginFollowTheV2Rules() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try assistant(at: 5, id: "m1", output: 100, stop: "tool_use"))
        _ = parser.consume(line: try user(at: 20, id: "interjection"))
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 40, id: "m2", output: 300, stop: "end_turn")))
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|prompt"))
        XCTAssertEqual(metric.outputTokens, 400)
        XCTAssertNil(parser.consume(line: try user(at: 50, id: "meta", meta: true)))
        XCTAssertNil(terminal(&parser, try assistant(at: 55, id: "m3", output: 10, stop: "end_turn")))
    }

    func testCoordinatorMetaFollowUpIsASecondSubagentTurn() throws {
        var subagent = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: .subagent)
        _ = subagent.consume(line: try user(at: 0, id: "task", sidechain: true))
        let first = try XCTUnwrap(terminal(&subagent, assistant(at: 10, id: "s1", output: 100, stop: "end_turn", sidechain: true)))
        XCTAssertEqual(first.id, try expectedID("\(sessionID)|\(agentID)|task"))

        // Other meta records stay ignored in a subagent transcript.
        XCTAssertNil(subagent.consume(line: try user(at: 50, id: "other-meta", sidechain: true, meta: true, kind: "system")))
        XCTAssertNil(subagent.consume(line: try user(at: 51, id: "plain-meta", sidechain: true, meta: true)))
        // A non-meta record with a foreign origin kind is activity only.
        XCTAssertNil(subagent.consume(line: try user(at: 51.5, id: "notification", sidechain: true, kind: "task-notification")))
        XCTAssertNil(terminal(&subagent, try assistant(at: 52, id: "s-orphan", output: 5, stop: "end_turn", sidechain: true)))

        XCTAssertNil(subagent.consume(line: try user(at: 100, id: "follow-up", sidechain: true, meta: true, kind: "coordinator")))
        let second = try XCTUnwrap(terminal(&subagent, assistant(at: 108, id: "s2", output: 80, stop: "end_turn", sidechain: true)))
        XCTAssertEqual(second.id, try expectedID("\(sessionID)|\(agentID)|follow-up"))
        XCTAssertEqual(second.durationSeconds, 8, accuracy: 0.001)
        XCTAssertEqual(second.outputTokens, 80)

        // The coordinator exception is subagent-only: in a primary transcript it is just an unknown origin.
        var primary = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        XCTAssertNil(primary.consume(line: try user(at: 0, id: "c", meta: true, kind: "coordinator")))
        XCTAssertNil(terminal(&primary, try assistant(at: 5, id: "m", output: 5, stop: "end_turn")))
    }

    // MARK: Mid-file start synchronisation

    func testTailStartedParserSkipsAPartialTurnAndMeasuresTheNextFullTurn() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        parser.markStartedMidFile()
        // The tail begins mid-turn: a human interjection (parent set) is not a reliable turn start.
        XCTAssertNil(parser.consume(line: try user(at: 0, id: "interjection", kind: "human")))
        XCTAssertNil(parser.consume(line: try assistant(at: 5, id: "m1", output: 9_000, stop: "tool_use")))
        XCTAssertNil(terminal(&parser, try assistant(at: 10, id: "m2", output: 9_000, stop: "end_turn")))
        // The terminal record synchronised the parser; the next prompt is measured.
        _ = parser.consume(line: try user(at: 100, id: "next", kind: "human"))
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 110, id: "m3", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|next"))
        XCTAssertEqual(metric.outputTokens, 100)
    }

    func testTailStartedParserSynchronisesOnAConversationRootPrompt() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        parser.markStartedMidFile()
        XCTAssertNil(parser.consume(line: try toolResult(at: 0)))
        _ = parser.consume(line: try user(at: 1, id: "root", rootPrompt: true))
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 11, id: "m1", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|root"))

        // A parser reset (file replaced) starts from the beginning again.
        var replaced = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        replaced.markStartedMidFile()
        replaced.reset(sourceIdentity: "synthetic")
        _ = replaced.consume(line: try user(at: 0, id: "p"))
        XCTAssertNotNil(terminal(&replaced, try assistant(at: 5, id: "m", output: 10, stop: "end_turn")))
    }

    func testAbsentParentUuidDoesNotSynchroniseATailStartedParser() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        parser.markStartedMidFile()
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: user(at: 0, id: "no-parent-key", rootPrompt: true)) as? [String: Any])
        record.removeValue(forKey: "parentUuid")
        XCTAssertNil(parser.consume(line: try JSONSerialization.data(withJSONObject: record)))
        XCTAssertNil(parser.consume(line: try assistant(at: 5, id: "m1", output: 10, stop: "tool_use")))
        XCTAssertNil(terminal(&parser, try assistant(at: 6, id: "m2", output: 10, stop: "end_turn")), "still unsynchronised before the terminal record")
    }

    func testLiveTailSkipsTheTurnItJoinedMidwayWhileTheArchiveReaderMeasuresItWhole() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("synthetic-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let start = Date.now.addingTimeInterval(-120)
        let padding = Data(repeating: 0x20, count: CodexSessionMonitor.recentTailBytes + 4_096) + Data([0x0A])
        var data = Data()
        for line in [
            try user(at: 0, id: "long", origin: start, kind: "human", rootPrompt: true),
            try assistant(at: 5, id: "m1", output: 100, stop: "tool_use", origin: start)
        ] { data.append(line); data.append(0x0A) }
        data.append(padding)
        for line in [
            try user(at: 30, id: "interjection", origin: start, kind: "human"),
            try assistant(at: 40, id: "m2", output: 300, stop: "end_turn", origin: start),
            try user(at: 50, id: "next", origin: start, kind: "human"),
            try assistant(at: 55, id: "m3", output: 60, stop: "end_turn", origin: start)
        ] { data.append(line); data.append(0x0A) }
        try data.write(to: project.appendingPathComponent("\(sessionID).jsonl"))

        let monitor = ClaudeSessionMonitor(root: root)
        var collected: [String: TurnMetric] = [:]
        var all: [TurnMetric] = []
        for step in 0..<12 {
            let records = try await monitor.poll(now: Date.now.addingTimeInterval(Double(step) * 11)).metrics
            all += records
            for record in records { collected[record.id] = record }
        }
        XCTAssertEqual(collected.count, 2)
        let long = try XCTUnwrap(collected[try expectedID("\(sessionID)|long")])
        XCTAssertEqual(long.outputTokens, 400, "the archive reader measures the whole turn")
        XCTAssertEqual(long.durationSeconds, 40, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(collected[try expectedID("\(sessionID)|next")]).outputTokens, 60)
        XCTAssertEqual(all.filter { $0.outputTokens == 300 }.count, 0, "the tail never emits the partial turn")
    }

    // MARK: Provider attribution and model ids (0.1.13)

    private let anthropicMessage = "msg_01ABCDEFGHIJKLMNOPQRSTUV"
    private let anthropicRequest = "req_011CABCDEFGHIJKLMNOPQRST"
    private let bedrockMessage = "msg_bdrk_01ABCDEFGHIJKLMNOPQR"
    private let vertexMessage = "msg_vrtx_01ABCDEFGHIJKLMNOPQR"

    private func metric(
        scope: ClaudeTranscriptParser.Scope = .primary,
        records: [(id: String, requestID: String?, model: String)]
    ) throws -> TurnMetric? {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: scope)
        let sidechain = scope == .subagent
        _ = parser.consume(line: try user(at: 0, id: "prompt", sidechain: sidechain))
        var result: TurnMetric?
        for (index, record) in records.enumerated() {
            let last = index == records.count - 1
            result = parser.consume(line: try assistant(
                at: Double(index + 1) * 5, id: record.id, model: record.model, output: 10,
                stop: last ? "end_turn" : "tool_use", sidechain: sidechain, requestID: record.requestID
            ))
        }
        return result ?? parser.pollEnded(now: base, isFinal: false)
    }

    func testProviderIsAttributedFromExplicitMessageAndRequestIdentifiers() throws {
        for scope in [ClaudeTranscriptParser.Scope.primary, .subagent] {
            XCTAssertEqual(try metric(scope: scope, records: [(anthropicMessage, anthropicRequest, "claude-sonnet-5-5")])?.provider, "anthropic")
            XCTAssertEqual(try metric(scope: scope, records: [(bedrockMessage, nil, "claude-sonnet-5-5")])?.provider, "amazon-bedrock")
            XCTAssertEqual(try metric(scope: scope, records: [(vertexMessage, nil, "claude-sonnet-5-5")])?.provider, "google-vertex")
        }
        let first = try metric(records: [(anthropicMessage, anthropicRequest, "m"), ("msg_01ZYXWVUTSRQPONMLKJIHGFE", "req_011CZYXWVUTSRQPONMLKJIHG", "m")])
        XCTAssertEqual(first?.provider, "anthropic")
    }

    func testProviderStaysUnknownWithoutCompleteEvidence() throws {
        // msg_01 alone is not enough: the request ID is required, and it must have the req_ shape.
        XCTAssertEqual(try metric(records: [(anthropicMessage, nil, "claude-sonnet-5-5")])?.provider, "unknown")
        XCTAssertEqual(try metric(records: [(anthropicMessage, "request-1", "claude-sonnet-5-5")])?.provider, "unknown")
        XCTAssertEqual(try metric(records: [(anthropicMessage, "req_short", "claude-sonnet-5-5")])?.provider, "unknown")
        // Wrong message shapes.
        XCTAssertEqual(try metric(records: [("msg_01SHORT", anthropicRequest, "claude-sonnet-5-5")])?.provider, "unknown")
        XCTAssertEqual(try metric(records: [("m1", anthropicRequest, "claude-sonnet-5-5")])?.provider, "unknown")
        XCTAssertEqual(try metric(records: [("msg_bdrk_short", nil, "claude-sonnet-5-5")])?.provider, "unknown")
        XCTAssertEqual(try metric(records: [("msg_vrtx_" + String(repeating: "A", count: 65), nil, "claude-sonnet-5-5")])?.provider, "unknown")
        // The model name is never routing evidence.
        XCTAssertEqual(try metric(records: [("m1", nil, "us.anthropic.claude-sonnet-4-5-20250929-v1:0")])?.provider, "unknown")
    }

    func testMixedOrPartialProviderEvidenceInOneTurnIsUnknown() throws {
        for scope in [ClaudeTranscriptParser.Scope.primary, .subagent] {
            XCTAssertEqual(try metric(scope: scope, records: [
                (anthropicMessage, anthropicRequest, "claude-sonnet-5-5"), (bedrockMessage, nil, "claude-sonnet-5-5")
            ])?.provider, "unknown")
            XCTAssertEqual(try metric(scope: scope, records: [
                (bedrockMessage, nil, "claude-sonnet-5-5"), (vertexMessage, nil, "claude-sonnet-5-5")
            ])?.provider, "unknown")
            XCTAssertEqual(try metric(scope: scope, records: [
                (bedrockMessage, nil, "claude-sonnet-5-5"), ("msg-no-evidence", nil, "claude-sonnet-5-5")
            ])?.provider, "unknown")
            XCTAssertEqual(try metric(scope: scope, records: [
                ("msg-no-evidence", nil, "claude-sonnet-5-5"), (bedrockMessage, nil, "claude-sonnet-5-5")
            ])?.provider, "unknown")
        }
        // A later turn is judged on its own records.
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "p1"))
        XCTAssertEqual(terminal(&parser, try assistant(at: 5, id: "m1", output: 5, stop: "end_turn"))?.provider, "unknown")
        _ = parser.consume(line: try user(at: 10, id: "p2"))
        XCTAssertEqual(terminal(&parser, try assistant(at: 15, id: bedrockMessage, output: 5, stop: "end_turn"))?.provider, "amazon-bedrock")
    }

    func testClaudeModelIdentifiersAreNormalisedAcrossPlatforms() throws {
        let table: [(raw: String, expected: String?)] = [
            ("claude-sonnet-5-5", "claude-sonnet-5-5"),
            ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5-20250929"),
            ("eu.anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5-20250929"),
            ("us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5-20250929"),
            ("anthropic.claude-3-haiku-20240307-v1:0", "claude-3-haiku-20240307"),
            ("global.anthropic.claude-opus-4-6-v1", "claude-opus-4-6"),
            ("anthropic.claude-opus-4-6", "claude-opus-4-6"),
            ("claude-sonnet-4-5@20250929", "claude-sonnet-4-5-20250929"),
            ("claude-3-5-sonnet@20240620", "claude-3-5-sonnet-20240620"),
            ("claude-opus-4@latest", nil),
            ("arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/abc123", nil),
            ("arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0", nil),
            ("anthropic.claude-sonnet-4-5-20250929-v1:", nil),
            ("projects/p/locations/l/publishers/anthropic/models/claude-sonnet-4-5@20250929", nil),
            ("custom/claude", nil)
        ]
        for (raw, expected) in table {
            let result = try metric(records: [(anthropicMessage, anthropicRequest, raw)])
            XCTAssertNotNil(result, raw)
            XCTAssertEqual(result?.model, expected, raw)
        }
    }

    func testModelConsistencyComparesNormalisedIdentifiers() throws {
        let same = try metric(records: [
            (bedrockMessage, nil, "us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
            ("msg_bdrk_01ZYXWVUTSRQPONMLKJI", nil, "claude-sonnet-4-5-20250929")
        ])
        XCTAssertEqual(same?.model, "claude-sonnet-4-5-20250929")
        let different = try metric(records: [
            (bedrockMessage, nil, "us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
            ("msg_bdrk_01ZYXWVUTSRQPONMLKJI", nil, "claude-opus-4-6")
        ])
        XCTAssertNil(different?.model)
    }

    func testBedrockSharedSampleCarriesProviderAndNormalisedModel() throws {
        let result = try XCTUnwrap(metric(records: [(bedrockMessage, nil, "global.anthropic.claude-opus-4-6-v1")]))
        let sample = try XCTUnwrap(SharedSample(result.withDelegatedOutputTokens(0)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertEqual(json["provider"] as? String, "amazon-bedrock")
        XCTAssertEqual(json["model"] as? String, "claude-opus-4-6")
    }

    func testSharedSampleProviderAllowlistDependsOnClient() throws {
        func sample(client: String, provider: String) -> SharedSample? {
            let (parser, metricVersion): (String, String) = switch client {
            case "claude-code": ("claude-transcript-v4", "claude-observed-turn-v1")
            case "grok-build": ("grok-session-v2", "grok-observed-work-turn-v1")
            default: ("codex-rollout-v2", "turn-v1")
            }
            return SharedSample(TurnMetric(
                id: "id", completedAt: base, model: "m", outputTokens: 10, durationSeconds: 2, codexTTFTSeconds: nil,
                turnThroughputTPS: 5, client: client, clientVersion: client == "grok-build" ? nil : "1.0",
                parserVersion: parser, metricVersion: metricVersion, sourceKind: "primary", provider: provider,
                delegatedOutputTokens: 0
            ))
        }
        for provider in ["openai", "anthropic", "xai", "unknown"] {
            for client in ["codex", "claude-code", "grok-build"] {
                XCTAssertNotNil(sample(client: client, provider: provider), "\(client) \(provider)")
            }
        }
        for provider in ["amazon-bedrock", "google-vertex"] {
            XCTAssertEqual(sample(client: "claude-code", provider: provider)?.provider, provider)
            XCTAssertNil(sample(client: "codex", provider: provider))
            XCTAssertNil(sample(client: "grok-build", provider: provider))
        }
        XCTAssertNil(sample(client: "claude-code", provider: "azure"))
        XCTAssertEqual(SharedSample(try XCTUnwrap(metric(records: [(anthropicMessage, anthropicRequest, "m")])).withDelegatedOutputTokens(0))?.appVersion, "0.1.19")
    }

    // MARK: Response speed (response-v1)

    func testToolLoopMeasuresEachResponseFromItsOwnTrigger() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(parser.consume(line: try assistant(at: 10, id: "m1", output: 500, stop: "tool_use")))
        XCTAssertNil(parser.consume(line: try toolResult(at: 12)))
        XCTAssertNil(parser.consume(line: try assistant(at: 20, id: "m2", output: 400, stop: "end_turn")))
        XCTAssertTrue(parser.hasPendingWork)
        let metric = try XCTUnwrap(parser.pollEnded(now: base, isFinal: false))
        XCTAssertFalse(parser.hasPendingWork)

        XCTAssertEqual(metric.outputTokens, 900)
        XCTAssertEqual(metric.durationSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(metric.responseOutputTokens, 900)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 18, accuracy: 0.001, "m1 runs 0 to 10 s, m2 runs from the tool result at 12 s to 20 s")
        XCTAssertEqual(metric.responseCount, 2)
        XCTAssertEqual(try XCTUnwrap(metric.responseSpeedTPS), 50, accuracy: 0.001)

        let responses = parser.drainCompletedResponses()
        XCTAssertEqual(responses.map(\.outputTokens), [500, 400])
        XCTAssertEqual(responses.map(\.durationSeconds), [10, 8])
        XCTAssertEqual(responses.map(\.completedAt), [base.addingTimeInterval(10), base.addingTimeInterval(20)])
    }

    func testMultiBlockMessageEndsAtItsLastRecordAndTurnCompletesThere() throws {
        // Thinking block, then the text block of the same terminal message.
        var thinking = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = thinking.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(thinking.consume(line: try assistant(at: 3, id: "m1", output: 120, stop: nil)))
        XCTAssertFalse(thinking.hasPendingWork, "a record without a stop reason is still streaming")
        XCTAssertNil(thinking.consume(line: try assistant(at: 9, id: "m1", output: 400, stop: "end_turn")))
        let metric = try XCTUnwrap(thinking.pollEnded(now: base, isFinal: false))
        XCTAssertEqual(metric.completedAt, base.addingTimeInterval(9), "the turn completes at the last record of the terminal message")
        XCTAssertEqual(metric.durationSeconds, 9, accuracy: 0.001)
        XCTAssertEqual(metric.outputTokens, 400, "the message counts its largest usage once")
        XCTAssertEqual(metric.responseOutputTokens, 400)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 9, accuracy: 0.001)
        XCTAssertEqual(metric.responseCount, 1)

        // Records that already carry the terminal stop reason keep extending the message.
        var repeated = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = repeated.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(repeated.consume(line: try assistant(at: 3, id: "m1", output: 200, stop: "end_turn")))
        XCTAssertNil(repeated.consume(line: try assistant(at: 9, id: "m1", output: 450, stop: "end_turn")))
        let second = try XCTUnwrap(repeated.pollEnded(now: base, isFinal: false))
        XCTAssertEqual(second.completedAt, base.addingTimeInterval(9))
        XCTAssertEqual(second.responseOutputTokens, 450)
        XCTAssertEqual(try XCTUnwrap(second.responseDurationSeconds), 9, accuracy: 0.001)
        XCTAssertNil(repeated.pollEnded(now: base, isFinal: false), "a closed turn is not emitted twice")
    }

    func testStreamingToolResultBetweenRecordsOfOneMessageDoesNotMoveItsStart() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(parser.consume(line: try assistant(at: 3, id: "m1", output: 100, stop: nil)))
        XCTAssertNil(parser.consume(line: try toolResult(at: 5)))
        XCTAssertNil(parser.consume(line: try assistant(at: 9, id: "m1", output: 300, stop: "tool_use")))
        XCTAssertNil(parser.consume(line: try assistant(at: 15, id: "m2", output: 250, stop: "end_turn")))
        let metric = try XCTUnwrap(parser.pollEnded(now: base, isFinal: false))
        // m1 still starts at the prompt (9 s); m2 starts at the tool result (5 s to 15 s).
        XCTAssertEqual(metric.responseOutputTokens, 550)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 19, accuracy: 0.001)
        XCTAssertEqual(metric.responseCount, 2)
        XCTAssertEqual(parser.drainCompletedResponses().map(\.durationSeconds), [9, 10])
    }

    func testResponsesUnderTwoHundredTokensAreExcluded() throws {
        XCTAssertEqual(ResponseSpeed.minimumOutputTokens, 200)
        func metric(tokens: Int) throws -> TurnMetric {
            var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
            _ = parser.consume(line: try user(at: 0, id: "prompt"))
            return try XCTUnwrap(terminal(&parser, assistant(at: 10, id: "m1", output: tokens, stop: "end_turn")))
        }
        let short = try metric(tokens: 199)
        XCTAssertNil(short.responseOutputTokens)
        XCTAssertNil(short.responseDurationSeconds)
        XCTAssertNil(short.responseCount)
        XCTAssertNil(short.responseSpeedTPS)
        XCTAssertEqual(short.outputTokens, 199, "the turn metric itself is unaffected")
        let boundary = try metric(tokens: 200)
        XCTAssertEqual(boundary.responseOutputTokens, 200)
        XCTAssertEqual(boundary.responseCount, 1)

        // Only the qualifying response of a loop contributes, with its own duration.
        var loop = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = loop.consume(line: try user(at: 0, id: "prompt"))
        _ = loop.consume(line: try assistant(at: 5, id: "m1", output: 150, stop: "tool_use"))
        _ = loop.consume(line: try toolResult(at: 6))
        let mixed = try XCTUnwrap(terminal(&loop, assistant(at: 16, id: "m2", output: 300, stop: "end_turn")))
        XCTAssertEqual(mixed.outputTokens, 450)
        XCTAssertEqual(mixed.responseOutputTokens, 300)
        XCTAssertEqual(try XCTUnwrap(mixed.responseDurationSeconds), 10, accuracy: 0.001)
        XCTAssertEqual(mixed.responseCount, 1)
        XCTAssertEqual(loop.drainCompletedResponses().map(\.outputTokens), [300])
    }

    func testResponsesLongerThanTenMinutesAreExcludedAndExactlyTenMinutesIsKept() throws {
        XCTAssertEqual(ResponseSpeed.maximumDurationSeconds, 600)
        func metric(seconds: Double) throws -> TurnMetric {
            var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
            _ = parser.consume(line: try user(at: 0, id: "prompt"))
            return try XCTUnwrap(terminal(&parser, assistant(at: seconds, id: "m1", output: 1_000, stop: "end_turn")))
        }
        let stalled = try metric(seconds: 601)
        XCTAssertNil(stalled.responseOutputTokens)
        XCTAssertNil(stalled.responseCount)
        XCTAssertEqual(stalled.outputTokens, 1_000)
        let limit = try metric(seconds: 600)
        XCTAssertEqual(limit.responseOutputTokens, 1_000)
        XCTAssertEqual(try XCTUnwrap(limit.responseDurationSeconds), 600, accuracy: 0.001)

        var live = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = live.consume(line: try user(at: 0, id: "prompt"))
        _ = terminal(&live, try assistant(at: 601, id: "m1", output: 1_000, stop: "end_turn"))
        XCTAssertTrue(live.drainCompletedResponses().isEmpty)
    }

    func testSyntheticMessageNeverCountsAndInvalidatesTheTurn() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(parser.consume(line: try assistant(at: 10, id: "m-synthetic", model: "<synthetic>", output: 900, stop: "tool_use")))
        XCTAssertNil(parser.consume(line: try toolResult(at: 11)))
        XCTAssertNil(terminal(&parser, try assistant(at: 20, id: "m-final", output: 500, stop: "end_turn")), "the turn is invalid")
        XCTAssertNil(parser.pollEnded(now: base, isFinal: false))
        let responses = parser.drainCompletedResponses()
        XCTAssertFalse(responses.contains { $0.id.contains("m-synthetic") }, "a synthetic message is never a response")
        XCTAssertEqual(responses.map(\.outputTokens), [500], "the live stream still times genuine responses on their own data")

        // A terminal synthetic message discards the turn outright.
        var terminalSynthetic = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = terminalSynthetic.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(terminal(&terminalSynthetic, try assistant(at: 10, id: "m-synthetic", model: "<synthetic>", output: 900, stop: "stop_sequence")))
        XCTAssertTrue(terminalSynthetic.drainCompletedResponses().isEmpty)
    }

    func testInterruptedTurnEmitsNoTurnAndItsStreamingResponseIsNeverDrained() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try assistant(at: 10, id: "m1", output: 500, stop: "tool_use"))
        _ = parser.consume(line: try toolResult(at: 11))
        // m2 is still streaming (no stop reason) when the user interrupts.
        _ = parser.consume(line: try assistant(at: 30, id: "m2", output: 600, stop: nil))
        XCTAssertNil(parser.consume(line: try user(at: 31, id: "interrupt", content: "[Request interrupted by user]")))
        XCTAssertNil(parser.pollEnded(now: base, isFinal: false))
        XCTAssertFalse(parser.hasPendingWork)
        // m1 completed before the interruption and was already reported; m2 never completed.
        XCTAssertEqual(parser.drainCompletedResponses().map(\.outputTokens), [500])

        // A completed response of an interrupted turn is still reported, but no turn is.
        var completed = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = completed.consume(line: try user(at: 0, id: "prompt"))
        _ = completed.consume(line: try assistant(at: 10, id: "m1", output: 500, stop: "tool_use"))
        _ = completed.consume(line: try user(at: 11, id: "interrupt", content: "[Request interrupted by user for tool use]"))
        XCTAssertNil(completed.pollEnded(now: base, isFinal: false))
        XCTAssertEqual(completed.drainCompletedResponses().map(\.outputTokens), [500])
    }

    func testMidFileReaderMeasuresNoTurnButDrainsResponsesWithTheirOwnTrigger() throws {
        var tail = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        tail.markStartedMidFile()
        _ = tail.consume(line: try user(at: 0, id: "interjection", kind: "human"))
        _ = tail.consume(line: try assistant(at: 10, id: "m1", output: 500, stop: "tool_use"))
        XCTAssertNil(tail.pollEnded(now: base, isFinal: false))
        let responses = tail.drainCompletedResponses()
        XCTAssertEqual(responses.map(\.outputTokens), [500])
        XCTAssertEqual(responses.first?.durationSeconds ?? 0, 10, accuracy: 0.001)

        // Without any user record before it the response has no trigger and cannot be timed.
        var untimed = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        untimed.markStartedMidFile()
        _ = untimed.consume(line: try assistant(at: 10, id: "m1", output: 500, stop: "tool_use"))
        XCTAssertNil(untimed.pollEnded(now: base, isFinal: false))
        XCTAssertTrue(untimed.drainCompletedResponses().isEmpty)
    }

    func testResponseOutsideAHumanTurnIsDrainedButNeverCountedInATurn() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        // A background notification triggers a response while no human turn is active.
        XCTAssertNil(parser.consume(line: try user(at: 0, id: "notification", kind: "task-notification")))
        XCTAssertNil(parser.consume(line: try assistant(at: 10, id: "m-reaction", output: 400, stop: "end_turn")))
        XCTAssertNil(parser.pollEnded(now: base, isFinal: false), "no turn exists to emit")
        let reaction = parser.drainCompletedResponses()
        XCTAssertEqual(reaction.map(\.outputTokens), [400])
        XCTAssertEqual(reaction.first?.durationSeconds ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(reaction.first?.sourceKind, "primary")

        // The next human turn's totals contain only its own response.
        _ = parser.consume(line: try user(at: 20, id: "prompt", kind: "human"))
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 30, id: "m-next", output: 300, stop: "end_turn")))
        XCTAssertEqual(metric.outputTokens, 300)
        XCTAssertEqual(metric.responseOutputTokens, 300)
        XCTAssertEqual(metric.responseCount, 1)
        XCTAssertEqual(parser.drainCompletedResponses().map(\.outputTokens), [300])

        // A response left open when a turn starts belongs to no turn either.
        var open = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = open.consume(line: try user(at: 0, id: "notification", kind: "task-notification"))
        _ = open.consume(line: try assistant(at: 10, id: "m-reaction", output: 400, stop: "end_turn"))
        _ = open.consume(line: try user(at: 20, id: "prompt", kind: "human"))
        let second = try XCTUnwrap(terminal(&open, assistant(at: 30, id: "m-next", output: 300, stop: "end_turn")))
        XCTAssertEqual(second.responseOutputTokens, 300, "the reaction began before the turn")
        XCTAssertEqual(second.responseCount, 1)
        XCTAssertEqual(open.drainCompletedResponses().map(\.outputTokens), [400, 300])
    }

    func testTurnWithoutQualifyingResponsesStillEmitsWithNilResponseFields() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        let metric = try XCTUnwrap(terminal(&parser, assistant(at: 5, id: "m1", output: 50, stop: "end_turn")))
        XCTAssertEqual(metric.outputTokens, 50)
        XCTAssertNil(metric.responseOutputTokens)
        XCTAssertNil(metric.responseDurationSeconds)
        XCTAssertNil(metric.responseCount)
        XCTAssertNil(metric.responseSpeedTPS)
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty)
    }

    func testMetaAndNotificationRecordsAreTriggersForTheNextResponse() throws {
        // A meta record (for example injected context) is a trigger even though it is never a prompt.
        var meta = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = meta.consume(line: try user(at: 0, id: "prompt"))
        _ = meta.consume(line: try assistant(at: 10, id: "m1", output: 300, stop: "tool_use"))
        _ = meta.consume(line: try user(at: 12, id: "meta", meta: true))
        let first = try XCTUnwrap(terminal(&meta, assistant(at: 20, id: "m2", output: 400, stop: "end_turn")))
        XCTAssertEqual(first.responseOutputTokens, 700)
        XCTAssertEqual(try XCTUnwrap(first.responseDurationSeconds), 18, accuracy: 0.001, "m1 10 s plus m2 8 s from the meta record")

        // The latest trigger wins: a background notification after the meta record.
        var notification = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = notification.consume(line: try user(at: 0, id: "prompt", kind: "human"))
        _ = notification.consume(line: try assistant(at: 10, id: "m1", output: 300, stop: "tool_use"))
        _ = notification.consume(line: try user(at: 12, id: "meta", meta: true))
        _ = notification.consume(line: try user(at: 15, id: "notification", kind: "task-notification"))
        let second = try XCTUnwrap(terminal(&notification, assistant(at: 20, id: "m2", output: 400, stop: "end_turn")))
        XCTAssertEqual(try XCTUnwrap(second.responseDurationSeconds), 15, accuracy: 0.001, "m1 10 s plus m2 5 s from the notification")
        XCTAssertEqual(second.durationSeconds, 20, accuracy: 0.001)
    }

    func testPollEndedClosesTerminalTurnsAndCompletedResponsesOnly() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        XCTAssertNil(parser.pollEnded(now: base, isFinal: false))
        XCTAssertFalse(parser.hasPendingWork)
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(parser.pollEnded(now: base, isFinal: false), "a turn without records has nothing to close")

        // A response that is still streaming (no stop reason yet) is never cut.
        _ = parser.consume(line: try assistant(at: 4, id: "m1", output: 300, stop: nil))
        XCTAssertFalse(parser.hasPendingWork)
        XCTAssertNil(parser.pollEnded(now: base, isFinal: false))
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty)

        // The same message completes; it is held until a record or the end of a poll proves it is complete.
        _ = parser.consume(line: try assistant(at: 8, id: "m1", output: 320, stop: "tool_use"))
        XCTAssertTrue(parser.hasPendingWork)
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty)
        XCTAssertNil(parser.pollEnded(now: base, isFinal: false), "a non-terminal response finalises but emits no turn")
        XCTAssertFalse(parser.hasPendingWork)
        let finalised = parser.drainCompletedResponses()
        XCTAssertEqual(finalised.map(\.outputTokens), [320])
        XCTAssertEqual(finalised.first?.durationSeconds ?? 0, 8, accuracy: 0.001)
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty)

        // The turn carries on and the terminal message waits for the end of the poll.
        _ = parser.consume(line: try toolResult(at: 9))
        XCTAssertNil(parser.consume(line: try assistant(at: 15, id: "m2", output: 250, stop: "end_turn")))
        XCTAssertTrue(parser.hasPendingWork)
        let metric = try XCTUnwrap(parser.pollEnded(now: base, isFinal: false))
        XCTAssertEqual(metric.outputTokens, 570)
        XCTAssertEqual(metric.responseCount, 2)
        XCTAssertFalse(parser.hasPendingWork)
        XCTAssertNil(parser.pollEnded(now: base, isFinal: false))
    }

    // MARK: Pending terminal messages that end in a thinking block

    func testThinkingFirstTerminalMessageReportsItsFinalUsageAndLastRecordTime() throws {
        for endPollBetweenRecords in [false, true] {
            var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
            _ = parser.consume(line: try user(at: 0, id: "prompt"))
            XCTAssertNil(parser.consume(line: try assistant(at: 3, id: "m1", output: 50, stop: "end_turn", blocks: ["thinking"])))
            if endPollBetweenRecords {
                XCTAssertNil(parser.pollEnded(now: base, isFinal: false), "a thinking-last message may still receive its text")
            }
            XCTAssertNil(parser.consume(line: try assistant(at: 9, id: "m1", output: 400, stop: "end_turn", blocks: ["text"])))
            let metric = try XCTUnwrap(parser.pollEnded(now: base.addingTimeInterval(1), isFinal: false), "a text-last message closes at once")
            XCTAssertEqual(metric.outputTokens, 400, "the final usage, not the partial one")
            XCTAssertEqual(metric.completedAt, base.addingTimeInterval(9))
            XCTAssertEqual(metric.durationSeconds, 9, accuracy: 0.001)
            XCTAssertEqual(metric.responseOutputTokens, 400)
            XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 9, accuracy: 0.001)
            XCTAssertEqual(parser.drainCompletedResponses().map(\.outputTokens), [400])
        }
    }

    func testThinkingLastTerminalMessageSurvivesPollEndsUntilTextOrALaterRecordArrives() throws {
        // Closed by a later record: the turn ends at the thinking record.
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(parser.consume(line: try assistant(at: 3, id: "m1", output: 300, stop: "end_turn", blocks: ["thinking"])))
        XCTAssertTrue(parser.hasPendingWork)
        XCTAssertNil(parser.pollEnded(now: base, isFinal: false))
        XCTAssertNil(parser.pollEnded(now: base.addingTimeInterval(10), isFinal: false))
        XCTAssertTrue(parser.hasPendingWork)
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty)
        let metric = try XCTUnwrap(parser.consume(line: try user(at: 20, id: "next")))
        XCTAssertEqual(metric.completedAt, base.addingTimeInterval(3))
        XCTAssertEqual(metric.outputTokens, 300)
        XCTAssertEqual(parser.drainCompletedResponses().map(\.durationSeconds), [3])
    }

    func testThinkingLastTerminalMessageTimesOutAfterThirtySecondsOfPollClock() throws {
        XCTAssertEqual(ClaudeTranscriptParser.pendingTimeout, 30)
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try assistant(at: 3, id: "m1", output: 300, stop: "end_turn", blocks: ["thinking"]))
        let t0 = base.addingTimeInterval(100)
        XCTAssertNil(parser.pollEnded(now: t0, isFinal: false), "the first call starts the clock")
        XCTAssertNil(parser.pollEnded(now: t0.addingTimeInterval(29), isFinal: false))
        let metric = try XCTUnwrap(parser.pollEnded(now: t0.addingTimeInterval(30), isFinal: false))
        XCTAssertEqual(metric.completedAt, base.addingTimeInterval(3))
        XCTAssertFalse(parser.hasPendingWork)
        XCTAssertNil(parser.pollEnded(now: t0.addingTimeInterval(60), isFinal: false))

        // A text record that arrives before the timeout closes it at the next poll end instead.
        var text = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = text.consume(line: try user(at: 0, id: "prompt"))
        _ = text.consume(line: try assistant(at: 3, id: "m1", output: 300, stop: "end_turn", blocks: ["thinking"]))
        XCTAssertNil(text.pollEnded(now: t0, isFinal: false))
        _ = text.consume(line: try assistant(at: 9, id: "m1", output: 420, stop: "end_turn", blocks: ["text"]))
        let closed = try XCTUnwrap(text.pollEnded(now: t0.addingTimeInterval(1), isFinal: false))
        XCTAssertEqual(closed.completedAt, base.addingTimeInterval(9))
        XCTAssertEqual(closed.outputTokens, 420)
    }

    func testFinalPollEndClosesAThinkingLastMessageImmediately() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try assistant(at: 3, id: "m1", output: 300, stop: "end_turn", blocks: ["thinking"]))
        let metric = try XCTUnwrap(parser.pollEnded(now: base, isFinal: true))
        XCTAssertEqual(metric.completedAt, base.addingTimeInterval(3))
        XCTAssertNil(parser.pollEnded(now: base, isFinal: true))

        // A non-terminal thinking-last response (a tool call is still to come) also closes.
        var loop = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = loop.consume(line: try user(at: 0, id: "prompt"))
        _ = loop.consume(line: try assistant(at: 5, id: "m1", output: 300, stop: "tool_use", blocks: ["thinking"]))
        XCTAssertNil(loop.pollEnded(now: base, isFinal: false))
        XCTAssertTrue(loop.drainCompletedResponses().isEmpty)
        XCTAssertNil(loop.pollEnded(now: base, isFinal: true))
        XCTAssertEqual(loop.drainCompletedResponses().map(\.outputTokens), [300])
    }

    func testTerminalTurnIsEmittedByTheNextRecordThatIsNotItsOwn() throws {
        // The next prompt returns the previous turn and starts its own.
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "first"))
        XCTAssertNil(parser.consume(line: try assistant(at: 10, id: "m1", output: 300, stop: "end_turn")))
        XCTAssertNil(parser.consume(line: try assistant(at: 11, id: "m1", output: 300, stop: "end_turn")), "more records of the terminal message do not close it")
        let first = try XCTUnwrap(parser.consume(line: try user(at: 40, id: "second")))
        XCTAssertEqual(first.id, try expectedID("\(sessionID)|first"))
        XCTAssertEqual(first.completedAt, base.addingTimeInterval(11))
        let second = try XCTUnwrap(terminal(&parser, assistant(at: 50, id: "m2", output: 300, stop: "end_turn")))
        XCTAssertEqual(second.id, try expectedID("\(sessionID)|second"))
        XCTAssertEqual(second.responseDurationSeconds ?? 0, 10, accuracy: 0.001, "the second response starts at the second prompt")

        // Another message after the terminal one also closes the turn; it belongs to no turn.
        var other = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = other.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(other.consume(line: try assistant(at: 10, id: "m1", output: 300, stop: "end_turn")))
        XCTAssertNotNil(other.consume(line: try assistant(at: 12, id: "m-other", output: 300, stop: "tool_use")))
        XCTAssertNil(other.pollEnded(now: base, isFinal: false))

        // Without a later record the end of the poll emits the turn, exactly once.
        var idle = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = idle.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(idle.consume(line: try assistant(at: 10, id: "m1", output: 300, stop: "end_turn")))
        XCTAssertNotNil(idle.pollEnded(now: base, isFinal: false))
        XCTAssertNil(idle.pollEnded(now: base, isFinal: false))
    }

    func testLiveResponsesAreDrainedOnceWithTheirDescriptors() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        let requestA = "req_011CABCDEFGHIJKLMNOPQRST", requestB = "req_011CZYXWVUTSRQPONMLKJIHG"
        _ = parser.consume(line: try user(at: 0, id: "prompt", kind: "human"))
        _ = parser.consume(line: try assistant(at: 10, id: anthropicMessage, output: 500, stop: "tool_use", requestID: requestA, effort: "high"))
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty, "a response is final only once a later record arrives")
        _ = parser.consume(line: try toolResult(at: 12))
        _ = parser.consume(line: try assistant(at: 20, id: "msg_01ZYXWVUTSRQPONMLKJIHGFE", output: 400, stop: "end_turn", requestID: requestB, effort: "high"))

        let first = parser.drainCompletedResponses()
        XCTAssertEqual(first.count, 1)
        let response = try XCTUnwrap(first.first)
        XCTAssertEqual(response.id, liveDigest("\(sessionID)||\(anthropicMessage)"))
        XCTAssertEqual(response.model, "claude-sonnet-5-5")
        XCTAssertEqual(response.provider, "anthropic")
        XCTAssertEqual(response.client, "claude-code")
        XCTAssertEqual(response.sourceKind, "primary")
        XCTAssertEqual(response.metricVersion, "claude-observed-turn-v1")
        XCTAssertEqual(response.reasoningEffort, "high")
        XCTAssertEqual(response.completedAt, base.addingTimeInterval(10))
        XCTAssertEqual(response.outputTokens, 500)
        XCTAssertEqual(response.durationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(response.tokensPerSecond, 50, accuracy: 0.001)
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty, "a drained response is not reported again")

        let metric = try XCTUnwrap(parser.pollEnded(now: base, isFinal: false))
        let last = try XCTUnwrap(parser.drainCompletedResponses().first)
        XCTAssertEqual(last.id, liveDigest("\(sessionID)||msg_01ZYXWVUTSRQPONMLKJIHGFE"))
        XCTAssertEqual(last.completedAt, metric.completedAt)
        XCTAssertEqual(last.durationSeconds, 8, accuracy: 0.001)
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty)
        XCTAssertNil(parser.pollEnded(now: base, isFinal: false))
        XCTAssertTrue(parser.drainCompletedResponses().isEmpty, "ending the poll twice finalises nothing twice")
    }

    func testSubagentResponsesFollowTheSameRulesAndCarrySubagentDescriptors() throws {
        var parser = ClaudeSubagentTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "task", sidechain: true))
        _ = parser.consume(line: try assistant(at: 10, id: "s1", output: 500, stop: "tool_use", sidechain: true))
        _ = parser.consume(line: try toolResult(at: 12, sidechain: true))
        XCTAssertNil(parser.consume(line: try assistant(at: 20, id: "s2", output: 400, stop: "end_turn", sidechain: true)))
        XCTAssertTrue(parser.hasPendingWork)
        let metric = try XCTUnwrap(parser.pollEnded(now: base, isFinal: false))
        XCTAssertEqual(metric.sourceKind, "subagent")
        XCTAssertEqual(metric.responseOutputTokens, 900)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 18, accuracy: 0.001)
        XCTAssertEqual(metric.responseCount, 2)
        let responses = parser.drainCompletedResponses()
        XCTAssertEqual(responses.map(\.id), ["s1", "s2"].map { liveDigest("\(sessionID)|\(agentID)|\($0)") })
        XCTAssertEqual(Set(responses.map(\.sourceKind)), ["subagent"])
        XCTAssertEqual(Set(responses.map(\.metricVersion)), ["claude-observed-subagent-turn-v1"])
        XCTAssertEqual(Set(responses.map(\.client)), ["claude-code"])
        XCTAssertEqual(responses.map(\.durationSeconds), [10, 8])

        // The primary parser never sees sidechain records, so it reports nothing for them.
        var primary = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = primary.consume(line: try user(at: 0, id: "task", sidechain: true))
        _ = primary.consume(line: try assistant(at: 10, id: "s1", output: 500, stop: "end_turn", sidechain: true))
        XCTAssertNil(primary.pollEnded(now: base, isFinal: false))
        XCTAssertTrue(primary.drainCompletedResponses().isEmpty)
    }

    // MARK: Bedrock inference-profile region

    func testBedrockProviderRegionComesFromTheInferenceProfilePrefix() throws {
        let cases: [(model: String, region: String)] = [
            ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "us"),
            ("eu.anthropic.claude-sonnet-4-5-20250929-v1:0", "eu"),
            ("apac.anthropic.claude-sonnet-4-5-20250929-v1:0", "apac"),
            ("global.anthropic.claude-opus-4-6-v1", "global"),
            ("jp.anthropic.claude-sonnet-4-5-20250929-v1:0", "jp"),
            ("au.anthropic.claude-sonnet-4-5-20250929-v1:0", "au"),
            ("ca.anthropic.claude-sonnet-4-5-20250929-v1:0", "ca"),
            ("us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0", "us-gov"),
            // No prefix, an unrecognised prefix, or a model id that is not a Bedrock one.
            ("anthropic.claude-3-haiku-20240307-v1:0", "unknown"),
            ("xx.anthropic.claude-sonnet-4-5-20250929-v1:0", "unknown"),
            ("claude-sonnet-5-5", "unknown")
        ]
        for (model, region) in cases {
            let result = try XCTUnwrap(metric(records: [(bedrockMessage, nil, model)]), model)
            XCTAssertEqual(result.provider, "amazon-bedrock", model)
            XCTAssertEqual(result.providerRegion, region, model)
        }
        // Model normalisation is unchanged by the region.
        XCTAssertEqual(try metric(records: [(bedrockMessage, nil, "us.anthropic.claude-sonnet-4-5-20250929-v1:0")])?.model, "claude-sonnet-4-5-20250929")

        // Messages that disagree on the region leave it unknown; agreement keeps it.
        let secondMessage = "msg_bdrk_01ZYXWVUTSRQPONMLKJI"
        XCTAssertEqual(try metric(records: [
            (bedrockMessage, nil, "us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
            (secondMessage, nil, "eu.anthropic.claude-sonnet-4-5-20250929-v1:0")
        ])?.providerRegion, "unknown")
        XCTAssertEqual(try metric(records: [
            (bedrockMessage, nil, "us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
            (secondMessage, nil, "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
        ])?.providerRegion, "us")
        for scope in [ClaudeTranscriptParser.Scope.primary, .subagent] {
            XCTAssertEqual(try metric(scope: scope, records: [(bedrockMessage, nil, "global.anthropic.claude-opus-4-6-v1")])?.providerRegion, "global")
        }
    }

    func testProviderRegionIsNilForEveryNonBedrockProvider() throws {
        let bedrockModel = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
        for records in [
            [(anthropicMessage, Optional(anthropicRequest), bedrockModel)],
            [(vertexMessage, nil, bedrockModel)],
            [("msg-no-evidence", nil, bedrockModel)],
            [(bedrockMessage, nil, bedrockModel), (anthropicMessage, anthropicRequest, bedrockModel)]
        ] {
            let result = try XCTUnwrap(metric(records: records))
            XCTAssertNotEqual(result.provider, "amazon-bedrock")
            XCTAssertNil(result.providerRegion)
        }
        XCTAssertNil(try metric(records: [(anthropicMessage, anthropicRequest, "claude-sonnet-5-5")])?.providerRegion)
    }

    func testBedrockRegionReachesTheSharedSample() throws {
        let result = try XCTUnwrap(metric(records: [(bedrockMessage, nil, "eu.anthropic.claude-sonnet-4-5-20250929-v1:0")]))
        let sample = try XCTUnwrap(SharedSample(result.withDelegatedOutputTokens(0)))
        XCTAssertEqual(sample.providerRegion, "eu")
        XCTAssertEqual(sample.provider, "amazon-bedrock")
    }

    // MARK: Surface (0.1.18)

    private func withEntrypoint(_ line: Data, _ entrypoint: String?) throws -> Data {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        if let entrypoint { value["entrypoint"] = entrypoint }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func surface(
        scope: ClaudeTranscriptParser.Scope = .primary, userEntrypoint: String?, assistantEntrypoints: [String?] = [nil]
    ) throws -> TurnMetric {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: scope)
        let sidechain = scope == .subagent
        _ = parser.consume(line: try withEntrypoint(try user(at: 0, id: "prompt", sidechain: sidechain), userEntrypoint))
        var result: TurnMetric?
        for (index, entrypoint) in assistantEntrypoints.enumerated() {
            let last = index == assistantEntrypoints.count - 1
            let line = try withEntrypoint(try assistant(
                at: Double(index + 1) * 5, id: "msg-\(index)", output: 10, stop: last ? "end_turn" : "tool_use", sidechain: sidechain
            ), entrypoint)
            result = parser.consume(line: line)
        }
        return try XCTUnwrap(result ?? parser.pollEnded(now: base, isFinal: false))
    }

    func testSurfaceComesFromTheUserTurnEntrypointInBothScopes() throws {
        for scope in [ClaudeTranscriptParser.Scope.primary, .subagent] {
            XCTAssertEqual(try surface(scope: scope, userEntrypoint: "cli").surface, .cli)
            XCTAssertEqual(try surface(scope: scope, userEntrypoint: "claude-desktop").surface, .desktop)
            XCTAssertEqual(try surface(scope: scope, userEntrypoint: "claude-vscode").surface, .ide)
            XCTAssertEqual(try surface(scope: scope, userEntrypoint: "sdk-ts").surface, .sdk)
            XCTAssertEqual(try surface(scope: scope, userEntrypoint: "mcp").surface, .other)
            XCTAssertNil(try surface(scope: scope, userEntrypoint: nil).surface)
            XCTAssertNil(try surface(scope: scope, userEntrypoint: "").surface)
        }
    }

    func testSurfaceFallsBackToAssistantRecordsAndTheFirstValueWins() throws {
        XCTAssertEqual(try surface(userEntrypoint: nil, assistantEntrypoints: [nil, "sdk-py", "cli"]).surface, .sdk)
        XCTAssertEqual(try surface(userEntrypoint: "cli", assistantEntrypoints: ["claude-desktop"]).surface, .cli)
        XCTAssertNil(try surface(userEntrypoint: nil, assistantEntrypoints: [nil, nil]).surface)
    }

    func testTheRawEntrypointIsNeverPersisted() throws {
        let metric = try surface(userEntrypoint: "some-third-party-app")
        XCTAssertEqual(metric.surface, .other)
        let stored = String(decoding: try JSONEncoder().encode(metric), as: UTF8.self)
        XCTAssertFalse(stored.contains("some-third-party-app"))
    }

    // MARK: Prompt cache (0.1.18)

    /// Usage the way Claude Code writes it: `input_tokens` excludes the cached tokens.
    private func cacheUsage(input: Int? = 0, read: Int? = 0, create: Int? = 0) -> [String: Int] {
        var usage: [String: Int] = [:]
        if let input { usage["input_tokens"] = input }
        if let read { usage["cache_read_input_tokens"] = read }
        if let create { usage["cache_creation_input_tokens"] = create }
        return usage
    }

    func testPromptCacheSumsUniqueMessagesAndTakesRepeatedRecordsOfOneMessageOnce() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        // One message is written as several records: only output_tokens grows, the rest repeats.
        for (index, output) in [10, 40, 90].enumerated() {
            XCTAssertNil(parser.consume(line: try assistant(
                at: 2 + Double(index), id: "m1", output: output, stop: index == 2 ? "tool_use" : nil,
                cache: cacheUsage(input: 5, read: 1_000, create: 200)
            )))
        }
        XCTAssertNil(parser.consume(line: try toolResult(at: 6)))
        let metric = try XCTUnwrap(terminal(&parser, assistant(
            at: 10, id: "m2", output: 60, stop: "end_turn", cache: cacheUsage(input: 3, read: 1_300, create: 0)
        )))
        XCTAssertEqual(metric.outputTokens, 150)
        // input = Σ(input + read + create) = (5 + 1_000 + 200) + (3 + 1_300 + 0)
        XCTAssertEqual(metric.inputTokens, 2_508)
        XCTAssertEqual(metric.cacheReadInputTokens, 2_300)
        XCTAssertEqual(metric.cacheWriteInputTokens, 200)
    }

    func testPromptCacheTakesAFieldFromTheFirstRecordThatHasIt() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        XCTAssertNil(parser.consume(line: try assistant(at: 2, id: "m1", output: 5, stop: nil)))
        let metric = try XCTUnwrap(terminal(&parser, assistant(
            at: 10, id: "m1", output: 50, stop: "end_turn", cache: cacheUsage(input: 4, read: 90, create: 6)
        )))
        XCTAssertEqual(metric.inputTokens, 100)
        XCTAssertEqual(metric.cacheReadInputTokens, 90)
        XCTAssertEqual(metric.cacheWriteInputTokens, 6)
    }

    func testPromptCacheIsNilWhenAnyCountedMessageLacksAField() throws {
        func metric(first: [String: Int], second: [String: Int]) throws -> TurnMetric {
            var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
            _ = parser.consume(line: try user(at: 0, id: "prompt"))
            _ = parser.consume(line: try assistant(at: 3, id: "m1", output: 20, stop: "tool_use", cache: first))
            _ = parser.consume(line: try toolResult(at: 5))
            return try XCTUnwrap(terminal(&parser, assistant(at: 10, id: "m2", output: 20, stop: "end_turn", cache: second)))
        }
        let complete = cacheUsage(input: 1, read: 2, create: 3)
        XCTAssertEqual(try metric(first: complete, second: complete).inputTokens, 12)
        for incomplete in [
            cacheUsage(input: nil), cacheUsage(read: nil), cacheUsage(create: nil), [:]
        ] {
            for turn in [try metric(first: incomplete, second: complete), try metric(first: complete, second: incomplete)] {
                // Missing is not zero: the whole set is not reported, but the turn itself still is.
                XCTAssertEqual(turn.outputTokens, 40)
                XCTAssertNil(turn.inputTokens)
                XCTAssertNil(turn.cacheReadInputTokens)
                XCTAssertNil(turn.cacheWriteInputTokens)
            }
        }
    }

    func testPromptCacheIsReportedForSubagentTurnsToo() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: .subagent)
        _ = parser.consume(line: try user(at: 0, id: "task", sidechain: true))
        _ = parser.consume(line: try assistant(at: 4, id: "s1", output: 60, stop: "tool_use", sidechain: true, cache: cacheUsage(input: 2, read: 500, create: 100)))
        _ = parser.consume(line: try toolResult(at: 5, sidechain: true))
        let metric = try XCTUnwrap(terminal(&parser, assistant(
            at: 10, id: "s2", output: 140, stop: "end_turn", sidechain: true, cache: cacheUsage(input: 1, read: 700, create: 0)
        )))
        XCTAssertEqual(metric.sourceKind, "subagent")
        XCTAssertEqual(metric.inputTokens, 1_303)
        XCTAssertEqual(metric.cacheReadInputTokens, 1_200)
        XCTAssertEqual(metric.cacheWriteInputTokens, 100)
        let sample = try XCTUnwrap(SharedSample(metric))
        XCTAssertEqual(sample.inputTokens, 1_303)
        XCTAssertEqual(sample.cacheWriteInputTokens, 100)
    }

    func testPromptCacheCountsOnlyTheMessagesTheTurnCounts() throws {
        // A second turn starts fresh: the first turn's messages never leak into it.
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "p1"))
        let first = try XCTUnwrap(terminal(&parser, assistant(at: 5, id: "a1", output: 20, stop: "end_turn", cache: cacheUsage(input: 1, read: 10, create: 5))))
        XCTAssertEqual(first.inputTokens, 16)
        _ = parser.consume(line: try user(at: 4_000, id: "p2"))
        let second = try XCTUnwrap(terminal(&parser, assistant(at: 4_005, id: "a2", output: 20, stop: "end_turn", cache: cacheUsage(input: 2, read: 0, create: 0))))
        XCTAssertEqual(second.inputTokens, 2)
        XCTAssertEqual(second.cacheReadInputTokens, 0)
        XCTAssertEqual(second.cacheWriteInputTokens, 0)
    }

    // MARK: Synthetic fixtures

    /// Feeds a terminal record. A terminal turn closes on the next record or at the end of a poll, so
    /// a fixture that ends with it ends the poll when `consume` did not already return the turn.
    private func terminal(_ parser: inout ClaudeTranscriptParser, _ line: Data) -> TurnMetric? {
        if let metric = parser.consume(line: line) { return metric }
        return parser.pollEnded(now: base, isFinal: false)
    }

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

    private func user(
        at seconds: Double, id: String, sidechain: Bool = false, meta: Bool = false, content: Any = "PRIVATE_PROMPT",
        origin: Date? = nil, kind: String? = nil, rootPrompt: Bool = false
    ) throws -> Data {
        var value = envelope(sidechain: sidechain)
        if let kind { value["origin"] = ["kind": kind] }
        value["parentUuid"] = rootPrompt ? NSNull() : "previous-record"
        value["type"] = "user"
        value["uuid"] = id
        value["timestamp"] = timestamp(seconds, origin: origin ?? base)
        value["message"] = ["role": "user", "content": content]
        if meta { value["isMeta"] = true }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func attachment(
        at seconds: Double, id: String, type: String = "PRIVATE_ATTACHMENT", parent: String = "previous-record", sidechain: Bool = false
    ) throws -> Data {
        var value = envelope(sidechain: sidechain)
        value["type"] = "attachment"
        value["uuid"] = id
        value["parentUuid"] = parent
        value["timestamp"] = timestamp(seconds, origin: base)
        value["attachment"] = ["type": type]
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func toolResult(at seconds: Double, sidechain: Bool = false) throws -> Data {
        try user(at: seconds, id: "tool-result-\(Int(seconds))", sidechain: sidechain, content: [["type": "tool_result", "content": "PRIVATE_RESPONSE"]])
    }

    private func assistant(
        at seconds: Double, id: String, model: String = "claude-sonnet-5-5", output: Int?, stop: String?,
        sidechain: Bool = false, origin: Date? = nil, requestID: String? = nil, effort: String? = nil,
        blocks: [String]? = nil, parent: String? = nil, cache: [String: Int] = [:]
    ) throws -> Data {
        var value = envelope(sidechain: sidechain)
        if let parent { value["parentUuid"] = parent }
        if let requestID { value["requestId"] = requestID }
        if let effort { value["perTurnEffort"] = effort }
        var usage: [String: Any] = [:]
        if let output { usage["output_tokens"] = output }
        usage.merge(cache) { _, new in new }
        value["type"] = "assistant"
        value["uuid"] = "record-\(id)"
        value["timestamp"] = timestamp(seconds, origin: origin ?? base)
        let content: Any = blocks.map { types in
            types.map { type -> [String: Any] in type == "thinking" ? ["type": type, "thinking": "PRIVATE_RESPONSE"] : ["type": type, "text": "PRIVATE_RESPONSE"] }
        } ?? "PRIVATE_RESPONSE"
        value["message"] = ["id": id, "role": "assistant", "model": model, "content": content, "stop_reason": stop ?? NSNull(), "usage": usage]
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
