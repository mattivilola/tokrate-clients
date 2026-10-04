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
        XCTAssertEqual(metric.parserVersion, "claude-transcript-v3")
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
        XCTAssertEqual(first.parserVersion, "claude-transcript-v3")
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
        XCTAssertEqual(json["parserVersion"] as? String, "claude-transcript-v3")
        XCTAssertEqual(json["appVersion"] as? String, "0.1.13")
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

    // MARK: Origin-aware prompts (claude-transcript-v3)

    func testBackgroundNotificationAfterTheTerminalMessageStartsNoTurn() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt", kind: "human"))
        XCTAssertNotNil(parser.consume(line: try assistant(at: 5, id: "m1", output: 100, stop: "end_turn")))
        XCTAssertNil(parser.consume(line: try user(at: 20, id: "notification", kind: "task-notification")))
        XCTAssertNil(parser.consume(line: try assistant(at: 25, id: "m-reaction", output: 50, stop: "tool_use")))
        XCTAssertNil(parser.consume(line: try assistant(at: 30, id: "m-reaction-final", output: 50, stop: "end_turn")))
        _ = parser.consume(line: try user(at: 100, id: "next", kind: "human"))
        let metric = try XCTUnwrap(parser.consume(line: assistant(at: 110, id: "m-next", output: 100, stop: "end_turn")))
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
        let metric = try XCTUnwrap(parser.consume(line: assistant(at: 3_010, id: "m2", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|prompt"))
        XCTAssertEqual(metric.outputTokens, 200)
        XCTAssertEqual(metric.durationSeconds, 3_010, accuracy: 0.001)

        // A notification never starts a turn on its own, even from an idle parser.
        var idle = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        XCTAssertNil(idle.consume(line: try user(at: 0, id: "notification", kind: "task-notification")))
        XCTAssertNil(idle.consume(line: try assistant(at: 5, id: "m1", output: 10, stop: "end_turn")))
        // An origin object without a human kind is not a prompt either.
        XCTAssertNil(idle.consume(line: try user(at: 10, id: "other", kind: "something-new")))
        XCTAssertNil(idle.consume(line: try assistant(at: 15, id: "m2", output: 10, stop: "end_turn")))
    }

    func testRecordsWithoutOriginFollowTheV2Rules() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        _ = parser.consume(line: try user(at: 0, id: "prompt"))
        _ = parser.consume(line: try assistant(at: 5, id: "m1", output: 100, stop: "tool_use"))
        _ = parser.consume(line: try user(at: 20, id: "interjection"))
        let metric = try XCTUnwrap(parser.consume(line: assistant(at: 40, id: "m2", output: 300, stop: "end_turn")))
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|prompt"))
        XCTAssertEqual(metric.outputTokens, 400)
        XCTAssertNil(parser.consume(line: try user(at: 50, id: "meta", meta: true)))
        XCTAssertNil(parser.consume(line: try assistant(at: 55, id: "m3", output: 10, stop: "end_turn")))
    }

    func testCoordinatorMetaFollowUpIsASecondSubagentTurn() throws {
        var subagent = ClaudeTranscriptParser(sourceIdentity: "synthetic", scope: .subagent)
        _ = subagent.consume(line: try user(at: 0, id: "task", sidechain: true))
        let first = try XCTUnwrap(subagent.consume(line: assistant(at: 10, id: "s1", output: 100, stop: "end_turn", sidechain: true)))
        XCTAssertEqual(first.id, try expectedID("\(sessionID)|\(agentID)|task"))

        // Other meta records stay ignored in a subagent transcript.
        XCTAssertNil(subagent.consume(line: try user(at: 50, id: "other-meta", sidechain: true, meta: true, kind: "system")))
        XCTAssertNil(subagent.consume(line: try user(at: 51, id: "plain-meta", sidechain: true, meta: true)))
        // A non-meta record with a foreign origin kind is activity only.
        XCTAssertNil(subagent.consume(line: try user(at: 51.5, id: "notification", sidechain: true, kind: "task-notification")))
        XCTAssertNil(subagent.consume(line: try assistant(at: 52, id: "s-orphan", output: 5, stop: "end_turn", sidechain: true)))

        XCTAssertNil(subagent.consume(line: try user(at: 100, id: "follow-up", sidechain: true, meta: true, kind: "coordinator")))
        let second = try XCTUnwrap(subagent.consume(line: assistant(at: 108, id: "s2", output: 80, stop: "end_turn", sidechain: true)))
        XCTAssertEqual(second.id, try expectedID("\(sessionID)|\(agentID)|follow-up"))
        XCTAssertEqual(second.durationSeconds, 8, accuracy: 0.001)
        XCTAssertEqual(second.outputTokens, 80)

        // The coordinator exception is subagent-only: in a primary transcript it is just an unknown origin.
        var primary = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        XCTAssertNil(primary.consume(line: try user(at: 0, id: "c", meta: true, kind: "coordinator")))
        XCTAssertNil(primary.consume(line: try assistant(at: 5, id: "m", output: 5, stop: "end_turn")))
    }

    // MARK: Mid-file start synchronisation

    func testTailStartedParserSkipsAPartialTurnAndMeasuresTheNextFullTurn() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        parser.markStartedMidFile()
        // The tail begins mid-turn: a human interjection (parent set) is not a reliable turn start.
        XCTAssertNil(parser.consume(line: try user(at: 0, id: "interjection", kind: "human")))
        XCTAssertNil(parser.consume(line: try assistant(at: 5, id: "m1", output: 9_000, stop: "tool_use")))
        XCTAssertNil(parser.consume(line: try assistant(at: 10, id: "m2", output: 9_000, stop: "end_turn")))
        // The terminal record synchronised the parser; the next prompt is measured.
        _ = parser.consume(line: try user(at: 100, id: "next", kind: "human"))
        let metric = try XCTUnwrap(parser.consume(line: assistant(at: 110, id: "m3", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|next"))
        XCTAssertEqual(metric.outputTokens, 100)
    }

    func testTailStartedParserSynchronisesOnAConversationRootPrompt() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        parser.markStartedMidFile()
        XCTAssertNil(parser.consume(line: try toolResult(at: 0)))
        _ = parser.consume(line: try user(at: 1, id: "root", rootPrompt: true))
        let metric = try XCTUnwrap(parser.consume(line: assistant(at: 11, id: "m1", output: 100, stop: "end_turn")))
        XCTAssertEqual(metric.id, try expectedID("\(sessionID)|root"))

        // A parser reset (file replaced) starts from the beginning again.
        var replaced = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        replaced.markStartedMidFile()
        replaced.reset(sourceIdentity: "synthetic")
        _ = replaced.consume(line: try user(at: 0, id: "p"))
        XCTAssertNotNil(replaced.consume(line: try assistant(at: 5, id: "m", output: 10, stop: "end_turn")))
    }

    func testAbsentParentUuidDoesNotSynchroniseATailStartedParser() throws {
        var parser = ClaudeTranscriptParser(sourceIdentity: "synthetic")
        parser.markStartedMidFile()
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: user(at: 0, id: "no-parent-key", rootPrompt: true)) as? [String: Any])
        record.removeValue(forKey: "parentUuid")
        XCTAssertNil(parser.consume(line: try JSONSerialization.data(withJSONObject: record)))
        XCTAssertNil(parser.consume(line: try assistant(at: 5, id: "m1", output: 10, stop: "tool_use")))
        XCTAssertNil(parser.consume(line: try assistant(at: 6, id: "m2", output: 10, stop: "end_turn")), "still unsynchronised before the terminal record")
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
            let records = try await monitor.poll(now: Date.now.addingTimeInterval(Double(step) * 11))
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
        return result
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
        XCTAssertEqual(parser.consume(line: try assistant(at: 5, id: "m1", output: 5, stop: "end_turn"))?.provider, "unknown")
        _ = parser.consume(line: try user(at: 10, id: "p2"))
        XCTAssertEqual(parser.consume(line: try assistant(at: 15, id: bedrockMessage, output: 5, stop: "end_turn"))?.provider, "amazon-bedrock")
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
        let sample = try XCTUnwrap(SharedSample(result))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertEqual(json["provider"] as? String, "amazon-bedrock")
        XCTAssertEqual(json["model"] as? String, "claude-opus-4-6")
    }

    func testSharedSampleProviderAllowlistDependsOnClient() throws {
        func sample(client: String, provider: String) -> SharedSample? {
            let (parser, metricVersion): (String, String) = switch client {
            case "claude-code": ("claude-transcript-v3", "claude-observed-turn-v1")
            case "grok-build": ("grok-session-v1", "grok-observed-work-turn-v1")
            default: ("codex-rollout-v1", "turn-v1")
            }
            return SharedSample(TurnMetric(
                id: "id", completedAt: base, model: "m", outputTokens: 10, durationSeconds: 2, codexTTFTSeconds: nil,
                turnThroughputTPS: 5, client: client, clientVersion: client == "grok-build" ? nil : "1.0",
                parserVersion: parser, metricVersion: metricVersion, sourceKind: "primary", provider: provider
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
        XCTAssertEqual(SharedSample(try XCTUnwrap(metric(records: [(anthropicMessage, anthropicRequest, "m")])))?.appVersion, "0.1.13")
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

    private func toolResult(at seconds: Double, sidechain: Bool = false) throws -> Data {
        try user(at: seconds, id: "tool-result-\(Int(seconds))", sidechain: sidechain, content: [["type": "tool_result", "content": "PRIVATE_RESPONSE"]])
    }

    private func assistant(
        at seconds: Double, id: String, model: String = "claude-sonnet-5-5", output: Int?, stop: String?,
        sidechain: Bool = false, origin: Date? = nil, requestID: String? = nil
    ) throws -> Data {
        var value = envelope(sidechain: sidechain)
        if let requestID { value["requestId"] = requestID }
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
