import Foundation
import XCTest
@testable import TokrateCore

final class MultiSourceParserTests: XCTestCase {
    private let sessionID = "synthetic-session-31"

    func testClaudeToolLoopDeduplicatesMessageUsageAndOnlyEmitsOnTerminalMessage() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "/tmp/private-transcript.jsonl")
        XCTAssertNil(parser.consume(line: try claudeUser(timestamp: "2026-10-03T20:00:00.000Z", id: "user-root")))
        XCTAssertNil(parser.consume(line: try claudeAssistant(timestamp: "2026-10-03T20:00:01.000Z", id: "msg-tool", model: "claude-sonnet-4", output: 10, stop: "tool_use", apiBlockIndex: 0)))
        XCTAssertNil(parser.consume(line: try claudeAssistant(timestamp: "2026-10-03T20:00:01.100Z", id: "msg-tool", model: "claude-sonnet-4", output: 12, stop: "tool_use", apiBlockIndex: 1)))
        XCTAssertNil(parser.consume(line: try claudeToolResult(timestamp: "2026-10-03T20:00:02.000Z")))
        XCTAssertNil(parser.consume(line: try claudeUser(timestamp: "2026-10-03T20:00:03.000Z", id: "subagent-user", sidechain: true)))

        let metric = try XCTUnwrap(terminal(&parser, claudeAssistant(
            timestamp: "2026-10-03T20:00:05.000Z",
            id: "msg-final",
            model: "claude-sonnet-4",
            output: 30,
            stop: "end_turn",
            effort: "high"
        )))

        XCTAssertEqual(metric.client, "claude-code")
        XCTAssertEqual(metric.parserVersion, "claude-transcript-v4")
        XCTAssertEqual(metric.metricVersion, "claude-observed-turn-v1")
        XCTAssertEqual(metric.outputTokens, 42)
        XCTAssertEqual(metric.durationSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(metric.turnThroughputTPS, 8.4, accuracy: 0.001)
        XCTAssertEqual(metric.model, "claude-sonnet-4")
        XCTAssertEqual(metric.clientVersion, "2.1.37")
        XCTAssertEqual(metric.reasoningEffort, "high")
        XCTAssertEqual(metric.provider, "unknown")
        XCTAssertEqual(metric.sourceKind, "primary")
        XCTAssertNil(metric.ttftSeconds)
        XCTAssertNil(metric.responseOutputTokens, "no response reached 200 tokens")
        XCTAssertNil(metric.responseSpeedTPS)
        XCTAssertNil(metric.providerRegion)
        XCTAssertNil(parser.consume(line: try claudeAssistant(timestamp: "2026-10-03T20:00:06.000Z", id: "msg-after", model: "claude-sonnet-4", output: 1, stop: "tool_use")))

        let sample = try XCTUnwrap(SharedSample(metric))
        let bytes = try JSONEncoder().encode(sample)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["client"] as? String, "claude-code")
        XCTAssertEqual(json["parserVersion"] as? String, "claude-transcript-v4")
        XCTAssertEqual(json["metricVersion"] as? String, "claude-observed-turn-v1")
        XCTAssertEqual(json["appVersion"] as? String, "0.1.14")
        XCTAssertTrue(json["ttftMs"] is NSNull)
        let serialized = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(serialized.contains("PRIVATE_PROMPT"))
        XCTAssertFalse(serialized.contains("PRIVATE_RESPONSE"))
        XCTAssertFalse(serialized.contains("private-transcript"))
        XCTAssertFalse(serialized.contains(sessionID))
    }

    func testClaudeRequiresExplicitTerminalAndRejectsIncompleteUsageButMarksMixedModelsUnknown() throws {
        var incomplete = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = incomplete.consume(line: try claudeUser(timestamp: "2026-10-03T20:00:00Z", id: "user-incomplete"))
        XCTAssertNil(terminal(&incomplete, try claudeAssistant(timestamp: "2026-10-03T20:00:01Z", id: "msg-incomplete", model: "claude-sonnet-4", output: nil, stop: "end_turn")))

        var nonterminal = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = nonterminal.consume(line: try claudeUser(timestamp: "2026-10-03T20:00:00Z", id: "user-not-done"))
        XCTAssertNil(nonterminal.consume(line: try claudeAssistant(timestamp: "2026-10-03T20:00:01Z", id: "msg-not-done", model: "claude-sonnet-4", output: 4, stop: "tool_use")))

        var mixed = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = mixed.consume(line: try claudeUser(timestamp: "2026-10-03T20:00:00Z", id: "user-mixed"))
        _ = mixed.consume(line: try claudeAssistant(timestamp: "2026-10-03T20:00:01Z", id: "msg-a", model: "claude-sonnet-4", output: 4, stop: "tool_use"))
        let mixedMetric = try XCTUnwrap(terminal(&mixed, claudeAssistant(timestamp: "2026-10-03T20:00:02Z", id: "msg-b", model: "claude-opus-4", output: 5, stop: "stop_sequence")))
        XCTAssertNil(mixedMetric.model)
        XCTAssertEqual(mixedMetric.outputTokens, 9)
    }

    func testClaudeDecreasingRepeatedMessageUsageFailsClosedAndMissingUsageCanBeCompleted() throws {
        var decreasing = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = decreasing.consume(line: try claudeUser(timestamp: "2026-10-03T20:00:00Z", id: "user-decreasing"))
        _ = decreasing.consume(line: try claudeAssistant(timestamp: "2026-10-03T20:00:01Z", id: "msg-repeated", model: "claude-sonnet-4", output: 12, stop: "tool_use", apiBlockIndex: 0))
        _ = decreasing.consume(line: try claudeAssistant(timestamp: "2026-10-03T20:00:02Z", id: "msg-repeated", model: "claude-sonnet-4", output: 10, stop: "tool_use", apiBlockIndex: 1))
        XCTAssertNil(terminal(&decreasing, try claudeAssistant(timestamp: "2026-10-03T20:00:03Z", id: "msg-final", model: "claude-sonnet-4", output: 8, stop: "end_turn")))

        var lateUsage = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = lateUsage.consume(line: try claudeUser(timestamp: "2026-10-03T20:00:00Z", id: "user-late-usage"))
        _ = lateUsage.consume(line: try claudeAssistant(timestamp: "2026-10-03T20:00:01Z", id: "msg-late", model: "claude-sonnet-4", output: nil, stop: "tool_use", apiBlockIndex: 0))
        _ = lateUsage.consume(line: try claudeAssistant(timestamp: "2026-10-03T20:00:02Z", id: "msg-late", model: "claude-sonnet-4", output: 12, stop: "tool_use", apiBlockIndex: 1))
        let metric = try XCTUnwrap(terminal(&lateUsage, claudeAssistant(timestamp: "2026-10-03T20:00:03Z", id: "msg-final-late", model: "claude-sonnet-4", output: 8, stop: "stop_sequence")))
        XCTAssertEqual(metric.outputTokens, 20)
    }

    func testGrokMatchesSuccessfulPrimaryTurnWithNestedSubagentOutputAndOneExplicitModel() throws {
        var parser = GrokSessionParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try grokStart(timestamp: "2026-10-03T20:00:00.000Z", number: 7, relationship: "primary", model: "selected-model"))
        _ = parser.consume(line: try grokStart(timestamp: "2026-10-03T20:00:01.000Z", number: 70, relationship: "subagent", model: "subagent-model"))
        _ = parser.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:02.000Z", outcome: "completed"))
        _ = parser.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:05.000Z", outcome: "completed"))

        let snapshot = try usageSnapshot(number: 7, endedAt: "2026-10-03T20:00:25.000Z", output: 160, updatedAt: "2026-10-03T20:00:26.000Z", modelUsage: ["grok-4": ["outputTokens": 160]])
        let metric = try XCTUnwrap(parser.reconcile(snapshot: snapshot).first)
        XCTAssertEqual(metric.client, "grok-build")
        XCTAssertEqual(metric.parserVersion, "grok-session-v1")
        XCTAssertEqual(metric.metricVersion, "grok-observed-work-turn-v1")
        XCTAssertEqual(metric.model, "grok-4")
        XCTAssertEqual(metric.outputTokens, 160)
        XCTAssertEqual(metric.durationSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(metric.turnThroughputTPS, 32, accuracy: 0.001)
        XCTAssertEqual(metric.throughputLabel, "Work-turn speed")
        XCTAssertEqual(metric.provider, "unknown")
        XCTAssertNil(metric.clientVersion)
        XCTAssertNil(metric.ttftSeconds)
        XCTAssertEqual(metric.reasoningOutputTokens, 20)
        XCTAssertTrue(parser.reconcile(snapshot: snapshot).isEmpty)

        let sample = try XCTUnwrap(SharedSample(metric))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertEqual(json["client"] as? String, "grok-build")
        XCTAssertEqual(json["clientVersion"] as? String, "unknown")
        XCTAssertEqual(json["provider"] as? String, "unknown")
        XCTAssertEqual(json["metricVersion"] as? String, "grok-observed-work-turn-v1")
        XCTAssertTrue(json["ttftMs"] is NSNull)
    }

    func testGrokRejectsAmbiguousStartsFailedTurnsIncompleteUsageAndTimestampMismatch() throws {
        var nested = GrokSessionParser(sourceIdentity: "synthetic")
        _ = nested.consume(line: try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 1, relationship: "primary"))
        _ = nested.consume(line: try grokStart(timestamp: "2026-10-03T20:00:01Z", number: 2, relationship: "primary"))
        _ = nested.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:02Z", outcome: "completed"))
        _ = nested.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:03Z", outcome: "completed"))
        XCTAssertTrue(nested.reconcile(snapshot: try usageSnapshot(number: 1, endedAt: "2026-10-03T20:00:03Z", output: 30, updatedAt: "2026-10-03T20:00:04Z", modelUsage: ["grok-4": [:]])).isEmpty)

        var cancelled = GrokSessionParser(sourceIdentity: "synthetic")
        _ = cancelled.consume(line: try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 3, relationship: "primary"))
        _ = cancelled.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:03Z", outcome: "cancelled"))
        XCTAssertTrue(cancelled.reconcile(snapshot: try usageSnapshot(number: 3, endedAt: "2026-10-03T20:00:03Z", output: 30, updatedAt: "2026-10-03T20:00:04Z", modelUsage: ["grok-4": [:]])).isEmpty)

        for (ending, updatedAt, incomplete) in [("2026-10-03T20:01:06Z", "2026-10-03T20:01:07Z", false), ("2026-10-03T20:00:03Z", "2026-10-03T20:00:04Z", true)] {
            var parser = GrokSessionParser(sourceIdentity: "synthetic")
            _ = parser.consume(line: try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 4, relationship: "primary"))
            _ = parser.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:03Z", outcome: "completed"))
            XCTAssertTrue(parser.reconcile(snapshot: try usageSnapshot(number: 4, endedAt: ending, output: 30, updatedAt: updatedAt, incomplete: incomplete, modelUsage: ["grok-4": [:]])).isEmpty)
        }
    }

    func testGrokDelayedLedgerWriteHonorsNextIncompletePrimaryBoundaryAndOneMinuteCap() throws {
        var boundedByNextStart = GrokSessionParser(sourceIdentity: "synthetic")
        _ = boundedByNextStart.consume(line: try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 11, relationship: "primary"))
        _ = boundedByNextStart.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:05Z", outcome: "completed"))
        // The following turn is incomplete, but its explicit primary start still bounds persistence.
        _ = boundedByNextStart.consume(line: try grokStart(timestamp: "2026-10-03T20:00:30Z", number: 12, relationship: "primary"))
        let beforeNextStart = try usageSnapshot(number: 11, endedAt: "2026-10-03T20:00:25Z", output: 30, updatedAt: "2026-10-03T20:00:31Z", modelUsage: ["grok-4": [:]])
        XCTAssertEqual(boundedByNextStart.reconcile(snapshot: beforeNextStart).count, 1)

        var afterNextStart = GrokSessionParser(sourceIdentity: "synthetic")
        _ = afterNextStart.consume(line: try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 13, relationship: "primary"))
        _ = afterNextStart.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:05Z", outcome: "completed"))
        _ = afterNextStart.consume(line: try grokStart(timestamp: "2026-10-03T20:00:30Z", number: 14, relationship: "primary"))
        let lateSnapshot = try usageSnapshot(number: 13, endedAt: "2026-10-03T20:00:31Z", output: 30, updatedAt: "2026-10-03T20:00:32Z", modelUsage: ["grok-4": [:]])
        XCTAssertTrue(afterNextStart.reconcile(snapshot: lateSnapshot).isEmpty)

        var oneMinute = GrokSessionParser(sourceIdentity: "synthetic")
        _ = oneMinute.consume(line: try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 15, relationship: "primary"))
        _ = oneMinute.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:05Z", outcome: "completed"))
        let exactlyOneMinute = try usageSnapshot(number: 15, endedAt: "2026-10-03T20:01:05Z", output: 30, updatedAt: "2026-10-03T20:01:06Z", modelUsage: ["grok-4": [:]])
        XCTAssertEqual(oneMinute.reconcile(snapshot: exactlyOneMinute).count, 1)

        var earlyTolerance = GrokSessionParser(sourceIdentity: "synthetic")
        _ = earlyTolerance.consume(line: try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 16, relationship: "primary"))
        _ = earlyTolerance.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:05Z", outcome: "completed"))
        let withinTolerance = try usageSnapshot(number: 16, endedAt: "2026-10-03T20:00:04Z", output: 30, updatedAt: "2026-10-03T20:00:06Z", modelUsage: ["grok-4": [:]])
        XCTAssertEqual(earlyTolerance.reconcile(snapshot: withinTolerance).count, 1)

        var tooEarly = GrokSessionParser(sourceIdentity: "synthetic")
        _ = tooEarly.consume(line: try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 17, relationship: "primary"))
        _ = tooEarly.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:05Z", outcome: "completed"))
        let beyondEarlyTolerance = try usageSnapshot(number: 17, endedAt: "2026-10-03T20:00:03Z", output: 30, updatedAt: "2026-10-03T20:00:06Z", modelUsage: ["grok-4": [:]])
        XCTAssertTrue(tooEarly.reconcile(snapshot: beyondEarlyTolerance).isEmpty)
    }

    func testGrokJoinsZeroBasedEventTurnsToOneBasedUsageLedgerTurns() throws {
        // Verbatim shape of a real Grok Build 1.0.x session: events number turns from 0,
        // the usage ledger from 1.
        func session() throws -> GrokSessionParser {
            var parser = GrokSessionParser(sourceIdentity: "synthetic")
            _ = parser.consume(line: try grokStart(timestamp: "2026-09-28T09:50:38.177Z", number: 0, relationship: "primary"))
            _ = parser.consume(line: try grokEnd(timestamp: "2026-09-28T09:52:30.218Z", outcome: "completed"))
            _ = parser.consume(line: try grokStart(timestamp: "2026-09-28T09:52:42.306Z", number: 1, relationship: "primary"))
            _ = parser.consume(line: try grokEnd(timestamp: "2026-09-28T09:53:25.953Z", outcome: "completed"))
            return parser
        }
        func ledger(_ rows: [(number: Int, endedAt: String, output: Int)]) throws -> Data {
            try json([
                "sessionId": sessionID, "updatedAt": "2026-09-28T09:53:25.968126+00:00",
                "turns": rows.map { row -> [String: Any] in
                    // Real ledgers carry no usageIsIncomplete flag on complete rows.
                    ["turnNumber": row.number, "endedAt": row.endedAt, "outputTokens": row.output, "turnCount": 1,
                     "modelUsage": ["grok-4.7-build": ["outputTokens": row.output]]]
                }
            ])
        }

        var parser = try session()
        let real = try ledger([
            (1, "2026-09-28T09:52:30.232828+00:00", 4897),
            (2, "2026-09-28T09:53:25.968126+00:00", 2505)
        ])
        let records = parser.reconcile(snapshot: real).sorted { $0.completedAt < $1.completedAt }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.outputTokens), [4897, 2505])
        XCTAssertEqual(records[0].durationSeconds, 112.041, accuracy: 0.001)
        XCTAssertEqual(records[1].durationSeconds, 43.647, accuracy: 0.001)
        XCTAssertEqual(records[0].turnThroughputTPS, 4897 / 112.041, accuracy: 0.001)
        XCTAssertEqual(records[1].turnThroughputTPS, 2505 / 43.647, accuracy: 0.001)
        XCTAssertEqual(Set(records.map(\.model)), ["grok-4.7-build"])

        // A ledger numbered like the events (the old assumption) must not match any turn.
        var wrong = try session()
        let sameNumbers = try ledger([
            (0, "2026-09-28T09:52:30.232828+00:00", 4897),
            (1, "2026-09-28T09:53:25.968126+00:00", 2505)
        ])
        XCTAssertTrue(wrong.reconcile(snapshot: sameNumbers).isEmpty)
    }

    func testGrokDoesNotInferModelFromSelectedModelAndSplitsMultiModelUsage() throws {
        for usage in [[:], ["grok-4": [:], "local-llama": [:]]] as [[String: [String: Int]]] {
            var parser = GrokSessionParser(sourceIdentity: "synthetic")
            _ = parser.consume(line: try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 8, relationship: "primary", model: "selected-model"))
            _ = parser.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:03Z", outcome: "completed"))
            let snapshot = try usageSnapshot(number: 8, endedAt: "2026-10-03T20:00:03Z", output: 40, updatedAt: "2026-10-03T20:00:04Z", modelUsage: usage, primaryModelId: "also-not-evidence")
            XCTAssertNil(try XCTUnwrap(parser.reconcile(snapshot: snapshot).first).model)
        }
    }

    func testGrokAttributesSessionEffortOnlyWhenObservedAtLiveStartAndUnchangedAtEmit() async throws {
        let live = try await grokMonitorRecords(summaryAtStart: "high", summaryAtEmit: "high", backfilled: false)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.reasoningEffort, "high")

        let changed = try await grokMonitorRecords(summaryAtStart: "high", summaryAtEmit: "low", backfilled: false)
        XCTAssertEqual(changed.count, 1)
        XCTAssertNil(changed.first?.reasoningEffort)

        let backfilled = try await grokMonitorRecords(summaryAtStart: "high", summaryAtEmit: "high", backfilled: true)
        XCTAssertEqual(backfilled.count, 1)
        XCTAssertNil(backfilled.first?.reasoningEffort)

        let missing = try await grokMonitorRecords(summaryAtStart: nil, summaryAtEmit: nil, backfilled: false)
        XCTAssertEqual(missing.count, 1)
        XCTAssertNil(missing.first?.reasoningEffort)
    }

    func testGrokMonitorDiscoversDirectAndChildSessionFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = root.appendingPathComponent("session-child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date.now
        let eventTimestamp = iso8601(now.addingTimeInterval(-8))
        let completionTimestamp = iso8601(now.addingTimeInterval(-5))
        let updateTimestamp = iso8601(now.addingTimeInterval(-4))
        try writeGrokSession(directory: root, session: "direct-session", number: 1, startedAt: eventTimestamp, endedAt: completionTimestamp, updatedAt: updateTimestamp)
        try writeGrokSession(directory: child, session: "child-session", number: 2, startedAt: eventTimestamp, endedAt: completionTimestamp, updatedAt: updateTimestamp)

        let monitor = GrokSessionMonitor(root: root)
        let firstPoll = try await monitor.poll(now: now)
        XCTAssertTrue(firstPoll.isEmpty)
        let records = try await monitor.poll(now: now.addingTimeInterval(5))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.client)), ["grok-build"])
        XCTAssertEqual(Set(records.map(\.metricVersion)), ["grok-observed-work-turn-v1"])
        let status = await monitor.status()
        XCTAssertTrue(status.rootAvailable)
        XCTAssertEqual(status.sessions, 2)
    }

    func testLegacyHistoryDefaultsToCodexAndCorruptNonCodexTTFTIsSuppressed() throws {
        let legacy = #"{"id":"legacy","completedAt":"2026-10-03T20:00:00Z","model":"gpt-test","outputTokens":100,"durationSeconds":10,"codexTTFTSeconds":1.5,"turnThroughputTPS":10,"streamingTPS":null}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metric = try decoder.decode(TurnMetric.self, from: Data(legacy.utf8))
        XCTAssertEqual(metric.client, "codex")
        XCTAssertEqual(metric.parserVersion, "codex-rollout-v1")
        XCTAssertEqual(metric.metricVersion, "turn-v1")
        XCTAssertEqual(metric.ttftSeconds, 1.5)

        let corrupted = TurnMetric(
            id: "corrupt",
            completedAt: Date(timeIntervalSince1970: 1_800_000_000),
            model: "claude-sonnet-4",
            outputTokens: 20,
            durationSeconds: 2,
            codexTTFTSeconds: 0.1,
            turnThroughputTPS: 10,
            client: "claude-code",
            parserVersion: "claude-transcript-v4",
            metricVersion: "claude-observed-turn-v1",
            provider: "unknown"
        )
        XCTAssertNil(corrupted.ttftSeconds)
        let sample = try XCTUnwrap(SharedSample(corrupted))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertTrue(json["ttftMs"] is NSNull)
        XCTAssertNil(SharedSample(TurnMetric(
            id: "wrong-tuple",
            completedAt: Date(timeIntervalSince1970: 1_800_000_000),
            model: "claude-sonnet-4",
            outputTokens: 20,
            durationSeconds: 2,
            codexTTFTSeconds: nil,
            turnThroughputTPS: 10,
            client: "claude-code",
            parserVersion: "codex-rollout-v1",
            metricVersion: "turn-v1"
        )))
    }

    /// A terminal record closes its turn on the next record or at the end of a poll.
    private func terminal(_ parser: inout ClaudeTranscriptParser, _ line: Data) -> TurnMetric? {
        if let metric = parser.consume(line: line) { return metric }
        return parser.pollEnded(now: .now, isFinal: false)
    }

    private func claudeUser(
        timestamp: String,
        id: String,
        sidechain: Bool = false,
        content: Any = "PRIVATE_PROMPT"
    ) throws -> Data {
        try json([
            "type": "user", "uuid": id, "timestamp": timestamp, "sessionId": sessionID,
            "isSidechain": sidechain, "userType": "external", "version": "2.1.37",
            "message": ["role": "user", "content": content]
        ])
    }

    private func claudeToolResult(timestamp: String) throws -> Data {
        try claudeUser(timestamp: timestamp, id: "tool-result", content: [["type": "tool_result", "content": "PRIVATE_RESPONSE"]])
    }

    private func claudeAssistant(
        timestamp: String,
        id: String,
        model: String,
        output: Int?,
        stop: String?,
        effort: String? = "high",
        apiBlockIndex: Int = 0
    ) throws -> Data {
        var usage: [String: Any] = [:]
        if let output { usage["output_tokens"] = output }
        return try json([
            "type": "assistant", "uuid": "record-\(id)-\(apiBlockIndex)", "timestamp": timestamp,
            "sessionId": sessionID, "isSidechain": false, "userType": "external", "version": "2.1.37",
            "apiBlockIndex": apiBlockIndex,
            "message": [
                "id": id, "role": "assistant", "model": model, "content": "PRIVATE_RESPONSE",
                "stop_reason": stop ?? NSNull(), "usage": usage, "perTurnEffort": effort as Any? ?? NSNull()
            ]
        ])
    }

    private func grokStart(timestamp: String, number: Int, relationship: String, model: String? = nil) throws -> Data {
        var value: [String: Any] = [
            "type": "turn_started", "ts": timestamp, "session_id": sessionID,
            "turn_number": number, "session_relationship": relationship, "schema_version": "1.0"
        ]
        if let model { value["model_id"] = model }
        return try json(value)
    }

    private func grokEnd(timestamp: String, outcome: String) throws -> Data {
        try json(["type": "turn_ended", "ts": timestamp, "outcome": outcome])
    }

    private func usageSnapshot(
        number: Int,
        endedAt: String,
        output: Int,
        updatedAt: String,
        incomplete: Bool = false,
        modelUsage: [String: [String: Int]],
        primaryModelId: String? = nil
    ) throws -> Data {
        // The usage ledger numbers turns from 1 while events.jsonl numbers them from 0.
        var turn: [String: Any] = [
            "turnNumber": number + 1, "endedAt": endedAt, "outputTokens": output,
            "reasoningTokens": 20, "modelCalls": 2, "turnCount": 1,
            "usageIsIncomplete": incomplete, "modelUsage": modelUsage
        ]
        if let primaryModelId { turn["primaryModelId"] = primaryModelId }
        return try json(["sessionId": sessionID, "updatedAt": updatedAt, "turns": [turn]])
    }

    private func writeGrokSession(directory: URL, session: String, number: Int, startedAt: String, endedAt: String, updatedAt: String) throws {
        let events = [
            try json(["type": "turn_started", "ts": startedAt, "session_id": session, "turn_number": number, "model_id": "selected-model", "session_relationship": "primary", "schema_version": "1.0"]),
            try json(["type": "turn_ended", "ts": endedAt, "outcome": "completed"])
        ].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(events.utf8).write(to: directory.appendingPathComponent("events.jsonl"))
        let ledger = try JSONSerialization.data(withJSONObject: [
            "sessionId": session, "updatedAt": updatedAt,
            "turns": [["turnNumber": number + 1, "endedAt": endedAt, "outputTokens": 50, "reasoningTokens": 10, "modelCalls": 1, "turnCount": 1, "usageIsIncomplete": false, "modelUsage": ["grok-4": ["outputTokens": 50]]]]
        ])
        try ledger.write(to: directory.appendingPathComponent("usage.json"))
    }

    /// Runs one Grok turn through the monitor. `backfilled` writes the finished session before the first
    /// poll; otherwise the turn is appended after the monitor has caught up with an empty event log.
    private func grokMonitorRecords(summaryAtStart: String?, summaryAtEmit: String?, backfilled: Bool) async throws -> [TurnMetric] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("events.jsonl")
        let usageURL = root.appendingPathComponent("usage.json")
        let summaryURL = root.appendingPathComponent("summary.json")
        func writeSummary(_ effort: String?) throws {
            guard let effort else { try? FileManager.default.removeItem(at: summaryURL); return }
            try json(["reasoning_effort": effort, "current_model_id": "grok-4", "context_window": 256_000]).write(to: summaryURL)
        }
        func line(_ data: Data) -> Data { data + Data("\n".utf8) }
        let start = line(try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 0, relationship: "primary"))
        let end = line(try grokEnd(timestamp: "2026-10-03T20:00:05Z", outcome: "completed"))
        let usage = try usageSnapshot(number: 0, endedAt: "2026-10-03T20:00:05.020Z", output: 50, updatedAt: "2026-10-03T20:00:06Z", modelUsage: ["grok-4": [:]])

        let monitor = GrokSessionMonitor(root: root)
        let t0 = Date.now
        var records: [TurnMetric] = []
        try writeSummary(summaryAtStart)
        if backfilled {
            try (start + end).write(to: eventsURL)
            try usage.write(to: usageURL)
            records += try await monitor.poll(now: t0)
        } else {
            try Data().write(to: eventsURL)
            records += try await monitor.poll(now: t0)
            try start.write(to: eventsURL)
            records += try await monitor.poll(now: t0.addingTimeInterval(1))
            try (start + end).write(to: eventsURL)
            try usage.write(to: usageURL)
        }
        try writeSummary(summaryAtEmit)
        records += try await monitor.poll(now: t0.addingTimeInterval(2))
        records += try await monitor.poll(now: t0.addingTimeInterval(7))
        return records
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
