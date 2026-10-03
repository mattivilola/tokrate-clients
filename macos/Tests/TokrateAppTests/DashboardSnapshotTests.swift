import XCTest
import TokrateCore
@testable import TokrateApp

final class DashboardSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func metric(
        _ id: String,
        secondsAgo: Double,
        model: String? = "test-model",
        provider: String? = "openai",
        clientVersion: String? = "0.159.2",
        outputTokens: Int = 100,
        rate: Double,
        ttft: Double? = nil,
        reasoningEffort: String? = nil
    ) -> TurnMetric {
        TurnMetric(
            id: id,
            completedAt: now.addingTimeInterval(-secondsAgo),
            model: model,
            outputTokens: outputTokens,
            durationSeconds: 10,
            codexTTFTSeconds: ttft,
            turnThroughputTPS: rate,
            clientVersion: clientVersion,
            provider: provider,
            reasoningEffort: reasoningEffort
        )
    }

    func testFiftyThousandTurnsProduceAtMostFiftySixChartPoints() {
        let records = (0..<50_000).map { metric("\($0)", secondsAgo: Double($0) * 12, rate: Double($0 % 100)) }
        let snapshot = DashboardSnapshot(records: records, range: .week, now: now)
        XCTAssertEqual(snapshot.throughput.count, 50_000)
        XCTAssertLessThanOrEqual(snapshot.points.count, 56)
        XCTAssertEqual(snapshot.points.reduce(0) { $0 + $1.turns }, 50_000)
        XCTAssertEqual(snapshot.medianRate, 49.5)
        XCTAssertTrue(snapshot.points.allSatisfy { snapshot.dates.contains($0.date) })
    }

    func testSelectionUsesLatestCohortOrExactModelProviderAndClientVersion() {
        let old = metric("old", secondsAgo: 600, model: "gpt-s", clientVersion: "1.0", rate: 10)
        let selected = metric("selected", secondsAgo: 500, model: "gpt-s", clientVersion: "1.0", rate: 30)
        let otherVersion = metric("version", secondsAgo: 20, model: "gpt-s", clientVersion: "2.0", rate: 200)
        let otherProvider = metric("provider", secondsAgo: 10, model: "gpt-s", provider: "other", clientVersion: "1.0", rate: 300)
        let records = [old, selected, otherVersion, otherProvider]

        let latest = DashboardSnapshot(records: records, range: .week, selection: .latest, now: now)
        XCTAssertEqual(latest.selectedCohort, ModelCohort(otherProvider))
        XCTAssertEqual(latest.records.map(\.id), [otherProvider.id])

        let cohort = ModelCohort(model: "gpt-s", provider: "openai", clientVersion: "1.0")
        let selectedSnapshot = DashboardSnapshot(records: records, range: .week, selection: .cohort(cohort), now: now)
        XCTAssertEqual(Set(selectedSnapshot.records.map(\.id)), Set([old.id, selected.id]))
        XCTAssertEqual(selectedSnapshot.throughput.median, 20)
        XCTAssertEqual(selectedSnapshot.throughput.count, 2)
        XCTAssertEqual(DashboardSelection.restored(from: DashboardSelection.cohort(cohort).persistenceValue), .cohort(cohort))

        let all = DashboardSnapshot(records: records, range: .week, selection: .all, now: now)
        XCTAssertNil(all.latest)
        XCTAssertNil(all.medianRate)
        XCTAssertNil(all.medianTTFT)
        XCTAssertTrue(all.points.isEmpty)
        XCTAssertEqual(all.cohortSummaries.count, 3)
        XCTAssertEqual(all.cohortSummaries.map(\.throughput.count).sorted(), [1, 1, 2])
    }

    func testRollingRangesUseEligibleTurnsAndMetricSpecificMissingCounts() {
        let records = [
            metric("1h", secondsAgo: 3_600, rate: 10),
            metric("10h", secondsAgo: 36_000, rate: 20, ttft: 1),
            metric("25h", secondsAgo: 90_000, rate: 30, ttft: 3),
            metric("6d", secondsAgo: 6 * 86_400, rate: 40),
            metric("short", secondsAgo: 100, outputTokens: 19, rate: 999, ttft: 0.5),
            metric("old", secondsAgo: 8 * 86_400, rate: 700)
        ]
        let day = DashboardSnapshot(records: records, range: .day, now: now)
        XCTAssertEqual(day.throughput.count, 2)
        XCTAssertEqual(day.throughput.median, 15)
        XCTAssertEqual(day.throughput.minimum, 10)
        XCTAssertEqual(day.throughput.maximum, 20)
        XCTAssertEqual(day.ttft.count, 2)
        XCTAssertEqual(day.ttft.median, 0.75)
        XCTAssertEqual(day.latest?.id, "1h")
        XCTAssertEqual(day.turnCount, 2)
        XCTAssertTrue(day.dates.contains(now.addingTimeInterval(-86_400)))

        let week = DashboardSnapshot(records: records, range: .week, now: now)
        XCTAssertEqual(week.throughput.count, 4)
        XCTAssertEqual(week.throughput.median, 25)
        XCTAssertEqual(week.throughput.minimum, 10)
        XCTAssertEqual(week.throughput.maximum, 40)
        XCTAssertEqual(week.ttft.count, 3)
        XCTAssertEqual(week.ttft.minimum, 0.5)
        XCTAssertEqual(week.ttft.maximum, 3)
    }

    func testReasoningEffortSplitsCohortsAndLegacySelectionsRestoreAsUnknown() {
        let records = [
            metric("high", secondsAgo: 20, model: "gpt-s", clientVersion: "1.0", rate: 10, reasoningEffort: "high"),
            metric("low", secondsAgo: 10, model: "gpt-s", clientVersion: "1.0", rate: 20, reasoningEffort: "low"),
            metric("unknown", secondsAgo: 5, model: "gpt-s", clientVersion: "1.0", rate: 30)
        ]
        let all = DashboardSnapshot(records: records, range: .day, selection: .all, now: now)
        XCTAssertEqual(all.cohortSummaries.count, 3)
        XCTAssertEqual(Set(all.cohortSummaries.map(\.cohort.reasoningEffort)), Set(["high", "low", nil]))
        XCTAssertTrue(all.cohortSummaries.allSatisfy { $0.cohort.detailLabel.contains("reasoning effort") })

        let high = ModelCohort(model: "gpt-s", provider: "openai", clientVersion: "1.0", reasoningEffort: "high")
        let selected = DashboardSnapshot(records: records, range: .day, selection: .cohort(high), now: now)
        XCTAssertEqual(selected.records.map(\.id), ["high"])
        XCTAssertEqual(DashboardSelection.restored(from: DashboardSelection.cohort(high).persistenceValue), .cohort(high))
        XCTAssertEqual(high.communityBoardID, #"["gpt-s","openai","1.0","codex-rollout-v1","turn-v1","high","codex"]"#)

        let oldParts = ["gpt-s", "openai", "1.0"].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
        let restoredLegacy = try! XCTUnwrap(ModelCohort(id: oldParts))
        XCTAssertNil(restoredLegacy.reasoningEffort)
        XCTAssertEqual(restoredLegacy, ModelCohort(model: "gpt-s", provider: "openai", clientVersion: "1.0"))
        XCTAssertEqual(DashboardSelection.restored(from: "cohort:\(oldParts)"), .cohort(restoredLegacy))
    }

    func testLocalPeriodComparisonKeepsMetricCountsIndependentAndRequiresFiveValues() {
        let current = (0..<5).map { index in
            metric("current-\(index)", secondsAgo: Double(index + 1) * 60, rate: 20, ttft: index < 4 ? 2 : nil, reasoningEffort: "high")
        }
        let previous = (0..<5).map { index in
            metric("previous-\(index)", secondsAgo: 90_000 + Double(index), rate: 10, ttft: 1, reasoningEffort: "high")
        }
        let otherEffort = (0..<5).map { index in
            metric("other-\(index)", secondsAgo: Double(index + 1) * 30, rate: 999, ttft: 0.01, reasoningEffort: "low")
        }
        let selected = ModelCohort(model: "test-model", provider: "openai", clientVersion: "0.159.2", reasoningEffort: "high")
        let day = DashboardSnapshot(records: current + previous + otherEffort, range: .day, selection: .cohort(selected), now: now)
        let comparison = try! XCTUnwrap(day.localPeriodComparison)

        XCTAssertEqual(comparison.recent15Minutes.throughput.count, 5)
        XCTAssertEqual(comparison.last24Hours.throughput.count, 5)
        XCTAssertEqual(comparison.last24Hours.throughput.median, 20)
        XCTAssertEqual(comparison.previous24Hours.throughput.count, 5)
        XCTAssertEqual(comparison.throughputChangePercent, 100)
        XCTAssertEqual(comparison.last24Hours.ttft.count, 4)
        XCTAssertEqual(comparison.previous24Hours.ttft.count, 5)
        XCTAssertNil(comparison.ttftChangePercent)
        XCTAssertNotNil(comparison.previousRange)
    }

    func testLocalPercentChangeIsNilForInsufficientSamplesOrZeroBaselineAndWeekHasNoPriorWeek() {
        let fourCurrent = (0..<4).map { index in
            metric("four-current-\(index)", secondsAgo: Double(index + 1) * 60, rate: 10, ttft: 1)
        }
        let zeroPrevious = (0..<5).map { index in
            metric("zero-previous-\(index)", secondsAgo: 90_000 + Double(index), rate: 0, ttft: 0)
        }
        let insufficient = DashboardSnapshot(records: fourCurrent + zeroPrevious, range: .day, now: now)
        XCTAssertEqual(insufficient.localPeriodComparison?.last24Hours.throughput.count, 4)
        XCTAssertNil(insufficient.localPeriodComparison?.throughputChangePercent)
        XCTAssertNil(insufficient.localPeriodComparison?.ttftChangePercent)

        let current = (0..<5).map { index in
            metric("current-\(index)", secondsAgo: Double(index + 1) * 60, rate: 10, ttft: 1)
        }
        let enoughZeroBaseline = DashboardSnapshot(records: current + zeroPrevious, range: .day, now: now)
        XCTAssertNil(enoughZeroBaseline.localPeriodComparison?.throughputChangePercent)
        XCTAssertNil(enoughZeroBaseline.localPeriodComparison?.ttftChangePercent)

        let week = DashboardSnapshot(records: current + zeroPrevious, range: .week, now: now)
        XCTAssertNil(week.localPeriodComparison?.previousRange)
        XCTAssertEqual(week.localPeriodComparison?.range, .week)
    }

    func testAllModelOrderingUsesNeutralDefaultAndLeavesMissingSpeedValuesLast() {
        let recent = metric("recent", secondsAgo: 10, model: "model-recent", rate: 9, ttft: nil)
        let fast = metric("fast", secondsAgo: 20, model: "model-fast", rate: 30, ttft: 0.3)
        let noThroughput = metric("missing", secondsAgo: 5, model: "model-missing", outputTokens: 10, rate: 999, ttft: 0.2)
        let snapshot = DashboardSnapshot(records: [recent, fast, noThroughput], range: .day, selection: .all, now: now)

        let neutral = DashboardSnapshot.ordered(snapshot.cohortSummaries, by: .recent)
        let throughput = DashboardSnapshot.ordered(snapshot.cohortSummaries, by: .higherThroughput)
        let ttft = DashboardSnapshot.ordered(snapshot.cohortSummaries, by: .lowerTTFT)
        XCTAssertEqual(neutral.first?.cohort.model, "model-missing")
        XCTAssertEqual(throughput.map(\.cohort.model), ["model-fast", "model-recent", "model-missing"])
        XCTAssertEqual(ttft.map(\.cohort.model), ["model-missing", "model-fast", "model-recent"])
    }

    func testPersonalTrendDoesNotPoolEffortsOrUnknownModelProviders() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let highBaseline = (0..<20).map { index in
            metric("effort-base-\(index)", secondsAgo: 36 * 3_600 + Double(index / 10) * 86_400 + Double(index), rate: 100, reasoningEffort: "high")
        }
        let lowCurrent = (0..<5).map { index in
            metric("effort-now-\(index)", secondsAgo: Double(index) * 60, rate: 60, reasoningEffort: "low")
        }
        let selectedLow = ModelCohort(model: "test-model", provider: "openai", clientVersion: "0.159.2", reasoningEffort: "low")
        let split = DashboardSnapshot(records: highBaseline + lowCurrent, range: .day, selection: .cohort(selectedLow), now: now, calendar: calendar)
        XCTAssertEqual(split.personalTrend?.status, .buildingBaseline)
        XCTAssertEqual(split.personalTrend?.baselineThroughput.count, 0)

        let unknown = (0..<25).map { index in
            metric("unknown-\(index)", secondsAgo: Double(index) * 60, model: nil, provider: "unknown", rate: 1)
        }
        XCTAssertNil(DashboardSnapshot(records: unknown, range: .day, now: now, calendar: calendar).personalTrend)
    }

    func testPersonalTrendRequiresRecentCurrentTurnsAndTwoBaselineDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let baseline = (0..<20).map { index in
            metric("base-\(index)", secondsAgo: 36 * 3_600 + Double(index / 10) * 86_400 + Double(index) * 30, rate: 100, ttft: 1)
        }
        let current = (0..<5).map { index in
            metric("current-\(index)", secondsAgo: Double(index) * 60, rate: 60, ttft: 2.2)
        }
        let snapshot = DashboardSnapshot(records: baseline + current, range: .day, now: now, calendar: calendar)
        let trend = try! XCTUnwrap(snapshot.personalTrend)
        XCTAssertEqual(trend.status, .slower)
        XCTAssertEqual(trend.currentThroughput.median, 60)
        XCTAssertEqual(trend.currentThroughput.count, 5)
        XCTAssertEqual(trend.baselineThroughput.median, 100)
        XCTAssertEqual(trend.baselineThroughput.count, 20)
        XCTAssertEqual(trend.currentTTFT.median, 2.2)
        XCTAssertEqual(trend.currentTTFT.count, 5)

        let recentTooOld = current.map { item in
            TurnMetric(id: item.id, completedAt: now.addingTimeInterval(-7_200), model: item.model, outputTokens: item.outputTokens, durationSeconds: item.durationSeconds, codexTTFTSeconds: item.codexTTFTSeconds, turnThroughputTPS: item.turnThroughputTPS, clientVersion: item.clientVersion, provider: item.provider)
        }
        let noRecent = DashboardSnapshot(records: baseline + recentTooOld, range: .day, now: now, calendar: calendar)
        XCTAssertEqual(noRecent.personalTrend?.status, .noRecentObservations)

        let smallCurrent = Array(current.prefix(4))
        let building = DashboardSnapshot(records: baseline + smallCurrent, range: .week, now: now, calendar: calendar)
        XCTAssertEqual(building.personalTrend?.status, .buildingBaseline)
    }

    func testTrendUsesThirtyPercentAndOneSecondThresholdsAndMissingTTFTStaysMissing() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let baseline = (0..<20).map { index in
            metric("b-\(index)", secondsAgo: 40 * 3_600 + Double(index / 10) * 86_400 + Double(index), rate: 10)
        }
        let current = (0..<5).map { index in
            metric("c-\(index)", secondsAgo: Double(index) * 60, rate: 7.1)
        }
        let belowThreshold = DashboardSnapshot(records: baseline + current, range: .week, now: now, calendar: calendar)
        XCTAssertEqual(belowThreshold.personalTrend?.status, .noLargeChange)
        XCTAssertNil(belowThreshold.medianTTFT)
        XCTAssertEqual(belowThreshold.ttft.count, 0)

        let missingRecentTTFT = (0..<5).map { index in
            metric("c-ttft-\(index)", secondsAgo: Double(index) * 60, rate: 10, ttft: nil)
        }
        let missingBaselineTTFT = (0..<20).map { index in
            metric("b-ttft-\(index)", secondsAgo: 40 * 3_600 + Double(index / 10) * 86_400 + Double(index), rate: 10, ttft: nil)
        }
        let noFakedTTFT = DashboardSnapshot(records: missingBaselineTTFT + missingRecentTTFT, range: .week, now: now, calendar: calendar)
        XCTAssertEqual(noFakedTTFT.personalTrend?.status, .noLargeChange)
        XCTAssertEqual(noFakedTTFT.personalTrend?.currentTTFT.count, 0)
        XCTAssertNil(noFakedTTFT.personalTrend?.currentTTFT.median)

        let baselineWithTTFT = (0..<20).map { index in
            metric("tb-\(index)", secondsAgo: 40 * 3_600 + Double(index / 10) * 86_400 + Double(index), rate: 10, ttft: 1)
        }
        let exactTTFTThreshold = (0..<5).map { index in
            metric("tc-\(index)", secondsAgo: Double(index) * 60, rate: 8, ttft: 2)
        }
        let ttftSlower = DashboardSnapshot(records: baselineWithTTFT + exactTTFTThreshold, range: .week, now: now, calendar: calendar)
        XCTAssertEqual(ttftSlower.personalTrend?.status, .slower)

        let subSecondIncrease = (0..<5).map { index in
            metric("subsecond-\(index)", secondsAgo: Double(index) * 60, rate: 8, ttft: 1.9)
        }
        let notEnoughTTFTIncrease = DashboardSnapshot(records: baselineWithTTFT + subSecondIncrease, range: .week, now: now, calendar: calendar)
        XCTAssertEqual(notEnoughTTFTIncrease.personalTrend?.status, .noLargeChange)

        let zeroBaseline = (0..<20).map { index in
            metric("zero-\(index)", secondsAgo: 40 * 3_600 + Double(index / 10) * 86_400 + Double(index), rate: 0)
        }
        let zeroCannotCompare = DashboardSnapshot(records: zeroBaseline + current, range: .week, now: now, calendar: calendar)
        XCTAssertEqual(zeroCannotCompare.personalTrend?.status, .buildingBaseline)
    }

    func testTTFTNeedsItsOwnBaselineAndMayUseShortTurns() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sparseBaseline = (0..<20).map { index in
            metric("sparse-b-\(index)", secondsAgo: 40 * 3_600 + Double(index / 10) * 86_400 + Double(index), rate: 10, ttft: index == 0 ? 1 : nil)
        }
        let sparseCurrent = (0..<5).map { index in
            metric("sparse-c-\(index)", secondsAgo: Double(index) * 60, rate: 10, ttft: index == 0 ? 3 : nil)
        }
        let sparse = DashboardSnapshot(records: sparseBaseline + sparseCurrent, range: .week, now: now, calendar: calendar)
        XCTAssertEqual(sparse.personalTrend?.status, .noLargeChange)
        XCTAssertFalse(try XCTUnwrap(sparse.personalTrend).comparesTTFT)
        XCTAssertTrue(try XCTUnwrap(sparse.personalTrend).comparesThroughput)

        let shortBaseline = (0..<20).map { index in
            metric("short-b-\(index)", secondsAgo: 40 * 3_600 + Double(index / 10) * 86_400 + Double(index), outputTokens: 10, rate: 10, ttft: 1)
        }
        let shortCurrent = (0..<5).map { index in
            metric("short-c-\(index)", secondsAgo: Double(index) * 60, outputTokens: 10, rate: 10, ttft: 2)
        }
        let shortTurns = DashboardSnapshot(records: shortBaseline + shortCurrent, range: .week, now: now, calendar: calendar)
        let shortTrend = try! XCTUnwrap(shortTurns.personalTrend)
        XCTAssertEqual(shortTrend.status, .slower)
        XCTAssertFalse(shortTrend.comparesThroughput)
        XCTAssertTrue(shortTrend.comparesTTFT)
        XCTAssertEqual(shortTrend.currentTTFT.count, 5)
        XCTAssertEqual(shortTrend.baselineTTFT.count, 20)
        XCTAssertEqual(shortTrend.currentThroughput.count, 0)
    }
}
