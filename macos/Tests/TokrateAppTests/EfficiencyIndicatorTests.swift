import XCTest
import TokrateCore
@testable import TokrateApp

final class EfficiencyIndicatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func turn(
        _ id: String,
        secondsAgo: Double = 60,
        model: String? = "gpt-5",
        tokens: Int = 1_000,
        delegated: Int? = 0,
        effort: String? = "high",
        client: String = "codex",
        parser: String = "codex-rollout-v2",
        metricVersion: String = "turn-v1",
        sourceKind: String? = "primary",
        provider: String? = "openai",
        reasoning: Int? = nil
    ) -> TurnMetric {
        TurnMetric(
            id: id, completedAt: now.addingTimeInterval(-secondsAgo), model: model, outputTokens: tokens, durationSeconds: 10,
            codexTTFTSeconds: nil, turnThroughputTPS: Double(tokens) / 10, client: client, clientVersion: "1.0",
            parserVersion: parser, metricVersion: metricVersion, reasoningOutputTokens: reasoning, sourceKind: sourceKind,
            provider: provider, reasoningEffort: effort, delegatedOutputTokens: delegated
        )
    }

    private func turns(_ count: Int, prefix: String, tokens: Int, secondsAgo: Double = 100, step: Double = 60, delegated: Int? = 0, model: String? = "gpt-5", effort: String? = "high", client: String = "codex", parser: String = "codex-rollout-v2", metricVersion: String = "turn-v1", provider: String? = "openai") -> [TurnMetric] {
        (0..<count).map { turn("\(prefix)\($0)", secondsAgo: secondsAgo + Double($0) * step, model: model, tokens: tokens, delegated: delegated, effort: effort, client: client, parser: parser, metricVersion: metricVersion, provider: provider) }
    }

    // MARK: Eligibility

    func testTotalIsOutputPlusDelegatedAndNeedsAFinalDelegatedValue() {
        XCTAssertEqual(EfficiencyIndicator.totalTokens(turn("a", tokens: 900, delegated: 300)), 1_200)
        XCTAssertEqual(EfficiencyIndicator.totalTokens(turn("b", tokens: 900, delegated: 0)), 900)
        XCTAssertNil(EfficiencyIndicator.totalTokens(turn("c", tokens: 900, delegated: nil)), "attribution not final yet")
    }

    func testEligibilityNeedsPrimaryKnownModelSupportedTupleFinalDelegationAndTheFloor() {
        XCTAssertEqual(EfficiencyIndicator.eligibleTotal(turn("ok")), 1_000)
        // The 200-token floor applies to the total: output plus delegated.
        XCTAssertEqual(EfficiencyIndicator.eligibleTotal(turn("edge", tokens: 150, delegated: 50)), 200)
        XCTAssertNil(EfficiencyIndicator.eligibleTotal(turn("below", tokens: 150, delegated: 49)))
        XCTAssertNil(EfficiencyIndicator.eligibleTotal(turn("nil-delegated", delegated: nil)))
        XCTAssertNil(EfficiencyIndicator.eligibleTotal(turn("subagent", sourceKind: "subagent")))
        XCTAssertNil(EfficiencyIndicator.eligibleTotal(turn("legacy-no-kind", sourceKind: nil)))
        XCTAssertNil(EfficiencyIndicator.eligibleTotal(turn("no-model", model: nil)))
        XCTAssertNil(EfficiencyIndicator.eligibleTotal(turn("empty-model", model: "")))
        XCTAssertNil(EfficiencyIndicator.eligibleTotal(turn("bad-tuple", parser: "codex-rollout-v9")))
    }

    func testNonEligibleTurnsNeverReachTheReferenceOrRows() {
        let eligible = turns(20, prefix: "e", tokens: 1_000)
        let noise = [turn("sub", tokens: 90_000, sourceKind: "subagent"), turn("open", tokens: 90_000, delegated: nil), turn("tiny", tokens: 50)]
        let reference = EfficiencyIndicator.reference(in: eligible + noise)
        XCTAssertEqual(reference, EfficiencyIndicator.Reference(median: 1_000, turns: 20))
        XCTAssertEqual(EfficiencyIndicator.rows(in: eligible + noise, reference: reference).map(\.turns), [20])
    }

    // MARK: Groups, floors and rounding

    func testGroupsCombineToolsProvidersAndVersionsButNotEffort() {
        let records = turns(10, prefix: "codex", tokens: 1_000)
            + turns(10, prefix: "claude", tokens: 1_000, client: "claude-code", parser: "claude-transcript-v4", metricVersion: "claude-observed-turn-v1", provider: "anthropic")
            + turns(7, prefix: "other-effort", tokens: 1_000, effort: "low")
            + turns(6, prefix: "no-effort", tokens: 1_000, effort: nil)
        let rows = EfficiencyIndicator.rows(in: records, reference: EfficiencyIndicator.reference(in: records))
        let byEffort = Dictionary(uniqueKeysWithValues: rows.map { ($0.effort, $0) })
        XCTAssertEqual(Set(byEffort.keys), ["high", "low", "unknown"], "a missing effort is its own `unknown` group")
        XCTAssertEqual(byEffort["high"]?.turns, 20, "Codex and Claude Code turns of one model and effort share a row")
        XCTAssertNil(byEffort["high"]?.provider, "several providers: no single provider")
        XCTAssertEqual(byEffort["low"]?.provider, "openai")
    }

    func testIndicatorNeedsTwentyEligibleTurnsPerGroupAndForTheReference() {
        let few = turns(19, prefix: "few", tokens: 1_000)
        XCTAssertNil(EfficiencyIndicator.reference(in: few), "the reference needs 20 eligible turns overall")
        XCTAssertNil(EfficiencyIndicator.rows(in: few, reference: nil).first?.indicator)

        let typical = turns(20, prefix: "typical", tokens: 1_000)
        let lean = turns(20, prefix: "lean", tokens: 500, model: "lean-model")
        let small = turns(19, prefix: "small", tokens: 4_000, model: "small-model")
        let all = typical + lean + small
        let reference = EfficiencyIndicator.reference(in: all)
        XCTAssertEqual(reference?.turns, 59)
        let rows = Dictionary(uniqueKeysWithValues: EfficiencyIndicator.rows(in: all, reference: reference).map { ($0.model, $0) })
        XCTAssertEqual(rows["gpt-5"]?.indicator, 100, "R is 1000, the group median is 1000")
        XCTAssertEqual(rows["lean-model"]?.indicator, 200, "half the tokens")
        XCTAssertNil(rows["small-model"]?.indicator, "19 of 20 requests")
        XCTAssertEqual(rows["small-model"]?.turns, 19)
    }

    func testIndicatorRoundsToTheNearestInteger() {
        XCTAssertEqual(EfficiencyIndicator.indicator(reference: 1_000, median: 1_500), 67)
        XCTAssertEqual(EfficiencyIndicator.indicator(reference: 1_000, median: 3_000), 33)
        XCTAssertEqual(EfficiencyIndicator.indicator(reference: 1_050, median: 1_000), 105)
        XCTAssertEqual(EfficiencyIndicator.indicator(reference: 1_005, median: 1_000), 101)
        XCTAssertEqual(EfficiencyIndicator.indicator(reference: 1_000, median: 2_000), 50)
    }

    func testReferenceIsTheMedianOverAllEligibleTurnsNotOfGroupMedians() {
        // 30 turns of 1000 and 10 of 9000: the pooled median is 1000 (a median of group medians would be 5000).
        let records = turns(30, prefix: "a", tokens: 1_000) + turns(10, prefix: "b", tokens: 9_000, model: "other")
        XCTAssertEqual(EfficiencyIndicator.reference(in: records)?.median, 1_000)
    }

    // MARK: Statistics

    func testPercentilesInterpolateLinearly() {
        XCTAssertEqual(EfficiencyIndicator.percentile([1, 2, 3, 4, 5], 0.25), 2)
        XCTAssertEqual(EfficiencyIndicator.percentile([1, 2, 3, 4, 5], 0.75), 4)
        XCTAssertEqual(EfficiencyIndicator.percentile([10, 20], 0.5), 15)
        XCTAssertEqual(EfficiencyIndicator.percentile([10, 20, 30, 40], 0.25), 17.5)
        XCTAssertEqual(EfficiencyIndicator.percentile([7], 0.75), 7)
        XCTAssertNil(EfficiencyIndicator.percentile([], 0.5))
    }

    func testDetailStatisticsOfAGroup() throws {
        // 20 turns: totals 1000...1950 in steps of 50, so p25 = 1237.5, median = 1475, p75 = 1712.5.
        // Only the first two report reasoning tokens (50% and 25% of their output).
        let records = (0..<20).map { index in
            turn("t\(index)", secondsAgo: 100 + Double(index), tokens: 1_000 + index * 50, delegated: 0, reasoning: index == 0 ? 500 : index == 1 ? 262 : nil)
        }
        let reference = EfficiencyIndicator.reference(in: records)
        let row = try XCTUnwrap(EfficiencyIndicator.rows(in: records, reference: reference).first)
        XCTAssertEqual(row.turns, 20)
        XCTAssertEqual(row.medianTokens, 1_475, accuracy: 0.001)
        XCTAssertEqual(row.p25Tokens, 1_237.5, accuracy: 0.001)
        XCTAssertEqual(row.p75Tokens, 1_712.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.reasoningShare), (0.5 + 262.0 / 1_050) / 2, accuracy: 0.0001, "median over turns that report reasoning tokens")
        XCTAssertEqual(row.delegatedShare, 0)
        XCTAssertEqual(row.indicator, 100)
        XCTAssertEqual(row.latestAt, now.addingTimeInterval(-100))
    }

    func testReasoningShareIsNilWithoutReasoningTokensAndDelegatedShareIsTheTokenShare() throws {
        let records = turns(10, prefix: "a", tokens: 800, delegated: 200) + turns(10, prefix: "b", tokens: 1_000, delegated: 0)
        let row = try XCTUnwrap(EfficiencyIndicator.rows(in: records, reference: EfficiencyIndicator.reference(in: records)).first)
        XCTAssertNil(row.reasoningShare)
        // Σ delegated / Σ total = 2000 / 20000.
        XCTAssertEqual(row.delegatedShare, 0.1, accuracy: 0.0001)
        XCTAssertEqual(row.medianTokens, 1_000)
    }

    func testRowsOrderByIndicatorThenEvidenceAndByRecency() {
        func row(_ model: String, indicator: Int?, turns: Int, ago: Double) -> EfficiencyIndicator.Row {
            EfficiencyIndicator.Row(group: .init(model: model, effort: "high"), provider: nil, turns: turns, indicator: indicator, medianTokens: 1, p25Tokens: 1, p75Tokens: 1, reasoningShare: nil, delegatedShare: 0, latestAt: now.addingTimeInterval(-ago))
        }
        let rows = [row("c", indicator: nil, turns: 5, ago: 10), row("a", indicator: 120, turns: 30, ago: 300), row("d", indicator: nil, turns: 12, ago: 400), row("b", indicator: 180, turns: 25, ago: 200)]
        XCTAssertEqual(EfficiencyIndicator.ordered(rows, by: .higher).map(\.model), ["b", "a", "d", "c"])
        XCTAssertEqual(EfficiencyIndicator.ordered(rows, by: .recent).map(\.model), ["c", "b", "a", "d"])
        XCTAssertEqual(EfficiencyIndicator.scaleMaximum(rows), 180)
        XCTAssertEqual(EfficiencyIndicator.scaleMaximum([row("x", indicator: 60, turns: 20, ago: 0)]), 100, "the scale never drops below the 100 tick")
    }

    // MARK: Chart buckets

    func testBucketsNeedThreeEligibleTurnsAndUseTheSharedReference() throws {
        let start = now.addingTimeInterval(-86_400)
        // Hourly buckets: three turns land in bucket 5, two in bucket 6 (a gap).
        let hour = 3_600.0
        let bucket5 = (0..<3).map { turn("a\($0)", secondsAgo: 86_400 - 5 * hour - 600 - Double($0), tokens: 500) }
        let bucket6 = (0..<2).map { turn("b\($0)", secondsAgo: 86_400 - 6 * hour - 600 - Double($0), tokens: 500) }
        let background = turns(20, prefix: "bg", tokens: 1_000, model: "other", effort: "low")
        let records = bucket5 + bucket6 + background
        let reference = try XCTUnwrap(EfficiencyIndicator.reference(in: records))
        let group = EfficiencyIndicator.Key(model: "gpt-5", effort: "high")
        let points = EfficiencyIndicator.points(in: records, group: group, reference: reference, start: start, now: now, duration: 86_400, bucketCount: 24)
        XCTAssertEqual(points.count, 1)
        // R over 25 turns (500 x5, 1000 x20) is 1000; the bucket median is 500: indicator 200.
        XCTAssertEqual(points.first?.median, 200)
        XCTAssertEqual(points.first?.turns, 3)
        XCTAssertEqual(points.first?.date, start.addingTimeInterval(5.5 * hour))
        // Without a reference a group bucket is a gap.
        XCTAssertTrue(EfficiencyIndicator.points(in: records, group: group, reference: nil, start: start, now: now, duration: 86_400, bucketCount: 24).isEmpty)
    }

    func testAllModelsBucketsPlotMedianTokensPerRequest() {
        let start = now.addingTimeInterval(-86_400)
        let records = turns(4, prefix: "a", tokens: 1_000) + turns(4, prefix: "b", tokens: 3_000, model: "other", effort: "low")
        let points = EfficiencyIndicator.points(in: records, group: nil, reference: nil, start: start, now: now, duration: 86_400, bucketCount: 24)
        XCTAssertEqual(points.map(\.median), [2_000], "the reference itself, in tokens, even without a reference value")
        XCTAssertEqual(points.map(\.turns), [8])
    }

    func testBucketsIgnoreOtherGroupsAndTurnsOutsideTheRange() {
        let start = now.addingTimeInterval(-86_400)
        let inside = turns(3, prefix: "in", tokens: 1_000)
        let outside = turns(5, prefix: "old", tokens: 1_000, secondsAgo: 90_000)
        let other = turns(5, prefix: "other", tokens: 1_000, model: "other")
        let reference = EfficiencyIndicator.Reference(median: 1_000, turns: 40)
        let points = EfficiencyIndicator.points(in: inside + outside + other, group: .init(model: "gpt-5", effort: "high"), reference: reference, start: start, now: now, duration: 86_400, bucketCount: 24)
        XCTAssertEqual(points.map(\.turns), [3])
    }

    // MARK: Formatting

    func testCompactTokensAndPercentText() {
        XCTAssertEqual(EfficiencyIndicator.compactTokens(950), "950")
        XCTAssertEqual(EfficiencyIndicator.compactTokens(4_900), "4.9k")
        XCTAssertEqual(EfficiencyIndicator.compactTokens(1_000), "1k")
        XCTAssertEqual(EfficiencyIndicator.compactTokens(12_300), "12k")
        XCTAssertEqual(EfficiencyIndicator.compactTokens(1_250_000), "1.3M")
        XCTAssertEqual(EfficiencyIndicator.compactTokens(1_237.5), "1.2k")
        XCTAssertEqual(EfficiencyIndicator.percentText(0.376), "38%")
        XCTAssertEqual(EfficiencyIndicator.percentText(nil), "—")
    }

    // MARK: Snapshot and presentation

    private func twoGroupHistory() -> [TurnMetric] {
        // GPT-5 high: 25 requests of 1000 tokens in the last half hour. Opus (no effort): 25 requests of
        // 5000 tokens two to three days ago. R = median of the pooled 50 = 3000.
        turns(25, prefix: "g", tokens: 1_000)
            + turns(25, prefix: "o", tokens: 5_000, secondsAgo: 2 * 86_400, step: 600, model: "claude-opus-5", effort: nil, client: "claude-code", parser: "claude-transcript-v4", metricVersion: "claude-observed-turn-v1", provider: "anthropic")
    }

    func testSnapshotEfficiencyCoversTheWholeHistoryWhateverTheRange() throws {
        let records = twoGroupHistory()
        let cohort = ModelCohort(records[0])
        let day = DashboardSnapshot(records: records, range: .day, selection: .cohort(cohort), now: now)
        let week = DashboardSnapshot(records: records, range: .week, selection: .cohort(cohort), now: now)
        XCTAssertEqual(day.efficiencyRows, week.efficiencyRows)
        XCTAssertEqual(day.efficiencyReference, week.efficiencyReference)
        XCTAssertEqual(day.efficiencyReference, EfficiencyIndicator.Reference(median: 3_000, turns: 50))
        let selected = try XCTUnwrap(day.efficiencySelected)
        XCTAssertEqual(selected.model, "gpt-5")
        XCTAssertEqual(selected.indicator, 300)
        XCTAssertEqual(day.efficiencyRows.first { $0.model == "claude-opus-5" }?.indicator, 60)
        XCTAssertEqual(day.efficiencyRows.first { $0.model == "claude-opus-5" }?.effort, "unknown")
        // Chart points: the selected group only, one hourly bucket in 24 h and one six-hourly bucket in 7 d.
        XCTAssertEqual(day.efficiencyPoints.map(\.median), [300])
        XCTAssertEqual(week.efficiencyPoints.map(\.median), [300])
    }

    func testSnapshotAllModelsPlotsTokensPerRequestAndKeepsTheRows() {
        let records = twoGroupHistory()
        let snapshot = DashboardSnapshot(records: records, range: .week, selection: .all, now: now)
        XCTAssertNil(snapshot.efficiencySelected)
        XCTAssertEqual(snapshot.efficiencyRows.count, 2)
        XCTAssertEqual(snapshot.efficiencyPoints.last?.median, 1_000, "the newest bucket holds only GPT-5 requests")
        XCTAssertTrue(snapshot.efficiencyPoints.contains { $0.median == 5_000 })
    }

    func testSnapshotEfficiencyRespectsTheCodingToolFilterAndRetention() {
        let old = turns(30, prefix: "old", tokens: 1_000, secondsAgo: 8 * 86_400)
        let snapshot = DashboardSnapshot(records: twoGroupHistory() + old, range: .day, selection: .all, now: now, clientFilter: "codex")
        XCTAssertEqual(snapshot.efficiencyRows.map(\.model), ["gpt-5"])
        XCTAssertEqual(snapshot.efficiencyRows.first?.turns, 25, "history older than seven days is out")
        XCTAssertEqual(snapshot.efficiencyRows.first?.indicator, 100, "a lone group is the reference itself")
    }

    func testSelectedGroupBelowTheFloorShowsProgressAndNoIndicator() throws {
        let records = turns(25, prefix: "g", tokens: 1_000) + turns(12, prefix: "n", tokens: 2_000, model: "new-model")
        let snapshot = DashboardSnapshot(records: records, range: .day, selection: .cohort(ModelCohort(records.last!)), now: now)
        let selected = try XCTUnwrap(snapshot.efficiencySelected)
        XCTAssertEqual(selected.turns, 12)
        XCTAssertNil(selected.indicator)
        let series = snapshot.trendSeries(for: .efficiency)
        XCTAssertEqual(series.summary?.line, "12 of 20 requests in 7 d")
        XCTAssertEqual(series.emptyText, EfficiencyCopy.insufficient)
    }

    func testEfficiencyTrendSeriesIsUnitlessWithTheSpecCopy() throws {
        let records = twoGroupHistory()
        let snapshot = DashboardSnapshot(records: records, range: .day, selection: .cohort(ModelCohort(records[0])), now: now)
        XCTAssertEqual(snapshot.availableTrendMetrics.last, .efficiency)
        XCTAssertNotEqual(snapshot.effectiveTrendMetric(nil), .efficiency, "automatic never picks efficiency")
        XCTAssertEqual(snapshot.effectiveTrendMetric(.efficiency), .efficiency)
        XCTAssertEqual(TrendMetric.efficiency.shortTitle, "Efficiency")
        let series = snapshot.trendSeries(for: .efficiency)
        XCTAssertEqual(series.title, "Efficiency indicator")
        XCTAssertEqual(series.unit, "")
        XCTAssertEqual(series.digits, 0)
        XCTAssertEqual(series.value(300), "300")
        XCTAssertEqual(series.bucketCount, 24)
        XCTAssertEqual(series.definition, "Fewer output tokens per request scores higher. 100 = a typical request.")
        XCTAssertEqual(series.summary?.line, "300 indicator · 25 requests in 7 d")
        XCTAssertEqual(series.statsLine(range: .day), "300 indicator · 25 requests in 7 d")
        XCTAssertFalse(series.statsAccessibility(range: .day).contains("tokens per second"))
        XCTAssertEqual(series.emptyText, "Not enough requests in this range")
        XCTAssertTrue(series.help.contains("An interval needs 3 eligible requests"))
    }

    func testEfficiencyTrendRunsUseTheirOwnBucketWidth() {
        let width = DashboardRange.day.duration / Double(DashboardRange.day.efficiencyBucketCount)
        func bucket(_ index: Double) -> DashboardSnapshot.Bucket {
            DashboardSnapshot.Bucket(date: now.addingTimeInterval(index * width), median: 120, turns: 3)
        }
        // Adjacent and one-empty-bucket spacing join; two empty buckets leave a gap.
        let runs = TrendRun.runs(from: [bucket(0), bucket(2), bucket(5)], range: .day, bucketCount: DashboardRange.day.efficiencyBucketCount)
        XCTAssertEqual(runs.map(\.points.count), [2, 1])
    }

    func testEfficiencyCopyIsTheSpecWording() {
        XCTAssertEqual(EfficiencyCopy.title, "Efficiency indicator")
        XCTAssertEqual(EfficiencyCopy.shortTitle, "Efficiency")
        XCTAssertEqual(EfficiencyCopy.badge, "Indicator")
        XCTAssertEqual(EfficiencyCopy.insufficient, "Not enough requests yet: the efficiency indicator needs 20 eligible requests per model.")
        XCTAssertEqual(EfficiencyCopy.explanation, "The efficiency indicator compares the median output tokens a model spends to finish one of your requests (reasoning and delegated subagent work included) with the median across all your requests in the last 7 days. 100 is typical; 200 means half the tokens. It is an indicator, not a benchmark: it depends on what you ask each model to do, requests under 200 tokens are left out, and answer quality is not measured.")
        XCTAssertEqual(EfficiencyCopy.requestsOfFloor(12), "12 of 20 requests")
        XCTAssertEqual(EfficiencyCopy.requestCount(1), "1 request")
        XCTAssertEqual(EfficiencyCopy.requestCount(87), "87 requests")
        XCTAssertEqual(EfficiencyCopy.effortChip("unknown"), "effort unknown")
        XCTAssertEqual(EfficiencyCopy.effortChip("high"), "high")
        XCTAssertEqual(ComparisonMetric.allCases.map(\.title), ["Response speed", "Turn speed", "Efficiency"])
        XCTAssertEqual(EfficiencyComparisonSort.allCases.map(\.title), ["Most recent", "Higher efficiency"])
    }
}
