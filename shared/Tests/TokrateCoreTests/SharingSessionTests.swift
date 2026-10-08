import CryptoKit
import Foundation
@testable import TokrateCore
import XCTest

private final class MemoryIdentity: SharingIdentity, @unchecked Sendable {
    let key = Curve25519.Signing.PrivateKey().rawRepresentation
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func loadOrCreate() throws -> Data { lock.withLock { count += 1 }; return key }
}
private actor MockTransport: SharingTransport {
    var requests: [URLRequest] = []
    var uploadStatus = 200
    var boardStatus = 200
    var pause = false
    var continuation: CheckedContinuation<Void, Never>?
    func configure(uploadStatus: Int = 200, boardStatus: Int = 200, pause: Bool = false) {
        self.uploadStatus = uploadStatus
        self.boardStatus = boardStatus
        self.pause = pause
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if pause { await withCheckedContinuation { continuation = $0 } }
        if request.httpMethod == "POST" { return (Data(), uploadStatus) }
        return (Data(#"{"schemaVersion":1,"generatedAt":"2026-10-03T10:00:00Z","dataAsOf":null,"collectionEnabled":true,"state":"insufficient_data","window":"15m","cohorts":[],"alerts":[],"unknownField":true}"#.utf8), boardStatus)
    }
    func resume() { continuation?.resume(); continuation = nil; pause = false }
    func snapshot() -> [URLRequest] { requests }
    func isSuspended() -> Bool { continuation != nil }
}

/// A scripted random source: hands out the given delays in order and counts the draws.
private final class ScriptedJitter: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval]
    private var drawn = 0
    init(_ delays: [TimeInterval]) { self.delays = delays }
    var draws: Int { lock.withLock { drawn } }
    func next() -> TimeInterval {
        lock.withLock {
            drawn += 1
            return delays.isEmpty ? 0 : delays.removeFirst()
        }
    }
}

