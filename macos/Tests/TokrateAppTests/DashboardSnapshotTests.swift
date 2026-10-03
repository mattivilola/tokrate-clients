import XCTest
import TokrateCore
@testable import TokrateApp

final class DashboardSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func metric(_ secondsAgo: Double, rate: Double, ttft: Double? = nil) -> TurnMetric {
        TurnMetric(id: "\(secondsAgo)", completedAt: now.addingTimeInterval(-secondsAgo), model: "test-model", outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: ttft, turnThroughputTPS: rate)
    }

    func testFiftyThousandTurnsProduceAtMostFiftySixChartPoints() {
        let records = (0..<50_000).map { metric(Double($0) * 12, rate: Double($0 % 100)) }
        let snapshot = DashboardSnapshot(records: records, range: .week, now: now)
        XCTAssertEqual(snapshot.turnCount, 50_000)
        XCTAssertLessThanOrEqual(snapshot.points.count, 56)
        XCTAssertEqual(snapshot.points.reduce(0) { $0 + $1.turns }, 50_000)
        XCTAssertEqual(snapshot.medianRate, 49.5)
        XCTAssertTrue(snapshot.points.allSatisfy { snapshot.dates.contains($0.date) })
    }

    func testFilteringAndMediansDoNotInventMissingValues() {
        let records = [metric(10, rate: 20, ttft: 2), metric(20, rate: 40), metric(30, rate: 60, ttft: 4), metric(-1, rate: 999), metric(700_000, rate: 999), metric(40, rate: .nan)]
        let snapshot = DashboardSnapshot(records: records, range: .week, now: now)
        XCTAssertEqual(snapshot.turnCount, 3)
        XCTAssertEqual(snapshot.medianRate, 40)
        XCTAssertEqual(snapshot.medianTTFT, 3)
        XCTAssertEqual(snapshot.latest?.turnThroughputTPS, 20)
        let empty = DashboardSnapshot(records: [], range: .week, now: now)
        XCTAssertNil(empty.medianRate)
        XCTAssertNil(empty.medianTTFT)
        XCTAssertNil(empty.latest)
        XCTAssertTrue(empty.points.isEmpty)
    }

    func testTodayFiltersSummaryButLatestRemainsActualLastTurn() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let elapsed = now.timeIntervalSince(calendar.startOfDay(for: now))
        let record = metric(elapsed + 60, rate: 25)
        let snapshot = DashboardSnapshot(records: [record], range: .today, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.turnCount, 0)
        XCTAssertEqual(snapshot.latest, record)
        XCTAssertTrue(snapshot.points.isEmpty)
        let midnight = calendar.startOfDay(for: now)
        let midnightRecord = TurnMetric(id: "midnight", completedAt: midnight, model: nil, outputTokens: 0, durationSeconds: 1, codexTTFTSeconds: nil, turnThroughputTPS: 0)
        let midnightSnapshot = DashboardSnapshot(records: [midnightRecord], range: .today, now: midnight, calendar: calendar)
        XCTAssertEqual(midnightSnapshot.turnCount, 1)
        XCTAssertTrue(midnightSnapshot.dates.contains(midnightSnapshot.points[0].date))
    }
}
