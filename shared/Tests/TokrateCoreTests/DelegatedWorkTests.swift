import Foundation
import XCTest
@testable import TokrateCore

/// Delegated output attribution (contract "Delegated output"): Claude subagent turns and Codex
/// `thread_spawn` child turns are attributed to the primary turn that started them. Time is driven
/// by the `now:` of each monitor poll; every timestamp is an offset in seconds from `origin`.
final class DelegatedWorkTests: XCTestCase {
    /// Whole seconds, so transcript timestamps (millisecond precision) round-trip exactly.
    private let origin = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
    private let settle = DelegationAttributor.settleSeconds
    private let maximumWait = DelegationAttributor.maximumWaitSeconds

    // MARK: Claude

    private let session = "claude-session-1"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testClaudeSyncSubagentFinishingBeforeTheParentIsAddedOnceSettled() async throws {
        let monitor = try claudeMonitor(
            primary: [prompt(0), assistant("p1", 5, 100, "tool_use"), assistant("p2", 60, 300, "end_turn")],
            subagents: ["a1": [prompt(6, agent: "a1"), assistant("s1", 40, 700, "end_turn", agent: "a1")]]
        )
        let first = try await monitor.poll(now: at(60))
        let parent = try XCTUnwrap(first.metrics.first { $0.sourceKind == "primary" })
        XCTAssertEqual(parent.outputTokens, 400)
        XCTAssertNil(parent.delegatedOutputTokens, "emitted at once, before the delegated total is known")
        let subagent = try XCTUnwrap(first.metrics.first { $0.sourceKind == "subagent" })
        XCTAssertEqual(subagent.outputTokens, 700)
        XCTAssertNil(subagent.delegatedOutputTokens, "subagent records never carry a delegated total")

        let early = try await monitor.poll(now: at(60 + settle - 1))
        XCTAssertTrue(early.metrics.isEmpty, "not final before the settle time")
        let settled = try await monitor.poll(now: at(60 + settle))
        XCTAssertEqual(settled.metrics.map(\.id), [parent.id], "the same record id is re-emitted")
        XCTAssertEqual(settled.metrics.first?.delegatedOutputTokens, 700)
        XCTAssertEqual(settled.metrics.first?.outputTokens, 400, "outputTokens itself is unchanged")
        let after = try await monitor.poll(now: at(60 + settle + 10))
        XCTAssertTrue(after.metrics.isEmpty, "a final record is not emitted again")
    }

    func testClaudeParentWithoutSubagentsSettlesToZero() async throws {
        let monitor = try claudeMonitor(primary: [prompt(0), assistant("p1", 20, 300, "end_turn")], subagents: [:])
        let first = try await monitor.poll(now: at(20))
        XCTAssertEqual(first.metrics.count, 1)
        XCTAssertNil(first.metrics.first?.delegatedOutputTokens)
        let settled = try await monitor.poll(now: at(20 + settle))
        XCTAssertEqual(settled.metrics.first?.delegatedOutputTokens, 0)
    }

    func testClaudeBackgroundSubagentFinishingAfterTheParentIsReEmittedWithTheSum() async throws {
        let subagentFile = "agent-a1.jsonl"
        let monitor = try claudeMonitor(
            primary: [prompt(0), assistant("p1", 60, 300, "end_turn")],
            subagents: ["a1": [prompt(6, agent: "a1"), assistant("s1", 10, 50, "tool_use", agent: "a1")]]
        )
        let first = try await monitor.poll(now: at(60))
        let parent = try XCTUnwrap(first.metrics.first { $0.sourceKind == "primary" })
        XCTAssertNil(parent.delegatedOutputTokens)
        // Settled, but the subagent turn that started inside the parent's window is still open.
        let waiting = try await monitor.poll(now: at(100))
        XCTAssertTrue(waiting.metrics.isEmpty)
        let stillWaiting = try await monitor.poll(now: at(110))
        XCTAssertTrue(stillWaiting.metrics.isEmpty)

        try append([assistant("s2", 120, 450, "end_turn", agent: "a1")], toSubagent: subagentFile, modified: at(120))
        let done = try await monitor.poll(now: at(125))
        let final = try XCTUnwrap(done.metrics.first { $0.sourceKind == "primary" })
        XCTAssertEqual(final.id, parent.id)
        XCTAssertEqual(final.delegatedOutputTokens, 500, "both messages of the subagent turn: 50 + 450")
    }

