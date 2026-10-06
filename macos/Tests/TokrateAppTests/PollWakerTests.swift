import XCTest
@testable import TokrateApp

final class PollWakerTests: XCTestCase {
    private func elapsed(_ body: () async -> Void) async -> TimeInterval {
        let start = ContinuousClock.now
        await body()
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    func testRepeatedTimeoutsEachActuallyWait() async {
        let waker = PollWaker()
        var results: [Bool] = []
        let total = await elapsed {
            for _ in 0..<3 { results.append(await waker.wait(timeout: 0.2)) }
        }
        XCTAssertEqual(results, [false, false, false])
        XCTAssertGreaterThanOrEqual(total, 0.6 - 0.02)
    }

    func testASignalBeforeAWaitReturnsImmediatelyAndIsConsumedOnce() async {
        let waker = PollWaker()
        await waker.signal()
        await waker.signal()
        var first = false
        let took = await elapsed { first = await waker.wait(timeout: 5) }
        XCTAssertTrue(first)
        XCTAssertLessThan(took, 1)
        let second = await waker.wait(timeout: 0.1)
        XCTAssertFalse(second, "signals collapse into one pending wake")
    }

    func testASignalDuringAWaitReturnsEarly() async {
        let waker = PollWaker()
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            await waker.signal()
        }
        var signalled = false
        let took = await elapsed { signalled = await waker.wait(timeout: 5) }
        XCTAssertTrue(signalled)
        XCTAssertLessThan(took, 2)
    }

    func testAWaitAfterSeveralTimeoutsStillReceivesASignal() async {
        let waker = PollWaker()
        for _ in 0..<3 { _ = await waker.wait(timeout: 0.05) }
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            await waker.signal()
        }
        var signalled = false
        let took = await elapsed { signalled = await waker.wait(timeout: 5) }
        XCTAssertTrue(signalled)
        XCTAssertLessThan(took, 2)
    }

    func testCancellingTheWaitingTaskResumesItAndTheWakerStaysUsable() async {
        let waker = PollWaker()
        let waiting = Task { await waker.wait(timeout: 30) }
        try? await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        let cancelled = await waiting.value
        XCTAssertFalse(cancelled)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await waker.signal()
        }
        let signalled = await waker.wait(timeout: 5)
        XCTAssertTrue(signalled, "a cancelled wait must not poison the next one")
    }
}
