import XCTest
import TokrateCore
@testable import TokrateApp

final class ResponseSpeedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func response(
        _ id: String, secondsAgo: Double, model: String? = "claude-opus-5-5", provider: String? = "anthropic",
        client: String = "claude-code", tokens: Int = 600, speed: Double = 100
    ) -> LiveResponse {
        LiveResponse(
            id: id, model: model, provider: provider, client: client, sourceKind: "primary",
            metricVersion: "claude-observed-turn-v1", reasoningEffort: nil,
            completedAt: now.addingTimeInterval(-secondsAgo), outputTokens: tokens, durationSeconds: Double(tokens) / speed
        )
    }

    private func turn(
        _ id: String, secondsAgo: Double, model: String? = "claude-opus-5-5", provider: String? = "anthropic",
        client: String = "claude-code", parser: String = "claude-transcript-v4", metricVersion: String = "claude-observed-turn-v1",
        sourceKind: String = "primary", turnSpeed: Double = 20, responseSpeed: Double? = 100, responses: Int = 2, effort: String? = nil
    ) -> TurnMetric {
        let responseTokens = responseSpeed.map { _ in 800 }
        return TurnMetric(
            id: id, completedAt: now.addingTimeInterval(-secondsAgo), model: model, outputTokens: 1_000, durationSeconds: 1_000 / turnSpeed,
            codexTTFTSeconds: nil, turnThroughputTPS: turnSpeed, client: client, clientVersion: "1.0", parserVersion: parser,
            metricVersion: metricVersion, sourceKind: sourceKind, provider: provider, reasoningEffort: effort,
            responseOutputTokens: responseTokens,
            responseDurationSeconds: responseSpeed.map { 800 / $0 },
            responseCount: responseSpeed == nil ? nil : responses
        )
    }

    // MARK: Live buffer and readout

    func testLiveSpeedIsTheMedianOfTheLastFiveResponsesWithinTenMinutes() throws {
        var buffer = LiveResponseBuffer()
        // Six responses in the window: the oldest (400 tok/s) is outside the latest five.
        buffer.append(contentsOf: [
            response("a", secondsAgo: 500, speed: 400),
            response("b", secondsAgo: 400, speed: 90), response("c", secondsAgo: 300, speed: 100),
            response("d", secondsAgo: 200, speed: 110), response("e", secondsAgo: 100, speed: 120),
            response("f", secondsAgo: 30, speed: 130),
            response("other-model", secondsAgo: 10, model: "gpt-5", provider: "openai", speed: 900),
            response("too-old", secondsAgo: 601, speed: 5)
        ])
        let speed = try XCTUnwrap(buffer.liveSpeed(for: ResponseGroupKey(model: "claude-opus-5-5", provider: "anthropic"), now: now))
        XCTAssertEqual(speed.medianTPS, 110, accuracy: 0.001)
        XCTAssertEqual(speed.responseCount, 5)
        XCTAssertEqual(speed.latestAt, now.addingTimeInterval(-30))
        XCTAssertEqual(speed.relativeCaption(now: now), "last 5 responses · just now")
        XCTAssertNil(buffer.liveSpeed(for: ResponseGroupKey(model: "claude-opus-5-5", provider: "anthropic"), now: now.addingTimeInterval(700)))
        XCTAssertNil(buffer.liveSpeed(for: nil, now: now))
        XCTAssertNil(buffer.liveSpeed(for: ResponseGroupKey(model: "unseen", provider: "anthropic"), now: now))
    }

    func testRingBufferDeduplicatesAndKeepsTheNewestTwoHundred() {
        var buffer = LiveResponseBuffer()
        buffer.append(contentsOf: (0..<250).map { response("r\($0)", secondsAgo: Double(250 - $0)) })
        buffer.append(contentsOf: [response("r249", secondsAgo: 1)])
        XCTAssertEqual(buffer.responses.count, LiveResponseBuffer.capacity)
        XCTAssertEqual(buffer.responses.first?.id, "r249")
        XCTAssertEqual(Set(buffer.responses.map(\.id)).count, LiveResponseBuffer.capacity)
        XCTAssertFalse(buffer.responses.contains { $0.id == "r0" })
    }

    func testMenuBarReadoutFormatsValueAndAccessibilityLabel() {
        let group = ResponseGroupKey(model: "claude-opus-5-5", provider: "anthropic")
        let live = LiveSpeed(medianTPS: 112.4, responseCount: 5, latestAt: now)
        let readout = MenuBarReadout.make(isMonitoring: true, selection: .auto, group: group, liveSpeed: live)
        XCTAssertEqual(readout.speedText, "112.4 tok/s")
        XCTAssertEqual(readout.accessibilityLabel, "Tokrate, Anthropic, response speed: 112.4 tokens per second")
        XCTAssertEqual(readout.maker, .anthropic)

        let none = MenuBarReadout.make(isMonitoring: true, selection: .auto, group: group, liveSpeed: nil)
        XCTAssertEqual(none.speedText, "— tok/s")
        XCTAssertEqual(none.maker, .anthropic, "the badge stays with the followed model")
        XCTAssertEqual(MenuBarReadout.make(isMonitoring: false, selection: .auto, group: group, liveSpeed: live), .unavailable)
        XCTAssertEqual(MenuBarReadout.make(isMonitoring: true, selection: .all, group: nil, liveSpeed: nil).speedText, "Compare")
        XCTAssertEqual(MenuBarReadout.make(isMonitoring: true, selection: .auto, group: nil, liveSpeed: nil).accessibilityLabel, "Tokrate, response speed: unavailable")
    }

    func testModelMakerFollowsModelIdThenProvider() {
        XCTAssertEqual(ModelMaker(model: "claude-opus-5-5", provider: "amazon-bedrock"), .anthropic)
        XCTAssertEqual(ModelMaker(model: nil, provider: "anthropic"), .anthropic)
        XCTAssertEqual(ModelMaker(model: "gpt-5-codex", provider: "unknown"), .openAI)
        XCTAssertEqual(ModelMaker(model: "o3-mini", provider: nil), .openAI)
        XCTAssertEqual(ModelMaker(model: "codex-auto-review", provider: "unknown"), .openAI)
        XCTAssertEqual(ModelMaker(model: "grok-4.7", provider: "unknown"), .xAI)
        XCTAssertEqual(ModelMaker(model: "mystery", provider: "xai"), .xAI)
        XCTAssertEqual(ModelMaker(model: "mystery", provider: "amazon-bedrock"), .unknown)
        XCTAssertEqual(ModelMaker(model: "orca", provider: "unknown"), .unknown, "o followed by a non-digit is not an OpenAI reasoning model")
        XCTAssertEqual(ModelMaker.anthropic.letter, "A")
        XCTAssertNil(ModelMaker.unknown.letter)
        XCTAssertEqual(ProviderBadgePalette.fill(.anthropic, isDark: false), 0xD97757)
        XCTAssertEqual(ProviderBadgePalette.fill(.openAI, isDark: true), 0x10A37F)
        XCTAssertEqual(ProviderBadgePalette.fill(.xAI, isDark: false), 0x000000)
        XCTAssertEqual(ProviderBadgePalette.fill(.xAI, isDark: true), 0xFFFFFF)
        XCTAssertEqual(ProviderBadgePalette.letterColor(.xAI, isDark: true), 0x000000)
        XCTAssertEqual(ProviderBadgePalette.letterColor(.xAI, isDark: false), 0xFFFFFF)
    }

    // MARK: Active model selection

    func testFirstQualifyingResponseBecomesActiveAndFlappingIsPrevented() {
        var selector = ActiveModelSelector()
        XCTAssertNil(selector.update(responses: [], now: now))
        let claude = ResponseGroupKey(model: "claude-opus-5-5", provider: "anthropic")
        let codex = ResponseGroupKey(model: "gpt-5-codex", provider: "openai")
        let claudeFirst = [response("c1", secondsAgo: 30, tokens: 1_000)]
        XCTAssertEqual(selector.update(responses: claudeFirst, now: now), claude)

        // Codex leads for 30 s, Claude leads again, Codex leads again: each change resets the clock.
        var responses = claudeFirst + [response("x1", secondsAgo: 20, model: "gpt-5-codex", provider: "openai", client: "codex", tokens: 3_000)]
        XCTAssertEqual(selector.update(responses: responses, now: now.addingTimeInterval(10)), claude)
        responses.append(response("c2", secondsAgo: -40, tokens: 5_000))
        XCTAssertEqual(selector.update(responses: responses, now: now.addingTimeInterval(40)), claude)
        responses.append(response("x2", secondsAgo: -70, model: "gpt-5-codex", provider: "openai", client: "codex", tokens: 9_000))
        XCTAssertEqual(selector.update(responses: responses, now: now.addingTimeInterval(70)), claude)
        XCTAssertEqual(selector.update(responses: responses, now: now.addingTimeInterval(150)), claude, "leader only since t+70 s: 80 s is not enough")
        XCTAssertEqual(selector.update(responses: responses, now: now.addingTimeInterval(190)), codex, "120 s of continuous leadership")
    }

    func testTakeoverNeedsTwoMinutesOfContinuousLeadership() {
        var selector = ActiveModelSelector()
        let claude = ResponseGroupKey(model: "claude-opus-5-5", provider: "anthropic")
        let codex = ResponseGroupKey(model: "gpt-5-codex", provider: "openai")
        let responses = [
            response("c", secondsAgo: 60, tokens: 800),
            response("x", secondsAgo: 30, model: "gpt-5-codex", provider: "openai", client: "codex", tokens: 4_000)
        ]
        XCTAssertEqual(selector.update(responses: [responses[0]], now: now.addingTimeInterval(-60)), claude)
        XCTAssertEqual(selector.update(responses: responses, now: now), claude)
        XCTAssertEqual(selector.update(responses: responses, now: now.addingTimeInterval(119)), claude)
        XCTAssertEqual(selector.update(responses: responses, now: now.addingTimeInterval(120)), codex)
    }

    func testQuietActiveModelIsReplacedAtOnceAndNoLiveDataClearsTheSelection() {
        var selector = ActiveModelSelector()
        let claude = ResponseGroupKey(model: "claude-opus-5-5", provider: "anthropic")
        let codex = ResponseGroupKey(model: "gpt-5-codex", provider: "openai")
        let old = response("c", secondsAgo: 300, tokens: 800)
        XCTAssertEqual(selector.update(responses: [old], now: now.addingTimeInterval(-300)), claude)
        let fresh = response("x", secondsAgo: 0, model: "gpt-5-codex", provider: "openai", client: "codex", tokens: 400)
        // Claude still leads while its response is in the window and Codex has not led for two minutes.
        XCTAssertEqual(selector.update(responses: [old, fresh], now: now.addingTimeInterval(200)), claude)
        // Ten minutes after Claude's last response only Codex is left: it takes over at once.
        XCTAssertEqual(selector.update(responses: [old, fresh], now: now.addingTimeInterval(310)), codex)
        // Everything aged out: no active model, so the dashboard falls back to history.
        XCTAssertNil(selector.update(responses: [old, fresh], now: now.addingTimeInterval(2_000)))
        XCTAssertNil(selector.active)
    }

    func testToolRestrictedAutoOnlyConsidersThatCodingTool() {
        var selector = ActiveModelSelector(clientRestriction: "codex")
        let codex = ResponseGroupKey(model: "gpt-5-codex", provider: "openai")
        let responses = [
            response("c", secondsAgo: 20, tokens: 9_000),
            response("x", secondsAgo: 30, model: "gpt-5-codex", provider: "openai", client: "codex", tokens: 300)
        ]
        XCTAssertEqual(selector.update(responses: responses, now: now), codex)
        selector.clientRestriction = nil
        XCTAssertNil(selector.active, "changing the restriction starts over")
        XCTAssertEqual(selector.update(responses: responses, now: now), ResponseGroupKey(model: "claude-opus-5-5", provider: "anthropic"))
    }

    func testFrequentSmallCodexCheckInsNeverBeatAnActiveClaudeSession() {
        var selector = ActiveModelSelector()
        let claude = ResponseGroupKey(model: "claude-opus-5-5", provider: "anthropic")
        var responses: [LiveResponse] = [response("c0", secondsAgo: 580, tokens: 500)]
        XCTAssertEqual(selector.update(responses: responses, now: now.addingTimeInterval(-580)), claude)
        // A 118-token Codex check-in every five minutes, even 40 of them.
        for index in 0..<40 {
            responses.append(response("x\(index)", secondsAgo: 500 - Double(index) * 5, model: "gpt-5-codex", provider: "openai", client: "codex", tokens: 118))
            responses.append(response("c\(index + 1)", secondsAgo: 500 - Double(index) * 5 - 1, tokens: 500))
            XCTAssertEqual(selector.update(responses: responses, now: now.addingTimeInterval(-500 + Double(index) * 5)), claude)
        }
        // On their own, such check-ins never become active either.
        var alone = ActiveModelSelector()
        XCTAssertNil(alone.update(responses: [response("only", secondsAgo: 5, model: "gpt-5-codex", provider: "openai", client: "codex", tokens: 118)], now: now))
    }

    // MARK: Selection persistence

    func testSelectionRestoresAndMigratesLatestToAuto() {
        XCTAssertEqual(DashboardSelection.restored(from: nil), .auto)
        XCTAssertEqual(DashboardSelection.restored(from: "latest"), .auto)
        XCTAssertEqual(DashboardSelection.restored(from: "auto"), .auto)
        XCTAssertEqual(DashboardSelection.restored(from: "auto:claude-code"), .autoTool("claude-code"))
        XCTAssertEqual(DashboardSelection.restored(from: DashboardSelection.autoTool("codex").persistenceValue), .autoTool("codex"))
        XCTAssertEqual(DashboardSelection.restored(from: "all"), .all)
        XCTAssertEqual(DashboardSelection.restored(from: "garbage"), .auto)
        let cohort = ModelCohort(model: "m", provider: "p", clientVersion: "1", providerRegion: "eu")
        XCTAssertEqual(DashboardSelection.restored(from: DashboardSelection.cohort(cohort).persistenceValue), .cohort(cohort))
        // Selections saved before the provider region existed (seven parts) still restore.
        let legacy = ModelCohort(model: "m", provider: "p", clientVersion: "1")
        XCTAssertEqual(ModelCohort(id: legacy.id)?.providerRegion, nil)
        XCTAssertNotEqual(cohort.id, legacy.id)
    }

    // MARK: Snapshot

    func testAutoSelectionFollowsTheActiveModelElseTheLatestTurnWithResponseData() {
        let opus = turn("opus", secondsAgo: 600, model: "claude-opus-5-5")
        let gpt = turn("gpt", secondsAgo: 300, model: "gpt-5-codex", provider: "openai", client: "codex", parser: "codex-rollout-v2", metricVersion: "turn-v1")
        let grokNoResponse = turn("grok", secondsAgo: 10, model: "grok-4.7", provider: "xai", client: "grok-build", parser: "grok-session-v1", metricVersion: "grok-observed-work-turn-v1", responseSpeed: nil)
        let records = [opus, gpt, grokNoResponse]

        let active = ResponseGroupKey(model: "claude-opus-5-5", provider: "anthropic")
        XCTAssertEqual(DashboardSnapshot(records: records, range: .day, selection: .auto, activeModel: active, now: now).selectedCohort, ModelCohort(opus))
        // No live model: the most recent turn that has response data, not the newer Grok turn.
        XCTAssertEqual(DashboardSnapshot(records: records, range: .day, selection: .auto, now: now).selectedCohort, ModelCohort(gpt))
        XCTAssertEqual(DashboardSnapshot(records: records, range: .day, selection: .autoTool("claude-code"), now: now).selectedCohort, ModelCohort(opus))
        // Only turns without response data: the most recent turn.
        XCTAssertEqual(DashboardSnapshot(records: [grokNoResponse], range: .day, selection: .auto, now: now).selectedCohort, ModelCohort(grokNoResponse))
    }

    func testResponseSpeedMergesCodingToolsAndSourceKindsOfOneModel() throws {
        let primary = (0..<4).map { turn("p\($0)", secondsAgo: Double($0 + 1) * 600, responseSpeed: 100) }
        let subagent = (0..<4).map {
            turn("s\($0)", secondsAgo: Double($0 + 1) * 700, parser: "claude-transcript-v4", metricVersion: "claude-observed-subagent-turn-v1", sourceKind: "subagent", turnSpeed: 4, responseSpeed: 116)
        }
        let otherModel = turn("o", secondsAgo: 100, model: "gpt-5-codex", provider: "openai", client: "codex", parser: "codex-rollout-v2", metricVersion: "turn-v1", responseSpeed: 60)
        let snapshot = DashboardSnapshot(records: primary + subagent + [otherModel], range: .day, selection: .cohort(ModelCohort(primary[0])), now: now)

        XCTAssertEqual(snapshot.response.count, 8)
        XCTAssertEqual(snapshot.responseCount, 16)
        XCTAssertEqual(try XCTUnwrap(snapshot.response.median), 108, accuracy: 0.001)
        // Turn speed keeps the exact cohort.
        XCTAssertEqual(snapshot.throughput.count, 4)
        XCTAssertEqual(try XCTUnwrap(snapshot.responseHero).id, "p0")

        let summary = try XCTUnwrap(snapshot.responseSummaries.first { $0.group.model == "claude-opus-5-5" })
        XCTAssertEqual(snapshot.responseSummaries.count, 2)
        XCTAssertEqual(summary.response.count, 8)
        XCTAssertTrue(summary.includesSubagent)
        XCTAssertEqual(summary.clients, ["claude-code"])
        XCTAssertEqual(summary.latestCohort.metricVersion, "claude-observed-turn-v1", "primary turns are preferred for selection")
        // The turn-speed list still separates measurement groups.
        XCTAssertEqual(snapshot.cohortSummaries.count, 3)
    }

    func testHeroReadingPrefersLiveThenResponseTurnThenTurnFallback() throws {
        let records = (0..<6).map { turn("t\($0)", secondsAgo: Double($0 + 1) * 3_600, turnSpeed: 20, responseSpeed: 100) }
        let cohort = ModelCohort(records[0])
        let snapshot = DashboardSnapshot(records: records, range: .day, selection: .cohort(cohort), now: now)
        let group = ResponseGroupKey(cohort)

        let live = snapshot.heroReading(live: LiveSpeed(medianTPS: 140, responseCount: 5, latestAt: now.addingTimeInterval(-120)), liveGroup: group)
        XCTAssertEqual(live.kind, .live)
        XCTAssertEqual(live.value, 140)
        XCTAssertEqual(live.caption(now: now), "last 5 responses · 2 min ago")
        let delta = try XCTUnwrap(snapshot.speedDelta(for: live))
        XCTAssertEqual(delta.roundedPercent, 40, "against the 24 h response-speed median of 100")
        XCTAssertEqual(delta.summary(medianName: "response-speed median"), "+40% vs your 24 h response-speed median")

        let history = snapshot.heroReading(live: nil, liveGroup: nil)
        XCTAssertEqual(history.kind, .latestTurnResponse)
        XCTAssertEqual(history.value, 100)
        XCTAssertEqual(history.caption(now: now), "latest turn · 1 h ago")

        let noResponse = (0..<3).map { turn("n\($0)", secondsAgo: Double($0 + 1) * 600, turnSpeed: 33, responseSpeed: nil) }
        let fallback = DashboardSnapshot(records: noResponse, range: .day, selection: .cohort(ModelCohort(noResponse[0])), now: now).heroReading(live: nil, liveGroup: nil)
        XCTAssertEqual(fallback.kind, .turnFallback)
        XCTAssertEqual(fallback.value, 33)
        XCTAssertFalse(fallback.usesResponseSpeed)
        XCTAssertEqual(DashboardSnapshot(records: [], range: .day, selection: .auto, now: now).heroReading(live: nil, liveGroup: nil).kind, .empty)
    }

    func testGaugeScaleUsesResponseSpeedMediansOfAllModels() {
        let fast = (0..<3).map { turn("f\($0)", secondsAgo: Double($0 + 1) * 600, model: "fast", responseSpeed: 200) }
        let slow = (0..<3).map { turn("l\($0)", secondsAgo: Double($0 + 1) * 600, model: "slow", responseSpeed: 50) }
        let stale = (0..<3).map { turn("o\($0)", secondsAgo: 2 * 86_400, model: "old", responseSpeed: 900) }
        let snapshot = DashboardSnapshot(records: fast + slow + stale, range: .day, selection: .cohort(ModelCohort(slow[0])), now: now)
        XCTAssertEqual(snapshot.responseGaugeMedian, 200)
    }

    func testResponseTrendIsPrimaryAndTurnSpeedStaysInDetails() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Turn speed is steady while response speed halves: the signal follows response speed.
        let baseline = (0..<20).map { turn("b\($0)", secondsAgo: 40 * 3_600 + Double($0 / 10) * 86_400 + Double($0), turnSpeed: 10, responseSpeed: 100) }
        let current = (0..<5).map { turn("c\($0)", secondsAgo: Double($0) * 60, turnSpeed: 10, responseSpeed: 40) }
        let snapshot = DashboardSnapshot(records: baseline + current, range: .week, selection: .cohort(ModelCohort(current[0])), now: now, calendar: calendar)
        let trend = try XCTUnwrap(snapshot.personalTrend)
        XCTAssertEqual(trend.basis, .response)
        XCTAssertEqual(trend.status, .slower)
        XCTAssertEqual(trend.currentResponse.median, 40)
        XCTAssertEqual(trend.baselineThroughput.median, 10, "turn speed stays available")
        XCTAssertEqual(trend.speedTitle, "Response speed")
        let comparison = try XCTUnwrap(snapshot.localPeriodComparison)
        XCTAssertEqual(comparison.last24Hours.response.median, 40)
        XCTAssertEqual(comparison.last24Hours.throughput.median, 10)
        XCTAssertEqual(snapshot.trendSeries(for: .responseSpeed).stats.count, snapshot.response.count)
        XCTAssertEqual(snapshot.availableTrendMetrics, [.responseSpeed, .turnSpeed])
        XCTAssertFalse(snapshot.responsePoints.isEmpty)
    }

    func testGrokBuildResponseSpeedCarriesTheTurnAverageNoteAndExplanation() {
        let grok = (0..<3).map {
            turn("g\($0)", secondsAgo: Double($0 + 1) * 600, model: "grok-4.7-build", provider: "xai", client: "grok-build",
                 parser: "grok-session-v2", metricVersion: "grok-observed-work-turn-v1", responseSpeed: 70, responses: 4)
        }
        let snapshot = DashboardSnapshot(records: grok, range: .day, selection: .cohort(ModelCohort(grok[0])), now: now)
        XCTAssertFalse(snapshot.responseSpeedUnavailable)
        XCTAssertEqual(snapshot.effectiveTrendMetric(nil), .responseSpeed)
        let hero = snapshot.heroReading(live: nil, liveGroup: nil)
        XCTAssertEqual(hero.kind, .latestTurnResponse)
        XCTAssertEqual(hero.cohort?.client, "grok-build")
        let series = snapshot.trendSeries(for: .responseSpeed)
        XCTAssertFalse(series.points.isEmpty)
        XCTAssertEqual(series.definition, "Grok Build: average over all model calls in a turn")
        XCTAssertTrue(series.help.hasSuffix(ResponseSpeedCopy.grokBuildExplanation))
        XCTAssertEqual(snapshot.responseSummaries.first?.clients, ["grok-build"])

        let claude = (0..<3).map { turn("c\($0)", secondsAgo: Double($0 + 1) * 600) }
        let other = DashboardSnapshot(records: claude, range: .day, selection: .cohort(ModelCohort(claude[0])), now: now)
        XCTAssertEqual(other.trendSeries(for: .responseSpeed).definition, ResponseSpeedCopy.definition)
        XCTAssertFalse(other.trendSeries(for: .responseSpeed).help.contains("Grok Build"))
    }

    func testTrendChartFollowsDataUntilTheUserPicksAMetric() {
        let timed = (0..<3).map { turn("t\($0)", secondsAgo: Double($0 + 1) * 600) }
        let withResponse = DashboardSnapshot(records: timed, range: .day, selection: .cohort(ModelCohort(timed[0])), now: now)
        XCTAssertFalse(withResponse.responseSpeedUnavailable)
        XCTAssertEqual(withResponse.effectiveTrendMetric(nil), .responseSpeed)
        XCTAssertEqual(withResponse.effectiveTrendMetric(.turnSpeed), .turnSpeed)
        XCTAssertEqual(withResponse.trendSeries(for: .responseSpeed).emptyText, "Your next completed response starts the chart.")

        let grok = (0..<3).map {
            turn("g\($0)", secondsAgo: Double($0 + 1) * 600, model: "grok-code-fast-1", provider: "xai", client: "grok-build",
                 parser: "grok-session-v1", metricVersion: "grok-observed-work-turn-v1", responseSpeed: nil)
        }
        let untimed = DashboardSnapshot(records: grok, range: .day, selection: .cohort(ModelCohort(grok[0])), now: now)
        XCTAssertTrue(untimed.responseSpeedUnavailable)
        XCTAssertEqual(untimed.effectiveTrendMetric(nil), .turnSpeed, "automatic follows the data")
        XCTAssertEqual(untimed.effectiveTrendMetric(.responseSpeed), .responseSpeed, "an explicit choice is never overridden")
        XCTAssertEqual(untimed.effectiveTrendMetric(.firstToken), .turnSpeed, "an unavailable choice falls back to automatic")
        let series = untimed.trendSeries(for: .responseSpeed)
        XCTAssertTrue(series.points.isEmpty)
        XCTAssertEqual(series.emptyText, "No response speed for these Grok Build turns: they were recorded before Tokrate 0.1.15.")
        XCTAssertEqual(untimed.availableTrendMetrics, [.responseSpeed, .turnSpeed])

        let other = (0..<3).map { turn("o\($0)", secondsAgo: Double($0 + 1) * 600, responseSpeed: nil) }
        let otherSnapshot = DashboardSnapshot(records: other, range: .day, selection: .cohort(ModelCohort(other[0])), now: now)
        XCTAssertEqual(otherSnapshot.trendSeries(for: .responseSpeed).emptyText, "No response speed for this model yet.")

        let none = DashboardSnapshot(records: [], range: .day, now: now)
        XCTAssertFalse(none.responseSpeedUnavailable)
        XCTAssertEqual(none.effectiveTrendMetric(nil), .responseSpeed, "no turns yet: the chart waits for a response")
    }

    func testSourcesWithoutResponseDataKeepTheTurnSpeedSignal() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let baseline = (0..<20).map { turn("b\($0)", secondsAgo: 40 * 3_600 + Double($0 / 10) * 86_400 + Double($0), turnSpeed: 100, responseSpeed: nil) }
        let current = (0..<5).map { turn("c\($0)", secondsAgo: Double($0) * 60, turnSpeed: 40, responseSpeed: nil) }
        let snapshot = DashboardSnapshot(records: baseline + current, range: .week, selection: .cohort(ModelCohort(current[0])), now: now, calendar: calendar)
        let trend = try XCTUnwrap(snapshot.personalTrend)
        XCTAssertEqual(trend.basis, .turn)
        XCTAssertEqual(trend.status, .slower)
        XCTAssertEqual(trend.speedTitle, "Turn speed")
    }

    func testProviderRegionIsPartOfTheLocalCohortAndItsLabel() {
        func bedrock(_ region: String?) -> TurnMetric {
            TurnMetric(id: "b-\(region ?? "none")", completedAt: now, model: "claude-sonnet-4-5-20250929", outputTokens: 500, durationSeconds: 10,
                       codexTTFTSeconds: nil, turnThroughputTPS: 50, client: "claude-code", clientVersion: "2.1.0",
                       parserVersion: "claude-transcript-v4", metricVersion: "claude-observed-turn-v1", sourceKind: "primary",
                       provider: "amazon-bedrock", providerRegion: region)
        }
        let us = ModelCohort(bedrock("us")), eu = ModelCohort(bedrock("eu")), none = ModelCohort(bedrock(nil))
        XCTAssertEqual(us.providerRegion, "us")
        XCTAssertNotEqual(us, eu)
        XCTAssertNotEqual(us.id, eu.id)
        XCTAssertEqual(ModelCohort(id: eu.id), eu)
        XCTAssertNil(ModelCohort(id: none.id)?.providerRegion)
        XCTAssertTrue(us.detailLabel.contains("Amazon Bedrock (US)"))
        XCTAssertEqual(ModelCohort.regionTitle("us-gov"), "US GovCloud")
        XCTAssertEqual(ModelCohort.regionTitle("unknown"), "region unknown")
        let labels = CohortLabeler.displays(for: [us, eu]).map(\.qualifier)
        XCTAssertEqual(labels, ["Bedrock US", "Bedrock EU"])
        // The public board's cohort identity is defined by the server and does not include the region.
        XCTAssertEqual(us.communityBoardID, eu.communityBoardID)
    }
}