    func testClaudeDiscardedSubagentTurnIsNotCountedAndDoesNotBlock() async throws {
        let monitor = try claudeMonitor(
            primary: [prompt(0), assistant("p1", 60, 300, "end_turn")],
            subagents: ["a1": [
                prompt(6, agent: "a1"),
                assistant("s1", 10, 900, "tool_use", agent: "a1"),
                interruption(20, agent: "a1"),
                prompt(25, agent: "a1", id: "task-2"),
                assistant("s2", 40, 120, "end_turn", agent: "a1")
            ]]
        )
        _ = try await monitor.poll(now: at(60))
        let settled = try await monitor.poll(now: at(60 + settle))
        XCTAssertEqual(settled.metrics.first?.delegatedOutputTokens, 120, "only the completed turn counts")
    }

    func testClaudeOpenSubagentBeyondMaximumWaitIsIgnored() async throws {
        let monitor = try claudeMonitor(
            primary: [prompt(0), assistant("p1", 60, 300, "end_turn")],
            subagents: [
                "done": [prompt(10, agent: "done"), assistant("d1", 30, 250, "end_turn", agent: "done")],
                "stuck": [prompt(12, agent: "stuck"), assistant("k1", 15, 80, "tool_use", agent: "stuck")]
            ]
        )
        _ = try await monitor.poll(now: at(60))
        let blocked = try await monitor.poll(now: at(60 + maximumWait - 1))
        XCTAssertTrue(blocked.metrics.isEmpty, "an open subagent turn holds the parent back")
        let released = try await monitor.poll(now: at(60 + maximumWait))
        XCTAssertEqual(released.metrics.first?.delegatedOutputTokens, 250, "finalized ignoring the open turn")
    }

    func testClaudeSubagentTurnsOutsideTheParentWindowOrSessionAreNotCounted() async throws {
        let monitor = try claudeMonitor(
            primary: [prompt(0), assistant("p1", 60, 300, "end_turn")],
            subagents: [
                "inside": [prompt(6, agent: "inside"), assistant("i1", 40, 111, "end_turn", agent: "inside")],
                "before": [prompt(-50, agent: "before"), assistant("b1", -10, 222, "end_turn", agent: "before")],
                "after": [prompt(61, agent: "after"), assistant("a1", 90, 333, "end_turn", agent: "after")],
                // Started after the parent completed and never finishes: it must not block the parent either.
                "open-after": [prompt(70, agent: "open-after"), assistant("o1", 72, 5, "tool_use", agent: "open-after")]
            ],
            otherSessionSubagents: ["foreign": [
                prompt(7, agent: "foreign", session: "another-session"),
                assistant("f1", 41, 444, "end_turn", agent: "foreign", session: "another-session")
            ]]
        )
        _ = try await monitor.poll(now: at(60))
        let settled = try await monitor.poll(now: at(60 + settle))
        XCTAssertEqual(settled.metrics.first?.delegatedOutputTokens, 111)
    }

    func testClaudeParentIsNotFinalizedWhileTheSubagentMonitorHasBacklog() async throws {
        // The subagent turn sits at the start of a file larger than the live tail, so only the
        // archive reader, which advances a batch per poll, finds it.
        var subagentData = Data()
        for line in [prompt(6, agent: "a1"), assistant("s1", 40, 700, "end_turn", agent: "a1")] {
            subagentData.append(line)
            subagentData.append(0x0A)
        }
        subagentData.append(Data(repeating: 0x20, count: 700_000) + Data([0x0A]))
        let monitor = try claudeMonitor(
            primary: [prompt(0), assistant("p1", 60, 300, "end_turn")],
            subagents: [:],
            rawSubagents: ["agent-a1.jsonl": subagentData]
        )
        let now = at(60 + settle + 5)
        var emitted: [TurnMetric] = []
        var firstFinalPoll: Int?
        for poll in 0..<60 {
            let update = try await monitor.poll(now: now)
            emitted += update.metrics.filter { $0.sourceKind == "primary" }
            if firstFinalPoll == nil, update.metrics.contains(where: { $0.delegatedOutputTokens != nil }) { firstFinalPoll = poll }
            if firstFinalPoll != nil { break }
        }
        XCTAssertEqual(emitted.first?.delegatedOutputTokens, nil, "emitted first without a total")
        let finals = emitted.filter { $0.delegatedOutputTokens != nil }
        XCTAssertEqual(finals.map(\.delegatedOutputTokens), [700], "never an intermediate zero while the archive was catching up")
        XCTAssertGreaterThan(try XCTUnwrap(firstFinalPoll), 1, "several polls of backlog came first")
    }

