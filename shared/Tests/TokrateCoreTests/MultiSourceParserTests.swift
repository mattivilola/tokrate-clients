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

        XCTAssertNil(SharedSample(metric), "a primary turn is shared only once its delegated total is final")
        let sample = try XCTUnwrap(SharedSample(metric.withDelegatedOutputTokens(0)))
        let bytes = try JSONEncoder().encode(sample)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["client"] as? String, "claude-code")
        XCTAssertEqual(json["parserVersion"] as? String, "claude-transcript-v4")
        XCTAssertEqual(json["metricVersion"] as? String, "claude-observed-turn-v1")
        XCTAssertEqual(json["appVersion"] as? String, "0.1.20")
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
        XCTAssertEqual(metric.parserVersion, "grok-session-v2")
        // A nested agent makes the turn's generation time ambiguous: no response speed.
        XCTAssertNil(metric.responseSpeedTPS)
        XCTAssertNil(metric.responseCount)
        XCTAssertEqual(metric.metricVersion, "grok-observed-work-turn-v1")
        XCTAssertEqual(metric.model, "grok-4")
        XCTAssertEqual(metric.outputTokens, 160)
        XCTAssertEqual(metric.delegatedOutputTokens, 0, "nested output is already in outputTokens; final at emission")
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

    func testGrokNestingNeverGrowsPastItsBoundWhateverTheLogContains() throws {
        let timestamp = "2026-10-03T20:00:00Z"
        func start(_ relationship: String, number: Int = 0, session: String? = nil) throws -> Data {
            try json(["type": "turn_started", "ts": timestamp, "session_id": session ?? sessionID, "turn_number": number, "session_relationship": relationship, "schema_version": "1.0"])
        }
        // Nested agents past the bound.
        var parser = GrokSessionParser(sourceIdentity: "grok-test")
        _ = parser.consume(line: try start("primary"))
        for _ in 0..<10_000 {
            _ = parser.consume(line: try start("subagent"))
            XCTAssertLessThanOrEqual(parser.frameDepth, 64)
        }
        XCTAssertLessThanOrEqual(parser.frameDepth, 64)

        // Starts that cannot be paired: another session, an unknown relationship, a second primary,
        // an unreadable start.
        for lines in [
            [try start("primary"), try start("primary", number: 1, session: "other-session")],
            [try start("primary"), try start("sidekick")],
            [try start("primary"), try start("primary", number: 1)],
            [try start("primary"), try json(["type": "turn_started", "schema_version": "1.0"])]
        ] {
            var parser = GrokSessionParser(sourceIdentity: "grok-test")
            _ = parser.consume(line: lines[0])
            for _ in 0..<10_000 { _ = parser.consume(line: lines[1]) }
            XCTAssertLessThanOrEqual(parser.frameDepth, 2)
        }

        // The discarded turn is lost, the next end marker ends the discarding, and a later turn is read.
        var after = GrokSessionParser(sourceIdentity: "grok-test")
        _ = after.consume(line: try start("primary", number: 0))
        for _ in 0..<100 { _ = after.consume(line: try start("subagent")) }
        for _ in 0..<70 { _ = after.consume(line: try start("primary", number: 9)) }
        _ = after.consume(line: try grokEnd(timestamp: "2026-10-03T20:00:05Z", outcome: "completed"))
        XCTAssertEqual(after.frameDepth, 0)
        _ = after.consume(line: try start("primary", number: 1))
        XCTAssertEqual(after.frameDepth, 1, "the next primary turn is tracked again")
    }

    func testGrokMonitorWatchesAtMostAsManySessionsAsTheDesktopClientAndAReplayScalesThat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<130 {
            let folder = root.appendingPathComponent("session-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("events.jsonl"))
        }
        XCTAssertEqual(GrokSessionMonitor.maximumSessions, 128)
        let live = GrokSessionMonitor(root: root)
        _ = try await live.poll(now: .now)
        let liveStatus = await live.status()
        XCTAssertEqual(liveStatus.sessions, 128)
        let replay = GrokSessionMonitor(root: root, scope: .replay(retention: MetricHistory.retention))
        _ = try await replay.poll(now: .now)
        let replayStatus = await replay.status()
        XCTAssertEqual(replayStatus.sessions, 130)
    }

    func testGrokMonitorReconcilesTheUsageLedgerAsItIsWhenItSettlesNotAsItWasFirstRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        let started = iso8601(now.addingTimeInterval(-8)), ended = iso8601(now.addingTimeInterval(-5)), updated = iso8601(now.addingTimeInterval(-4))
        try writeGrokSession(directory: root, session: "ledger-session", number: 1, startedAt: started, endedAt: ended, updatedAt: updated)
        let usageURL = root.appendingPathComponent("usage.json")
        let monitor = GrokSessionMonitor(root: root)
        var records = try await monitor.poll(now: now)

        // The ledger is rewritten (50 output tokens became 80) before it has settled.
        let ledger: [String: Any] = [
            "sessionId": "ledger-session", "updatedAt": updated,
            "turns": [["turnNumber": 2, "endedAt": ended, "outputTokens": 80, "reasoningTokens": 10, "modelCalls": 1, "turnCount": 1, "usageIsIncomplete": false, "modelUsage": ["grok-4": ["outputTokens": 80]]]]
        ]
        try JSONSerialization.data(withJSONObject: ledger).write(to: usageURL)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(2)], ofItemAtPath: usageURL.path)
        await monitor.noteChanges(SessionFolderChange(paths: [usageURL.standardizedFileURL.path]))
        records += try await monitor.poll(now: now.addingTimeInterval(4))
        XCTAssertTrue(records.isEmpty, "the changed ledger starts its settling again")
        records += try await monitor.poll(now: now.addingTimeInterval(8.5))
        XCTAssertEqual(records.map(\.outputTokens), [80], "the first read's 50 tokens are never reconciled")
    }

    func testGrokMonitorServicesReportedChangesWithoutWaitingForDiscoveryAndSchedulesTheSnapshotSettle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let known = root.appendingPathComponent("known", isDirectory: true)
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date.now
        let started = iso8601(now.addingTimeInterval(-8)), ended = iso8601(now.addingTimeInterval(-5)), updated = iso8601(now.addingTimeInterval(-4))
        try writeGrokSession(directory: known, session: "known-session", number: 1, startedAt: started, endedAt: ended, updatedAt: updated)
        let monitor = GrokSessionMonitor(root: root)
        _ = try await monitor.poll(now: now)
        let settling = await monitor.nextPollDeadline(now: now)
        XCTAssertEqual(settling, now.addingTimeInterval(4), "the snapshot is reconciled once it has been stable for four seconds")
        let records = try await monitor.poll(now: now.addingTimeInterval(4))
        XCTAssertEqual(records.count, 1)
        let idle = await monitor.nextPollDeadline(now: now.addingTimeInterval(4))
        XCTAssertNil(idle)

        try writeGrokSession(directory: fresh, session: "fresh-session", number: 2, startedAt: started, endedAt: ended, updatedAt: updated)
        _ = try await monitor.poll(now: now.addingTimeInterval(6))
        var status = await monitor.status()
        XCTAssertEqual(status.sessions, 1, "a new session waits for discovery unless it is reported")
        let unrelated = await monitor.noteChanges(SessionFolderChange(paths: [fresh.appendingPathComponent("notes.txt").path]))
        XCTAssertFalse(unrelated)
        let noted = await monitor.noteChanges(SessionFolderChange(paths: [fresh.appendingPathComponent("events.jsonl").standardizedFileURL.path]))
        XCTAssertTrue(noted)
        let pending = await monitor.nextPollDeadline(now: now.addingTimeInterval(6))
        XCTAssertEqual(pending, now.addingTimeInterval(6))
        _ = try await monitor.poll(now: now.addingTimeInterval(8))
        status = await monitor.status()
        XCTAssertEqual(status.sessions, 2)

        // A change to a known session's usage file services that session again and restarts its settle.
        try await Task.sleep(for: .milliseconds(20))
        try writeGrokSession(directory: known, session: "known-session", number: 1, startedAt: started, endedAt: ended, updatedAt: iso8601(now))
        await monitor.noteChanges(SessionFolderChange(paths: [known.appendingPathComponent("usage.json").standardizedFileURL.path]))
        let changed = await monitor.nextPollDeadline(now: now.addingTimeInterval(10))
        XCTAssertEqual(changed, now.addingTimeInterval(10))
        _ = try await monitor.poll(now: now.addingTimeInterval(10))
        let resettling = await monitor.nextPollDeadline(now: now.addingTimeInterval(10))
        XCTAssertEqual(resettling, now.addingTimeInterval(12), "the fresh session settles first")
    }

    func testGrokIdlePollsReadNothingUntilTheNextDiscoveryOrAReportedChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("events.jsonl")
        let usageURL = root.appendingPathComponent("usage.json")
        func line(_ data: Data) -> Data { data + Data("\n".utf8) }
        let first = line(try grokStart(timestamp: "2026-10-03T20:00:00Z", number: 0, relationship: "primary"))
            + line(try grokEnd(timestamp: "2026-10-03T20:00:05Z", outcome: "completed"))
        let second = line(try grokStart(timestamp: "2026-10-03T20:01:00Z", number: 1, relationship: "primary"))
            + line(try grokEnd(timestamp: "2026-10-03T20:01:05Z", outcome: "completed"))
        try first.write(to: eventsURL)
        try usageSnapshot(number: 0, endedAt: "2026-10-03T20:00:05.020Z", output: 50, updatedAt: "2026-10-03T20:00:06Z", modelUsage: ["grok-4": [:]])
            .write(to: usageURL)

        let monitor = GrokSessionMonitor(root: root)
        let t0 = Date.now
        let discovered = try await monitor.poll(now: t0)
        XCTAssertTrue(discovered.isEmpty)
        let reconciled = try await monitor.poll(now: t0.addingTimeInterval(4))
        XCTAssertEqual(reconciled.count, 1)
        let settled = await monitor.nextPollDeadline(now: t0.addingTimeInterval(4))
        XCTAssertNil(settled)
        let again = try await monitor.poll(now: t0.addingTimeInterval(6))
        XCTAssertTrue(again.isEmpty, "a snapshot is reconciled once, not on every poll")

        // A new turn nobody reported is not read by idle polls.
        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: second)
        try handle.close()
        try usageSnapshot(number: 1, endedAt: "2026-10-03T20:01:05.020Z", output: 60, updatedAt: "2026-10-03T20:01:06Z", modelUsage: ["grok-4": [:]])
            .write(to: usageURL)
        for seconds in [8.0, 12, 40, 200] {
            let idle = try await monitor.poll(now: t0.addingTimeInterval(seconds))
            XCTAssertTrue(idle.isEmpty)
            let deadline = await monitor.nextPollDeadline(now: t0.addingTimeInterval(seconds))
            XCTAssertNil(deadline)
        }

        // The discovery safety net visits every session, so the missed change is caught.
        let sweep = try await monitor.poll(now: t0.addingTimeInterval(305))
        XCTAssertTrue(sweep.isEmpty, "the snapshot has to settle first")
        let caught = try await monitor.poll(now: t0.addingTimeInterval(310))
        XCTAssertEqual(caught.map(\.outputTokens), [60])
    }

    // MARK: Grok Build response speed (0.1.15)

    /// One model call: generation window, then its tool run (with the repeated `tool_started` and the
    /// permission events real sessions write). The last call of a turn has no tool; `turn_ended` closes it.
    private struct GrokCall {
        let generating: TimeInterval
        var toolRun: TimeInterval? = 5
        var repeatedToolStarts = 1
    }

    private let grokBase = Date(timeIntervalSince1970: 1_790_000_000)

    private func grokTurn(
        number: Int = 0, firstLoopDelay: TimeInterval = 0.1, calls: [GrokCall], nestedAgentAt: TimeInterval? = nil
    ) throws -> (parser: GrokSessionParser, endedAt: Date) {
        var parser = GrokSessionParser(sourceIdentity: "synthetic")
        func at(_ offset: TimeInterval) -> String { iso8601(grokBase.addingTimeInterval(offset)) }
        _ = parser.consume(line: try grokStart(timestamp: at(0), number: number, relationship: "primary"))
        var cursor = firstLoopDelay
        for (index, call) in calls.enumerated() {
            _ = parser.consume(line: try json(["type": "loop_started", "ts": at(cursor), "loop_index": index]))
            _ = parser.consume(line: try json(["type": "phase_changed", "ts": at(cursor + 0.2), "phase": "streaming_text"]))
            cursor += call.generating
            guard let toolRun = call.toolRun else { continue }
            for repeated in 0..<call.repeatedToolStarts {
                _ = parser.consume(line: try json(["type": "tool_started", "ts": at(cursor + Double(repeated) * 0.05), "tool_name": "run"]))
            }
            _ = parser.consume(line: try json(["type": "permission_requested", "ts": at(cursor + 0.1)]))
            cursor += toolRun
            if let nestedAgentAt, index == 0 {
                _ = parser.consume(line: try grokStart(timestamp: at(nestedAgentAt), number: 90, relationship: "subagent"))
                _ = parser.consume(line: try grokEnd(timestamp: at(nestedAgentAt + 1), outcome: "completed"))
            }
        }
        _ = parser.consume(line: try grokEnd(timestamp: at(cursor), outcome: "completed"))
        return (parser, grokBase.addingTimeInterval(cursor))
    }

    private func grokMetric(
        _ turn: (parser: GrokSessionParser, endedAt: Date), output: Int, modelCalls: Any? = 9, number: Int = 0,
        extra: [String: Any] = [:]
    ) throws -> TurnMetric {
        var parser = turn.parser
        let snapshot = try usageSnapshot(
            number: number, endedAt: iso8601(turn.endedAt.addingTimeInterval(0.02)), output: output,
            updatedAt: iso8601(turn.endedAt.addingTimeInterval(1)), modelUsage: ["grok-4.7-build": ["outputTokens": output]],
            modelCalls: modelCalls, extra: extra
        )
        return try XCTUnwrap(parser.reconcile(snapshot: snapshot).first)
    }

    func testGrokReportsWholeTurnResponseSpeedFromGenerationWindows() throws {
        // Real-shape turn (Grok Build 1.0.46): nine model calls, eight followed by tool runs (the first
        // with parallel tool starts), windows summing to 179.9 s, 12,535 output tokens, 220 s in all.
        var calls = (0..<8).map { _ in GrokCall(generating: 20) }
        calls[3].repeatedToolStarts = 3
        calls.append(GrokCall(generating: 19.9, toolRun: nil))
        let metric = try grokMetric(try grokTurn(calls: calls), output: 12_535)

        XCTAssertEqual(metric.parserVersion, "grok-session-v2")
        XCTAssertEqual(metric.metricVersion, "grok-observed-work-turn-v1")
        XCTAssertEqual(metric.responseOutputTokens, 12_535)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 179.9, accuracy: 0.001)
        XCTAssertEqual(metric.responseCount, 9)
        XCTAssertEqual(try XCTUnwrap(metric.responseSpeedTPS), 12_535 / 179.9, accuracy: 0.01)
        XCTAssertEqual(metric.durationSeconds, 220, accuracy: 0.001)
        XCTAssertEqual(metric.turnThroughputTPS, 12_535 / 220, accuracy: 0.01)
        XCTAssertNil(metric.ttftSeconds)

        let sample = try XCTUnwrap(SharedSample(metric))
        XCTAssertEqual(sample.responseOutputTokens, 12_535)
        XCTAssertEqual(try XCTUnwrap(sample.responseDurationMs), 179_900, accuracy: 1)
        XCTAssertEqual(sample.responseCount, 9)
        XCTAssertEqual(sample.parserVersion, "grok-session-v2")
        XCTAssertEqual(sample.appVersion, "0.1.20")

        let shorter = try grokMetric(
            try grokTurn(calls: [GrokCall(generating: 33.0), GrokCall(generating: 33.0), GrokCall(generating: 33.2, toolRun: nil)]),
            output: 8_032, modelCalls: 3
        )
        XCTAssertEqual(try XCTUnwrap(shorter.responseDurationSeconds), 99.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(shorter.responseSpeedTPS), 8_032 / 99.2, accuracy: 0.01)
    }

    // MARK: Prompt cache (0.1.18)

    func testGrokPromptCacheComesFromTheLedgerRowAndCacheWriteIsNeverReported() throws {
        let metric = try grokMetric(
            try grokTurn(calls: [GrokCall(generating: 10)]), output: 400,
            extra: ["inputTokens": 90_000, "cachedReadTokens": 70_000, "cacheCreationTokens": 0]
        )
        // Grok's inputTokens already includes the cached tokens.
        XCTAssertEqual(metric.inputTokens, 90_000)
        XCTAssertEqual(metric.cacheReadInputTokens, 70_000)
        XCTAssertNil(metric.cacheWriteInputTokens, "cacheCreationTokens is always 0, which is not a report")
        let sample = try XCTUnwrap(SharedSample(metric))
        XCTAssertEqual(sample.inputTokens, 90_000)
        XCTAssertEqual(sample.cacheReadInputTokens, 70_000)
        XCTAssertNil(sample.cacheWriteInputTokens)
    }

    func testGrokPromptCacheIsNilWhenAKeyIsMissingOrTheRowIsInconsistent() throws {
        let calls = [GrokCall(generating: 10)]
        for extra: [String: Any] in [
            [:], ["inputTokens": 90_000], ["cachedReadTokens": 70_000],
            ["inputTokens": 100, "cachedReadTokens": 101], ["inputTokens": "90000", "cachedReadTokens": 1]
        ] {
            let metric = try grokMetric(try grokTurn(calls: calls), output: 400, extra: extra)
            XCTAssertEqual(metric.outputTokens, 400)
            XCTAssertNil(metric.inputTokens)
            XCTAssertNil(metric.cacheReadInputTokens)
            XCTAssertNil(metric.cacheWriteInputTokens)
        }
        let zero = try grokMetric(try grokTurn(calls: calls), output: 400, extra: ["inputTokens": 100, "cachedReadTokens": 0])
        XCTAssertEqual(zero.inputTokens, 100)
        XCTAssertEqual(zero.cacheReadInputTokens, 0)
    }

    func testGrokFirstWindowStartsAtLoopStartAndLastIsClosedByTurnEnd() throws {
        // A 2 s lead-in before the first call is not generation; the single window runs to turn_ended.
        let metric = try grokMetric(
            try grokTurn(firstLoopDelay: 2, calls: [GrokCall(generating: 10, toolRun: nil)]), output: 500, modelCalls: 1
        )
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 10, accuracy: 0.001)
        XCTAssertEqual(metric.responseCount, 1)
        XCTAssertEqual(metric.durationSeconds, 12, accuracy: 0.001)
    }

    func testGrokRepeatedToolStartsKeepTheWindowClosedAndLoopWithoutToolClosesPreviousWindow() throws {
        let repeated = try grokMetric(
            try grokTurn(calls: [GrokCall(generating: 10, toolRun: 30, repeatedToolStarts: 4), GrokCall(generating: 6, toolRun: nil)]),
            output: 800, modelCalls: 2
        )
        XCTAssertEqual(try XCTUnwrap(repeated.responseDurationSeconds), 16, accuracy: 0.001)

        // Two loop_started events with no tool_started between them: the first window ends at the second.
        var parser = GrokSessionParser(sourceIdentity: "synthetic")
        func at(_ offset: TimeInterval) -> String { iso8601(grokBase.addingTimeInterval(offset)) }
        _ = parser.consume(line: try grokStart(timestamp: at(0), number: 0, relationship: "primary"))
        _ = parser.consume(line: try json(["type": "loop_started", "ts": at(1), "loop_index": 0]))
        _ = parser.consume(line: try json(["type": "loop_started", "ts": at(5), "loop_index": 1]))
        _ = parser.consume(line: try grokEnd(timestamp: at(9), outcome: "completed"))
        let metric = try grokMetric((parser, grokBase.addingTimeInterval(9)), output: 400, modelCalls: 2)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 8, accuracy: 0.001)
        XCTAssertEqual(metric.responseCount, 2)
    }

    func testGrokTurnsWithNestedAgentsHaveNoResponseSpeed() throws {
        let turn = try grokTurn(
            calls: [GrokCall(generating: 20), GrokCall(generating: 20, toolRun: nil)], nestedAgentAt: 21
        )
        let metric = try grokMetric(turn, output: 4_000, modelCalls: 2)
        XCTAssertNil(metric.responseOutputTokens)
        XCTAssertNil(metric.responseDurationSeconds)
        XCTAssertNil(metric.responseCount)
        XCTAssertEqual(metric.outputTokens, 4_000, "the work-turn metric still includes nested output")
        XCTAssertEqual(metric.turnThroughputTPS, 4_000 / metric.durationSeconds, accuracy: 0.001)
        XCTAssertEqual(metric.parserVersion, "grok-session-v2")
    }

    func testGrokWindowsOutsideZeroToTenMinutesFailClosed() throws {
        XCTAssertNil(try grokMetric(
            try grokTurn(calls: [GrokCall(generating: 600.5, toolRun: nil)]), output: 5_000, modelCalls: 1
        ).responseCount)
        XCTAssertEqual(try grokMetric(
            try grokTurn(calls: [GrokCall(generating: 600, toolRun: nil)]), output: 5_000, modelCalls: 1
        ).responseCount, 1)

        // A turn_ended (or tool_started) at the same instant as its loop_started is a zero-length window.
        XCTAssertNil(try grokMetric(
            try grokTurn(calls: [GrokCall(generating: 10), GrokCall(generating: 0, toolRun: nil)]), output: 800, modelCalls: 2
        ).responseCount)

        // One bad window discards the turn even when the others are fine.
        XCTAssertNil(try grokMetric(
            try grokTurn(calls: [GrokCall(generating: 10), GrokCall(generating: 700, toolRun: nil)]), output: 9_000, modelCalls: 2
        ).responseCount)

        // Out-of-order timestamps give a negative window.
        var parser = GrokSessionParser(sourceIdentity: "synthetic")
        func at(_ offset: TimeInterval) -> String { iso8601(grokBase.addingTimeInterval(offset)) }
        _ = parser.consume(line: try grokStart(timestamp: at(0), number: 0, relationship: "primary"))
        _ = parser.consume(line: try json(["type": "loop_started", "ts": at(8), "loop_index": 0]))
        _ = parser.consume(line: try json(["type": "tool_started", "ts": at(6), "tool_name": "run"]))
        _ = parser.consume(line: try grokEnd(timestamp: at(10), outcome: "completed"))
        XCTAssertNil(try grokMetric((parser, grokBase.addingTimeInterval(10)), output: 500, modelCalls: 1).responseCount)

        // A loop_started without a timestamp cannot be trusted.
        var untimed = GrokSessionParser(sourceIdentity: "synthetic")
        _ = untimed.consume(line: try grokStart(timestamp: at(0), number: 0, relationship: "primary"))
        _ = untimed.consume(line: try json(["type": "loop_started", "loop_index": 0]))
        _ = untimed.consume(line: try json(["type": "loop_started", "ts": at(1), "loop_index": 1]))
        _ = untimed.consume(line: try grokEnd(timestamp: at(10), outcome: "completed"))
        XCTAssertNil(try grokMetric((untimed, grokBase.addingTimeInterval(10)), output: 500, modelCalls: 1).responseCount)
    }

    func testGrokModelCallsMustMatchTheWindowCount() throws {
        func metric(modelCalls: Any?) throws -> TurnMetric {
            try grokMetric(try grokTurn(calls: [GrokCall(generating: 10), GrokCall(generating: 10, toolRun: nil)]), output: 800, modelCalls: modelCalls)
        }
        XCTAssertEqual(try metric(modelCalls: 2).responseCount, 2)
        XCTAssertNil(try metric(modelCalls: 3).responseCount)
        XCTAssertNil(try metric(modelCalls: 1).responseCount)
        XCTAssertNil(try metric(modelCalls: "2").responseCount)
        XCTAssertNil(try metric(modelCalls: -2).responseCount)
        // A ledger row without a call count accepts the window count.
        XCTAssertEqual(try metric(modelCalls: nil).responseCount, 2)
        XCTAssertEqual(try metric(modelCalls: NSNull()).responseCount, 2)
        // The turn itself is still reported.
        XCTAssertEqual(try metric(modelCalls: 3).outputTokens, 800)
    }

    func testGrokResponseNeedsTwoHundredOutputTokensPerCallAndAPlausibleRate() throws {
        func metric(output: Int, generating: TimeInterval = 10) throws -> TurnMetric {
            try grokMetric(
                try grokTurn(calls: [GrokCall(generating: generating), GrokCall(generating: generating, toolRun: nil)]),
                output: output, modelCalls: 2
            )
        }
        XCTAssertEqual(try metric(output: 400).responseCount, 2)
        XCTAssertNil(try metric(output: 399).responseCount)
        XCTAssertNil(try metric(output: 399).responseSpeedTPS)
        XCTAssertEqual(try metric(output: 399).outputTokens, 399)
        // Faster than 2,000 tok/s over the summed windows is a measurement error.
        XCTAssertNotNil(try metric(output: 40_000).responseCount)
        XCTAssertNil(try metric(output: 40_001).responseCount)
    }

    func testGrokTurnWithoutGenerationEventsHasNoResponseSpeed() throws {
        let noLoops = try grokMetric(try grokTurn(firstLoopDelay: 10, calls: []), output: 500, modelCalls: 1)
        XCTAssertNil(noLoops.responseCount)
        XCTAssertEqual(noLoops.parserVersion, "grok-session-v2")
    }

    func testGrokSessionV1AndV2AreBothSupportedSourceTuples() {
        for parser in ["grok-session-v1", "grok-session-v2"] {
            XCTAssertTrue(TurnMetric.isSupportedSourceTuple(client: "grok-build", parserVersion: parser, metricVersion: "grok-observed-work-turn-v1"))
        }
        XCTAssertFalse(TurnMetric.isSupportedSourceTuple(client: "grok-build", parserVersion: "grok-session-v3", metricVersion: "grok-observed-work-turn-v1"))
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
        primaryModelId: String? = nil,
        modelCalls: Any? = 2,
        extra: [String: Any] = [:]
    ) throws -> Data {
        // The usage ledger numbers turns from 1 while events.jsonl numbers them from 0.
        var turn: [String: Any] = [
            "turnNumber": number + 1, "endedAt": endedAt, "outputTokens": output,
            "reasoningTokens": 20, "turnCount": 1,
            "usageIsIncomplete": incomplete, "modelUsage": modelUsage
        ]
        if let modelCalls { turn["modelCalls"] = modelCalls }
        turn.merge(extra) { _, new in new }
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
            await monitor.noteChanges(SessionFolderChange(paths: [eventsURL.standardizedFileURL.path]))
            records += try await monitor.poll(now: t0.addingTimeInterval(1))
            try (start + end).write(to: eventsURL)
            try usage.write(to: usageURL)
        }
        try writeSummary(summaryAtEmit)
        // Between discoveries a session is only read once a change to its files is reported.
        await monitor.noteChanges(SessionFolderChange(paths: Set([eventsURL, usageURL, summaryURL].map { $0.standardizedFileURL.path })))
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
