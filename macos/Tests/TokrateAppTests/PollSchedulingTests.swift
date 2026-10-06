import XCTest
@testable import TokrateApp

/// How long the polling task sleeps between polls (see `HistoryStore.pollDelay`).
final class PollSchedulingTests: XCTestCase {
    private let lastPoll = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { lastPoll.addingTimeInterval(seconds) }

    func testNothingPendingSleepsUntilTheIdleInterval() {
        XCTAssertEqual(HistoryStore.pollDelay(now: at(0), lastPoll: lastPoll, deadline: nil), HistoryStore.idlePollInterval)
        XCTAssertEqual(HistoryStore.pollDelay(now: at(10), lastPoll: lastPoll, deadline: nil), HistoryStore.idlePollInterval - 10)
        XCTAssertEqual(HistoryStore.pollDelay(now: at(HistoryStore.idlePollInterval + 5), lastPoll: lastPoll, deadline: nil), 0)
    }

    func testAPendingMonitorPollsAtTheMinimumSpacing() {
        XCTAssertEqual(HistoryStore.pollDelay(now: at(0), lastPoll: lastPoll, deadline: at(0)), HistoryStore.minimumPollSpacing)
        XCTAssertEqual(HistoryStore.pollDelay(now: at(0.5), lastPoll: lastPoll, deadline: at(-3)), HistoryStore.minimumPollSpacing - 0.5)
        XCTAssertEqual(HistoryStore.pollDelay(now: at(3), lastPoll: lastPoll, deadline: at(0)), 0, "already past the spacing")
    }

    func testADeadlineBeyondTheSpacingIsHonoredButNeverPastTheIdleInterval() {
        XCTAssertEqual(HistoryStore.pollDelay(now: at(0), lastPoll: lastPoll, deadline: at(12)), 12)
        XCTAssertEqual(
            HistoryStore.pollDelay(now: at(0), lastPoll: lastPoll, deadline: at(1_800)), HistoryStore.idlePollInterval,
            "a long delegation wait must not stall the live readout"
        )
    }

    func testAWakeAfterTheSpacingPollsAtOnceAndAnEarlyWakeWaitsOutTheRest() {
        // A change reported at `now` is polled as soon as the spacing since the last poll allows.
        XCTAssertEqual(HistoryStore.pollDelay(now: at(7), lastPoll: lastPoll, deadline: at(7)), 0)
        XCTAssertEqual(HistoryStore.pollDelay(now: at(0.4), lastPoll: lastPoll, deadline: at(0.4)), HistoryStore.minimumPollSpacing - 0.4, accuracy: 0.0001)
    }
}