    // MARK: Codex

    func testCodexChildTurnsAreAttributedToTheRootThroughSessionID() async throws {
        let root = codexRoot(turns: [codexTurn("t1", start: 0, end: 60, tokens: 300)])
        let child = codexChild(id: "child-1", session: "root-1", parent: "root-1", turns: [codexTurn("c1", start: 10, end: 40, tokens: 400)])
        // A child of the child still names the root thread in session_id.
        let nested = codexChild(id: "grand-1", session: "root-1", parent: "child-1", turns: [codexTurn("g1", start: 20, end: 30, tokens: 150)])
        let foreign = codexChild(id: "child-x", session: "root-2", parent: "root-2", turns: [codexTurn("x1", start: 12, end: 20, tokens: 777)])
        // Guardian approval reviews are harness overhead, never delegated work.
        let guardian = codexSession(
            id: "guardian-1", session: "root-1", parent: "root-1", source: ["subagent": ["other": "guardian"]],
            turns: [codexTurn("r1", start: 15, end: 25, tokens: 9_999)]
        )
        let monitor = try codexMonitor(files: ["root": root, "child": child, "nested": nested, "foreign": foreign, "guardian": guardian])

        let first = try await readAll(monitor, at: 61)
        XCTAssertEqual(first.metrics.count, 1, "child sessions emit no TurnMetric")
        XCTAssertEqual(first.metrics.first?.outputTokens, 300)
        XCTAssertNil(first.metrics.first?.delegatedOutputTokens)
        XCTAssertEqual(first.responses.map(\.id), ["root-1|resp-t1"], "child sessions emit no live responses")

        let early = try await monitor.poll(now: at(60 + settle - 1))
        XCTAssertTrue(early.metrics.isEmpty)
        let settled = try await monitor.poll(now: at(60 + settle))
        XCTAssertEqual(settled.metrics.map(\.id), first.metrics.map(\.id))
        XCTAssertEqual(settled.metrics.first?.delegatedOutputTokens, 550, "child 400 + nested child 150; guardian and foreign root excluded")
        XCTAssertTrue(settled.responses.isEmpty)
    }

    func testCodexChildTurnsOutsideTheWindowAreNotCounted() async throws {
        let root = codexRoot(turns: [codexTurn("t1", start: 0, end: 60, tokens: 300)])
        let child = codexChild(id: "child-1", session: "root-1", parent: "root-1", turns: [
            codexTurn("before", start: -40, end: -5, tokens: 111),
            codexTurn("inside", start: 10, end: 40, tokens: 222),
            codexTurn("after", start: 61, end: 80, tokens: 333)
        ])
        let monitor = try codexMonitor(files: ["root": root, "child": child])
        _ = try await readAll(monitor, at: 61)
        let settled = try await monitor.poll(now: at(60 + settle))
        XCTAssertEqual(settled.metrics.first?.delegatedOutputTokens, 222)
    }

    func testCodexAbortedChildTurnIsDiscardedAndIncompleteOneIsIgnoredAfterMaximumWait() async throws {
        let root = codexRoot(turns: [codexTurn("t1", start: 0, end: 60, tokens: 300)])
        let aborted = codexChild(id: "child-a", session: "root-1", parent: "root-1", turns: [
            codexTurn("a1", start: 10, end: 20, tokens: 900, outcome: "turn_aborted"),
            codexTurn("a2", start: 22, end: 30, tokens: 120)
        ])
        let running = codexChild(id: "child-r", session: "root-1", parent: "root-1", turns: [
            codexTurn("r1", start: 15, end: 50, tokens: 60, outcome: nil)
        ])
        let monitor = try codexMonitor(files: ["root": root, "aborted": aborted, "running": running])
        _ = try await readAll(monitor, at: 61)
        let blocked = try await monitor.poll(now: at(60 + maximumWait - 1))
        XCTAssertTrue(blocked.metrics.isEmpty, "the unfinished child turn holds the parent back")
        let released = try await monitor.poll(now: at(60 + maximumWait))
        XCTAssertEqual(released.metrics.first?.delegatedOutputTokens, 120)
    }

