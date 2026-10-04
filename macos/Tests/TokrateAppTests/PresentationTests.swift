import XCTest
import TokrateCore
@testable import TokrateApp

final class PresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func metric(
        _ id: String, secondsAgo: Double = 60, model: String? = "m", rate: Double,
        client: String = "codex", parser: String = "codex-rollout-v1", metricVersion: String = "turn-v1",
        sourceKind: String? = nil, effort: String? = nil, version: String? = "1.0", provider: String? = "openai"
    ) -> TurnMetric {
        TurnMetric(id: id, completedAt: now.addingTimeInterval(-secondsAgo), model: model, outputTokens: 100, durationSeconds: 10,
                   codexTTFTSeconds: nil, turnThroughputTPS: rate, client: client, clientVersion: version,
                   parserVersion: parser, metricVersion: metricVersion, sourceKind: sourceKind, provider: provider, reasoningEffort: effort)
    }

    // MARK: Delta

    func testSpeedDeltaNeedsThreeTurnsAndPositiveMedian() {
        XCTAssertNil(SpeedDelta(latest: 60, median: MetricStats(values: [50, 50])))
        XCTAssertNil(SpeedDelta(latest: nil, median: MetricStats(values: [50, 50, 50])))
        XCTAssertNil(SpeedDelta(latest: 60, median: MetricStats(values: [0, 0, 0])))
        let delta = SpeedDelta(latest: 56, median: MetricStats(values: [48, 50, 52]))
        XCTAssertEqual(delta?.roundedPercent, 12)
        XCTAssertEqual(delta?.summary, "+12% vs your 24 h median")
        XCTAssertEqual(delta?.accessibilitySummary, "12 percent faster than your 24 hour median")
    }

    func testSpeedDeltaSlowerAndOnPar() {
        let slower = SpeedDelta(latest: 40, median: MetricStats(values: [50, 50, 50]))
        XCTAssertEqual(slower?.summary, "−20% vs your 24 h median")
        XCTAssertEqual(slower?.isSlower, true)
        let level = SpeedDelta(latest: 50.2, median: MetricStats(values: [50, 50, 50]))
        XCTAssertEqual(level?.summary, "On par with your 24 h median")
    }

    func testSnapshotHeroAndDeltaIgnoreTheRangeControl() {
        var records = (1...6).map { metric("r\($0)", secondsAgo: Double($0) * 3_600 * 5, rate: 50) }
        records.append(metric("latest", secondsAgo: 120, rate: 75))
        let day = DashboardSnapshot(records: records, range: .day, now: now)
        let week = DashboardSnapshot(records: records, range: .week, now: now)
        XCTAssertEqual(day.heroMetric?.id, "latest")
        XCTAssertEqual(week.heroMetric?.id, "latest")
        XCTAssertEqual(day.speedDelta?.roundedPercent, week.speedDelta?.roundedPercent)
        XCTAssertNotNil(day.speedDelta)
    }

    func testHeroSurvivesAnEmptyTwentyFourHourRange() {
        let old = metric("old", secondsAgo: 3 * 86_400, rate: 40)
        let snapshot = DashboardSnapshot(records: [old], range: .day, now: now)
        XCTAssertNil(snapshot.latest)
        XCTAssertEqual(snapshot.heroMetric?.id, "old")
    }

    // MARK: Relative time

    func testRelativeTime() {
        func text(_ seconds: Double) -> String { RelativeTime.string(from: now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(text(5), "just now")
        XCTAssertEqual(text(-30), "just now")
        XCTAssertEqual(text(120), "2 min ago")
        XCTAssertEqual(text(50), "1 min ago")
        XCTAssertEqual(text(59 * 60), "59 min ago")
        XCTAssertEqual(text(3 * 3_600 + 10), "3 h ago")
        XCTAssertEqual(text(30 * 3_600), "yesterday")
        XCTAssertEqual(text(4 * 86_400), "4 d ago")
    }

    // MARK: Gauge scale

    func testGaugeScaleUsesNiceCeilingOfOnePointTwoFiveTimesTheMaximum() {
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 0), 20)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 10), 20)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 16), 20)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 17), 25)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 40), 50)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 60), 75)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 62.4), 100)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 80), 100)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 81), 150)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 119.8), 150)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 800), 1000)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: 900), 1250)
        XCTAssertEqual(GaugeScale.niceCeiling(forMaximum: .nan), 20)
    }

    func testHeroGaugeScaleTakesTheLargerOfLatestAndGroupMedian() {
        XCTAssertEqual(GaugeScale.ceiling(for: 30, groupMedian: 70), 100)
        XCTAssertEqual(GaugeScale.ceiling(for: 90, groupMedian: 20), 150)
        XCTAssertEqual(GaugeScale.ceiling(for: 12, groupMedian: nil), 20)
        XCTAssertEqual(GaugeScale.ceiling(for: nil, groupMedian: nil), 100)
        XCTAssertEqual(GaugeScale.progress(value: 50, ceiling: 100), 0.5)
        XCTAssertEqual(GaugeScale.progress(value: 500, ceiling: 100), 1)
    }

    func testGroupMedianOnlyPoolsTheSameClientMetricVersionAndSourceKind() {
        let hero = metric("hero", rate: 60, client: "claude-code", parser: "claude-transcript-v2", metricVersion: "claude-observed-turn-v1", sourceKind: "primary")
        let sameGroupOtherModel = (1...3).map { metric("s\($0)", secondsAgo: Double($0) * 600, model: "other", rate: 90, client: "claude-code", parser: "claude-transcript-v2", metricVersion: "claude-observed-turn-v1", sourceKind: "primary") }
        let subagent = (1...3).map { metric("a\($0)", secondsAgo: Double($0) * 600, model: "sub", rate: 400, client: "claude-code", parser: "claude-transcript-v2", metricVersion: "claude-observed-subagent-turn-v1", sourceKind: "subagent") }
        let codex = (1...3).map { metric("c\($0)", secondsAgo: Double($0) * 600, rate: 300) }
        let stale = (1...3).map { metric("o\($0)", secondsAgo: 2 * 86_400, model: "old", rate: 700, client: "claude-code", parser: "claude-transcript-v2", metricVersion: "claude-observed-turn-v1", sourceKind: "primary") }
        let all = [hero] + sameGroupOtherModel + subagent + codex + stale
        XCTAssertEqual(DashboardSnapshot.groupMedianMaximum(for: hero, in: all, now: now), 90)
        let snapshot = DashboardSnapshot(records: all, range: .day, selection: .cohort(ModelCohort(hero)), now: now)
        XCTAssertEqual(snapshot.gaugeGroupMedian, 90)
    }

    // MARK: Measurement and labels

    func testMeasurementKindsAndNames() {
        XCTAssertEqual(ModelCohort(metric("a", rate: 1)).measurement, .turn)
        let subagent = metric("b", rate: 1, client: "claude-code", parser: "claude-transcript-v2", metricVersion: "claude-observed-subagent-turn-v1", sourceKind: "subagent")
        XCTAssertEqual(ModelCohort(subagent).measurement, .subagent)
        XCTAssertTrue(subagent.isSubagentTurn)
        XCTAssertEqual(SpeedMeasurement.subagent.title, "Subagent turn speed")
        XCTAssertEqual(SpeedMeasurement.workTurn.title, "Work-turn speed")
        XCTAssertEqual(SpeedMeasurement.turn.title, "Turn speed")
        XCTAssertNil(SpeedMeasurement.turn.chipTitle)
        XCTAssertEqual(SpeedMeasurement.subagent.chipTitle, "Subagent")
        XCTAssertEqual(ModelCohort(metric("g", rate: 1, client: "grok-build", parser: "grok-session-v1", metricVersion: "grok-observed-work-turn-v1")).measurement, .workTurn)
        XCTAssertFalse(metric("p", rate: 1, sourceKind: "primary").isSubagentTurn)
        // Unsupported tuples never claim a special measurement.
        XCTAssertEqual(ModelCohort(metric("u", rate: 1, client: "codex", metricVersion: "claude-observed-subagent-turn-v1")).measurement, .turn)
    }

    func testLabelsAddQualifiersOnlyWhenEntriesWouldLookIdentical() {
        let a = ModelCohort(metric("1", model: "gpt", rate: 1, effort: "high", version: "1.0"))
        let b = ModelCohort(metric("2", model: "gpt", rate: 1, effort: "high", version: "2.0"))
        let c = ModelCohort(metric("3", model: "gpt", rate: 1, effort: "low", version: "1.0"))
        let displays = CohortLabeler.displays(for: [a, b, c])
        XCTAssertEqual(displays[0].menuTitle, "gpt · high · v1.0")
        XCTAssertEqual(displays[1].menuTitle, "gpt · high · v2.0")
        XCTAssertEqual(displays[2].menuTitle, "gpt · low")
        XCTAssertNil(displays[2].qualifier)
        let providers = CohortLabeler.displays(for: [
            ModelCohort(metric("4", model: "x", rate: 1, provider: "openai")),
            ModelCohort(metric("5", model: "x", rate: 1, provider: "unknown"))
        ])
        XCTAssertEqual(providers.map(\.qualifier), ["openai", "unknown"])
    }

    func testPickerSectionsGroupByCodingToolInAlphabeticalOrder() {
        let codex = ModelCohort(metric("1", model: "gpt", rate: 1))
        let claude = ModelCohort(metric("2", model: "opus", rate: 1, client: "claude-code", parser: "claude-transcript-v2", metricVersion: "claude-observed-turn-v1"))
        let subagent = ModelCohort(metric("3", model: "sonnet", rate: 1, client: "claude-code", parser: "claude-transcript-v2", metricVersion: "claude-observed-subagent-turn-v1", sourceKind: "subagent"))
        let sections = ModelPickerGrouping.sections(cohorts: [codex, subagent, claude])
        XCTAssertEqual(sections.map(\.title), ["Claude Code", "Codex"])
        XCTAssertEqual(sections[0].entries.map(\.title), ["sonnet", "opus"])
        XCTAssertEqual(sections[0].entries[0].menuTitle, "sonnet · Subagent")
        XCTAssertEqual(ModelPickerGrouping.label(selection: .all, latest: codex, cohorts: [codex]), "All models")
        XCTAssertEqual(ModelPickerGrouping.label(selection: .latest, latest: nil, cohorts: []), "Latest model")
        XCTAssertEqual(ModelPickerGrouping.label(selection: .cohort(claude), latest: codex, cohorts: [codex, claude]), "opus")
    }

    // MARK: Community line

    private func board(state: String = "ready", mode: String? = nil, window: String = "24h", median: Double = 50, id: String) throws -> GlobalBoard {
        let json = """
        {"schemaVersion":1,"collectionEnabled":true,"state":"\(state)","window":"\(window)",
         "methodology":{"publicationMode":\(mode.map { "\"\($0)\"" } ?? "null")},
         "cohorts":[{"id":\(String(data: try JSONEncoder().encode(id), encoding: .utf8)!),"model":"m","provider":"openai","contributors":1,"turns":10,"medianThroughput":\(median)}],"alerts":[]}
        """
        return try JSONDecoder().decode(GlobalBoard.self, from: Data(json.utf8))
    }

    func testCommunityLineComparesTheMatchingWindowAndFlagsCaution() throws {
        let cohort = ModelCohort(metric("1", rate: 60))
        let id = try XCTUnwrap(cohort.communityBoardID)
        let records = (1...5).map { metric("r\($0)", secondsAgo: Double($0) * 600, rate: 60) }
        let local = DashboardSnapshot(records: records, range: .day, now: now).localPeriodComparison

        let faster = try XCTUnwrap(CommunityLine.make(board: board(id: id), cohort: cohort, local: local))
        XCTAssertEqual(faster.position, .faster(percent: 20))
        XCTAssertEqual(faster.positionText, "You're 20% faster")
        XCTAssertNil(faster.caution)
        XCTAssertEqual(faster.windowLabel, "24 h")

        let slower = try XCTUnwrap(CommunityLine.make(board: board(median: 80, id: id), cohort: cohort, local: local))
        XCTAssertEqual(slower.positionText, "You're 25% slower")

        let early = try XCTUnwrap(CommunityLine.make(board: board(state: "insufficient_data", id: id), cohort: cohort, local: local))
        XCTAssertEqual(early.caution, .earlyData)
        let older = try XCTUnwrap(CommunityLine.make(board: board(state: "stale", id: id), cohort: cohort, local: local))
        XCTAssertEqual(older.caution, .older)
        XCTAssertEqual(CommunityLine.make(board: try board(mode: "early_data", id: id), cohort: cohort, local: local)?.caution, .earlyData)

        // A seven day community window is not compared with a 24 h median.
        let week = try XCTUnwrap(CommunityLine.make(board: board(window: "7d", id: id), cohort: cohort, local: local))
        XCTAssertNil(week.position)
        // No exact cohort match, no line.
        XCTAssertNil(CommunityLine.make(board: try board(id: "[\"other\"]"), cohort: cohort, local: local))
    }

    // MARK: Trend runs and the sample payload

    func testTrendRunsBreakOnlyAtLongGapsAndKeepSingleBuckets() {
        let width = DashboardRange.day.duration / Double(DashboardRange.day.bucketCount)
        func bucket(_ index: Double) -> DashboardSnapshot.Bucket {
            DashboardSnapshot.Bucket(date: now.addingTimeInterval(index * width), median: 50, turns: 3)
        }
        let runs = TrendRun.runs(from: [bucket(0), bucket(1), bucket(3), bucket(8), bucket(20), bucket(21)], range: .day)
        XCTAssertEqual(runs.map(\.points.count), [3, 1, 2])
    }

    func testSamplePayloadUsesTheRealUploadFieldsWithFakeValues() throws {
        let data = Data(SamplePayload.exampleJSON().utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let sample = try XCTUnwrap((object["samples"] as? [[String: Any]])?.first)
        let expected: Set<String> = ["sampleId", "observedAt", "client", "clientVersion", "appVersion", "parserVersion", "metricVersion", "model", "provider", "reasoningEffort", "sourceKind", "outputTokens", "reasoningOutputTokens", "durationMs", "ttftMs"]
        XCTAssertEqual(Set(sample.keys), expected)
        XCTAssertEqual(sample["model"] as? String, "example-model")
        XCTAssertFalse(SamplePayload.exampleJSON().contains("example-local-id-never-uploaded"))
    }

    func testSharingStateLabels() {
        XCTAssertEqual(SharingStateLabel.title(isRequested: true, isActive: true, isPending: false), "Sharing on")
        XCTAssertEqual(SharingStateLabel.title(isRequested: true, isActive: false, isPending: false), "Sharing needs attention")
        XCTAssertEqual(SharingStateLabel.title(isRequested: false, isActive: false, isPending: false), "Local only")
        XCTAssertEqual(SharingStateLabel.title(isRequested: false, isActive: false, isPending: true), "Sharing off")
    }

    // MARK: Measurement groups

    func testComparisonGroupsNeverMixMeasurementDefinitionsAndScaleBarsPerGroup() {
        var records: [TurnMetric] = []
        records += (1...3).map { metric("p\($0)", secondsAgo: Double($0) * 900, model: "opus", rate: 58, client: "claude-code", parser: "claude-transcript-v2", metricVersion: "claude-observed-turn-v1", sourceKind: "primary") }
        records += (1...3).map { metric("s\($0)", secondsAgo: Double($0) * 60, model: "sonnet", rate: 120, client: "claude-code", parser: "claude-transcript-v2", metricVersion: "claude-observed-subagent-turn-v1", sourceKind: "subagent") }
        records += (1...3).map { metric("g\($0)", secondsAgo: Double($0) * 1_800, model: "grok", rate: 127, client: "grok-build", parser: "grok-session-v1", metricVersion: "grok-observed-work-turn-v1") }
        records += (1...3).map { metric("c\($0)", secondsAgo: Double($0) * 2_700 + 5_000, model: "gpt", rate: 40) }
        records += (1...3).map { metric("c2-\($0)", secondsAgo: Double($0) * 2_700 + 6_000, model: "gpt", rate: 70, effort: "high") }
        let snapshot = DashboardSnapshot(records: records, range: .day, selection: .all, now: now)
        let groups = MeasurementGrouping.groups(snapshot.cohortSummaries, sort: .recent)
        // Most recently active group first.
        XCTAssertEqual(groups.map(\.title), ["Claude Code · Subagent turn speed", "Claude Code · Turn speed", "Grok Build · Work-turn speed", "Codex · Turn speed"])
        XCTAssertTrue(groups.allSatisfy { group in Set(group.summaries.map(\.cohort.metricVersion)).count == 1 && Set(group.summaries.map(\.cohort.client)).count == 1 })
        // Each bar scale comes from its own group only (1.25 x max median, nice step).
        XCTAssertEqual(groups.map(\.barCeiling), [150, 75, 200, 100])
        // Sorting applies within a group.
        let codex = groups[3]
        XCTAssertEqual(MeasurementGrouping.groups(snapshot.cohortSummaries, sort: .higherThroughput)[3].summaries.map { $0.throughput.median }, [70, 40])
        XCTAssertEqual(codex.summaries.count, 2)
    }
}
