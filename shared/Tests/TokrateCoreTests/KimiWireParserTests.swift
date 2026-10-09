import CryptoKit
import Foundation
import XCTest
@testable import TokrateCore

/// Kimi Code `wire.jsonl` parsing (contract "Kimi Code (0.1.21)").
final class KimiWireParserTests: XCTestCase {
    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A user prompt at 0 s and one `end_turn` step from 1 s to 11 s.
    private func simpleTurn(
        output: Int = 300, origin: [String: Any]? = ["kind": "user"], turn: String = "0", at offset: Double = 0
    ) -> [Data] {
        [KimiLog.prompt(at: offset, origin: origin)]
            + KimiLog.step(turn, 1, begin: offset + 1, end: offset + 11, finish: "end_turn", output: output)
    }

    // MARK: Real logs

    func testDesktopTwoStepTurnFromARealLog() throws {
        let path = "/tmp/kimi/sessions/wd_x/conv-22ebc177fa959871b7c04a95/agents/main/wire.jsonl"
        let result = KimiWireParser.parse(try KimiLog.fixture("desktop-k2d8-two-step-success"), surface: .desktop, path: path)
        let turn = try XCTUnwrap(result.metrics.first)
        XCTAssertEqual(result.metrics.count, 1)
        XCTAssertEqual(turn.id, digest("kimi-code|conv-22ebc177fa959871b7c04a95|0|1791543242286"))
        XCTAssertEqual(turn.completedAt, Date(timeIntervalSince1970: 1_791_543_260.330))
        XCTAssertEqual(turn.durationSeconds, 18.044, accuracy: 0.000_001)
        XCTAssertEqual(turn.outputTokens, 416, "131 + 285")
        XCTAssertEqual(turn.turnThroughputTPS, 416 / 18.044, accuracy: 0.000_001)
        XCTAssertEqual(turn.model, "k2d8-preview")
        XCTAssertEqual(turn.reasoningEffort, "high")
        XCTAssertEqual(turn.provider, "moonshot")
        XCTAssertEqual(turn.surface, .desktop)
        XCTAssertEqual(turn.inputTokens, 36_590)
        XCTAssertEqual(turn.cacheReadInputTokens, 30_976)
        XCTAssertNil(turn.cacheWriteInputTokens)
        XCTAssertNil(turn.reasoningOutputTokens)
        XCTAssertNil(turn.clientVersion)
        XCTAssertNil(turn.codexTTFTSeconds)
        XCTAssertNil(turn.providerRegion)
        XCTAssertEqual(turn.client, "kimi-code")
        XCTAssertEqual(turn.parserVersion, "kimi-wire-v1")
        XCTAssertEqual(turn.metricVersion, "kimi-observed-turn-v1")
        XCTAssertEqual(turn.sourceKind, "primary")
        // Step 1 has 131 tokens and does not qualify; step 2 ran from its request to its end.
        XCTAssertEqual(turn.responseCount, 1)
        XCTAssertEqual(turn.responseOutputTokens, 285)
        XCTAssertEqual(try XCTUnwrap(turn.responseDurationSeconds), 10.280, accuracy: 0.000_001)
        XCTAssertNil(turn.delegatedOutputTokens)
        XCTAssertEqual(result.events, [.primaryTurn(
            turnID: turn.id, root: DelegationRoot.key(client: "kimi-code", rawSessionID: "conv-22ebc177fa959871b7c04a95")
        )])
        XCTAssertEqual(result.responses.map(\.outputTokens), [285])
    }

    func testCapacityFailureYieldsNoTurnButEveryCompletedStepIsALiveResponse() throws {
        let result = KimiWireParser.parse(try KimiLog.fixture("desktop-k2d8-capacity-failure"), surface: .desktop)
        XCTAssertTrue(result.metrics.isEmpty, "step 10 never ended, then a new prompt started another turn")
        XCTAssertEqual(result.responses.map(\.outputTokens), [242, 313, 207, 240, 335, 414, 359, 263, 1_772])
        XCTAssertEqual(Set(result.responses.map(\.model)), ["k2d8-preview"])
        XCTAssertEqual(Set(result.responses.map(\.provider)), ["moonshot"])
        XCTAssertEqual(Set(result.responses.map(\.reasoningEffort)), ["high"])
        XCTAssertEqual(result.responses.count, Set(result.responses.map(\.id)).count)
    }

    func testProtocol13LogsHaveNoRequestsAndProduceNothing() throws {
        let result = KimiWireParser.parse(try KimiLog.fixture("desktop-protocol-1.3"), surface: .desktop)
        XCTAssertTrue(result.metrics.isEmpty)
        XCTAssertTrue(result.responses.isEmpty)
    }

    func testFailedCliTurnsProduceNothing() throws {
        let result = KimiWireParser.parse(try KimiLog.fixture("cli-2.1.1-failed-turns"))
        XCTAssertTrue(result.metrics.isEmpty)
        XCTAssertTrue(result.responses.isEmpty)
    }

    // MARK: Prompts

