import Foundation
import TokrateCore
import XCTest

final class MetricHistoryTests: XCTestCase {
    func testSevenDayRetentionDeduplicationAndReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = metric(id: "same", at: now.addingTimeInterval(-6 * 24 * 60 * 60))
        let duplicate = metric(id: "same", at: now.addingTimeInterval(-1))
        let expired = metric(id: "old", at: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let future = metric(id: "future", at: now.addingTimeInterval(1))
        var history = MetricHistory(records: [recent, duplicate, expired, future], now: now)

        XCTAssertEqual(history.records.map(\.id), ["same"])
        XCTAssertEqual(history.records.first?.completedAt, duplicate.completedAt)
        history.reset()
        XCTAssertTrue(history.records.isEmpty)
    }

    private func metric(id: String, at date: Date) -> TurnMetric {
        TurnMetric(
            id: id,
            completedAt: date,
            model: nil,
            outputTokens: 1,
            durationSeconds: 1,
            codexTTFTSeconds: nil,
            turnThroughputTPS: 1
        )
    }
}
