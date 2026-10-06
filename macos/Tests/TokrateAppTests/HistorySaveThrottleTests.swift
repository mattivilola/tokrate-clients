import XCTest
@testable import TokrateApp

/// When the history file is rewritten while records keep arriving (`HistorySaveThrottle`).
final class HistorySaveThrottleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// The polling loop's decision at one poll: note records, write when due.
    private func poll(_ throttle: inout HistorySaveThrottle, at now: Date, records: Bool) -> Bool {
        if records { throttle.noteNewRecords() }
        guard throttle.isDue(now: now) else { return false }
        throttle.didSave(at: now, succeeded: true)
        return true
    }

    func testTheFirstRecordsAreWrittenAtOnceAndNothingWaitsWithoutRecords() {
        var throttle = HistorySaveThrottle()
        XCTAssertFalse(throttle.isDue(now: at(0)))
        XCTAssertNil(throttle.dueAt(now: at(0)))
        XCTAssertTrue(poll(&throttle, at: at(0), records: true))
        XCTAssertNil(throttle.dueAt(now: at(0)), "written, so nothing is pending")
    }

    func testAReplayWithRecordsOnEveryPollWritesAtMostOncePerInterval() {
        var throttle = HistorySaveThrottle()
        // Polls two seconds apart for a minute, each with new records.
        let writes = stride(from: 0.0, through: 60, by: 2).filter { poll(&throttle, at: at($0), records: true) }
        XCTAssertEqual(writes, [0, 10, 20, 30, 40, 50, 60])
        for (previous, next) in zip(writes, writes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next - previous, HistorySaveThrottle.interval)
        }
    }

    func testRecordsWaitingWhenTheMonitorsGoIdleAreWrittenAtTheirDeadline() {
        var throttle = HistorySaveThrottle()
        XCTAssertTrue(poll(&throttle, at: at(0), records: true))
        XCTAssertFalse(poll(&throttle, at: at(4), records: true))
        // The pending write is the poll deadline, so the idle poll that would wait 30 s comes sooner.
        let due = throttle.dueAt(now: at(4))
        XCTAssertEqual(due, at(10))
        XCTAssertEqual(HistoryStore.pollDelay(now: at(4), lastPoll: at(4), deadline: due), 6)
        // That poll finds no records and still writes them.
        XCTAssertTrue(poll(&throttle, at: at(10), records: false))
        XCTAssertNil(throttle.dueAt(now: at(10)))
        XCTAssertFalse(poll(&throttle, at: at(40), records: false))
    }

    func testAFailedWriteIsRetriedAfterTheIntervalNotAtEveryPoll() {
        var throttle = HistorySaveThrottle()
        throttle.noteNewRecords()
        XCTAssertTrue(throttle.isDue(now: at(0)))
        throttle.didSave(at: at(0), succeeded: false)
        XCTAssertFalse(throttle.isDue(now: at(2)))
        XCTAssertEqual(throttle.dueAt(now: at(2)), at(10))
        XCTAssertTrue(throttle.isDue(now: at(10)))
    }

    func testAClockThatMovedBackwardsDoesNotStallTheWrite() {
        var throttle = HistorySaveThrottle()
        throttle.noteNewRecords()
        throttle.didSave(at: at(100), succeeded: true)
        throttle.noteNewRecords()
        XCTAssertTrue(throttle.isDue(now: at(50)))
    }

    func testAnotherWriteRestartsTheInterval() {
        var throttle = HistorySaveThrottle()
        XCTAssertTrue(poll(&throttle, at: at(0), records: true))
        // The busy-to-idle checkpoint write (or any other) counts as a write.
        throttle.didSave(at: at(8), succeeded: true)
        XCTAssertFalse(poll(&throttle, at: at(12), records: true))
        XCTAssertTrue(poll(&throttle, at: at(18), records: false))
    }

    func testAResetSessionWritesItsFirstRecordsAtOnce() {
        var throttle = HistorySaveThrottle()
        throttle.didSave(at: at(0), succeeded: true)
        throttle.reset()
        XCTAssertTrue(poll(&throttle, at: at(1), records: true))
    }
}
