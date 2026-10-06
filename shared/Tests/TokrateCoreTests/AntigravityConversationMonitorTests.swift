import CryptoKit
import Foundation
import XCTest
@testable import TokrateCore

final class AntigravityConversationMonitorTests: XCTestCase {
    private var root: URL!
    private var bumps = 0
    private let conversationID = "11111111-2222-3333-4444-555555555555"
    private static let safetyNet = AntigravityConversationMonitor.discoveryInterval

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tokrate-antigravity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private struct Call {
        var created: Double
        var completed: Double
        var output: UInt64
        var thinking: UInt64 = 0
        var generation: UInt64? = 0
    }

    private func databaseURL(_ id: String? = nil, folder: String = "antigravity") -> URL {
        root.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(id ?? conversationID).db")
    }

    private func makeDatabase(_ id: String? = nil, folder: String = "antigravity", writeAheadLog: Bool = false) throws -> SyntheticAntigravityDatabase {
        try SyntheticAntigravityDatabase(url: databaseURL(id, folder: folder), writeAheadLog: writeAheadLog)
    }

    /// Adds one run: the user's step, the model calls with a tool run between them, and a final step.
    @discardableResult
    private func addRun(
        _ database: SyntheticAntigravityDatabase, execution: String = "exec-1", state: UInt64 = 4,
        variant: String? = "gemini-3.8-flash-medium", model: String? = "gemini-3.8-flash", start: Double = 0,
        calls: [Call], finalCompleted: Double? = nil
    ) throws -> Double {
        if let model { try database.addGeneration(index: 0, model: model) }
        try database.addExecutor(id: execution, state: state, variant: variant)
        try database.addStep(SyntheticStep(execution: execution, created: start, completed: start + 0.1))
        var end = start + 0.1
        for call in calls {
            try database.addStep(SyntheticStep(
                execution: execution, created: call.created, completed: call.completed, output: call.output,
                thinking: call.thinking, generation: call.generation
            ))
            end = max(end, call.completed)
        }
        let final = finalCompleted ?? end + 0.25
        try database.addStep(SyntheticStep(execution: execution, created: end, completed: final))
        return final
    }

    private let standardCalls = [
        Call(created: 1, completed: 11, output: 1_000, thinking: 300),
        Call(created: 20, completed: 25, output: 150, thinking: 50),
        Call(created: 26, completed: 31.5, output: 550, thinking: 100)
    ]