    func testOnlyAPromptTheUserTypedStartsAMeasuredTurn() {
        let measured: [[String: Any]?] = [
            nil,
            ["kind": "user"],
            ["kind": "skill_activation", "trigger": "user-slash"],
            ["kind": "plugin_command", "trigger": "user-slash"]
        ]
        for origin in measured {
            let result = KimiWireParser.parse(simpleTurn(origin: origin))
            XCTAssertEqual(result.metrics.count, 1, "\(String(describing: origin))")
        }
        let unmeasured: [[String: Any]] = [
            ["kind": "skill_activation"],
            ["kind": "skill_activation", "trigger": "model"],
            ["kind": "plugin_command", "trigger": "hook"],
            ["kind": "system"],
            ["kind": "injection"],
            ["kind": "automation"],
            ["trigger": "user-slash"],
            [:]
        ]
        for origin in unmeasured {
            let result = KimiWireParser.parse(simpleTurn(origin: origin))
            XCTAssertTrue(result.metrics.isEmpty, "\(origin)")
            XCTAssertEqual(result.responses.count, 1, "an unmeasured turn still feeds the live stream: \(origin)")
        }
        // An origin that is not an object is malformed, not absent.
        let malformed = [KimiLog.line(["type": "turn.prompt", "time": KimiLog.milliseconds(0), "origin": "user"])]
            + KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn")
        XCTAssertTrue(KimiWireParser.parse(malformed).metrics.isEmpty)
    }

    func testTheLatestPromptSinceThePreviousTurnBeganDecidesAndStartingATurnClearsIt() {
        // The system prompt came last, so the turn is not a user turn.
        var lines = [KimiLog.prompt(at: 0), KimiLog.prompt(at: 0.5, origin: ["kind": "system"])]
        lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn")
        XCTAssertTrue(KimiWireParser.parse(lines).metrics.isEmpty)

        // A later turn without a prompt of its own does not reuse the earlier one.
        lines = simpleTurn()
        lines += KimiLog.step("1", 1, begin: 21, end: 31, finish: "end_turn")
        let result = KimiWireParser.parse(lines)
        XCTAssertEqual(result.metrics.count, 1)
        XCTAssertEqual(result.responses.count, 2)
    }

    func testTheTurnStartsAtItsPromptNotAtItsFirstStep() throws {
        let lines = [KimiLog.prompt(at: 0)] + KimiLog.step("0", 1, begin: 4, end: 14, finish: "end_turn")
        let turn = try XCTUnwrap(KimiWireParser.parse(lines).metrics.first)
        XCTAssertEqual(turn.durationSeconds, 14, accuracy: 0.000_001)
        XCTAssertEqual(turn.id, digest("kimi-code|conv-1|0|\(KimiLog.milliseconds(0))"))
    }

    func testAMessageSentWhileATurnRunsDoesNotEndIt() throws {
        var lines = [KimiLog.prompt(at: 0)]
        lines += KimiLog.step("0", 1, begin: 1, end: 11, output: 300)
        lines.append(KimiLog.prompt(at: 12))
        lines += KimiLog.step("0", 2, begin: 13, end: 23, finish: "end_turn", output: 400)
        let result = KimiWireParser.parse(lines)
        let turn = try XCTUnwrap(result.metrics.first)
        XCTAssertEqual(result.metrics.count, 1)
        XCTAssertEqual(turn.outputTokens, 700)
        XCTAssertEqual(turn.durationSeconds, 23, accuracy: 0.000_001)
    }

    // MARK: Turn identity and mid-file starts

    func testAReaderThatJoinedMidTurnMeasuresNoTurnUntilTheNextOne() throws {
        var lines = KimiLog.step("0", 3, begin: 1, end: 11, output: 300)
        lines += KimiLog.step("0", 4, begin: 12, end: 22, finish: "end_turn", output: 300)
        lines += simpleTurn(turn: "1", at: 30)
        let result = KimiWireParser.parse(lines, startedMidFile: true)
        XCTAssertEqual(result.metrics.count, 1)
        XCTAssertEqual(result.metrics.first?.id, digest("kimi-code|conv-1|1|\(KimiLog.milliseconds(30))"))
        XCTAssertEqual(result.responses.count, 3, "the unmeasured steps still feed the live stream")
    }

    func testAFirstObservedStepAboveOneIsNotMeasuredEvenWithAPrompt() {
        let lines = [KimiLog.prompt(at: 0)] + KimiLog.step("0", 2, begin: 1, end: 11, finish: "end_turn")
        let result = KimiWireParser.parse(lines)
        XCTAssertTrue(result.metrics.isEmpty)
        XCTAssertEqual(result.responses.count, 1)
    }

    func testLaterStepsOfAnUnmeasuredTurnNeverBecomeATurn() {
        var lines = [KimiLog.prompt(at: 0, origin: ["kind": "system"])]
        lines += KimiLog.step("0", 1, begin: 1, end: 11)
        lines += KimiLog.step("0", 2, begin: 12, end: 22, finish: "end_turn")
        let result = KimiWireParser.parse(lines)
        XCTAssertTrue(result.metrics.isEmpty)
        XCTAssertEqual(result.responses.count, 2)
    }

    // MARK: Requests