    func testCodexLargeChildSessionIsReadFromTheStartAndHoldsTheParentWhileCatchingUp() async throws {
        let root = codexRoot(turns: [codexTurn("t1", start: 0, end: 60, tokens: 300)])
        // The child's turn lies far before the live tail of a file larger than 256 KiB.
        let child = codexChild(id: "child-1", session: "root-1", parent: "root-1", turns: [codexTurn("c1", start: 10, end: 40, tokens: 640)])
            + Data(repeating: 0x20, count: 700_000) + Data([0x0A])
        let monitor = try codexMonitor(files: ["root": root, "child": child])
        let now = at(60 + settle + 5)
        var delegatedTotals: [Int] = []
        var polls = 0
        while delegatedTotals.isEmpty, polls < 80 {
            let update = try await monitor.poll(now: now)
            delegatedTotals += update.metrics.compactMap(\.delegatedOutputTokens)
            polls += 1
        }
        XCTAssertEqual(delegatedTotals, [640], "no intermediate zero while the child was being read")
        XCTAssertGreaterThan(polls, 2)
    }

    func testCodexParserReportsSpawnedChildrenAsWorkOnlyAndSkipsOtherAgentSessions() throws {
        func parser(source: Any, extra: [String: Any] = [:]) throws -> CodexEventParser {
            var parser = CodexEventParser(sourceIdentity: "test")
            var payload: [String: Any] = ["id": "child-1", "source": source, "model_provider": "openai"]
            payload.merge(extra) { $1 }
            XCTAssertNil(parser.consume(line: try codexLine("session_meta", payload, at: 0)))
            return parser
        }
        var spawned = try parser(source: ["subagent": ["thread_spawn": ["parent_thread_id": "root-1", "depth": 1]]], extra: ["session_id": "root-1", "parent_thread_id": "root-1"])
        XCTAssertTrue(spawned.isDelegatedWork)
        XCTAssertFalse(spawned.isSkippedSession)
        var emitted: [TurnMetric] = []
        for line in codexTurn("c1", start: 10, end: 20, tokens: 500) { if let metric = spawned.consume(line: line) { emitted.append(metric) } }
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertTrue(spawned.drainCompletedResponses().isEmpty)
        let events = spawned.drainDelegationEvents()
        let root = DelegationRoot.key(client: "codex", rawSessionID: "root-1")
        XCTAssertEqual(events.count, 2)
        guard case .workStarted(let startedID, let startedRoot, let startedAt) = events[0],
              case .workFinished(let finishedID, let tokens, let finishedAt) = events[1] else { return XCTFail("\(events)") }
        XCTAssertEqual(startedID, finishedID)
        XCTAssertEqual(startedRoot, root)
        XCTAssertEqual(tokens, 500)
        XCTAssertEqual(finishedAt.timeIntervalSince(startedAt), 10, accuracy: 0.01)

        // The parent thread is the root when the session carries no session_id.
        var parentOnly = try parser(source: ["subagent": ["thread_spawn": [:]]], extra: ["parent_thread_id": "root-9"])
        _ = parentOnly.consume(line: try codexLine("event_msg", ["type": "task_started", "turn_id": "c"], at: 1))
        guard case .workStarted(_, let parentRoot, _)? = parentOnly.drainDelegationEvents().first else { return XCTFail("no start") }
        XCTAssertEqual(parentRoot, DelegationRoot.key(client: "codex", rawSessionID: "root-9"))

        // Any other agent session stays fully skipped.
        for source in [["subagent": ["other": "guardian"]], ["subagent": "review"], ["subagent": ["memory_consolidation": [:]]]] as [[String: Any]] {
            let skipped = try parser(source: source, extra: ["session_id": "root-1", "parent_thread_id": "root-1"])
            XCTAssertTrue(skipped.isSkippedSession, "\(source)")
            XCTAssertFalse(skipped.isDelegatedWork, "\(source)")
        }
        let withoutRoot = try parser(source: ["subagent": ["thread_spawn": [:]]])
        XCTAssertTrue(withoutRoot.isSkippedSession, "a spawned child that names no root cannot be attributed")
    }