@MainActor
final class SharingSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_020_401)
    /// After the slot of `now` (one period after its bucket closed) and its random delay.
    private var later: Date { now.addingTimeInterval(700) }
    private func metric(id: String = "LOCAL_PRIVATE_DIGEST", date: Date? = nil, model: String? = "gpt-test", reasoningEffort: String? = nil, delegated: Int? = 0) -> TurnMetric {
        TurnMetric(id: id, completedAt: date ?? now, model: model, outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: 1, turnThroughputTPS: 10, clientVersion: "0.159.2", sourceKind: "primary", provider: "openai", reasoningEffort: reasoningEffort, delegatedOutputTokens: delegated)
    }

    func testLocalOnlyDoesNotCreateIdentityOrContactServer() async {
        let transport = MockTransport(), identity = MemoryIdentity()
        let session = SharingSession(identity: identity, transport: transport)
        session.enqueue([metric()], now: now)
        await session.refresh(now: now)
        XCTAssertEqual(identity.calls, 0)
        let requests = await transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertNil(session.board)
    }

    func testHTTP426DiscardsQueuedUploadsAndStopsFurtherRequests() async {
        let transport = MockTransport(), identity = MemoryIdentity()
        await transport.configure(uploadStatus: 426)
        let session = SharingSession(identity: identity, transport: transport)
        session.enable(now: now, startPolling: false)
        session.enqueue([
            metric(id: "first", date: now),
            metric(id: "second", date: now.addingTimeInterval(1))
        ], now: now.addingTimeInterval(1))
        XCTAssertEqual(session.pendingCount, 2)

        await session.refresh(now: later)

        XCTAssertTrue(session.requiresUpdate)
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertNil(session.board)
        XCTAssertTrue(session.status.contains("Check for Updates"))
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "POST")

        session.enable(now: later.addingTimeInterval(30), startPolling: false)
        session.enqueue([metric(id: "after-block", date: later.addingTimeInterval(31))], now: later.addingTimeInterval(31))
        await session.refresh(now: later.addingTimeInterval(31))
        XCTAssertEqual(identity.calls, 1)
        XCTAssertEqual(session.pendingCount, 0)
        let afterRetry = await transport.snapshot()
        XCTAssertEqual(afterRetry.count, 1)
    }

    func testHTTP426FromBoardAlsoStopsSharing() async {
        let transport = MockTransport(), identity = MemoryIdentity()
        await transport.configure(boardStatus: 426)
        let session = SharingSession(identity: identity, transport: transport)
        session.enable(now: now, startPolling: false)

        await session.refresh(now: now)

        XCTAssertTrue(session.requiresUpdate)
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(session.status.contains("Check for Updates"))
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
    }

    func testFutureOnlySignedAllowlistAndFiveMinuteBuckets() async throws {
        let transport = MockTransport(), identity = MemoryIdentity()
        let session = SharingSession(identity: identity, transport: transport)
        session.enable(now: now, startPolling: false)
        session.enqueue([metric(id: "old", date: now.addingTimeInterval(-1)), metric(), metric()], now: now)
        XCTAssertEqual(session.pendingCount, 1)
        await session.refresh(now: later)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        let request = requests[0], body = try XCTUnwrap(request.httpBody)
        let publicKeyData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(request.value(forHTTPHeaderField: "X-Tokrate-Key"))))
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(request.value(forHTTPHeaderField: "X-Tokrate-Signature"))))
        XCTAssertTrue(try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData).isValidSignature(signature, for: body))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(Set(samples[0].keys), Set(["sampleId", "observedAt", "client", "clientVersion", "appVersion", "parserVersion", "metricVersion", "model", "provider", "reasoningEffort", "sourceKind", "outputTokens", "reasoningOutputTokens", "durationMs", "ttftMs", "responseOutputTokens", "responseDurationMs", "responseCount", "providerRegion", "delegatedOutputTokens", "surface", "inputTokens", "cacheReadInputTokens", "cacheWriteInputTokens"]))
        XCTAssertEqual(samples[0]["appVersion"] as? String, "0.1.20")
        XCTAssertEqual(samples[0]["reasoningEffort"] as? String, "unknown")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("LOCAL_PRIVATE_DIGEST"))
        let observed = try XCTUnwrap(ISO8601DateFormatter().date(from: try XCTUnwrap(samples[0]["observedAt"] as? String)))
        XCTAssertEqual(observed.timeIntervalSince1970.truncatingRemainder(dividingBy: 300), 0)
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertNotNil(session.board)
        session.disable()
        XCTAssertNil(session.board)
        await session.refresh(now: later.addingTimeInterval(100))
        let after = await transport.snapshot()
        XCTAssertEqual(after.count, 2)
    }

    // MARK: Upload timing

    /// The start of the five-minute bucket that `now` is in.
    private var bucket: Date { Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 300) * 300) }
    private func uploads(_ requests: [URLRequest]) -> [URLRequest] { requests.filter { $0.httpMethod == "POST" } }
    private func uploadCount(_ transport: MockTransport) async -> Int { uploads(await transport.snapshot()).count }
    private func sampleCount(_ request: URLRequest) throws -> Int {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        return try XCTUnwrap(object["samples"] as? [[String: Any]]).count
    }

    func testASampleIsNotUploadedBeforeAFullPeriodAfterItsBucketHasClosedAndItsRandomDelayHasPassed() async {
        let transport = MockTransport()
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: ScriptedJitter([42]).next)
        session.enable(now: bucket, startPolling: false)
        session.enqueue([metric(date: bucket.addingTimeInterval(10))], now: bucket.addingTimeInterval(10))

        // The bucket closes at +300 s and the sample takes the slot one period later, +600 s; this
        // slot's delay is 42 s.
        await session.refresh(now: bucket.addingTimeInterval(299))
        await session.refresh(now: bucket.addingTimeInterval(341.9))
        await session.refresh(now: bucket.addingTimeInterval(599))
        await session.refresh(now: bucket.addingTimeInterval(641.9))
        var requests = await transport.snapshot()
        XCTAssertTrue(uploads(requests).isEmpty)
        XCTAssertEqual(session.pendingCount, 1, "the sample waits in the queue")

        await session.refresh(now: bucket.addingTimeInterval(642))
        requests = await transport.snapshot()
        XCTAssertEqual(uploads(requests).count, 1)
        XCTAssertEqual(session.pendingCount, 0)
    }

    func testTurnsOfOneBucketLeaveInTheSameSlotWhereverInsideTheBucketTheyFinished() async throws {
        let transport = MockTransport()
        let jitter = ScriptedJitter([25])
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: jitter.next)
        session.enable(now: bucket, startPolling: false)
        // One turn finishes early in the bucket, one in its last seconds and is queued 30 s later
        // (after its delegated-total wait), when the bucket has already closed.
        session.enqueue([metric(id: "early", date: bucket.addingTimeInterval(10))], now: bucket.addingTimeInterval(40))
        session.enqueue([metric(id: "late", date: bucket.addingTimeInterval(295))], now: bucket.addingTimeInterval(325))
        XCTAssertEqual(jitter.draws, 1, "both take the slot at +600 s")
        await session.refresh(now: bucket.addingTimeInterval(624.9))
        let early = await uploadCount(transport)
        XCTAssertEqual(early, 0)
        await session.refresh(now: bucket.addingTimeInterval(625))
        let requests = uploads(await transport.snapshot())
        XCTAssertEqual(try requests.map(sampleCount), [2], "one batch, so the send time does not tell them apart")
    }

    func testSamplesOfOneSlotLeaveTogetherAndEachSlotHasItsOwnRandomDelay() async throws {
        let transport = MockTransport()
        let jitter = ScriptedJitter([10, 50])
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: jitter.next)
        session.enable(now: bucket, startPolling: false)
        session.enqueue([
            metric(id: "a", date: bucket.addingTimeInterval(5)),
            metric(id: "b", date: bucket.addingTimeInterval(120)),
            metric(id: "c", date: bucket.addingTimeInterval(299))
        ], now: bucket.addingTimeInterval(299.5))
        // A sample of the next bucket takes the slot a period after that bucket closed.
        session.enqueue([metric(id: "next", date: bucket.addingTimeInterval(310))], now: bucket.addingTimeInterval(310))
        XCTAssertEqual(jitter.draws, 2, "one draw per slot")

        // The first slot is uploadable from +610 s (+600 and a delay of 10), the next from +950 s.
        await session.refresh(now: bucket.addingTimeInterval(609.9))
        let early = await uploadCount(transport)
        XCTAssertEqual(early, 0)
        await session.refresh(now: bucket.addingTimeInterval(610))
        var requests = uploads(await transport.snapshot())
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try sampleCount(requests[0]), 3, "one batch for the whole slot")
        XCTAssertEqual(session.pendingCount, 1)

        await session.refresh(now: bucket.addingTimeInterval(949))
        let uploadsSoFar = await uploadCount(transport)
        XCTAssertEqual(uploadsSoFar, 1)
        await session.refresh(now: bucket.addingTimeInterval(950))
        requests = uploads(await transport.snapshot())
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try sampleCount(requests[1]), 1)
        XCTAssertEqual(jitter.draws, 2)
    }

    func testASampleQueuedLongAfterItsBucketClosedWaitsForTheNextSlotNotThirtySeconds() async throws {
        let transport = MockTransport()
        let jitter = ScriptedJitter([20])
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: jitter.next)
        session.enable(now: bucket, startPolling: false)
        // A primary turn queued once its delegated total is final, 30 minutes after its bucket closed
        // and 7 s into a slot.
        let queuedAt = bucket.addingTimeInterval(300 + 1_800 + 7)
        session.enqueue([metric(date: bucket.addingTimeInterval(10))], now: queuedAt)
        await session.refresh(now: queuedAt.addingTimeInterval(30))
        await session.refresh(now: bucket.addingTimeInterval(2_399.9))
        let early = await uploadCount(transport)
        XCTAssertEqual(early, 0, "not within 30 s of becoming queueable")
        // The next boundary is +2,400 s; its delay is 20 s.
        await session.refresh(now: bucket.addingTimeInterval(2_419.9))
        let beforeDelay = await uploadCount(transport)
        XCTAssertEqual(beforeDelay, 0)
        await session.refresh(now: bucket.addingTimeInterval(2_420))
        let sent = await uploadCount(transport)
        XCTAssertEqual(sent, 1)
    }

    func testSamplesOfDifferentBucketsQueuedInOneFiveMinutePeriodShareOneSlotAndOneDelay() async throws {
        let transport = MockTransport()
        let jitter = ScriptedJitter([33, 5])
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: jitter.next)
        session.enable(now: bucket, startPolling: false)
        // Both buckets closed long ago; both samples are queued within the slot ending at +3,000 s.
        session.enqueue([metric(id: "old", date: bucket.addingTimeInterval(10))], now: bucket.addingTimeInterval(2_710))
        session.enqueue([metric(id: "older", date: bucket.addingTimeInterval(400))], now: bucket.addingTimeInterval(2_990))
        XCTAssertEqual(jitter.draws, 1, "one slot, one delay")
        await session.refresh(now: bucket.addingTimeInterval(3_032.9))
        let early = await uploadCount(transport)
        XCTAssertEqual(early, 0)
        await session.refresh(now: bucket.addingTimeInterval(3_033))
        let requests = uploads(await transport.snapshot())
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try sampleCount(requests[0]), 2)
    }

    func testAnEnqueueExactlyOnABoundaryIsAssignedThatBoundary() async throws {
        let transport = MockTransport()
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: ScriptedJitter([15, 40]).next)
        session.enable(now: bucket, startPolling: false)
        session.enqueue([metric(id: "exact", date: bucket.addingTimeInterval(10))], now: bucket.addingTimeInterval(900))
        // Queued a moment after the boundary: the following one.
        session.enqueue([metric(id: "after", date: bucket.addingTimeInterval(20))], now: bucket.addingTimeInterval(900.5))
        await session.refresh(now: bucket.addingTimeInterval(914.9))
        let early = await uploadCount(transport)
        XCTAssertEqual(early, 0)
        await session.refresh(now: bucket.addingTimeInterval(915))
        var requests = uploads(await transport.snapshot())
        XCTAssertEqual(try requests.map(sampleCount), [1])
        await session.refresh(now: bucket.addingTimeInterval(1_239.9))
        let still = await uploadCount(transport)
        XCTAssertEqual(still, 1)
        await session.refresh(now: bucket.addingTimeInterval(1_240))
        requests = uploads(await transport.snapshot())
        XCTAssertEqual(try requests.map(sampleCount), [1, 1])
    }

    func testAnEnqueueExactlyAtAPeriodAfterTheBucketClosedTakesThatSlotAndOneMomentLaterTheNext() async throws {
        let transport = MockTransport()
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: ScriptedJitter([0, 0]).next)
        session.enable(now: bucket, startPolling: false)
        session.enqueue([metric(id: "exact", date: bucket.addingTimeInterval(10))], now: bucket.addingTimeInterval(600))
        session.enqueue([metric(id: "after", date: bucket.addingTimeInterval(20))], now: bucket.addingTimeInterval(600.5))
        await session.refresh(now: bucket.addingTimeInterval(600))
        var requests = uploads(await transport.snapshot())
        XCTAssertEqual(try requests.map(sampleCount), [1])
        await session.refresh(now: bucket.addingTimeInterval(899.9))
        let still = await uploadCount(transport)
        XCTAssertEqual(still, 1)
        await session.refresh(now: bucket.addingTimeInterval(900))
        requests = uploads(await transport.snapshot())
        XCTAssertEqual(try requests.map(sampleCount), [1, 1])
    }

    func testABucketLargerThanTheRequestCapLeavesInBatchesOfFifty() async throws {
        let transport = MockTransport()
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: ScriptedJitter([0]).next)
        session.enable(now: bucket, startPolling: false)
        session.enqueue((0..<60).map { metric(id: "m\($0)", date: bucket.addingTimeInterval(5)) }, now: bucket.addingTimeInterval(10))
        await session.refresh(now: bucket.addingTimeInterval(600))
        await session.refresh(now: bucket.addingTimeInterval(630))
        let requests = uploads(await transport.snapshot())
        XCTAssertEqual(try requests.map(sampleCount), [50, 10])
    }

    func testTheBoardIsFetchedAtItsOwnCadenceWhetherOrNotAnythingIsUploaded() async {
        let transport = MockTransport()
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: ScriptedJitter([0]).next)
        session.enable(now: bucket, startPolling: false)
        // Nothing queued, then a sample that is still waiting for its bucket to close.
        await session.refresh(now: bucket)
        session.enqueue([metric(date: bucket.addingTimeInterval(1))], now: bucket.addingTimeInterval(1))
        await session.refresh(now: bucket.addingTimeInterval(10))
        await session.refresh(now: bucket.addingTimeInterval(29.9))
        await session.refresh(now: bucket.addingTimeInterval(30))
        await session.refresh(now: bucket.addingTimeInterval(60))
        var requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET"], "every 30 s, and no upload yet")

        // Once uploadable, the upload goes out at its own moment and the board keeps its schedule.
        await session.refresh(now: bucket.addingTimeInterval(600))
        await session.refresh(now: bucket.addingTimeInterval(610))
        await session.refresh(now: bucket.addingTimeInterval(630))
        requests = await transport.snapshot()
        XCTAssertEqual(requests.suffix(3).map(\.httpMethod), ["POST", "GET", "GET"])
        XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, 5)
    }

    func testTheLoopWakesAtTheNextEligibilityNotFasterThanTheBoardCadence() async {
        let transport = MockTransport()
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: ScriptedJitter([42]).next)
        session.enable(now: bucket, startPolling: false)
        session.enqueue([metric(date: bucket.addingTimeInterval(10))], now: bucket.addingTimeInterval(10))
        await session.refresh(now: bucket.addingTimeInterval(600))
        XCTAssertEqual(session.secondsUntilNextRefresh(now: bucket.addingTimeInterval(600)), 30, accuracy: 0.001, "the board is due first")
        await session.refresh(now: bucket.addingTimeInterval(630))
        XCTAssertEqual(session.secondsUntilNextRefresh(now: bucket.addingTimeInterval(630)), 12, accuracy: 0.001, "the sample leaves at +642 s, before the board")
    }

    func testAFailedUploadIsRetriedAfterThirtySecondsNotAtOnce() async {
        let transport = MockTransport()
        await transport.configure(uploadStatus: 503)
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: ScriptedJitter([0]).next)
        session.enable(now: bucket, startPolling: false)
        session.enqueue([metric(date: bucket.addingTimeInterval(10))], now: bucket.addingTimeInterval(10))
        await session.refresh(now: bucket.addingTimeInterval(600))
        XCTAssertEqual(session.secondsUntilNextRefresh(now: bucket.addingTimeInterval(600)), 30, accuracy: 0.001)
        await session.refresh(now: bucket.addingTimeInterval(610))
        let uploadsSoFar = await uploadCount(transport)
        XCTAssertEqual(uploadsSoFar, 1)
        await session.refresh(now: bucket.addingTimeInterval(630))
        let uploadsAfterRetry = await uploadCount(transport)
        XCTAssertEqual(uploadsAfterRetry, 2)
        XCTAssertEqual(session.pendingCount, 1)
    }

    func testDisablingClearsQueuedSamplesAndTheirRandomDelays() async {
        let transport = MockTransport()
        let jitter = ScriptedJitter([5, 6])
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: jitter.next)
        session.enable(now: bucket, startPolling: false)
        session.enqueue([metric(id: "waiting", date: bucket.addingTimeInterval(10))], now: bucket.addingTimeInterval(10))
        XCTAssertEqual(session.pendingCount, 1)
        session.disable()
        XCTAssertEqual(session.pendingCount, 0)
        await session.refresh(now: bucket.addingTimeInterval(400))
        let afterDisable = await transport.snapshot()
        XCTAssertTrue(afterDisable.isEmpty, "nothing is sent after the switch is turned off")

        // Switching on again starts from nothing, including a fresh delay for the same bucket.
        session.enable(now: bucket.addingTimeInterval(20), startPolling: false)
        session.enqueue([metric(id: "waiting", date: bucket.addingTimeInterval(30))], now: bucket.addingTimeInterval(30))
        XCTAssertEqual(jitter.draws, 2)
        await session.refresh(now: bucket.addingTimeInterval(605.9))
        let early = await transport.snapshot()
        XCTAssertTrue(uploads(early).isEmpty)
        await session.refresh(now: bucket.addingTimeInterval(606))
        let sent = await transport.snapshot()
        XCTAssertEqual(uploads(sent).count, 1)
    }

    func testTheRandomDelayIsClampedToOneMinuteAndTheDefaultSourceIsUniformWithinIt() {
        XCTAssertEqual(SharingSession.maximumJitterSeconds, 60)
        let draws = (0..<2_000).map { _ in SharingSession.secureRandomJitter() }
        XCTAssertTrue(draws.allSatisfy { $0 >= 0 && $0 < 60 })
        XCTAssertGreaterThan(Set(draws).count, 1_900, "not a constant")
        XCTAssertTrue(draws.contains { $0 < 10 } && draws.contains { $0 > 50 })
    }

    func testAnOutOfRangeRandomSourceCannotDelayAnUploadBeyondOneMinute() async {
        let transport = MockTransport()
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: { 10_000 })
        session.enable(now: bucket, startPolling: false)
        session.enqueue([metric(date: bucket.addingTimeInterval(10))], now: bucket.addingTimeInterval(10))
        await session.refresh(now: bucket.addingTimeInterval(660))
        let requests = await transport.snapshot()
        XCTAssertEqual(uploads(requests).count, 1)
    }

    func testUploadReportsOnlyAllowlistedEffortAndUsesUnknownFallback() throws {
        let reported = try XCTUnwrap(SharedSample(metric(reasoningEffort: "ultra")))
        XCTAssertEqual(reported.appVersion, "0.1.20")
        XCTAssertEqual(reported.reasoningEffort, "ultra")
        let missing = try XCTUnwrap(SharedSample(metric()))
        XCTAssertEqual(missing.reasoningEffort, "unknown")
        let invalidMetric = TurnMetric(id: "bad-effort", completedAt: now, model: "gpt-test", outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: nil, turnThroughputTPS: 10, reasoningEffort: "automatic")
        XCTAssertEqual(try XCTUnwrap(SharedSample(invalidMetric)).reasoningEffort, "unknown")
    }

    func testPrimaryTurnIsSharedExactlyOnceAndOnlyOnceItsDelegatedTotalIsFinal() async throws {
        let transport = MockTransport(), identity = MemoryIdentity()
        let session = SharingSession(identity: identity, transport: transport)
        session.enable(now: now, startPolling: false)
        session.enqueue([metric(id: "turn", delegated: nil)], now: now)
        XCTAssertEqual(session.pendingCount, 0, "a primary turn waits for its delegated total")
        session.enqueue([metric(id: "turn", delegated: nil)], now: now)
        XCTAssertEqual(session.pendingCount, 0)

        // The settled re-emission under the same id is the one that is shared, once.
        session.enqueue([metric(id: "turn", delegated: 250)], now: now)
        XCTAssertEqual(session.pendingCount, 1)
        session.enqueue([metric(id: "turn", delegated: 250), metric(id: "turn", delegated: 300), metric(id: "turn", delegated: nil)], now: now)
        XCTAssertEqual(session.pendingCount, 1)

        await session.refresh(now: later)
        let requests = await transport.snapshot()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0]["delegatedOutputTokens"] as? Int, 250)
        session.enqueue([metric(id: "turn", delegated: 250)], now: now)
        XCTAssertEqual(session.pendingCount, 0, "already shared in this session")
    }

    func testRetryKeepsRandomSampleIDAndRefreshIsRateLimited() async throws {
        let transport = MockTransport(), identity = MemoryIdentity()
        await transport.configure(uploadStatus: 503)
        let session = SharingSession(identity: identity, transport: transport)
        session.enable(now: now, startPolling: false)
        session.enqueue([metric()], now: now)
        await session.refresh(now: later)
        await session.refresh(now: later.addingTimeInterval(1))
        await session.refresh(now: later.addingTimeInterval(30))
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 4)
        func sampleID(_ request: URLRequest) throws -> String {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            return try XCTUnwrap((object["samples"] as? [[String: Any]])?.first?["sampleId"] as? String)
        }
        XCTAssertEqual(try sampleID(requests[0]), try sampleID(requests[2]))
        XCTAssertNotEqual(requests[0].httpBody, requests[2].httpBody)
        XCTAssertEqual(session.pendingCount, 1)
        session.disable()
        XCTAssertEqual(session.pendingCount, 0)
    }

    func testOffDuringInflightUploadCannotPollOrRestoreBoard() async {
        let transport = MockTransport(), identity = MemoryIdentity()
        await transport.configure(pause: true)
        let session = SharingSession(identity: identity, transport: transport)
        session.enable(now: now, startPolling: false)
        session.enqueue([metric()], now: now)
        let task = Task { await session.refresh(now: later) }
        while !(await transport.isSuspended()) { await Task.yield() }
        session.disable()
        await transport.resume()
        await task.value
        XCTAssertNil(session.board)
        XCTAssertEqual(session.pendingCount, 0)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
    }

    func testUnsafeModelIsUnknownAndInvalidTimingsAreOmitted() throws {
        let sample = try XCTUnwrap(SharedSample(metric(model: "/private/prompt text")))
        XCTAssertEqual(sample.model, "unknown")
        XCTAssertNil(SharedSample(TurnMetric(id: "bad", completedAt: now, model: nil, outputTokens: 10_000_001, durationSeconds: 1, codexTTFTSeconds: nil, turnThroughputTPS: 1)))
        let nullSample = try XCTUnwrap(SharedSample(TurnMetric(id: "bad-ttft", completedAt: now, model: nil, outputTokens: 1, durationSeconds: 1, codexTTFTSeconds: 2, turnThroughputTPS: 1)))
        XCTAssertNil(nullSample.ttftMs)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: SampleEnvelope(sentAt: now, samples: [nullSample]).encoded()) as? [String: Any])
        let row = try XCTUnwrap((object["samples"] as? [[String: Any]])?.first)
        XCTAssertTrue(row["ttftMs"] is NSNull)
        XCTAssertTrue(row["reasoningOutputTokens"] is NSNull)
    }

    func testLegacyClaudeParserRecordsAreNeverShared() {
        func claude(_ parser: String) -> TurnMetric {
            TurnMetric(id: parser, completedAt: now, model: "claude-test", outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: nil, turnThroughputTPS: 10, client: "claude-code", parserVersion: parser, metricVersion: "claude-observed-turn-v1", sourceKind: "primary", provider: "unknown", delegatedOutputTokens: 0)
        }
        XCTAssertNil(SharedSample(claude("claude-transcript-v1")))
        XCTAssertNil(SharedSample(claude("claude-transcript-v2")))
        XCTAssertNotNil(SharedSample(claude("claude-transcript-v3")))
        XCTAssertNotNil(SharedSample(claude("claude-transcript-v4")))
        XCTAssertTrue(claude("claude-transcript-v2").isSupportedSourceTuple, "v2 stays displayable locally")
    }

    func testTheQueueNeverHoldsMoreThanTheCapEvenWhileABatchIsAppended() async throws {
        let transport = MockTransport()
        let session = SharingSession(identity: MemoryIdentity(), transport: transport, jitter: { 0 })
        session.enable(now: now, startPolling: false)
        // 1,100 distinct turns in one batch: the output token count tells them apart.
        let batch = (0..<1_100).map { index in
            TurnMetric(id: "turn-\(index)", completedAt: now, model: "gpt-test", outputTokens: index + 1, durationSeconds: 10, codexTTFTSeconds: 1, turnThroughputTPS: 10, clientVersion: "0.159.2", sourceKind: "primary", provider: "openai", delegatedOutputTokens: 0)
        }
        session.enqueue(batch, now: now)
        XCTAssertEqual(session.largestQueue, SharingSession.maximumQueued, "never above the cap, not even for an instant")
        XCTAssertEqual(session.pendingCount, 1_000)
        // The oldest 100 made room: the first upload starts with the 101st turn.
        await session.refresh(now: later)
        let requests = await transport.snapshot()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(uploads(requests).first?.httpBody)) as? [String: Any])
        let tokens = try XCTUnwrap(object["samples"] as? [[String: Any]]).compactMap { $0["outputTokens"] as? Int }
        XCTAssertEqual(tokens, Array(101...150))
    }

    func testQueueIsBoundedAndExpiresAfterADay() {
        let session = SharingSession(identity: MemoryIdentity(), transport: MockTransport())
        session.enable(now: now, startPolling: false)
        session.enqueue((0..<1100).map { metric(id: "\($0)") }, now: now)
        XCTAssertEqual(session.pendingCount, 1000)
        session.enqueue([], now: now.addingTimeInterval(86_401))
        XCTAssertEqual(session.pendingCount, 0)
    }

    func testGlobalBoardDecodesOptionalExactCohortAndMetricFields() throws {
        let json = #"{"schemaVersion":1,"generatedAt":"2026-10-03T10:00:00Z","dataAsOf":null,"collectionEnabled":true,"state":"stale","window":"24h","methodology":{"statistics":"percentiles across contributor medians","publicationMode":"early_data","minimumContributors":1,"minimumTurns":1,"observationBucketMinutes":5,"streamingSpeedAvailable":false,"source":"self-reported community observations","detectorVersion":"community-v1-5m"},"cohorts":[{"id":"[\"gpt-test\",\"openai\",\"0.159.2\",\"codex-rollout-v1\",\"turn-v1\",\"high\",\"codex\"]","model":"gpt-test","provider":"openai","clientVersion":"0.159.2","reasoningEffort":"high","client":"codex","parserVersion":"codex-rollout-v1","metricVersion":"turn-v1","contributors":4,"turns":12,"throughputContributors":3,"throughputTurns":11,"ttftContributors":2,"ttftTurns":9,"medianThroughput":8.5,"minThroughput":3.0,"maxThroughput":20.0,"p10Throughput":4.0,"medianTtftMs":900.0,"minTtftMs":200.0,"maxTtftMs":1800.0,"p95TtftMs":1700.0}],"alerts":[]}"#
        let board = try JSONDecoder().decode(GlobalBoard.self, from: Data(json.utf8))
        let cohort = try XCTUnwrap(board.cohorts.first)
        XCTAssertEqual(board.methodology?.statistics, "percentiles across contributor medians")
        XCTAssertEqual(board.publicationMode, "early_data")
        XCTAssertEqual(cohort.clientVersion, "0.159.2")
        XCTAssertEqual(cohort.reasoningEffort, "high")
        XCTAssertEqual(cohort.client, "codex")
        XCTAssertEqual(cohort.parserVersion, "codex-rollout-v1")
        XCTAssertEqual(cohort.metricVersion, "turn-v1")
        XCTAssertEqual(cohort.throughputTurns, 11)
        XCTAssertEqual(cohort.minThroughput, 3)
        XCTAssertEqual(cohort.maxThroughput, 20)
        XCTAssertEqual(cohort.ttftTurns, 9)
        XCTAssertEqual(cohort.minTtftMs, 200)
        XCTAssertEqual(cohort.maxTtftMs, 1_800)

        let legacy = #"{"schemaVersion":1,"collectionEnabled":true,"state":"early_data","window":"15m","cohorts":[{"id":"legacy","model":"gpt-test","provider":"openai","contributors":1,"turns":1}],"alerts":[]}"#
        let oldBoard = try JSONDecoder().decode(GlobalBoard.self, from: Data(legacy.utf8))
        XCTAssertNil(oldBoard.cohorts.first?.reasoningEffort)
        XCTAssertNil(oldBoard.cohorts.first?.client)
    }

    func testGlobalBoardDecodesOptionalComparisonAndSignalFieldsIncludingNulls() throws {
        let json = #"{"schemaVersion":1,"collectionEnabled":true,"state":"ready","window":"24h","cohorts":[{"id":"cohort","model":"gpt-test","provider":"openai","contributors":3,"turns":9,"comparison":{"throughput":{"method":"median of turn observations","current":{"startAt":"2026-10-02T10:00:00Z","endAt":"2026-10-03T10:00:00Z","median":12.5,"contributors":3,"turns":9},"previous":null,"changePercent":null,"availability":"outside_retention"},"ttft":{"current":{"median":800,"contributors":2,"turns":4},"previous":{"median":1000,"contributors":2,"turns":5},"changePercent":-20,"availability":"available"}},"signals":{"throughput":null,"ttft":{"state":"insufficient_baseline","reason":"Need more baseline buckets","baselineBuckets":2,"baselineDays":1,"baselineHours":2.5,"baselineMedian":900,"changePercent":null,"lastObservedAt":"2026-10-03T09:55:00Z","recentContributors":2,"recentTurns":4}}}],"alerts":[]}"#
        let board = try JSONDecoder().decode(GlobalBoard.self, from: Data(json.utf8))
        let cohort = try XCTUnwrap(board.cohorts.first)
        let throughput = try XCTUnwrap(cohort.comparison?.throughput)
        XCTAssertEqual(throughput.method, "median of turn observations")
        XCTAssertEqual(throughput.current?.median, 12.5)
        XCTAssertNil(throughput.previous)
        XCTAssertNil(throughput.changePercent)
        XCTAssertEqual(throughput.availability, "outside_retention")
        XCTAssertEqual(cohort.comparison?.ttft?.changePercent, -20)
        XCTAssertNil(cohort.signals?.throughput)
        XCTAssertEqual(cohort.signals?.ttft?.baselineBuckets, 2)
        XCTAssertEqual(cohort.signals?.ttft?.baselineDays, 1)
        XCTAssertEqual(cohort.signals?.ttft?.recentTurns, 4)
    }
}