    private func monitor(liveSince: Date = .distantFuture) -> AntigravityConversationMonitor {
        AntigravityConversationMonitor(root: root, liveSince: liveSince)
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Changes the modification time so a rewrite inside the same file-system tick is still seen.
    private func bump(_ database: SyntheticAntigravityDatabase) throws {
        bumps += 1
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(Double(bumps))], ofItemAtPath: database.url.path)
    }

    /// What the folder watcher would report for a changed database.
    @discardableResult
    private func notify(_ monitor: AntigravityConversationMonitor, _ database: SyntheticAntigravityDatabase, wal: Bool = false) async -> Bool {
        await monitor.noteChanges(SessionFolderChange(paths: [database.url.standardizedFileURL.path + (wal ? "-wal" : "")]))
    }

    private func onlyMetric(_ update: MonitorUpdate, file: StaticString = #filePath, line: UInt = #line) throws -> TurnMetric {
        XCTAssertEqual(update.metrics.count, 1, file: file, line: line)
        return try XCTUnwrap(update.metrics.first, file: file, line: line)
    }

    // MARK: Finished executions

    func testFinishedExecutionProducesTheContractedTurn() async throws {
        let database = try makeDatabase()
        try addRun(database, calls: standardCalls, finalCompleted: 31.75)
        let update = await monitor().poll()
        let metric = try onlyMetric(update)

        XCTAssertEqual(metric.id, digest("antigravity|\(conversationID)|exec-1"))
        XCTAssertEqual(metric.client, "antigravity")
        XCTAssertEqual(metric.parserVersion, "antigravity-conversation-v1")
        XCTAssertEqual(metric.metricVersion, "antigravity-observed-execution-v1")
        XCTAssertEqual(metric.sourceKind, "primary")
        XCTAssertEqual(metric.model, "gemini-3.8-flash")
        XCTAssertEqual(metric.reasoningEffort, "medium")
        XCTAssertEqual(metric.provider, "google")
        XCTAssertNil(metric.clientVersion)
        XCTAssertNil(metric.codexTTFTSeconds)
        XCTAssertNil(metric.providerRegion)
        XCTAssertEqual(metric.outputTokens, 1_700)
        XCTAssertEqual(metric.reasoningOutputTokens, 450)
        XCTAssertEqual(metric.durationSeconds, 31.75, accuracy: 0.000_001)
        XCTAssertEqual(metric.turnThroughputTPS, 1_700 / 31.75, accuracy: 0.000_001)
        XCTAssertEqual(metric.completedAt.timeIntervalSince1970, SyntheticTime(31.75).date.timeIntervalSince1970, accuracy: 0.000_001)
        // The 150-token call is below the 200-token floor.
        XCTAssertEqual(metric.responseCount, 2)
        XCTAssertEqual(metric.responseOutputTokens, 1_550)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 15.5, accuracy: 0.000_001)
        XCTAssertEqual(metric.delegatedOutputTokens, 0)
        XCTAssertTrue(metric.isSupportedSourceTuple)
        XCTAssertEqual(metric.throughputLabel, "Turn speed")
        XCTAssertEqual(metric.throughputExplanation, "Prompt through final answer of one agent run, including tools & waiting")
        XCTAssertTrue(metric.hasPlausibleResponseTiming)
        XCTAssertTrue(update.responses.isEmpty, "history is not live")
    }

    func testStepsOfOtherExecutionsAndOfNoExecutionDoNotCount() async throws {
        let database = try makeDatabase()
        try addRun(database, execution: "exec-1", calls: [Call(created: 1, completed: 11, output: 1_000)], finalCompleted: 12)
        try addRun(database, execution: "exec-2", state: 3, calls: [Call(created: 100, completed: 140, output: 4_000)])
        try database.addStep(SyntheticStep(execution: nil, created: 500, completed: 520, output: 9_000))
        let metric = try onlyMetric(await monitor().poll())
        XCTAssertEqual(metric.outputTokens, 1_000)
        XCTAssertEqual(metric.durationSeconds, 12, accuracy: 0.000_001)
    }

    func testUnfinishedExecutionIsEmittedExactlyOnceWhenItFinishes() async throws {
        let database = try makeDatabase()
        try addRun(database, state: 3, calls: standardCalls)
        let monitor = monitor()
        let first = await monitor.poll()
        XCTAssertTrue(first.metrics.isEmpty, "state 3 is not finished")

        try database.setExecutor(id: "exec-1", state: 4, variant: "gemini-3.8-flash-medium")
        try bump(database)
        await notify(monitor, database)
        let finished = await monitor.poll()
        XCTAssertEqual(finished.metrics.count, 1)

        try bump(database)
        await notify(monitor, database)
        let readsBefore = await monitor.databaseReadCount
        let again = await monitor.poll()
        XCTAssertTrue(again.metrics.isEmpty, "an emitted execution is not emitted again")
        let readsAfter = await monitor.databaseReadCount
        XCTAssertEqual(readsAfter, readsBefore + 1, "the database was re-read; the record was not repeated")
    }

    func testOnlyStateFourIsAccepted() async throws {
        for state: UInt64 in [0, 1, 2, 3, 5] {
            let isolated = root.appendingPathComponent("state-\(state)", isDirectory: true)
            let url = isolated.appendingPathComponent("antigravity/conversations/c.db")
            let database = try SyntheticAntigravityDatabase(url: url)
            try addRun(database, state: state, calls: standardCalls)
            let update = await AntigravityConversationMonitor(root: isolated).poll()
            XCTAssertTrue(update.metrics.isEmpty, "state \(state)")
        }
    }

    func testAbsentGenerationIndexMeansGenerationZero() async throws {
        let database = try makeDatabase()
        // `generation: nil` omits field 20 entirely, as proto3 does for 0; the default Call does that.
        try addRun(database, calls: [Call(created: 1, completed: 11, output: 1_000, generation: nil)])
        let update = await monitor().poll()
        XCTAssertEqual(try onlyMetric(update).model, "gemini-3.8-flash")
    }

    func testAbsentThinkingTokensAndStateAreZero() async throws {
        let database = try makeDatabase()
        try database.addGeneration(index: 0, model: "gemini-3.8-flash")
        // An executor whose state is absent (0) is not finished; thinking 9.9 absent is 0 tokens.
        var executor = ProtoWriter()
        executor.string(9, "exec-1")
        try database.addExecutorBlob(executor.data)
        try database.addStep(SyntheticStep(execution: "exec-1", created: 0, completed: 1))
        try database.addStep(SyntheticStep(execution: "exec-1", created: 1, completed: 11, output: 1_000))
        let unfinished = await monitor().poll()
        XCTAssertTrue(unfinished.metrics.isEmpty)
        try database.setExecutor(id: "exec-1", state: 4, variant: nil)
        try bump(database)
        let metric = try onlyMetric(await monitor().poll())
        XCTAssertEqual(metric.reasoningOutputTokens, 0)
    }

    // MARK: Model, effort, provider

    func testMixedModelsMakeTheModelAndEffortUnknown() async throws {
        let database = try makeDatabase()
        try database.addGeneration(index: 1, model: "gemini-3.8-pro")
        try addRun(database, calls: [
            Call(created: 1, completed: 11, output: 1_000, generation: 0),
            Call(created: 12, completed: 22, output: 1_000, generation: 1)
        ])
        let metric = try onlyMetric(await monitor().poll())
        XCTAssertNil(metric.model)
        XCTAssertNil(metric.reasoningEffort)
        XCTAssertEqual(metric.provider, "unknown")
    }

    func testACallWithoutAGenerationMakesTheModelUnknown() async throws {
        let database = try makeDatabase()
        try addRun(database, calls: [
            Call(created: 1, completed: 11, output: 1_000, generation: 0),
            Call(created: 12, completed: 22, output: 1_000, generation: 7)
        ])
        let metric = try onlyMetric(await monitor().poll())
        XCTAssertNil(metric.model)
        XCTAssertEqual(metric.provider, "unknown")
        XCTAssertEqual(metric.outputTokens, 2_000, "the turn is still measured")
    }

    func testNonGeminiVariantHasNoEffortAndNoProvider() async throws {
        let database = try makeDatabase()
        try database.addGeneration(index: 0, model: "claude-opus-4-6-thinking", nonGemini: "true")
        try addRun(database, variant: "claude-opus-4-6-thinking", model: nil, calls: [Call(created: 1, completed: 11, output: 1_000)])
        let metric = try onlyMetric(await monitor().poll())
        XCTAssertEqual(metric.model, "claude-opus-4-6-thinking")
        XCTAssertNil(metric.reasoningEffort)
        XCTAssertEqual(metric.provider, "unknown")
    }

    func testProviderIsGoogleOnlyForGeminiWithExplicitFalseFlag() async throws {
        let cases: [(model: String, flag: String?, provider: String)] = [
            ("gemini-3.8-flash", "false", "google"),
            ("gemini-3.8-flash", "true", "unknown"),
            ("gemini-3.8-flash", nil, "unknown"),
            ("gemini-3.8-flash", "maybe", "unknown"),
            ("claude-opus-4-6-thinking", "false", "unknown"),
            ("gpt-oss-120b-medium", "true", "unknown")
        ]
        for (index, entry) in cases.enumerated() {
            let isolated = root.appendingPathComponent("provider-\(index)", isDirectory: true)
            let database = try SyntheticAntigravityDatabase(url: isolated.appendingPathComponent("antigravity/conversations/c.db"))
            try database.addGeneration(index: 0, model: entry.model, nonGemini: entry.flag)
            try addRun(database, variant: nil, model: nil, calls: [Call(created: 1, completed: 11, output: 1_000)])
            let metric = try onlyMetric(await AntigravityConversationMonitor(root: isolated).poll())
            XCTAssertEqual(metric.provider, entry.provider, "\(entry.model) \(entry.flag ?? "no flag")")
        }
    }

    func testEffortSuffixParsing() {
        let model = "gemini-3.8-flash"
        for effort in ["minimal", "low", "medium", "high", "xhigh", "max"] {
            XCTAssertEqual(AntigravityModelID.effort(variantID: "\(model)-\(effort)", model: model), effort)
        }
        XCTAssertNil(AntigravityModelID.effort(variantID: model, model: model), "no suffix")
        XCTAssertNil(AntigravityModelID.effort(variantID: "\(model)-ultra", model: model), "not an Antigravity effort")
        XCTAssertNil(AntigravityModelID.effort(variantID: "\(model)-none", model: model))
        XCTAssertNil(AntigravityModelID.effort(variantID: "\(model)-medium-fast", model: model))
        XCTAssertNil(AntigravityModelID.effort(variantID: "gemini-3.8-pro-medium", model: model), "a different model")
        XCTAssertNil(AntigravityModelID.effort(variantID: "\(model)medium", model: model), "the dash is required")
        XCTAssertNil(AntigravityModelID.effort(variantID: "claude-opus-4-6-thinking", model: "claude-opus-4-6-thinking"))
        XCTAssertNil(AntigravityModelID.effort(variantID: nil, model: model))
        XCTAssertNil(AntigravityModelID.effort(variantID: "\(model)-high", model: nil))
    }

    // MARK: Subagents and delegated output

    func testASubagentTrajectoryIsNotMeasured() async throws {
        let database = try makeDatabase()
        try addRun(database, calls: standardCalls)
        try database.addParentReference()
        let update = await monitor(liveSince: .distantPast).poll()
        XCTAssertTrue(update.metrics.isEmpty)
        XCTAssertTrue(update.responses.isEmpty, "a subagent trajectory does not feed the live stream either")
    }

    func testSubtrajectoryLeavesDelegatedOutputPendingAndOtherwiseZero() async throws {
        let plain = try makeDatabase("plain")
        try addRun(plain, calls: standardCalls)
        let delegating = try makeDatabase("delegating")
        try addRun(delegating, calls: standardCalls)
        try delegating.addStep(SyntheticStep(execution: "exec-1", created: 5, completed: 6, hasSubtrajectory: true))

        let update = await monitor().poll()
        XCTAssertEqual(update.metrics.count, 2)
        let plainMetric = try XCTUnwrap(update.metrics.first { $0.id == digest("antigravity|plain|exec-1") })
        let delegatingMetric = try XCTUnwrap(update.metrics.first { $0.id == digest("antigravity|delegating|exec-1") })
        XCTAssertEqual(plainMetric.delegatedOutputTokens, 0)
        XCTAssertTrue(plainMetric.isDelegationFinal)
        XCTAssertNil(delegatingMetric.delegatedOutputTokens)
        XCTAssertFalse(delegatingMetric.isDelegationFinal)
        XCTAssertNil(SharedSample(delegatingMetric), "never final, so never shared")
        XCTAssertNotNil(SharedSample(plainMetric))
        XCTAssertEqual(delegatingMetric.outputTokens, plainMetric.outputTokens)
    }

    // MARK: Response speed

    func testResponseQualificationBounds() async throws {
        let database = try makeDatabase()
        try addRun(database, calls: [
            Call(created: 1, completed: 6, output: 199),                // below 200 tokens
            Call(created: 7, completed: 607, output: 1_200),            // exactly 600 s: qualifies
            Call(created: 608, completed: 1_209, output: 1_200),        // 601 s: too long
            Call(created: 1_210, completed: 1_213, output: 5_000),      // 1,666 tok/s: qualifies
            Call(created: 1_214, completed: 1_215, output: 2_500),      // 2,500 tok/s: above the bound
            Call(created: 1_216, completed: 1_216, output: 900)         // zero duration
        ])
        let metric = try onlyMetric(await monitor().poll())
        XCTAssertEqual(metric.responseCount, 2)
        XCTAssertEqual(metric.responseOutputTokens, 6_200)
        XCTAssertEqual(try XCTUnwrap(metric.responseDurationSeconds), 603, accuracy: 0.000_001)
        XCTAssertEqual(metric.outputTokens, 199 + 1_200 + 1_200 + 5_000 + 2_500 + 900)
    }

    func testTurnWithoutQualifyingResponsesHasNoResponseFields() async throws {
        let database = try makeDatabase()
        try addRun(database, calls: [Call(created: 1, completed: 6, output: 100), Call(created: 7, completed: 17, output: 120)])
        let metric = try onlyMetric(await monitor().poll())
        XCTAssertNil(metric.responseCount)
        XCTAssertNil(metric.responseOutputTokens)
        XCTAssertNil(metric.responseDurationSeconds)
    }

    func testTurnAboveTheThroughputBoundIsDropped() async throws {
        let database = try makeDatabase()
        // 5,000 tokens inside a 1.25 s run: 4,000 tok/s.
        try addRun(database, calls: [Call(created: 0.5, completed: 1, output: 5_000)], finalCompleted: 1.25)
        let update = await monitor(liveSince: .distantPast).poll()
        XCTAssertTrue(update.metrics.isEmpty)
        XCTAssertTrue(update.responses.isEmpty)
    }

    func testExecutionNeedsOrderedTimestampsOnEveryModelCall() async throws {
        let cases: [(String, Call?, SyntheticStep?)] = [
            ("completed before created", Call(created: 20, completed: 10, output: 1_000), nil),
            ("no completed timestamp", nil, SyntheticStep(execution: "exec-1", created: 30, completed: nil, output: 1_000)),
            ("no created timestamp", nil, SyntheticStep(execution: "exec-1", created: nil, completed: 40, output: 1_000))
        ]
        for (index, entry) in cases.enumerated() {
            let isolated = root.appendingPathComponent("order-\(index)", isDirectory: true)
            let database = try SyntheticAntigravityDatabase(url: isolated.appendingPathComponent("antigravity/conversations/c.db"))
            try addRun(database, calls: [Call(created: 1, completed: 11, output: 1_000)])
            if let call = entry.1 {
                try database.addStep(SyntheticStep(execution: "exec-1", created: call.created, completed: call.completed, output: call.output))
            }
            if let step = entry.2 { try database.addStep(step) }
            let update = await AntigravityConversationMonitor(root: isolated).poll()
            XCTAssertTrue(update.metrics.isEmpty, entry.0)
        }
    }

    func testExecutionWithoutModelCallsOrDurationIsSkipped() async throws {
        let database = try makeDatabase()
        try database.addExecutor(id: "exec-1", state: 4, variant: nil)
        try database.addStep(SyntheticStep(execution: "exec-1", created: 0, completed: 5))
        let withoutCalls = await monitor().poll()
        XCTAssertTrue(withoutCalls.metrics.isEmpty, "no model call")

        let isolated = root.appendingPathComponent("zero", isDirectory: true)
        let zero = try SyntheticAntigravityDatabase(url: isolated.appendingPathComponent("antigravity/conversations/z.db"))
        try zero.addGeneration(index: 0, model: "gemini-3.8-flash")
        try zero.addExecutor(id: "exec-1", state: 4, variant: nil)
        try zero.addStep(SyntheticStep(execution: "exec-1", created: 5, completed: 5, output: 1_000))
        let withoutDuration = await AntigravityConversationMonitor(root: isolated).poll()
        XCTAssertTrue(withoutDuration.metrics.isEmpty, "zero duration")
    }

    // MARK: Live responses

    func testLiveResponsesArePublishedOnceAndOnlyForCallsCompletedAfterTheMonitorStarted() async throws {
        let database = try makeDatabase()
        // The run is unfinished, so only the live stream can see its calls.
        try addRun(database, state: 3, calls: [
            Call(created: 1, completed: 11, output: 1_000),        // before the monitor started
            Call(created: 120, completed: 130, output: 2_000),     // after
            Call(created: 131, completed: 133, output: 100)        // after, but below 200 tokens
        ])
        let monitor = monitor(liveSince: SyntheticTime(100).date)
        let first = await monitor.poll()
        XCTAssertTrue(first.metrics.isEmpty)
        let response = try XCTUnwrap(first.responses.first)
        XCTAssertEqual(first.responses.count, 1)
        XCTAssertEqual(response.model, "gemini-3.8-flash")
        XCTAssertEqual(response.provider, "google")
        XCTAssertEqual(response.client, "antigravity")
        XCTAssertEqual(response.sourceKind, "primary")
        XCTAssertEqual(response.metricVersion, "antigravity-observed-execution-v1")
        XCTAssertEqual(response.reasoningEffort, "medium")
        XCTAssertEqual(response.outputTokens, 2_000)
        XCTAssertEqual(response.durationSeconds, 10, accuracy: 0.000_001)
        XCTAssertEqual(response.completedAt.timeIntervalSince1970, SyntheticTime(130).date.timeIntervalSince1970, accuracy: 0.000_001)

        // A new call arrives; the earlier one is not published again.
        try database.addStep(SyntheticStep(execution: "exec-1", created: 140, completed: 150, output: 1_500, generation: nil))
        try bump(database)
        await notify(monitor, database)
        let second = await monitor.poll()
        XCTAssertEqual(second.responses.map(\.outputTokens), [1_500])

        try bump(database)
        await notify(monitor, database)
        let third = await monitor.poll()
        XCTAssertTrue(third.responses.isEmpty)
        XCTAssertFalse(response.id.contains(conversationID), "the local id carries no conversation id")
    }

    func testLiveResponseEffortIsUnknownWithoutAnExecutorRowAndFollowsItsVariant() async throws {
        let database = try makeDatabase()
        try database.addGeneration(index: 0, model: "gemini-3.8-flash")
        try database.addStep(SyntheticStep(execution: "orphan", created: 120, completed: 130, output: 1_000))
        let update = await monitor(liveSince: SyntheticTime(100).date).poll()
        XCTAssertEqual(update.responses.count, 1)
        XCTAssertNil(update.responses.first?.reasoningEffort)
    }

    // MARK: Malformed data

    func testMalformedBlobsSkipTheRecordWithoutCrashing() async throws {
        // A step that is not a protobuf message could belong to any execution: nothing is measured.
        let brokenStep = try makeDatabase("broken-step")
        try addRun(brokenStep, calls: standardCalls)
        try brokenStep.addStep(SyntheticStep(rawMetadata: Data("not a protobuf".utf8)))

        // A broken executor row only loses its own execution.
        let brokenExecutor = try makeDatabase("broken-executor")
        try addRun(brokenExecutor, calls: standardCalls)
        try brokenExecutor.addExecutorBlob(Data([0xFF, 0xFF, 0xFF]))

        // An unreadable generation only loses the model.
        let brokenGeneration = try makeDatabase("broken-generation")
        try addRun(brokenGeneration, calls: standardCalls)
        try brokenGeneration.addGenerationBlob(index: 0, Data([0x0A, 0xFF]))

        // A usage message with the wrong wire type for the output tokens.
        let brokenUsage = try makeDatabase("broken-usage")
        try addRun(brokenUsage, calls: [Call(created: 1, completed: 11, output: 1_000)])
        var usage = ProtoWriter()
        SyntheticTime(40).encode(1, into: &usage)
        SyntheticTime(50).encode(7, into: &usage)
        usage.message(9) { $0.string(3, "oops") }
        usage.string(12, "exec-1")
        try brokenUsage.addStep(SyntheticStep(rawMetadata: usage.data))

        // An invalid timestamp message.
        let brokenTimestamp = try makeDatabase("broken-timestamp")
        try addRun(brokenTimestamp, calls: [Call(created: 1, completed: 11, output: 1_000)])
        var timestamp = ProtoWriter()
        timestamp.message(1) { $0.string(1, "not seconds") }
        timestamp.string(12, "exec-1")
        try brokenTimestamp.addStep(SyntheticStep(rawMetadata: timestamp.data))

        // A file that is not a database at all.
        let garbage = databaseURL("garbage")
        try FileManager.default.createDirectory(at: garbage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not an sqlite file".utf8).write(to: garbage)

        // A database with a different schema.
        let foreign = databaseURL("foreign")
        _ = try SyntheticAntigravityDatabase(url: foreign)
        try FileManager.default.removeItem(at: foreign)
        try Data().write(to: foreign)

        let update = await monitor().poll()
        let ids = Set(update.metrics.map(\.id))
        XCTAssertFalse(ids.contains(digest("antigravity|broken-step|exec-1")))
        XCTAssertFalse(ids.contains(digest("antigravity|broken-usage|exec-1")))
        XCTAssertFalse(ids.contains(digest("antigravity|broken-timestamp|exec-1")))
        XCTAssertTrue(ids.contains(digest("antigravity|broken-executor|exec-1")))
        let generationMetric = try XCTUnwrap(update.metrics.first { $0.id == digest("antigravity|broken-generation|exec-1") })
        XCTAssertNil(generationMetric.model)
        XCTAssertEqual(generationMetric.outputTokens, 1_700)
        XCTAssertEqual(update.metrics.count, 2)
    }

    func testUnreadableDatabaseIsRetriedLaterNotOnEveryPoll() async throws {
        let garbage = databaseURL("garbage")
        try FileManager.default.createDirectory(at: garbage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: garbage)
        let monitor = monitor()
        let start = Date.now
        _ = await monitor.poll(now: start)
        _ = await monitor.poll(now: start.addingTimeInterval(2))
        var reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 1, "a failed read waits before the next attempt")
        _ = await monitor.poll(now: start.addingTimeInterval(11))
        reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 2)
    }

    // MARK: Files and folders

    func testOnlyDatabaseFilesInTheThreeFoldersAreRead() async throws {
        for (index, folder) in ["antigravity", "antigravity-ide", "antigravity-cli"].enumerated() {
            let database = try makeDatabase("conversation-\(index)", folder: folder)
            try addRun(database, calls: standardCalls)
        }
        let other = try makeDatabase("elsewhere", folder: "antigravity-backup")
        try addRun(other, calls: standardCalls)
        // Legacy encrypted conversations and SQLite side files are ignored.
        let conversations = databaseURL().deletingLastPathComponent()
        try Data(repeating: 0x41, count: 64).write(to: conversations.appendingPathComponent("legacy.pb"))
        try Data(repeating: 0x42, count: 64).write(to: conversations.appendingPathComponent("stray.db-shm"))
        try Data(repeating: 0x43, count: 64).write(to: conversations.appendingPathComponent("stray.db-wal"))
        let nested = conversations.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("deep.db"))

        let monitor = monitor()
        let update = await monitor.poll()
        XCTAssertEqual(Set(update.metrics.map(\.id)), Set((0..<3).map { digest("antigravity|conversation-\($0)|exec-1") }))
        let status = await monitor.status()
        XCTAssertTrue(status.rootAvailable)
        XCTAssertEqual(status.conversations, 3)
        let reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 3)
    }

    func testMissingRootReportsUnavailableAndYieldsNothing() async {
        let monitor = AntigravityConversationMonitor(root: root.appendingPathComponent("absent", isDirectory: true))
        let update = await monitor.poll()
        XCTAssertTrue(update.metrics.isEmpty)
        let status = await monitor.status()
        XCTAssertFalse(status.rootAvailable)
        XCTAssertEqual(status.conversations, 0)
        XCTAssertFalse(AntigravityConversationMonitor.hasConversationFolder(root: root.appendingPathComponent("absent")))
    }

    func testFilesOlderThanSevenDaysAreNotOpened() async throws {
        let database = try makeDatabase()
        try addRun(database, calls: standardCalls)
        let eightDays = Date.now.addingTimeInterval(-8 * 24 * 3_600)
        try FileManager.default.setAttributes([.modificationDate: eightDays], ofItemAtPath: database.url.path)
        let monitor = monitor()
        let stale = await monitor.poll()
        XCTAssertTrue(stale.metrics.isEmpty)
        let reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 0, "the file was never opened")
        let status = await monitor.status()
        XCTAssertEqual(status.conversations, 0)

        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-6 * 24 * 3_600)], ofItemAtPath: database.url.path)
        let recent = await AntigravityConversationMonitor(root: root).poll()
        XCTAssertEqual(recent.metrics.count, 1)
    }

    func testDatabaseIsReadAgainOnlyWhenItChanged() async throws {
        let database = try makeDatabase()
        try addRun(database, state: 3, calls: standardCalls)
        let monitor = monitor()
        let start = Date.now
        _ = await monitor.poll(now: start)
        _ = await monitor.poll(now: start.addingTimeInterval(2))
        _ = await monitor.poll(now: start.addingTimeInterval(4))
        var reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 1, "unchanged databases are not opened")

        try bump(database)
        await notify(monitor, database)
        _ = await monitor.poll(now: start.addingTimeInterval(6))
        reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 2)

        // A discovery pass sees the same signature and does not re-read either.
        _ = await monitor.poll(now: start.addingTimeInterval(Self.safetyNet + 30))
        reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 2)
    }

    func testWriteAheadLogContentIsReadAndItsChangesTriggerARead() async throws {
        // The writer stays open, so the newest rows live only in the -wal file.
        let database = try makeDatabase(writeAheadLog: true)
        try addRun(database, state: 3, calls: standardCalls, finalCompleted: 31.75)
        let walPath = database.url.path + "-wal"
        XCTAssertTrue(FileManager.default.fileExists(atPath: walPath))
        let monitor = monitor()
        let start = Date.now
        _ = await monitor.poll(now: start)
        let readsAfterFirst = await monitor.databaseReadCount
        XCTAssertEqual(readsAfterFirst, 1)

        try database.setExecutor(id: "exec-1", state: 4, variant: "gemini-3.8-flash-medium")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)], ofItemAtPath: walPath)
        await notify(monitor, database, wal: true)
        let update = await monitor.poll(now: start.addingTimeInterval(2))
        XCTAssertEqual(update.metrics.count, 1, "the finished state exists only in the write-ahead log")
        XCTAssertEqual(update.metrics.first?.outputTokens, 1_700)
    }

    func testAConversationOnlyTouchedInItsLogIsStillWatched() async throws {
        let database = try makeDatabase(writeAheadLog: true)
        try addRun(database, calls: standardCalls)
        // The main file was last written long ago; the log is current.
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-9 * 24 * 3_600)], ofItemAtPath: database.url.path)
        let update = await monitor().poll()
        XCTAssertEqual(update.metrics.count, 1)
    }

    func testPathsWithSpacesAndURISpecialCharactersAreOpened() async throws {
        let strange = root.appendingPathComponent("My Data #1 ?100% done", isDirectory: true)
        let url = strange.appendingPathComponent("antigravity/conversations/conv with space.db")
        let database = try SyntheticAntigravityDatabase(url: url)
        try addRun(database, calls: standardCalls)
        let update = await AntigravityConversationMonitor(root: strange).poll()
        XCTAssertEqual(try onlyMetric(update).id, digest("antigravity|conv with space|exec-1"))
    }

    func testReadOnlyURIEncodesEverythingThatCouldChangeItsMeaning() {
        let url = URL(fileURLWithPath: "/tmp/a b/c?d#e%f&g=h/x.db")
        XCTAssertEqual(AntigravityDatabase.readOnlyURI(for: url), "file:/tmp/a%20b/c%3Fd%23e%25f%26g%3Dh/x.db?mode=ro")
        XCTAssertEqual(AntigravityDatabase.readOnlyURI(for: URL(fileURLWithPath: "/Users/matti/.gemini/a.db")), "file:/Users/matti/.gemini/a.db?mode=ro")
    }

    func testDatabaseFilesAreNeverModified() async throws {
        for writeAheadLog in [false, true] {
            let name = writeAheadLog ? "wal" : "plain"
            let database = try makeDatabase(name, writeAheadLog: writeAheadLog)
            try addRun(database, calls: standardCalls)
            let before = try Data(contentsOf: database.url)
            let walURL = URL(fileURLWithPath: database.url.path + "-wal")
            let walBefore = try? Data(contentsOf: walURL)
            let modifiedBefore = try FileManager.default.attributesOfItem(atPath: database.url.path)[.modificationDate] as? Date

            let update = await monitor(liveSince: .distantPast).poll()
            XCTAssertFalse(update.metrics.isEmpty, name)

            XCTAssertEqual(try Data(contentsOf: database.url), before, "\(name): database bytes")
            XCTAssertEqual(try? Data(contentsOf: walURL), walBefore, "\(name): log bytes")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: database.url.path)[.modificationDate] as? Date, modifiedBefore, name)
            try FileManager.default.removeItem(at: root.appendingPathComponent("antigravity"))
        }
    }

    func testAPollReadsAtMostEightDatabasesAndTheRestWaitForTheNextPoll() async throws {
        for index in 0..<10 {
            let database = try makeDatabase("conversation-\(index)")
            try addRun(database, calls: standardCalls)
        }
        let monitor = monitor()
        let start = Date.now
        let first = await monitor.poll(now: start)
        XCTAssertEqual(first.metrics.count, 8)
        let second = await monitor.poll(now: start.addingTimeInterval(2))
        XCTAssertEqual(second.metrics.count, 2)
        let third = await monitor.poll(now: start.addingTimeInterval(4))
        XCTAssertTrue(third.metrics.isEmpty)
        let reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 10)
    }

    func testBlobPrivacyNothingFromUnselectedColumnsReachesTheRecord() async throws {
        let database = try makeDatabase()
        try addRun(database, calls: standardCalls)
        let update = await monitor(liveSince: .distantPast).poll()
        let serialized = String(decoding: try JSONEncoder().encode(update.metrics), as: UTF8.self)
        XCTAssertFalse(serialized.contains(SyntheticAntigravityDatabase.privateText))
        XCTAssertFalse(serialized.contains(conversationID))
        XCTAssertFalse(serialized.contains(root.lastPathComponent))
    }

    // MARK: Bookkeeping

    func testBoundedSetForgetsItsOldestMembersAndNeverRepeatsAnInsert() {
        var set = BoundedSet<Int>(limit: 3)
        XCTAssertTrue(set.insert(1))
        XCTAssertFalse(set.insert(1))
        for value in 2...5 { XCTAssertTrue(set.insert(value)) }
        XCTAssertFalse(set.contains(1))
        XCTAssertFalse(set.contains(2))
        for value in 3...5 { XCTAssertTrue(set.contains(value)) }
        // Compaction after many evictions keeps the newest members.
        for value in 6...100 { set.insert(value) }
        XCTAssertTrue(set.contains(100))
        XCTAssertTrue(set.contains(98))
        XCTAssertFalse(set.contains(97))
    }

    // MARK: Surface

    func testSurfaceFollowsTheFolderTheDatabaseWasFoundIn() async throws {
        let expected = [("antigravity", "desktop"), ("antigravity-ide", "ide"), ("antigravity-cli", "cli")]
        for (folder, _) in expected {
            let database = try makeDatabase("conversation-\(folder)", folder: folder)
            try addRun(database, calls: standardCalls)
        }
        let update = await monitor().poll()
        XCTAssertEqual(update.metrics.count, 3)
        for (folder, surface) in expected {
            let metric = try XCTUnwrap(update.metrics.first { $0.id == digest("antigravity|conversation-\(folder)|exec-1") })
            XCTAssertEqual(metric.surface?.rawValue, surface, folder)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SharedSample(metric))) as? [String: Any])
            XCTAssertEqual(json["surface"] as? String, surface, folder)
            // The surface survives the settle re-emission and a save/load round trip.
            XCTAssertEqual(metric.withDelegatedOutputTokens(0).surface?.rawValue, surface)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            XCTAssertEqual(try decoder.decode(TurnMetric.self, from: encoder.encode(metric)).surface?.rawValue, surface)
        }
    }

    // MARK: Ambiguous executors

    func testAnExecutionIdWithMoreThanOneExecutorRowIsSkipped() async throws {
        let database = try makeDatabase()
        try addRun(database, execution: "exec-1", calls: standardCalls)
        try database.addExecutor(id: "exec-1", state: 4, variant: "gemini-3.8-flash-high")
        try addRun(database, execution: "exec-2", calls: [Call(created: 100, completed: 110, output: 1_000)])
        let update = await monitor(liveSince: .distantPast).poll()
        XCTAssertEqual(update.metrics.map(\.id), [digest("antigravity|\(conversationID)|exec-2")], "exec-1 is ambiguous")
        // Responses are newest first: exec-2's call, then the two qualifying calls of the ambiguous exec-1.
        XCTAssertEqual(update.responses.map(\.outputTokens), [1_000, 550, 1_000])
        XCTAssertEqual(update.responses.map(\.reasoningEffort), ["medium", nil, nil], "no effort for calls whose execution has two executor rows")
    }

    // MARK: Folder watcher

    func testNoteChangesIgnoresEverythingExceptDatabasesInTheConversationFolders() async throws {
        let database = try makeDatabase()
        try addRun(database, calls: standardCalls)
        let monitor = monitor()
        _ = await monitor.poll()
        let folder = database.url.deletingLastPathComponent().standardizedFileURL.path
        let gemini = root.standardizedFileURL.path
        let irrelevant: Set<String> = [
            "\(gemini)/antigravity/brain/abc/overview.txt",
            "\(gemini)/antigravity/implicit/x.pb",
            "\(gemini)/tmp/session/chat.json",
            "\(gemini)/GEMINI.md",
            "\(folder)/legacy.pb",
            "\(folder)/\(conversationID).db-shm",
            "\(folder)/\(conversationID).db-journal",
            "\(folder)/nested/deep.db",
            "\(gemini)/antigravity-backup/conversations/\(conversationID).db",
            "\(folder)/.db",
            "\(folder)/.db-wal"
        ]
        let noted = await monitor.noteChanges(SessionFolderChange(paths: irrelevant))
        XCTAssertFalse(noted)
        let deadline = await monitor.nextPollDeadline(now: .now)
        XCTAssertNil(deadline, "irrelevant churn leaves nothing pending")
        let reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 1)
    }

    func testDatabaseAndWalChangesAreReadOnTheNextPoll() async throws {
        let database = try makeDatabase(writeAheadLog: true)
        try addRun(database, state: 3, calls: standardCalls)
        let monitor = monitor()
        let start = Date.now
        _ = await monitor.poll(now: start)
        let idle = await monitor.nextPollDeadline(now: start)
        XCTAssertNil(idle, "caught up")

        for wal in [false, true] {
            try database.setExecutor(id: "exec-1", state: wal ? 4 : 3, variant: nil)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(Double(bumps + 10))], ofItemAtPath: database.url.path + (wal ? "-wal" : ""))
            bumps += 10
            let noted = await notify(monitor, database, wal: wal)
            XCTAssertTrue(noted, wal ? "-wal" : ".db")
            let deadline = await monitor.nextPollDeadline(now: start)
            XCTAssertEqual(deadline, start, "a changed database is pending")
            let update = await monitor.poll(now: start.addingTimeInterval(2))
            XCTAssertEqual(update.metrics.count, wal ? 1 : 0)
            let after = await monitor.nextPollDeadline(now: start.addingTimeInterval(2))
            XCTAssertNil(after)
        }
        // A report for an unchanged database has nothing to read.
        let unchanged = await notify(monitor, database)
        XCTAssertFalse(unchanged)
    }

    func testANewDatabaseTriggersDiscoveryAndAVanishedOneIsDropped() async throws {
        let first = try makeDatabase("first")
        try addRun(first, calls: standardCalls)
        let monitor = monitor()
        let start = Date.now
        let initial = await monitor.poll(now: start)
        XCTAssertEqual(initial.metrics.count, 1)

        let second = try makeDatabase("second", folder: "antigravity-cli")
        try addRun(second, calls: standardCalls)
        // Without a report the new file waits for the safety net.
        let quiet = await monitor.poll(now: start.addingTimeInterval(2))
        XCTAssertTrue(quiet.metrics.isEmpty)

        let noted = await notify(monitor, second)
        XCTAssertTrue(noted)
        let deadline = await monitor.nextPollDeadline(now: start)
        XCTAssertEqual(deadline, start, "discovery is due")
        let discovered = await monitor.poll(now: start.addingTimeInterval(4))
        XCTAssertEqual(discovered.metrics.map(\.id), [digest("antigravity|second|exec-1")])
        let status = await monitor.status()
        XCTAssertEqual(status.conversations, 2)

        try FileManager.default.removeItem(at: first.url)
        let vanished = await notify(monitor, first)
        XCTAssertTrue(vanished)
        _ = await monitor.poll(now: start.addingTimeInterval(6))
        let afterRemoval = await monitor.status()
        XCTAssertEqual(afterRemoval.conversations, 1)
    }

    func testAConversationFolderEventAndALostEventTriggerDiscovery() async throws {
        let monitor = monitor()
        let folder = root.appendingPathComponent("antigravity/conversations", isDirectory: true).standardizedFileURL.path
        let notedFolder = await monitor.noteChanges(SessionFolderChange(paths: [folder]))
        XCTAssertTrue(notedFolder)
        var deadline = await monitor.nextPollDeadline(now: .now)
        XCTAssertNotNil(deadline)
        _ = await monitor.poll()
        deadline = await monitor.nextPollDeadline(now: .now)
        XCTAssertNil(deadline)

        let notedLoss = await monitor.noteChanges(SessionFolderChange(mustRescan: true))
        XCTAssertTrue(notedLoss)
        deadline = await monitor.nextPollDeadline(now: .now)
        XCTAssertNotNil(deadline)
    }

    func testNextPollDeadlineCoversDeferredReadsAndRetryBackoff() async throws {
        for index in 0..<10 {
            let database = try makeDatabase("conversation-\(index)")
            try addRun(database, calls: standardCalls)
        }
        let monitor = monitor()
        let start = Date.now
        _ = await monitor.poll(now: start)
        var deadline = await monitor.nextPollDeadline(now: start)
        XCTAssertEqual(deadline, start, "two reads were deferred by the per-poll cap")
        _ = await monitor.poll(now: start.addingTimeInterval(2))
        deadline = await monitor.nextPollDeadline(now: start.addingTimeInterval(2))
        XCTAssertNil(deadline)

        // An unreadable database is retried later, and the monitor asks to be polled then.
        let garbage = databaseURL("garbage")
        try Data("not sqlite".utf8).write(to: garbage)
        let noted = await monitor.noteChanges(SessionFolderChange(paths: [garbage.standardizedFileURL.path]))
        XCTAssertTrue(noted)
        _ = await monitor.poll(now: start.addingTimeInterval(4))
        let retry = await monitor.nextPollDeadline(now: start.addingTimeInterval(5))
        XCTAssertEqual(retry, start.addingTimeInterval(14))
        let due = await monitor.nextPollDeadline(now: start.addingTimeInterval(15))
        XCTAssertEqual(due, start.addingTimeInterval(15), "the retry is due")
    }

    func testAnIdleMonitorDoesNoFileWorkUntilTheSafetyNet() async throws {
        let database = try makeDatabase()
        try addRun(database, calls: standardCalls)
        let monitor = monitor()
        let start = Date.now
        _ = await monitor.poll(now: start)
        // A change nobody reported is not seen between discoveries...
        try addRun(database, execution: "exec-2", calls: [Call(created: 100, completed: 110, output: 1_000)])
        try bump(database)
        let unseen = await monitor.poll(now: start.addingTimeInterval(30))
        XCTAssertTrue(unseen.metrics.isEmpty)
        // ...but the safety-net discovery finds it.
        let found = await monitor.poll(now: start.addingTimeInterval(Self.safetyNet + 1))
        XCTAssertEqual(found.metrics.count, 1)
    }

    // MARK: Sharing

    func testGoogleProviderIsSharedOnlyForAntigravityAndSampleCarriesTheTuple() async throws {
        let database = try makeDatabase()
        try addRun(database, calls: standardCalls)
        let metric = try onlyMetric(await monitor().poll())
        let sample = try XCTUnwrap(SharedSample(metric))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertEqual(json["client"] as? String, "antigravity")
        XCTAssertEqual(json["provider"] as? String, "google")
        XCTAssertEqual(json["parserVersion"] as? String, "antigravity-conversation-v1")
        XCTAssertEqual(json["metricVersion"] as? String, "antigravity-observed-execution-v1")
        XCTAssertEqual(json["reasoningEffort"] as? String, "medium")
        XCTAssertEqual(json["sourceKind"] as? String, "primary")
        XCTAssertEqual(json["delegatedOutputTokens"] as? Int, 0)
        XCTAssertEqual(json["appVersion"] as? String, "0.1.18")
        XCTAssertEqual(json["surface"] as? String, "desktop")
        XCTAssertTrue(SharedSample.isAllowedProvider("google", client: "antigravity"))
        XCTAssertFalse(SharedSample.isAllowedProvider("google", client: "codex"))
        XCTAssertFalse(SharedSample.isAllowedProvider("google", client: "claude-code"))
        XCTAssertTrue(TurnMetric.isSupportedSourceTuple(client: "antigravity", parserVersion: "antigravity-conversation-v1", metricVersion: "antigravity-observed-execution-v1"))
        XCTAssertFalse(TurnMetric.isSupportedSourceTuple(client: "antigravity", parserVersion: "antigravity-conversation-v2", metricVersion: "antigravity-observed-execution-v1"))
    }
}