    func testCodexPrimaryTurnReportsItsRootSession() throws {
        var parser = CodexEventParser(sourceIdentity: "test")
        _ = parser.consume(line: try codexLine("session_meta", ["id": "root-1", "session_id": "root-1", "source": "vscode", "model_provider": "openai"], at: 0))
        var metric: TurnMetric?
        for line in codexTurn("t1", start: 1, end: 5, tokens: 300) { metric = parser.consume(line: line) ?? metric }
        let events = parser.drainDelegationEvents()
        XCTAssertEqual(events, [.primaryTurn(turnID: try XCTUnwrap(metric).id, root: DelegationRoot.key(client: "codex", rawSessionID: "root-1"))])

        // Without a session_id the thread id is the root.
        var plain = CodexEventParser(sourceIdentity: "test")
        _ = plain.consume(line: try codexLine("session_meta", ["id": "root-2", "source": "cli", "model_provider": "openai"], at: 0))
        var other: TurnMetric?
        for line in codexTurn("t2", start: 1, end: 5, tokens: 300) { other = plain.consume(line: line) ?? other }
        XCTAssertEqual(plain.drainDelegationEvents(), [.primaryTurn(turnID: try XCTUnwrap(other).id, root: DelegationRoot.key(client: "codex", rawSessionID: "root-2"))])
    }

    // MARK: Attributor

    func testAttributorKeepsFinishedWorkOverALaterDiscardAndCapsItsMemory() {
        var attributor = DelegationAttributor()
        let completedAt = origin
        let turn = TurnMetric(
            id: "turn", completedAt: completedAt, model: "m", outputTokens: 100, durationSeconds: 60, codexTTFTSeconds: nil,
            turnThroughputTPS: 1, sourceKind: "primary"
        )
        attributor.ingest(events: [
            .primaryTurn(turnID: "turn", root: "r"),
            .workStarted(id: "w", root: "r", startedAt: completedAt.addingTimeInterval(-30)),
            .workFinished(id: "w", outputTokens: 70, finishedAt: completedAt),
            .workDiscarded(id: "w")
        ], metrics: [turn])
        XCTAssertEqual(attributor.finalize(now: completedAt.addingTimeInterval(settle), hasHistoricalBacklog: true), [], "backlog holds it")
        let finals = attributor.finalize(now: completedAt.addingTimeInterval(settle), hasHistoricalBacklog: false)
        XCTAssertEqual(finals.first?.delegatedOutputTokens, 70)
        XCTAssertEqual(attributor.finalize(now: completedAt.addingTimeInterval(settle + 1), hasHistoricalBacklog: false), [], "pending entries are dropped once final")

        // Work older than the history retention is forgotten.
        var aged = DelegationAttributor()
        let old = completedAt.addingTimeInterval(-MetricHistory.retention - 3_600)
        aged.ingest(events: [.workStarted(id: "old", root: "r", startedAt: old)], metrics: [])
        let recent = TurnMetric(
            id: "recent", completedAt: completedAt, model: "m", outputTokens: 100, durationSeconds: MetricHistory.retention + 7_200,
            codexTTFTSeconds: nil, turnThroughputTPS: 1, sourceKind: "primary"
        )
        aged.ingest(events: [.primaryTurn(turnID: "recent", root: "r")], metrics: [recent])
        XCTAssertEqual(aged.finalize(now: completedAt.addingTimeInterval(settle), hasHistoricalBacklog: false).first?.delegatedOutputTokens, 0, "the expired open item no longer blocks")
    }

    // MARK: Claude fixtures

    private func at(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }

