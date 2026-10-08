import CryptoKit
import Foundation
import XCTest
@testable import TokrateCore

final class OpenCodeMonitorTests: XCTestCase {
    private var root: URL!
    private var bumps = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tokrate-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private typealias Message = SyntheticOpenCodeMessage

    /// Ten thousand seconds after the data starts: inside the retention window, beyond the 30-minute
    /// delegation wait only when a test asks for it.
    private var now: Date { at(10_000) }
    private func at(_ offset: Double) -> Date { SyntheticOpenCodeDatabase.date(offset) }

    private func makeDatabase(writeAheadLog: Bool = false, in folder: URL? = nil) throws -> SyntheticOpenCodeDatabase {
        try SyntheticOpenCodeDatabase(url: OpenCodeMonitor.databaseURL(root: folder ?? root), writeAheadLog: writeAheadLog)
    }

    private func monitor(liveSince: Date = .distantFuture) -> OpenCodeMonitor { OpenCodeMonitor(root: root, liveSince: liveSince) }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func bump(_ database: SyntheticOpenCodeDatabase) throws {
        bumps += 1
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(Double(bumps))], ofItemAtPath: database.url.path)
    }

    private func assistant(
        _ id: String, session: String = "ses1", parent: String = "msg_u1", created: Double, completed: Double?,
        output: Int? = 300, reasoning: Int? = 0, input: Int? = 1_000, cacheRead: Int? = 600, cacheWrite: Int? = 0,
        finish: String? = "stop", model: String? = "claude-sonnet-4-5", provider: String? = "anthropic", variant: String? = nil,
        errorName: String? = nil, updated: Double? = nil
    ) -> Message {
        Message(
            id: id, session: session, parentID: parent, created: created, completed: completed, updated: updated, output: output, reasoning: reasoning,
            input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, model: model, provider: provider, finish: finish,
            errorName: errorName, variant: variant
        )
    }

    /// A user prompt with two steps: a tool call, then the final answer.
    private func addStandardTurn(_ database: SyntheticOpenCodeDatabase, session: String = "ses1", user: String = "msg_u1", start: Double = 0, version: String = "1.18.31") throws {
        try database.addSession(session, version: version)
        try database.user(user, session: session, at: start)
        try database.put(assistant("\(user)_a1", session: session, parent: user, created: start + 1, completed: start + 11, output: 400, reasoning: 100, input: 1_000, cacheRead: 600, cacheWrite: 50, finish: "tool-calls", variant: "high"))
        try database.put(assistant("\(user)_a2", session: session, parent: user, created: start + 12, completed: start + 20, output: 200, reasoning: 50, input: 1_500, cacheRead: 1_200, cacheWrite: 10, finish: "stop", variant: "high"))
    }

    private func onlyMetric(_ update: MonitorUpdate, file: StaticString = #filePath, line: UInt = #line) throws -> TurnMetric {
        XCTAssertEqual(update.metrics.count, 1, file: file, line: line)
        return try XCTUnwrap(update.metrics.first, file: file, line: line)
    }

    // MARK: Turns

    func testCompleteMultiStepTurnProducesTheContractedRecord() async throws {
        let database = try makeDatabase()
        try addStandardTurn(database)
        let update = await monitor().poll(now: now)
        let metric = try onlyMetric(update)

        XCTAssertEqual(metric.id, digest("opencode|ses1|msg_u1"))
        XCTAssertEqual(metric.client, "opencode")
        XCTAssertEqual(metric.parserVersion, "opencode-db-v1")
        XCTAssertEqual(metric.metricVersion, "opencode-observed-turn-v1")
        XCTAssertEqual(metric.sourceKind, "primary")
        XCTAssertEqual(metric.clientVersion, "1.18.31")
        XCTAssertEqual(metric.model, "claude-sonnet-4-5")
        XCTAssertEqual(metric.provider, "anthropic")
        XCTAssertEqual(metric.reasoningEffort, "high")
        XCTAssertNil(metric.surface)
        XCTAssertNil(metric.codexTTFTSeconds)
        XCTAssertNil(metric.providerRegion)
        XCTAssertEqual(metric.outputTokens, 750, "output plus reasoning")
        XCTAssertEqual(metric.reasoningOutputTokens, 150)
        XCTAssertEqual(metric.durationSeconds, 20, accuracy: 0.000_001)
        XCTAssertEqual(metric.completedAt, at(20))
        XCTAssertEqual(metric.turnThroughputTPS, 37.5, accuracy: 0.000_001)
        XCTAssertEqual(metric.responseCount, 2)
        XCTAssertEqual(metric.responseOutputTokens, 750)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 18, accuracy: 0.000_001)
        XCTAssertEqual(metric.delegatedOutputTokens, 0)
        XCTAssertEqual(metric.inputTokens, (1_000 + 600 + 50) + (1_500 + 1_200 + 10))
        XCTAssertEqual(metric.cacheReadInputTokens, 1_800)
        XCTAssertEqual(metric.cacheWriteInputTokens, 60, "Anthropic reports cache writes")
        XCTAssertTrue(metric.isSupportedSourceTuple)
        XCTAssertEqual(metric.throughputLabel, "Turn speed")
        XCTAssertEqual(metric.throughputExplanation, "Prompt through final answer, including tools & waiting")
        XCTAssertTrue(update.responses.isEmpty, "history is not live")
    }

    func testATurnEndingInToolCallsIsEmittedOnceItCompletesWithStop() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, finish: "tool-calls"))
        let monitor = monitor()
        let first = await monitor.poll(now: now)
        XCTAssertTrue(first.metrics.isEmpty, "more steps follow a tool call")

        // The next step is still running.
        try database.put(assistant("msg_a2", created: 12, completed: nil, output: 0, finish: nil))
        try bump(database)
        let running = await monitor.poll(now: now)
        XCTAssertTrue(running.metrics.isEmpty)

        try database.put(assistant("msg_a2", created: 12, completed: 20, output: 300, finish: "stop"))
        try bump(database)
        let finished = await monitor.poll(now: now)
        XCTAssertEqual(finished.metrics.count, 1)
        XCTAssertEqual(finished.metrics.first?.outputTokens, 700)

        try bump(database)
        let again = await monitor.poll(now: now)
        XCTAssertTrue(again.metrics.isEmpty, "emitted once")
    }

    func testTerminalFinishValues() async throws {
        let cases: [(finish: String?, emitted: Bool)] = [
            ("stop", true), ("length", true), ("content-filter", true), ("other", true),
            ("tool-calls", false), ("unknown", false), (nil, false)
        ]
        for (index, entry) in cases.enumerated() {
            let folder = root.appendingPathComponent("finish-\(index)", isDirectory: true)
            let database = try makeDatabase(in: folder)
            try database.addSession("ses1")
            try database.user("msg_u1", session: "ses1", at: 0)
            try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, finish: entry.finish))
            let update = await OpenCodeMonitor(root: folder).poll(now: now)
            XCTAssertEqual(update.metrics.count, entry.emitted ? 1 : 0, entry.finish ?? "no finish")
        }
    }

    func testAnInterruptedTurnIsNeverEmitted() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, finish: "tool-calls"))
        // OpenCode leaves an empty, finish-less message with a completion time and no tokens.
        try database.put(assistant("msg_a2", created: 12, completed: 13, output: 0, reasoning: 0, input: 0, cacheRead: 0, finish: nil))
        let monitor = monitor()
        for offset in [0.0, 100, 3_000] {
            let update = await monitor.poll(now: at(1_000 + offset))
            XCTAssertTrue(update.metrics.isEmpty)
            try bump(database)
        }
    }

    func testAFailedMessageMeansNoTurn() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, finish: "tool-calls"))
        try database.put(assistant("msg_a2", created: 12, completed: 20, output: 300, finish: "stop", errorName: "MessageAbortedError"))
        // A second, clean prompt in the same session still counts.
        try database.user("msg_u2", session: "ses1", at: 30)
        try database.put(assistant("msg_b1", parent: "msg_u2", created: 31, completed: 41, output: 400, finish: "stop"))
        let metric = try onlyMetric(await monitor().poll(now: now))
        XCTAssertEqual(metric.id, digest("opencode|ses1|msg_u2"))
    }

    func testTurnWithoutAssistantMessagesOrWithABadDurationIsSkipped() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.user("msg_u2", session: "ses1", at: 100)
        // Completed before the prompt was written: no positive duration.
        try database.put(assistant("msg_b1", parent: "msg_u2", created: 90, completed: 95, output: 400, finish: "stop"))
        // 5,000 tokens in two seconds: above the throughput bound.
        try database.user("msg_u3", session: "ses1", at: 200)
        try database.put(assistant("msg_c1", parent: "msg_u3", created: 200.5, completed: 202, output: 5_000, finish: "stop"))
        let update = await monitor(liveSince: .distantPast).poll(now: now)
        XCTAssertTrue(update.metrics.isEmpty)
        // A live response is one message: the 400-token step qualifies even though its turn is unusable,
        // and the 3,333 tok/s one is above the bound.
        XCTAssertEqual(update.responses.map(\.outputTokens), [400])
    }

    func testMixedModelsProvidersAndEffortsAreUnknown() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, finish: "tool-calls", model: "claude-sonnet-4-5", provider: "anthropic", variant: "high"))
        try database.put(assistant("msg_a2", created: 12, completed: 20, output: 300, finish: "stop", model: "gpt-5", provider: "openai", variant: "low"))
        let metric = try onlyMetric(await monitor().poll(now: now))
        XCTAssertNil(metric.model)
        XCTAssertEqual(metric.provider, "unknown")
        XCTAssertNil(metric.reasoningEffort)
        XCTAssertNil(metric.cacheWriteInputTokens, "no common Anthropic provider")
    }

    func testEffortComesFromTheSharedVariantNamesOnly() async throws {
        let cases: [(variant: String?, effort: String?)] = [("high", "high"), ("xhigh", "xhigh"), ("max", "max"), ("minimal", "minimal"), ("fast", nil), ("HIGH", nil), (nil, nil)]
        for (index, entry) in cases.enumerated() {
            let folder = root.appendingPathComponent("effort-\(index)", isDirectory: true)
            let database = try makeDatabase(in: folder)
            try database.addSession("ses1")
            try database.user("msg_u1", session: "ses1", at: 0)
            try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, variant: entry.variant))
            let metric = try onlyMetric(await OpenCodeMonitor(root: folder).poll(now: now))
            XCTAssertEqual(metric.reasoningEffort, entry.effort, entry.variant ?? "none")
        }
    }

    // MARK: Provider mapping and sharing

    func testProviderMappingKeepsRawSanitizedIdsLocally() async throws {
        let cases: [(raw: String?, mapped: String)] = [
            ("anthropic", "anthropic"), ("openai", "openai"), ("google", "google"), ("xai", "xai"),
            ("openrouter", "openrouter"), ("kimi-for-coding", "kimi-for-coding"), ("opencode", "opencode"),
            ("amazon-bedrock", "amazon-bedrock"), ("google-vertex", "google-vertex"), ("myomlx", "myomlx"),
            ("Weird Provider!", "unknown"), ("UPPER", "unknown"), ("-leading", "unknown"),
            (String(repeating: "a", count: 41), "unknown"), (String(repeating: "a", count: 40), String(repeating: "a", count: 40)),
            (nil, "unknown")
        ]
        for (index, entry) in cases.enumerated() {
            let folder = root.appendingPathComponent("provider-\(index)", isDirectory: true)
            let database = try makeDatabase(in: folder)
            try database.addSession("ses1")
            try database.user("msg_u1", session: "ses1", at: 0)
            try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, provider: entry.raw))
            let metric = try onlyMetric(await OpenCodeMonitor(root: folder).poll(now: now))
            XCTAssertEqual(metric.provider, entry.mapped, entry.raw ?? "missing")
        }
    }

    func testOnlyShareableProvidersAreSharedAndModelPathsStayLocal() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, model: "moonshotai/kimi-k2.5", provider: "openrouter"))
        try database.addSession("ses2")
        try database.user("msg_u2", session: "ses2", at: 0)
        try database.put(assistant("msg_b1", session: "ses2", parent: "msg_u2", created: 1, completed: 11, output: 400, model: "claude-sonnet-4-5", provider: "anthropic"))
        try database.addSession("ses3")
        try database.user("msg_u3", session: "ses3", at: 0)
        try database.put(assistant("msg_c1", session: "ses3", parent: "msg_u3", created: 1, completed: 11, output: 400, model: "gemini-3.8-flash", provider: "google"))
        try database.addSession("ses4")
        try database.user("msg_u4", session: "ses4", at: 0)
        try database.put(assistant("msg_d1", session: "ses4", parent: "msg_u4", created: 1, completed: 11, output: 400, model: nil, provider: nil))

        let update = await monitor().poll(now: now)
        XCTAssertEqual(update.metrics.count, 4)
        let byProvider = Dictionary(uniqueKeysWithValues: update.metrics.map { ($0.provider ?? "-", $0) })
        let gateway = try XCTUnwrap(byProvider["openrouter"])
        XCTAssertEqual(gateway.model, "moonshotai/kimi-k2.5", "the local record keeps the vendor path")
        XCTAssertNil(SharedSample(gateway), "a gateway provider is never shared")
        let anthropic = try XCTUnwrap(SharedSample(try XCTUnwrap(byProvider["anthropic"])))
        XCTAssertNotNil(SharedSample(try XCTUnwrap(byProvider["google"])))
        XCTAssertNotNil(SharedSample(try XCTUnwrap(byProvider["unknown"])), "unknown is shareable")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(anthropic)) as? [String: Any])
        XCTAssertEqual(json["client"] as? String, "opencode")
        XCTAssertEqual(json["provider"] as? String, "anthropic")
        XCTAssertEqual(json["parserVersion"] as? String, "opencode-db-v1")
        XCTAssertEqual(json["metricVersion"] as? String, "opencode-observed-turn-v1")
        XCTAssertEqual(json["clientVersion"] as? String, "1.18.31")
        XCTAssertEqual(json["appVersion"] as? String, "0.1.19")
        XCTAssertTrue(json["surface"] is NSNull)
        XCTAssertEqual(json["cacheWriteInputTokens"] as? Int, 0)
        XCTAssertEqual(json["inputTokens"] as? Int, 1_600)
        for provider in ["anthropic", "openai", "google", "xai", "unknown"] {
            XCTAssertTrue(SharedSample.isAllowedProvider(provider, client: "opencode"), provider)
        }
        for provider in ["openrouter", "opencode", "amazon-bedrock", "google-vertex", "kimi-for-coding"] {
            XCTAssertFalse(SharedSample.isAllowedProvider(provider, client: "opencode"), provider)
        }
        XCTAssertTrue(SharedSample.isAllowedProvider("google", client: "antigravity"))
        XCTAssertFalse(SharedSample.isAllowedProvider("google", client: "codex"))
        XCTAssertTrue(TurnMetric.isSupportedSourceTuple(client: "opencode", parserVersion: "opencode-db-v1", metricVersion: "opencode-observed-turn-v1"))
        XCTAssertFalse(TurnMetric.isSupportedSourceTuple(client: "opencode", parserVersion: "opencode-db-v2", metricVersion: "opencode-observed-turn-v1"))
    }

    // MARK: Version floor

    func testOnlySessionsAtOrAboveVersion114AreMeasured() async throws {
        let database = try makeDatabase()
        let versions: [(String, Bool)] = [
            ("1.14.21", true), ("1.14", true), ("1.14.0", true), ("1.18.31", true), ("1.100.0", true), ("2.0.1", true),
            ("1.13.9", false), ("1.2.27", false), ("1.0.126", false), ("0.99.0", false),
            ("1.14.21-beta.1", false), ("v1.14.21", false), ("1", false), ("", false), ("1.14.x", false), ("1.14.2.1", false)
        ]
        for (index, entry) in versions.enumerated() {
            try addStandardTurn(database, session: "ses\(index)", user: "msg_u\(index)", version: entry.0)
        }
        let update = await monitor(liveSince: .distantPast).poll(now: now)
        let expected = Set(versions.enumerated().filter { $0.element.1 }.map { digest("opencode|ses\($0.offset)|msg_u\($0.offset)") })
        XCTAssertEqual(Set(update.metrics.map(\.id)), expected)
        let liveSessions = Set(update.responses.compactMap { $0.outputTokens })
        XCTAssertFalse(liveSessions.isEmpty)
        XCTAssertEqual(update.responses.count, 2 * expected.count, "no live responses from older versions either")
    }

    // MARK: Delegated output

    func testSubagentSessionsProduceNoTurnsAndTheirOutputIsDelegatedOnceFinished() async throws {
        let database = try makeDatabase()
        try addStandardTurn(database)                       // T: 0 ... 20 s
        try database.addSession("sub1", parent: "ses1")
        try database.user("msg_su", session: "sub1", at: 3)
        // A subagent step that started inside the turn and is still running.
        try database.put(assistant("msg_s1", session: "sub1", parent: "msg_su", created: 5, completed: nil, output: 0, finish: nil))
        let monitor = monitor(liveSince: .distantPast)
        let first = await monitor.poll(now: at(60))
        let pending = try onlyMetric(first)
        XCTAssertEqual(pending.id, digest("opencode|ses1|msg_u1"))
        XCTAssertNil(pending.delegatedOutputTokens, "not final while subagent work runs")
        XCTAssertFalse(pending.isDelegationFinal)
        XCTAssertNil(SharedSample(pending))
        XCTAssertEqual(first.responses.map(\.outputTokens), [250, 500], "newest first; only the primary session's responses are live")
        let deadline = await monitor.nextPollDeadline(now: at(60))
        XCTAssertEqual(deadline, at(20 + 1_800), "the turn stops waiting 30 minutes after it ended")

        // The subagent finishes, a grandchild session ran too, and some messages are outside the window.
        try database.put(assistant("msg_s1", session: "sub1", parent: "msg_su", created: 5, completed: 15, output: 600, reasoning: 100, finish: "stop"))
        try database.put(assistant("msg_s2", session: "sub1", parent: "msg_su", created: 8, completed: 12, output: 50, finish: "stop"))
        try database.addSession("sub2", parent: "sub1")
        try database.put(assistant("msg_s3", session: "sub2", parent: "msg_x", created: 10, completed: 12, output: 5, finish: "stop"))
        try database.put(assistant("msg_s4", session: "sub1", parent: "msg_su", created: 21, completed: 25, output: 1_000, finish: "stop"))
        try database.put(assistant("msg_s5", session: "sub1", parent: "msg_su", created: -1, completed: -0.5, output: 2_000, finish: "stop"))
        try bump(database)
        let second = await monitor.poll(now: at(61))
        let final = try onlyMetric(second)
        XCTAssertEqual(final.id, pending.id, "the same id is emitted again")
        XCTAssertEqual(final.delegatedOutputTokens, 700 + 50 + 5)
        XCTAssertEqual(final.outputTokens, 750, "delegated output is not added to the turn's own tokens")
        XCTAssertTrue(final.isDelegationFinal)
        XCTAssertNotNil(SharedSample(final))
        XCTAssertTrue(second.responses.isEmpty, "subagent responses never reach the live stream")

        try bump(database)
        let third = await monitor.poll(now: at(62))
        XCTAssertTrue(third.metrics.isEmpty)
        let idle = await monitor.nextPollDeadline(now: at(62))
        XCTAssertNil(idle)
    }

    func testUnfinishedSubagentMessagesAreIgnoredThirtyMinutesAfterTheTurn() async throws {
        let database = try makeDatabase()
        try addStandardTurn(database)
        try database.addSession("sub1", parent: "ses1")
        try database.put(assistant("msg_s1", session: "sub1", parent: "msg_su", created: 4, completed: 10, output: 300, finish: "stop"))
        try database.put(assistant("msg_s2", session: "sub1", parent: "msg_su", created: 6, completed: nil, output: 9_999, finish: nil))
        let monitor = monitor()
        let first = await monitor.poll(now: at(100))
        XCTAssertNil(try onlyMetric(first).delegatedOutputTokens)

        // Nothing changed on disk, but the wait is over.
        let early = await monitor.poll(now: at(20 + 1_799))
        XCTAssertTrue(early.metrics.isEmpty)
        let late = await monitor.poll(now: at(20 + 1_801))
        let settled = try onlyMetric(late)
        XCTAssertEqual(settled.delegatedOutputTokens, 300, "the unfinished message is ignored")
        let after = await monitor.poll(now: at(20 + 1_900))
        XCTAssertTrue(after.metrics.isEmpty)

        // History replay of an old turn settles at once.
        let replay = await OpenCodeMonitor(root: root).poll(now: at(20 + 3_600))
        XCTAssertEqual(try onlyMetric(replay).delegatedOutputTokens, 300)
    }

    func testFailedSubagentMessagesCountWithTheirRecordedTokens() async throws {
        let database = try makeDatabase()
        try addStandardTurn(database)
        try database.addSession("sub1", parent: "ses1")
        try database.put(assistant("msg_s1", session: "sub1", parent: "msg_su", created: 4, completed: 10, output: 40, finish: nil, errorName: "MessageAbortedError"))
        let metric = try onlyMetric(await monitor().poll(now: at(100)))
        XCTAssertEqual(metric.delegatedOutputTokens, 40)
    }

    // MARK: Incremental reads

    func testALaterUpdatedMessageIsMergedAndNothingIsEmittedTwice() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: nil, output: 0, input: nil, cacheRead: nil, cacheWrite: nil, finish: nil))
        let monitor = monitor()
        let first = await monitor.poll(now: now)
        XCTAssertTrue(first.metrics.isEmpty)
        var reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 1)

        _ = await monitor.poll(now: now)
        reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 1, "an unchanged database is not opened")

        // The same message row, updated: tokens and completion arrive.
        try database.put(assistant("msg_a1", created: 1, completed: 12, output: 400, finish: "stop"))
        try bump(database)
        let second = await monitor.poll(now: now)
        XCTAssertEqual(try onlyMetric(second).outputTokens, 400)
        reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 2)

        // A later change to another message does not repeat the turn.
        try database.user("msg_u2", session: "ses1", at: 50)
        try bump(database)
        let third = await monitor.poll(now: now)
        XCTAssertTrue(third.metrics.isEmpty)
        // And a new session appearing mid-way is fetched when a message names it.
        try database.addSession("ses2")
        try database.user("msg_u9", session: "ses2", at: 60)
        try database.put(assistant("msg_n1", session: "ses2", parent: "msg_u9", created: 61, completed: 71, output: 400, finish: "stop"))
        try bump(database)
        let fourth = await monitor.poll(now: now)
        XCTAssertEqual(try onlyMetric(fourth).id, digest("opencode|ses2|msg_u9"))
    }

    func testTheWatermarkOverlapReadsMessagesUpdatedJustBeforeIt() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, finish: "tool-calls", updated: 100))
        let monitor = monitor()
        _ = await monitor.poll(now: now)
        // Written with an update time one second behind the watermark (commit order is not time order).
        try database.put(assistant("msg_a2", created: 12, completed: 20, output: 300, finish: "stop", updated: 99))
        try bump(database)
        let update = await monitor.poll(now: now)
        XCTAssertEqual(try onlyMetric(update).outputTokens, 700)
    }

    func testAFullRereadEveryFiveMinutesDropsMessagesOpenCodeDeleted() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, finish: "stop"))
        // A later step that never finished and is then reverted (deleted).
        try database.put(assistant("msg_a2", created: 12, completed: nil, output: 0, finish: nil))
        let monitor = monitor()
        let start = at(500)
        _ = await monitor.poll(now: start)
        try database.deleteMessage("msg_a2")
        try bump(database)
        let incremental = await monitor.poll(now: start.addingTimeInterval(60))
        XCTAssertTrue(incremental.metrics.isEmpty, "an incremental read cannot see a deletion")
        try bump(database)
        let full = await monitor.poll(now: start.addingTimeInterval(301))
        XCTAssertEqual(try onlyMetric(full).outputTokens, 400, "the full re-read rebuilt the index")
    }

    func testBothReadsKeepOnlyTheNewestCreatedMessagesWhenThereAreMoreThanTheLimit() throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        for index in 0..<6 {
            try database.put(assistant("msg_\(index)", created: Double(index), completed: Double(index) + 1, updated: Double(100 + index)))
        }
        let reader = try OpenCodeDatabase(url: OpenCodeMonitor.databaseURL(root: root))
        defer { reader.close() }
        let since = SyntheticOpenCodeDatabase.milliseconds(0)
        XCTAssertEqual(try reader.messages(createdSince: since, limit: 3).map(\.id), ["msg_5", "msg_4", "msg_3"])
        XCTAssertEqual(try reader.messages(updatedSince: SyntheticOpenCodeDatabase.milliseconds(100), createdSince: since, limit: 3).map(\.id), ["msg_5", "msg_4", "msg_3"])
        // Updated recently but created before the window: not read, the index drops it anyway.
        XCTAssertEqual(try reader.messages(updatedSince: SyntheticOpenCodeDatabase.milliseconds(100), createdSince: SyntheticOpenCodeDatabase.milliseconds(4)).map(\.id), ["msg_5", "msg_4"])
        XCTAssertEqual(try reader.messages(updatedSince: SyntheticOpenCodeDatabase.milliseconds(104), createdSince: since).map(\.id), ["msg_5", "msg_4"])
        XCTAssertEqual(OpenCodeDatabase.maximumReadMessages, 100_000)
    }

    func testMessagesOlderThanSevenDaysAreNotIndexed() async throws {
        let database = try makeDatabase()
        try addStandardTurn(database)
        let late = at(8 * 24 * 3_600)
        let update = await monitor().poll(now: late)
        XCTAssertTrue(update.metrics.isEmpty)
        let recent = await monitor().poll(now: at(6 * 24 * 3_600))
        XCTAssertEqual(recent.metrics.count, 1)
    }

    // MARK: Prompt cache

    func testPromptCacheNullAndConsistencyRules() async throws {
        let database = try makeDatabase()
        // A step without tokens.input: all three fields are null for the turn.
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, input: nil, cacheRead: 5, finish: "tool-calls"))
        try database.put(assistant("msg_a2", created: 12, completed: 20, output: 300, finish: "stop"))
        // Without tokens.cache.read.
        try database.user("msg_u2", session: "ses1", at: 30)
        try database.put(assistant("msg_b1", parent: "msg_u2", created: 31, completed: 41, output: 400, input: 100, cacheRead: nil, finish: "stop"))
        // Absent cache.write is 0; a non-Anthropic provider never reports writes even when logged.
        try database.user("msg_u3", session: "ses1", at: 60)
        try database.put(assistant("msg_c1", parent: "msg_u3", created: 61, completed: 71, output: 400, input: 100, cacheRead: 40, cacheWrite: nil, finish: "stop"))
        try database.user("msg_u4", session: "ses1", at: 90)
        try database.put(assistant("msg_d1", parent: "msg_u4", created: 91, completed: 101, output: 400, input: 100, cacheRead: 40, cacheWrite: 7, finish: "stop", model: "gpt-5", provider: "openai"))
        // A fractional count is unusable for the cache fields (the turn itself is fine).
        try database.user("msg_u5", session: "ses1", at: 120)
        var odd = assistant("msg_e1", parent: "msg_u5", created: 121, completed: 131, output: 400, input: nil, cacheRead: 40, finish: "stop")
        odd.rawTokens = ["input": 1.5]
        try database.put(odd)

        let update = await monitor().poll(now: now)
        func metric(_ user: String) throws -> TurnMetric { try XCTUnwrap(update.metrics.first { $0.id == digest("opencode|ses1|\(user)") }, user) }
        for user in ["msg_u1", "msg_u2", "msg_u5"] {
            let value = try metric(user)
            XCTAssertNil(value.inputTokens, user)
            XCTAssertNil(value.cacheReadInputTokens, user)
            XCTAssertNil(value.cacheWriteInputTokens, user)
        }
        let absentWrite = try metric("msg_u3")
        XCTAssertEqual(absentWrite.inputTokens, 140)
        XCTAssertEqual(absentWrite.cacheReadInputTokens, 40)
        XCTAssertEqual(absentWrite.cacheWriteInputTokens, 0)
        let openAI = try metric("msg_u4")
        XCTAssertEqual(openAI.inputTokens, 147, "logged writes still belong to the input total")
        XCTAssertEqual(openAI.cacheReadInputTokens, 40)
        XCTAssertNil(openAI.cacheWriteInputTokens)
        XCTAssertEqual(update.metrics.count, 5)
    }

    // MARK: Response speed and live responses

    func testResponseQualificationBounds() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 6, output: 199, finish: "tool-calls"))                    // below 200
        try database.put(assistant("msg_a2", created: 7, completed: 607, output: 1_000, reasoning: 200, finish: "tool-calls"))   // exactly 600 s
        try database.put(assistant("msg_a3", created: 608, completed: 1_209, output: 1_200, finish: "tool-calls"))             // 601 s
        try database.put(assistant("msg_a4", created: 1_210, completed: 1_213, output: 5_000, finish: "tool-calls"))           // 1,666 tok/s
        try database.put(assistant("msg_a5", created: 1_214, completed: 1_215, output: 2_500, finish: "tool-calls"))           // above the bound
        try database.put(assistant("msg_a6", created: 1_216, completed: 1_216, output: 900, finish: "stop"))                   // zero duration
        let metric = try onlyMetric(await monitor().poll(now: now))
        XCTAssertEqual(metric.responseCount, 2)
        XCTAssertEqual(metric.responseOutputTokens, 1_200 + 5_000)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 603, accuracy: 0.000_001)
        XCTAssertEqual(metric.outputTokens, 199 + 1_200 + 1_200 + 5_000 + 2_500 + 900)
    }

    func testTurnWithNoQualifyingResponseHasNoResponseFields() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 8.2, output: 11, reasoning: 45, finish: "stop"))
        let metric = try onlyMetric(await monitor().poll(now: now))
        XCTAssertEqual(metric.outputTokens, 56)
        XCTAssertEqual(metric.reasoningOutputTokens, 45)
        XCTAssertNil(metric.responseCount)
        XCTAssertNil(metric.responseOutputTokens)
        XCTAssertNil(metric.responseDurationSeconds)
    }

    func testLiveResponsesArePublishedOnceAndOnlyForMessagesCompletedAfterTheMonitorStarted() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 1_000, finish: "tool-calls"))                       // before the start
        try database.put(assistant("msg_a2", created: 120, completed: 130, output: 2_000, finish: "tool-calls", variant: "high"))    // after
        try database.put(assistant("msg_a3", created: 131, completed: 133, output: 100, finish: "tool-calls"))                       // too short
        try database.put(assistant("msg_a4", created: 134, completed: 150, output: 900, finish: nil, errorName: "MessageAbortedError")) // failed
        try database.put(assistant("msg_a5", created: 151, completed: nil, output: 0, finish: nil))                                   // running
        let monitor = monitor(liveSince: at(100))
        let first = await monitor.poll(now: now)
        XCTAssertTrue(first.metrics.isEmpty, "the turn is still running")
        let response = try XCTUnwrap(first.responses.first)
        XCTAssertEqual(first.responses.count, 1)
        XCTAssertEqual(response.model, "claude-sonnet-4-5")
        XCTAssertEqual(response.provider, "anthropic")
        XCTAssertEqual(response.client, "opencode")
        XCTAssertEqual(response.sourceKind, "primary")
        XCTAssertEqual(response.metricVersion, "opencode-observed-turn-v1")
        XCTAssertEqual(response.reasoningEffort, "high")
        XCTAssertEqual(response.outputTokens, 2_000)
        XCTAssertEqual(response.durationSeconds, 10, accuracy: 0.000_001)
        XCTAssertEqual(response.completedAt, at(130))
        XCTAssertFalse(response.id.contains("msg_a2"))

        // The running message completes: only it is new.
        try database.put(assistant("msg_a5", created: 151, completed: 161, output: 1_500, finish: "stop"))
        try bump(database)
        let second = await monitor.poll(now: now)
        XCTAssertEqual(second.responses.map(\.outputTokens), [1_500])
        XCTAssertTrue(second.metrics.isEmpty, "the turn contains a failed message")

        try bump(database)
        let third = await monitor.poll(now: now)
        XCTAssertTrue(third.responses.isEmpty)
    }

    // MARK: Malformed data

    func testMalformedRowsAreSkippedWithoutCrashing() async throws {
        let database = try makeDatabase()
        try database.addSession("ses1")
        // A message whose JSON is invalid: skipped without failing the read.
        var corrupt = assistant("msg_corrupt", created: 1, completed: 5, output: 400)
        corrupt.rawData = "{not json"
        try database.put(corrupt)
        let invalidCounts: [(String, [String: Any])] = [
            ("fraction", ["output": 12.5]), ("negative", ["output": -4]), ("string", ["output": "400"]), ("huge", ["output": 100_000_001]),
            ("reasoning", ["output": 400, "reasoning": -1])
        ]
        for (index, entry) in invalidCounts.enumerated() {
            let user = "msg_u\(index)"
            try database.user(user, session: "ses1", at: Double(index * 100 + 100))
            var message = assistant("msg_bad\(index)", parent: user, created: Double(index * 100 + 101), completed: Double(index * 100 + 111), output: nil, reasoning: nil, finish: "stop")
            message.rawTokens = entry.1
            try database.put(message)
        }
        // A message that is not an object at all, and one with an unusable timestamp.
        var scalar = assistant("msg_scalar", created: 700, completed: 710, output: 400)
        scalar.rawData = "42"
        try database.put(scalar)
        try database.user("msg_utime", session: "ses1", at: 800)
        var badTime = assistant("msg_badtime", parent: "msg_utime", created: 801, completed: 811, output: 400, finish: "stop")
        badTime.extra = ["time": ["created": "yesterday", "completed": 1.5]]
        try database.put(badTime)
        // One valid turn survives them all.
        try database.user("msg_ok", session: "ses1", at: 900)
        try database.put(assistant("msg_okA", parent: "msg_ok", created: 901, completed: 911, output: 400, finish: "stop"))
        let update = await monitor(liveSince: .distantPast).poll(now: now)
        XCTAssertEqual(update.metrics.map(\.id), [digest("opencode|ses1|msg_ok")])
        XCTAssertEqual(update.responses.count, 1)
    }

    func testAnUnreadableDatabaseIsRetriedWithDoublingBackoffAndReportedAsPending() async throws {
        let garbage = OpenCodeMonitor.databaseURL(root: root)
        try Data("this is not an sqlite file".utf8).write(to: garbage)
        let monitor = monitor()
        let start = Date.now
        _ = await monitor.poll(now: start)
        var reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 1)
        var deadline = await monitor.nextPollDeadline(now: start.addingTimeInterval(1))
        XCTAssertEqual(deadline, start.addingTimeInterval(10))
        _ = await monitor.poll(now: start.addingTimeInterval(5))
        reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 1, "waits for the backoff")
        _ = await monitor.poll(now: start.addingTimeInterval(11))
        deadline = await monitor.nextPollDeadline(now: start.addingTimeInterval(12))
        XCTAssertEqual(deadline, start.addingTimeInterval(11 + 20))
        // The delays double up to five minutes.
        var clock = start.addingTimeInterval(31)
        for _ in 0..<8 {
            _ = await monitor.poll(now: clock)
            clock = clock.addingTimeInterval(400)
        }
        let capped = await monitor.nextPollDeadline(now: clock.addingTimeInterval(-399))
        XCTAssertEqual(capped, clock.addingTimeInterval(-400 + 300))
    }

    func testMissingDatabaseReportsUnavailableAndYieldsNothing() async {
        let monitor = monitor()
        let update = await monitor.poll(now: now)
        XCTAssertTrue(update.metrics.isEmpty)
        let status = await monitor.status()
        XCTAssertFalse(status.rootAvailable)
        let deadline = await monitor.nextPollDeadline(now: now)
        XCTAssertNil(deadline)
        XCTAssertFalse(OpenCodeMonitor.hasDatabase(root: root))
    }

    // MARK: Files and folders

    func testOnlyTheDatabaseAtTheRootIsRead() async throws {
        let nested = root.appendingPathComponent("storage", isDirectory: true)
        let other = try makeDatabase(in: nested)       // a database elsewhere in the data folder is ignored
        try addStandardTurn(other)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("snapshot"), withIntermediateDirectories: true)
        try Data("noise".utf8).write(to: root.appendingPathComponent("snapshot/x"))
        let monitor = monitor()
        let update = await monitor.poll(now: now)
        XCTAssertTrue(update.metrics.isEmpty)
        let status = await monitor.status()
        XCTAssertFalse(status.rootAvailable)

        let database = try makeDatabase()
        try addStandardTurn(database)
        let found = await monitor.poll(now: now)
        XCTAssertEqual(found.metrics.count, 1)
        let after = await monitor.status()
        XCTAssertTrue(after.rootAvailable)
        XCTAssertEqual(after.sessions, 1)
        XCTAssertTrue(OpenCodeMonitor.hasDatabase(root: root))
    }

    func testPathsWithSpacesAndURISpecialCharactersAreOpened() async throws {
        let strange = root.appendingPathComponent("My Data #1 ?100% done", isDirectory: true)
        let database = try makeDatabase(in: strange)
        try addStandardTurn(database)
        let update = await OpenCodeMonitor(root: strange).poll(now: now)
        XCTAssertEqual(update.metrics.count, 1)
    }

    func testDatabaseFilesAreNeverModified() async throws {
        for writeAheadLog in [false, true] {
            let folder = root.appendingPathComponent(writeAheadLog ? "wal" : "plain", isDirectory: true)
            let database = try makeDatabase(writeAheadLog: writeAheadLog, in: folder)
            try addStandardTurn(database)
            let before = try Data(contentsOf: database.url)
            let walURL = URL(fileURLWithPath: database.url.path + "-wal")
            let walBefore = try? Data(contentsOf: walURL)
            let modifiedBefore = try FileManager.default.attributesOfItem(atPath: database.url.path)[.modificationDate] as? Date

            let update = await OpenCodeMonitor(root: folder, liveSince: .distantPast).poll(now: now)
            XCTAssertFalse(update.metrics.isEmpty)

            XCTAssertEqual(try Data(contentsOf: database.url), before, "database bytes (wal: \(writeAheadLog))")
            XCTAssertEqual(try? Data(contentsOf: walURL), walBefore, "log bytes (wal: \(writeAheadLog))")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: database.url.path)[.modificationDate] as? Date, modifiedBefore)
        }
    }

    func testContentOnlyInTheWriteAheadLogIsReadAndLogChangesTriggerARead() async throws {
        // The writer stays open, so the newest rows live only in the -wal file.
        let database = try makeDatabase(writeAheadLog: true)
        try database.addSession("ses1")
        try database.user("msg_u1", session: "ses1", at: 0)
        try database.put(assistant("msg_a1", created: 1, completed: 11, output: 400, finish: "tool-calls"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.url.path + "-wal"))
        let monitor = monitor()
        let first = await monitor.poll(now: now)
        XCTAssertTrue(first.metrics.isEmpty)
        let walPath = database.url.path + "-wal"

        try database.put(assistant("msg_a2", created: 12, completed: 20, output: 300, finish: "stop"))
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)], ofItemAtPath: walPath)
        let update = await monitor.poll(now: now)
        XCTAssertEqual(try onlyMetric(update).outputTokens, 700, "the finishing message exists only in the write-ahead log")
    }

    func testPrivateTextOutsideTheContractedPathsNeverReachesARecord() async throws {
        let database = try makeDatabase()
        try addStandardTurn(database)
        let update = await monitor(liveSince: .distantPast).poll(now: now)
        let serialized = String(decoding: try JSONEncoder().encode(update.metrics), as: UTF8.self)
            + String(describing: update.responses)
        XCTAssertFalse(serialized.contains(SyntheticOpenCodeDatabase.privateText))
        XCTAssertFalse(serialized.contains("msg_u1"))
        XCTAssertFalse(serialized.contains("ses1"))
        XCTAssertFalse(serialized.contains(root.lastPathComponent))
    }

    // MARK: Folder watcher

    func testNoteChangesWakesOnlyForTheDatabaseAndItsLogDirectlyInTheRoot() async throws {
        let database = try makeDatabase()
        try addStandardTurn(database)
        let monitor = monitor()
        _ = await monitor.poll(now: now)
        let folder = root.standardizedFileURL.path
        let irrelevant: Set<String> = [
            "\(folder)/snapshot/abc/def", "\(folder)/tool-output/tool_1", "\(folder)/log/2026.log", "\(folder)/storage/session/x.json",
            "\(folder)/repos/r/.git/index", "\(folder)/auth.json", "\(folder)/opencode.db-shm", "\(folder)/opencode.db-journal",
            "\(folder)/storage/opencode.db", "\(folder)/other.db", "\(folder)/opencode.db.bak"
        ]
        let idleNoted = await monitor.noteChanges(SessionFolderChange(paths: irrelevant))
        XCTAssertFalse(idleNoted)
        var deadline = await monitor.nextPollDeadline(now: now)
        XCTAssertNil(deadline)

        // The files did not change: a report about them has nothing to read.
        let unchanged = await monitor.noteChanges(SessionFolderChange(paths: ["\(folder)/opencode.db", "\(folder)/opencode.db-wal"]))
        XCTAssertFalse(unchanged)

        try database.user("msg_u2", session: "ses1", at: 100)
        try database.put(assistant("msg_b1", parent: "msg_u2", created: 101, completed: 111, output: 400, finish: "stop"))
        try bump(database)
        let noted = await monitor.noteChanges(SessionFolderChange(paths: ["\(folder)/opencode.db"]))
        XCTAssertTrue(noted)
        deadline = await monitor.nextPollDeadline(now: now)
        XCTAssertEqual(deadline, now, "a changed database is waiting")
        let update = await monitor.poll(now: now)
        XCTAssertEqual(update.metrics.count, 1)
        deadline = await monitor.nextPollDeadline(now: now)
        XCTAssertNil(deadline)

        // A write-ahead-log change is reported the same way.
        try database.put(assistant("msg_b2", parent: "msg_u2", created: 112, completed: 120, output: 400, finish: "stop"))
        try bump(database)
        let walNoted = await monitor.noteChanges(SessionFolderChange(paths: ["\(folder)/opencode.db-wal"]))
        XCTAssertTrue(walNoted)

        let rescan = await monitor.noteChanges(SessionFolderChange(mustRescan: true))
        XCTAssertTrue(rescan, "a lost event is answered by a poll")
    }

    func testNextPollDeadlineIsNilWhenIdleAndNowWhenChanged() async throws {
        let database = try makeDatabase()
        try addStandardTurn(database)
        let monitor = monitor()
        let beforeAnyPoll = await monitor.nextPollDeadline(now: now)
        XCTAssertNil(beforeAnyPoll)
        _ = await monitor.poll(now: now)
        let idle = await monitor.nextPollDeadline(now: now)
        XCTAssertNil(idle)
        try bump(database)
        _ = await monitor.noteChanges(SessionFolderChange(paths: [OpenCodeMonitor.databaseURL(root: root).standardizedFileURL.path]))
        let changed = await monitor.nextPollDeadline(now: now)
        XCTAssertEqual(changed, now)
    }
}