    func testTheLatestRequestOfAStepAnswersIt() throws {
        let lines = [
            KimiLog.prompt(at: 0),
            KimiLog.begin("0", 1, at: 1),
            KimiLog.request("0", 1, at: 1.001, model: "first-model", provider: "openai", effort: "low"),
            KimiLog.request("0", 1, at: 5, model: "k2d8-preview", provider: "kimi", effort: "high"),
            KimiLog.end("0", 1, at: 15, finish: "end_turn", usage: KimiLog.usage(output: 300))
        ]
        let result = KimiWireParser.parse(lines)
        let turn = try XCTUnwrap(result.metrics.first)
        XCTAssertEqual(turn.model, "k2d8-preview")
        XCTAssertEqual(turn.provider, "moonshot")
        XCTAssertEqual(turn.reasoningEffort, "high")
        XCTAssertEqual(try XCTUnwrap(turn.responseDurationSeconds), 10, accuracy: 0.000_001, "from the retried request")
        XCTAssertEqual(turn.durationSeconds, 15, accuracy: 0.000_001, "the turn still starts at its prompt")
    }

    func testAStepWithoutARequestDiscardsTheTurnAndIsNoResponse() {
        var lines = [KimiLog.prompt(at: 0), KimiLog.begin("0", 1, at: 1)]
        lines.append(KimiLog.end("0", 1, at: 11, finish: "end_turn"))
        let result = KimiWireParser.parse(lines)
        XCTAssertTrue(result.metrics.isEmpty)
        XCTAssertTrue(result.responses.isEmpty)

        // A request written before the step began, or for another step, does not count.
        let early = [
            KimiLog.prompt(at: 0), KimiLog.request("0", 1, at: 0.5), KimiLog.begin("0", 1, at: 1),
            KimiLog.request("0", 2, at: 1.001), KimiLog.end("0", 1, at: 11, finish: "end_turn")
        ]
        XCTAssertTrue(KimiWireParser.parse(early).metrics.isEmpty)
    }

    func testAStepOfAnEarlierTurnMissingItsRequestDiscardsOnlyThatTurn() {
        var lines = [KimiLog.prompt(at: 0), KimiLog.begin("0", 1, at: 1), KimiLog.end("0", 1, at: 11, finish: "end_turn")]
        lines += simpleTurn(turn: "1", at: 20)
        let result = KimiWireParser.parse(lines)
        XCTAssertEqual(result.metrics.count, 1)
        XCTAssertEqual(result.metrics.first?.id, digest("kimi-code|conv-1|1|\(KimiLog.milliseconds(20))"))
    }

    // MARK: Failing steps