    private func timestamp(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: at(seconds))
    }

    private func claudeRecord(_ type: String, uuid: String, at seconds: Double, agent: String?, session: String, message: [String: Any]) -> Data {
        var value: [String: Any] = [
            "type": type, "uuid": uuid, "parentUuid": "previous", "sessionId": session, "userType": "external",
            "isSidechain": agent != nil, "version": "2.1.37", "timestamp": timestamp(seconds), "message": message
        ]
        if let agent { value["agentId"] = agent }
        return try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func prompt(_ seconds: Double, agent: String? = nil, id: String? = nil, session: String? = nil) -> Data {
        claudeRecord("user", uuid: id ?? "prompt-\(agent ?? "primary")-\(Int(seconds))", at: seconds, agent: agent, session: session ?? self.session,
                     message: ["role": "user", "content": "PRIVATE_PROMPT"])
    }

    private func interruption(_ seconds: Double, agent: String) -> Data {
        claudeRecord("user", uuid: "interrupt-\(agent)-\(Int(seconds))", at: seconds, agent: agent, session: session,
                     message: ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]])
    }

    private func assistant(_ id: String, _ seconds: Double, _ output: Int, _ stop: String, agent: String? = nil, session: String? = nil) -> Data {
        claudeRecord("assistant", uuid: "record-\(id)", at: seconds, agent: agent, session: session ?? self.session, message: [
            "id": id, "role": "assistant", "model": "claude-sonnet-5-5", "content": "PRIVATE_RESPONSE",
            "stop_reason": stop, "usage": ["output_tokens": output]
        ])
    }

    private func jsonl(_ lines: [Data]) -> Data {
        lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
    }

    private func claudeMonitor(
        primary: [Data], subagents: [String: [Data]], otherSessionSubagents: [String: [Data]] = [:], rawSubagents: [String: Data] = [:]
    ) throws -> ClaudeSessionMonitor {
        let project = directory.appendingPathComponent("project", isDirectory: true)
        let subagentDirectory = project.appendingPathComponent("\(session)/subagents", isDirectory: true)
        let otherDirectory = project.appendingPathComponent("another-session/subagents", isDirectory: true)
        for folder in [subagentDirectory, otherDirectory] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try jsonl(primary).write(to: project.appendingPathComponent("\(session).jsonl"))
        for (agent, lines) in subagents { try jsonl(lines).write(to: subagentDirectory.appendingPathComponent("agent-\(agent).jsonl")) }
        for (agent, lines) in otherSessionSubagents { try jsonl(lines).write(to: otherDirectory.appendingPathComponent("agent-\(agent).jsonl")) }
        for (name, data) in rawSubagents { try data.write(to: subagentDirectory.appendingPathComponent(name)) }
        return ClaudeSessionMonitor(root: directory, liveSince: origin)
    }

    private func append(_ lines: [Data], toSubagent name: String, modified: Date) throws {
        let url = directory.appendingPathComponent("project/\(session)/subagents/\(name)")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: jsonl(lines))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    // MARK: Codex fixtures

    private func codexLine(_ type: String, _ payload: [String: Any], at seconds: Double) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["timestamp": timestamp(seconds), "type": type, "payload": payload] as [String: Any], options: [.sortedKeys])
    }

    /// One turn: task_started, context, one response, then `outcome` (`task_complete`, `turn_aborted` or nothing).
    private func codexTurn(_ id: String, start: Double, end: Double, tokens: Int, outcome: String? = "task_complete") -> [Data] {
        var lines = [
            try! codexLine("event_msg", ["type": "task_started", "turn_id": id], at: start),
            try! codexLine("turn_context", ["turn_id": id, "model": "gpt-test"], at: start),
            try! codexLine("response_item", ["type": "reasoning"], at: start + 1),
            try! codexLine("token_usage_record", [
                "turn_id": id, "response_id": "resp-\(id)", "usage": ["output_tokens": tokens], "turn_token_usage": ["output_tokens": tokens]
            ], at: end - 1)
        ]
        if let outcome {
            lines.append(try! codexLine("event_msg", ["type": outcome, "turn_id": id, "duration_ms": (end - start) * 1_000], at: end))
        }
        return lines
    }

    private func codexSession(id: String, session: String?, parent: String?, source: Any, turns: [[Data]]) -> Data {
        var payload: [String: Any] = ["id": id, "source": source, "model_provider": "openai"]
        if let session { payload["session_id"] = session }
        if let parent { payload["parent_thread_id"] = parent }
        return jsonl([try! codexLine("session_meta", payload, at: -100)] + turns.flatMap { $0 })
    }

    private func codexRoot(turns: [[Data]]) -> Data {
        codexSession(id: "root-1", session: "root-1", parent: nil, source: "vscode", turns: turns)
    }

    private func codexChild(id: String, session: String, parent: String, turns: [[Data]]) -> Data {
        codexSession(id: id, session: session, parent: parent, source: ["subagent": ["thread_spawn": ["parent_thread_id": parent, "depth": 1]]], turns: turns)
    }

    /// A new Codex file is read in steps (header, then content), so a few polls at one clock reading read it all.
    private func readAll(_ monitor: CodexSessionMonitor, at seconds: Double) async throws -> MonitorUpdate {
        var metrics: [String: TurnMetric] = [:]
        var responses: [String: LiveResponse] = [:]
        for _ in 0..<4 {
            let update = try await monitor.poll(now: at(seconds))
            for metric in update.metrics { metrics[metric.id] = metric }
            for response in update.responses { responses[response.id] = response }
        }
        return MonitorUpdate(metrics: Array(metrics.values), responses: Array(responses.values))
    }

    private func codexMonitor(files: [String: Data]) throws -> CodexSessionMonitor {
        for (name, data) in files { try data.write(to: directory.appendingPathComponent("\(name).jsonl")) }
        return CodexSessionMonitor(root: directory, liveSince: at(-1_000))
    }
}