    func testEveryFailingFinishReasonDiscardsTheTurn() {
        for finish in ["interrupted", "error", "filtered", "max_tokens", "paused", "other", nil] as [String?] {
            var lines = [KimiLog.prompt(at: 0)]
            lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "tool_use")
            lines += KimiLog.step("0", 2, begin: 12, end: 22, finish: finish)
            lines += KimiLog.step("0", 3, begin: 23, end: 33, finish: "end_turn")
            let result = KimiWireParser.parse(lines)
            XCTAssertTrue(result.metrics.isEmpty, "\(String(describing: finish))")
            XCTAssertEqual(result.responses.count, 2, "only the successful steps are responses: \(String(describing: finish))")
        }
    }

    func testAStepWithoutCompleteUsageFails() {
        let invalid: [[String: Any]?] = [
            nil,
            ["output": 300, "inputOther": 1, "inputCacheRead": 1],
            ["output": 300, "inputOther": 1, "inputCacheCreation": 0],
            ["output": -1, "inputOther": 1, "inputCacheRead": 1, "inputCacheCreation": 0],
            ["output": 300.5, "inputOther": 1, "inputCacheRead": 1, "inputCacheCreation": 0],
            ["output": 300, "inputOther": 100_000_001, "inputCacheRead": 1, "inputCacheCreation": 0],
            ["output": true, "inputOther": 1, "inputCacheRead": 1, "inputCacheCreation": 0],
            ["output": "300", "inputOther": 1, "inputCacheRead": 1, "inputCacheCreation": 0]
        ]
        for usage in invalid {
            let lines = [
                KimiLog.prompt(at: 0), KimiLog.begin("0", 1, at: 1), KimiLog.request("0", 1, at: 1.001),
                KimiLog.end("0", 1, at: 11, finish: "end_turn", usage: usage)
            ]
            let result = KimiWireParser.parse(lines)
            XCTAssertTrue(result.metrics.isEmpty, "\(String(describing: usage))")
            XCTAssertTrue(result.responses.isEmpty, "\(String(describing: usage))")
        }
        // The bound itself is valid: 100,000,000 tokens over 50,000 s is exactly 2,000 tok/s.
        let edge = [
            KimiLog.prompt(at: 0), KimiLog.begin("0", 1, at: 1), KimiLog.request("0", 1, at: 1.001),
            KimiLog.end("0", 1, at: 50_000, finish: "end_turn", usage: KimiLog.usage(output: 100_000_000, inputOther: 100_000_000, cacheRead: 0, cacheCreation: 0))
        ]
        XCTAssertEqual(KimiWireParser.parse(edge).metrics.first?.outputTokens, 100_000_000)
    }

    func testAStepStillOpenWhenAnotherTurnBeginsDiscardsItsTurn() {
        var lines = [KimiLog.prompt(at: 0)]
        lines += KimiLog.step("0", 1, begin: 1, end: 11)
        lines += [KimiLog.begin("0", 2, at: 12), KimiLog.request("0", 2, at: 12.001)]
        lines += simpleTurn(turn: "1", at: 30)
        let result = KimiWireParser.parse(lines)
        XCTAssertEqual(result.metrics.map(\.id), [digest("kimi-code|conv-1|1|\(KimiLog.milliseconds(30))")])
    }

    func testANewStepOfTheSameTurnWhileOneIsOpenDiscardsTheTurn() {
        var lines = [KimiLog.prompt(at: 0), KimiLog.begin("0", 1, at: 1), KimiLog.request("0", 1, at: 1.001)]
        lines += KimiLog.step("0", 2, begin: 5, end: 15, finish: "end_turn")
        XCTAssertTrue(KimiWireParser.parse(lines).metrics.isEmpty)
    }

    func testAnEndWithoutAMatchingOpenStepIsIgnored() throws {
        var lines = [KimiLog.prompt(at: 0)]
        lines.append(KimiLog.end("0", 7, at: 0.5, finish: "error", usage: nil))
        lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn")
        lines.append(KimiLog.end("0", 1, at: 12, finish: "error", usage: nil))
        XCTAssertEqual(KimiWireParser.parse(lines).metrics.count, 1)
    }

    // MARK: Completion

    func testATurnCompletesAtItsFirstEndTurnAndIsEmittedAtOnce() throws {
        var parser = KimiWireParser(sourceIdentity: KimiLog.mainPath, scope: .main, surface: .cli)
        var emitted: [TurnMetric] = []
        let lines = simpleTurn()
        for line in lines.dropLast() { XCTAssertNil(parser.consume(line: line)) }
        XCTAssertFalse(parser.hasPendingWork)
        if let metric = parser.consume(line: try XCTUnwrap(lines.last)) { emitted.append(metric) }
        XCTAssertEqual(emitted.count, 1, "by the step.end itself, not by a later record or a poll end")
        XCTAssertEqual(emitted.first?.completedAt, KimiLog.date(11))
        XCTAssertFalse(parser.hasPendingWork)
        XCTAssertNil(parser.pollEnded(now: .now, isFinal: true), "nothing waits for the end of a poll or of the file")
        XCTAssertEqual(KimiWireParser.parse(lines).metrics, emitted, "a live reader and an archive reader measure alike")
    }

    func testAToolUseStepNeverCompletesATurn() {
        var lines = [KimiLog.prompt(at: 0)]
        lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "tool_use")
        XCTAssertTrue(KimiWireParser.parse(lines).metrics.isEmpty)
    }

    func testStepsAfterTheFirstEndTurnBelongToNoMeasuredTurnButStillFeedTheLiveStream() throws {
        var lines = [KimiLog.prompt(at: 0)]
        lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn", output: 300)
        lines.append(KimiLog.prompt(at: 12))
        lines += KimiLog.step("0", 2, begin: 13, end: 23, finish: "tool_use", output: 400)
        lines += KimiLog.step("0", 3, begin: 24, end: 34, finish: "end_turn", output: 500)
        let result = KimiWireParser.parse(lines)
        let turn = try XCTUnwrap(result.metrics.first)
        XCTAssertEqual(result.metrics.count, 1)
        XCTAssertEqual(turn.outputTokens, 300, "a reported turn is never re-reported with different totals")
        XCTAssertEqual(turn.completedAt, KimiLog.date(11))
        XCTAssertEqual(result.responses.map(\.outputTokens), [300, 400, 500])
    }

    func testFailuresAfterCompletionDoNotRetractTheTurn() {
        var lines = simpleTurn()
        lines += KimiLog.step("0", 2, begin: 12, end: 22, finish: "error")
        lines += [KimiLog.turnEnded(0, reason: "failed", at: 23), KimiLog.promptAborted(at: 24)]
        XCTAssertEqual(KimiWireParser.parse(lines).metrics.count, 1)
    }

    func testEachTurnIsEmittedOnceAtItsOwnEnd() {
        let result = KimiWireParser.parse(simpleTurn() + simpleTurn(turn: "1", at: 20))
        XCTAssertEqual(result.metrics.map(\.durationSeconds), [11, 11])
        XCTAssertEqual(result.metrics.last?.id, digest("kimi-code|conv-1|1|\(KimiLog.milliseconds(20))"))
    }

    func testTurnIdsAreComparedAsTheirDecimalStrings() throws {
        func record(_ type: String, _ time: Double, _ fields: [String: Any]) -> Data {
            KimiLog.line(["type": type, "time": KimiLog.milliseconds(time)].merging(fields) { $1 })
        }
        let usage = KimiLog.usage()
        let lines = [
            KimiLog.prompt(at: 0),
            record("context.append_loop_event", 1, ["event": ["type": "step.begin", "turnId": 0, "step": 1]]),
            record("llm.request", 1.001, ["turnStep": "0.1", "model": "k2d8-preview", "provider": "kimi"]),
            record("context.append_loop_event", 11, ["event": ["type": "step.end", "turnId": "0", "step": 1, "finishReason": "end_turn", "usage": usage]])
        ]
        let turn = try XCTUnwrap(KimiWireParser.parse(lines).metrics.first)
        XCTAssertEqual(turn.id, digest("kimi-code|conv-1|0|\(KimiLog.milliseconds(0))"))
        // And a turn-end record with an integer id discards the turn that a string id began.
        XCTAssertTrue(KimiWireParser.parse(Array(lines.dropLast()) + [KimiLog.turnEnded(0, reason: "failed", at: 5)] + [lines.last!]).metrics.isEmpty)
    }

    // MARK: Discards

    func testTurnEndRecordsDiscardTheirTurnBeforeItCompletes() {
        let discards: [(String, Data)] = [
            ("step interrupted", KimiLog.stepInterrupted(0, at: 12)),
            ("interrupted, string id", KimiLog.stepInterrupted("0", at: 12)),
            ("failed", KimiLog.turnEnded(0, reason: "failed", at: 12)),
            ("aborted", KimiLog.turnEnded(0, reason: "aborted", at: 12)),
            ("cancelled", KimiLog.turnEnded(0, reason: "cancelled", at: 12)),
            ("interrupted", KimiLog.turnEnded(0, reason: "interrupted", at: 12)),
            ("error", KimiLog.turnEnded("0", reason: "error", at: 12)),
            ("agent failed", KimiLog.agentTurnEnded(0, outcome: "failed", at: 12)),
            ("agent aborted", KimiLog.agentTurnEnded("0", outcome: "aborted", at: 12)),
            ("prompt aborted", KimiLog.promptAborted(at: 12))
        ]
        for (name, record) in discards {
            var lines = [KimiLog.prompt(at: 0)] + KimiLog.step("0", 1, begin: 1, end: 11, finish: "tool_use")
            lines.append(record)
            lines += KimiLog.step("0", 2, begin: 13, end: 23, finish: "end_turn")
            XCTAssertTrue(KimiWireParser.parse(lines).metrics.isEmpty, name)
        }
    }

    func testOtherEndValuesAndOtherTurnsAreIgnored() {
        let ignored: [Data] = [
            KimiLog.turnEnded(0, reason: "completed", at: 5),
            KimiLog.turnEnded(0, reason: "end_turn", at: 5),
            KimiLog.agentTurnEnded(0, outcome: "completed", at: 5),
            KimiLog.turnEnded(7, reason: "failed", at: 5),
            KimiLog.agentTurnEnded("7", outcome: "failed", at: 5),
            KimiLog.stepInterrupted(7, at: 5),
            KimiLog.line(["type": "turn.ended", "time": KimiLog.milliseconds(5), "turnId": 0]),
            KimiLog.line(["type": "turn.ended", "time": KimiLog.milliseconds(5), "reason": "failed"])
        ]
        for record in ignored {
            let lines = [KimiLog.prompt(at: 0), KimiLog.begin("0", 1, at: 1), record, KimiLog.request("0", 1, at: 1.001),
                         KimiLog.end("0", 1, at: 11, finish: "end_turn")]
            XCTAssertEqual(KimiWireParser.parse(lines).metrics.count, 1, String(decoding: record, as: UTF8.self))
        }
    }

    func testAnAbortedPromptDiscardsTheOpenTurnOnly() {
        var lines = [KimiLog.prompt(at: 0)] + KimiLog.step("0", 1, begin: 1, end: 11, finish: "tool_use")
        lines += [KimiLog.promptAborted(at: 12)]
        lines += simpleTurn(turn: "1", at: 20)
        XCTAssertEqual(KimiWireParser.parse(lines).metrics.map(\.id), [digest("kimi-code|conv-1|1|\(KimiLog.milliseconds(20))")])
    }

    // MARK: Values

    func testProviderIsMoonshotOnlyForTheKimiProvider() throws {
        func provider(_ raw: String?) throws -> String? {
            var lines = [KimiLog.prompt(at: 0)]
            lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn", provider: raw)
            return try XCTUnwrap(KimiWireParser.parse(lines).metrics.first).provider
        }
        XCTAssertEqual(try provider("kimi"), "moonshot")
        for other in ["openai", "anthropic", "Kimi", "moonshot", "kimi-code", "", nil] as [String?] {
            XCTAssertEqual(try provider(other), "unknown", "\(String(describing: other))")
        }
    }

    func testTurnProviderModelAndEffortNeedAllStepsToAgree() throws {
        func turn(_ first: (String?, String?, String?), _ second: (String?, String?, String?)) throws -> TurnMetric {
            var lines = [KimiLog.prompt(at: 0)]
            lines += KimiLog.step("0", 1, begin: 1, end: 11, model: first.0, provider: first.1, effort: first.2)
            lines += KimiLog.step("0", 2, begin: 12, end: 22, finish: "end_turn", model: second.0, provider: second.1, effort: second.2)
            return try XCTUnwrap(KimiWireParser.parse(lines).metrics.first)
        }
        let same = try turn(("k2d8-preview", "kimi", "high"), ("k2d8-preview", "kimi", "high"))
        XCTAssertEqual([same.model, same.provider, same.reasoningEffort], ["k2d8-preview", "moonshot", "high"])
        let mixed = try turn(("k2d8-preview", "kimi", "high"), ("kimi-for-coding", "openai", "low"))
        XCTAssertNil(mixed.model)
        XCTAssertEqual(mixed.provider, "unknown")
        XCTAssertNil(mixed.reasoningEffort)
        let partial = try turn(("k2d8-preview", "kimi", "high"), (nil, "kimi", "on"))
        XCTAssertNil(partial.model, "a step without a usable model leaves the turn's model unknown")
        XCTAssertEqual(partial.provider, "moonshot")
        XCTAssertNil(partial.reasoningEffort)
    }

    func testReasoningEffortIsKeptOnlyWhenItIsAnAllowedValue() throws {
        for effort in ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"] {
            var lines = [KimiLog.prompt(at: 0)]
            lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn", effort: effort)
            XCTAssertEqual(KimiWireParser.parse(lines).metrics.first?.reasoningEffort, effort)
        }
        for effort in ["on", "off", "", "HIGH", "auto"] as [String?] {
            var lines = [KimiLog.prompt(at: 0)]
            lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn", effort: effort)
            let result = KimiWireParser.parse(lines)
            XCTAssertEqual(result.metrics.count, 1)
            XCTAssertNil(result.metrics.first?.reasoningEffort, "\(String(describing: effort))")
            XCTAssertNil(result.responses.first?.reasoningEffort)
        }
    }

    func testTheModelMustBeASafeIdentifier() throws {
        for model in ["k2d8-preview", "kimi-for-coding", "kimi-k2.5", "a_b-c.d", String(repeating: "a", count: 80)] {
            var lines = [KimiLog.prompt(at: 0)]
            lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn", model: model)
            XCTAssertEqual(KimiWireParser.parse(lines).metrics.first?.model, model)
        }
        for model in ["", "has space", "kimi/for", "k\n", "../x", String(repeating: "a", count: 81), "kimi\u{00E9}"] {
            var lines = [KimiLog.prompt(at: 0)]
            lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn", model: model)
            let result = KimiWireParser.parse(lines)
            XCTAssertEqual(result.metrics.count, 1)
            XCTAssertNil(result.metrics.first?.model, model)
            XCTAssertNil(result.responses.first?.model, model)
        }
    }

    func testPromptCacheTotalsSumTheStepsAndCacheWritesAreNeverReported() throws {
        var lines = [KimiLog.prompt(at: 0)]
        lines += KimiLog.step("0", 1, begin: 1, end: 11, usage: KimiLog.usage(output: 300, inputOther: 10, cacheRead: 100, cacheCreation: 5))
        lines += KimiLog.step("0", 2, begin: 12, end: 22, finish: "end_turn", usage: KimiLog.usage(output: 300, inputOther: 20, cacheRead: 200, cacheCreation: 7))
        let turn = try XCTUnwrap(KimiWireParser.parse(lines).metrics.first)
        XCTAssertEqual(turn.inputTokens, 10 + 100 + 5 + 20 + 200 + 7)
        XCTAssertEqual(turn.cacheReadInputTokens, 300)
        XCTAssertNil(turn.cacheWriteInputTokens)
    }

    func testTheSurfaceComesFromTheRoot() throws {
        for surface in [ToolSurface.cli, .desktop] {
            XCTAssertEqual(KimiWireParser.parse(simpleTurn(), surface: surface).metrics.first?.surface, surface)
        }
    }

    // MARK: Speed bounds

    func testResponseRulesAreTheStandardOnes() throws {
        // 199 tokens: not a response. 200 tokens over 600 s: kept. Over 600 s: not. Over 2,000 tok/s: not.
        func responseCount(output: Int, seconds: Double) -> Int? {
            var lines = [KimiLog.prompt(at: 0)]
            lines += KimiLog.step("0", 1, begin: 1, end: 1 + seconds + 0.001, finish: "end_turn", output: output)
            return KimiWireParser.parse(lines).responses.count
        }
        XCTAssertEqual(responseCount(output: 199, seconds: 10), 0)
        XCTAssertEqual(responseCount(output: 200, seconds: 10), 1)
        XCTAssertEqual(responseCount(output: 200, seconds: 600), 1)
        XCTAssertEqual(responseCount(output: 200, seconds: 601), 0)
        XCTAssertEqual(responseCount(output: 4_000, seconds: 2), 1, "exactly 2,000 tok/s")
        XCTAssertEqual(responseCount(output: 4_001, seconds: 2), 0)
    }

    func testAFastResponseIsNotCountedButItsPlausibleTurnIsKept() throws {
        // 3,000 tokens in one second is over the response bound; the turn (2.001 s from its prompt) is not.
        var lines = [KimiLog.prompt(at: 0)]
        lines += KimiLog.step("0", 1, begin: 1, end: 2.001, finish: "end_turn", output: 3_000)
        let result = KimiWireParser.parse(lines)
        XCTAssertTrue(result.responses.isEmpty)
        let turn = try XCTUnwrap(result.metrics.first)
        XCTAssertNil(turn.responseCount)
        XCTAssertNil(turn.responseOutputTokens)
        XCTAssertNil(turn.responseDurationSeconds)
    }

    func testATurnOverTheThroughputBoundIsNotEmitted() {
        // 30,000 tokens in the 11 s from the prompt to the end of the step: about 2,727 tok/s.
        var lines = [KimiLog.prompt(at: 0)]
        lines += KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn", output: 30_000)
        XCTAssertTrue(KimiWireParser.parse(lines).metrics.isEmpty)
        var allowed = [KimiLog.prompt(at: 0)]
        allowed += KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn", output: 22_000)
        XCTAssertEqual(KimiWireParser.parse(allowed).metrics.count, 1, "exactly 2,000 tok/s")
    }

    func testATurnWhoseEndIsNotAfterItsPromptIsNotEmitted() {
        var lines = [KimiLog.prompt(at: 10)]
        lines += KimiLog.step("0", 1, begin: 1, end: 10, finish: "end_turn")
        XCTAssertTrue(KimiWireParser.parse(lines).metrics.isEmpty)
    }

    func testTheTurnsResponseTotalsSumOnlyQualifyingSteps() throws {
        var lines = [KimiLog.prompt(at: 0)]
        lines += KimiLog.step("0", 1, begin: 1, end: 11, output: 300)
        lines += KimiLog.step("0", 2, begin: 12, end: 22, output: 100)
        lines += KimiLog.step("0", 3, begin: 23, end: 43, finish: "end_turn", output: 600)
        let turn = try XCTUnwrap(KimiWireParser.parse(lines).metrics.first)
        XCTAssertEqual(turn.outputTokens, 1_000)
        XCTAssertEqual(turn.responseOutputTokens, 900)
        XCTAssertEqual(turn.responseCount, 2)
        XCTAssertEqual(try XCTUnwrap(turn.responseDurationSeconds), 9.999 + 19.999, accuracy: 0.000_001)
        XCTAssertTrue(turn.hasPlausibleResponseTiming)
    }

    // MARK: Records

    func testRecordsWithoutAFiniteIntegerTimeAreIgnored() throws {
        let end = try XCTUnwrap(JSONSerialization.jsonObject(with: KimiLog.end("0", 1, at: 11, finish: "end_turn")) as? [String: Any])
        let leading = [KimiLog.prompt(at: 0)] + KimiLog.step("0", 1, begin: 1, end: 11, finish: "end_turn").dropLast()
        XCTAssertEqual(KimiWireParser.parse(leading + [KimiLog.line(end)]).metrics.count, 1, "the intact record counts")
        for broken: Any? in [nil, "11", 1.5, true, -5, 1e30] {
            var copy = end
            copy["time"] = broken
            XCTAssertTrue(KimiWireParser.parse(leading + [KimiLog.line(copy)]).metrics.isEmpty, "\(String(describing: broken))")
        }
    }

    func testMalformedLinesAndUnrelatedRecordsAreSkipped() {
        let noise: [Data] = [
            Data("not json".utf8),
            Data("[1,2]".utf8),
            Data("{\"type\":5,\"time\":1}".utf8),
            KimiLog.line(["type": "metadata", "protocol_version": "1.4", "created_at": 1]),
            KimiLog.line(["type": "context.append_loop_event", "time": KimiLog.milliseconds(0.5), "event": ["type": "step.begin"]]),
            KimiLog.line(["type": "context.append_loop_event", "time": KimiLog.milliseconds(0.5), "event": ["type": "step.begin", "turnId": "0", "step": 0]]),
            KimiLog.line(["type": "context.append_loop_event", "time": KimiLog.milliseconds(0.5), "event": ["type": "content.part", "turnId": "0", "step": 1]]),
            KimiLog.line(["type": "usage.record", "time": KimiLog.milliseconds(0.5), "usage": ["output": 99_999]])
        ]
        XCTAssertEqual(KimiWireParser.parse(noise + simpleTurn()[...1] + noise + simpleTurn().dropFirst(2)).metrics.count, 1)
    }

    func testNoPromptTextOrIdentifierReachesTheRecord() throws {
        let secretPath = "/tmp/kimi/sessions/wd_secret/conv-SECRETSESSION/agents/main/wire.jsonl"
        var lines = [KimiLog.line(["type": "turn.prompt", "time": KimiLog.milliseconds(0), "origin": ["kind": "user"], "text": "SECRETPROMPT"])]
        lines += KimiLog.step("SECRETTURN", 1, begin: 1, end: 11, finish: "end_turn")
        let result = KimiWireParser.parse(lines, path: secretPath)
        let turn = try XCTUnwrap(result.metrics.first)
        let encoded = String(decoding: try JSONEncoder().encode(turn), as: UTF8.self)
        for secret in ["SECRET", "wd_secret", "conv-"] { XCTAssertFalse(encoded.contains(secret), secret) }
        for response in result.responses {
            XCTAssertFalse(String(describing: response).contains("SECRET"))
        }
    }

    func testResetDropsTheTurnAndThePromptAndTakesTheNewFilesIdentity() throws {
        var parser = KimiWireParser(sourceIdentity: KimiLog.mainPath, scope: .main, surface: .cli)
        let lines = simpleTurn()
        for line in lines.dropLast() { XCTAssertNil(parser.consume(line: line)) }
        parser.reset(sourceIdentity: "/tmp/kimi/sessions/wd_x/conv-2/agents/main/wire.jsonl")
        XCTAssertNil(parser.consume(line: try XCTUnwrap(lines.last)), "the step it ends was dropped")
        _ = parser.drainCompletedResponses()
        var emitted: TurnMetric?
        for line in simpleTurn() { emitted = parser.consume(line: line) ?? emitted }
        XCTAssertEqual(emitted?.id, digest("kimi-code|conv-2|0|\(KimiLog.milliseconds(0))"))
    }

    // MARK: Subagent scope

    func testASubagentTurnIsOneWorkItemAndProducesNoMetricOrResponse() throws {
        var lines = [KimiLog.prompt(at: 5, origin: ["kind": "system"])]
        lines += KimiLog.step("0", 1, begin: 6, end: 16, output: 300)
        lines += KimiLog.step("0", 2, begin: 17, end: 27, finish: "end_turn", output: 450)
        let result = KimiWireParser.parse(lines, scope: .subagent, path: KimiLog.subagentPath)
        XCTAssertTrue(result.metrics.isEmpty)
        XCTAssertTrue(result.responses.isEmpty)
        let root = DelegationRoot.key(client: "kimi-code", rawSessionID: "conv-1")
        XCTAssertEqual(result.events.count, 2)
        guard case .workStarted(let startedID, let startedRoot, let startedAt) = result.events[0],
              case .workFinished(let finishedID, let tokens, let finishedAt) = result.events[1] else {
            return XCTFail("\(result.events)")
        }
        XCTAssertEqual(startedID, finishedID)
        XCTAssertEqual(startedRoot, root)
        XCTAssertEqual(startedAt, KimiLog.date(5), "the prompt's time, whatever its origin")
        XCTAssertEqual(tokens, 750)
        XCTAssertEqual(finishedAt, KimiLog.date(27))
    }

    func testSubagentWorkIsKeyedByAgentSoSiblingsAndMainTurnsNeverCollide() {
        let lines = simpleTurn()
        func startedID(_ path: String, scope: KimiWireParser.Scope) -> String? {
            for case .workStarted(let id, _, _) in KimiWireParser.parse(lines, scope: scope, path: path).events { return id }
            return nil
        }
        let first = startedID(KimiLog.subagentPath, scope: .subagent)
        let second = startedID("/tmp/kimi/sessions/wd_x/conv-1/agents/sub-2/wire.jsonl", scope: .subagent)
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
        let mainID = KimiWireParser.parse(lines).metrics.first?.id
        XCTAssertNotEqual(first, mainID)
    }

    func testSubagentTurnsFollowTheTurnRulesAndReportDiscards() {
        func events(_ lines: [Data], midFile: Bool = false) -> [DelegationEvent] {
            KimiWireParser.parse(lines, scope: .subagent, path: KimiLog.subagentPath, startedMidFile: midFile).events
        }
        func summary(_ events: [DelegationEvent]) -> [String] {
            events.map {
                switch $0 {
                case .workStarted: "started"
                case .workFinished: "finished"
                case .workDiscarded: "discarded"
                case .primaryTurn: "primary"
                }
            }
        }
        // A failed step.
        var failed = [KimiLog.prompt(at: 0)] + KimiLog.step("0", 1, begin: 1, end: 11, finish: "error")
        XCTAssertEqual(summary(events(failed)), ["started", "discarded"])
        // An abandoned step when another turn begins, then a good turn.
        failed = [KimiLog.prompt(at: 0), KimiLog.begin("0", 1, at: 1), KimiLog.request("0", 1, at: 1.001)] + simpleTurn(turn: "1", at: 20)
        XCTAssertEqual(summary(events(failed)), ["started", "discarded", "started", "finished"])
        // A turn that ends in failure records.
        for record in [KimiLog.turnEnded(0, reason: "failed", at: 12), KimiLog.agentTurnEnded(0, outcome: "aborted", at: 12), KimiLog.promptAborted(at: 12)] {
            let lines = [KimiLog.prompt(at: 0)] + KimiLog.step("0", 1, begin: 1, end: 11, finish: "tool_use") + [record]
            XCTAssertEqual(summary(events(lines)), ["started", "discarded"])
        }
        // A later step of a finished work item changes nothing.
        XCTAssertEqual(summary(events(simpleTurn() + KimiLog.step("0", 2, begin: 12, end: 22, finish: "error"))), ["started", "finished"])
        // A turn that never completed.
        let open = [KimiLog.prompt(at: 0)] + KimiLog.step("0", 1, begin: 1, end: 11, finish: "tool_use")
        XCTAssertEqual(summary(events(open)), ["started"])
        // A reader that joined mid-turn measures nothing.
        XCTAssertEqual(summary(events(KimiLog.step("0", 3, begin: 1, end: 11, finish: "end_turn"), midFile: true)), [])
        // Records without a request cannot be measured.
        let unrequested = [KimiLog.prompt(at: 0), KimiLog.begin("0", 1, at: 1), KimiLog.end("0", 1, at: 11, finish: "end_turn")]
        XCTAssertEqual(summary(events(unrequested)), ["started", "discarded"])
    }

    func testMainScopeReportsOnlyThePrimaryTurnToTheAttribution() {
        let events = KimiWireParser.parse(simpleTurn() + simpleTurn(turn: "1", at: 20)).events
        XCTAssertEqual(events.count, 2)
        for event in events {
            guard case .primaryTurn = event else { return XCTFail("\(event)") }
        }
    }
}
