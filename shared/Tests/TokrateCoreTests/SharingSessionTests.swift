import CryptoKit
import Foundation
import TokrateCore
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

@MainActor
final class SharingSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_020_401)
    private func metric(id: String = "LOCAL_PRIVATE_DIGEST", date: Date? = nil, model: String? = "gpt-test", reasoningEffort: String? = nil) -> TurnMetric {
        TurnMetric(id: id, completedAt: date ?? now, model: model, outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: 1, turnThroughputTPS: 10, clientVersion: "0.159.2", sourceKind: "primary", provider: "openai", reasoningEffort: reasoningEffort)
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

        await session.refresh(now: now.addingTimeInterval(2))

        XCTAssertTrue(session.requiresUpdate)
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertNil(session.board)
        XCTAssertTrue(session.status.contains("Check for Updates"))
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "POST")

        session.enable(now: now.addingTimeInterval(30), startPolling: false)
        session.enqueue([metric(id: "after-block", date: now.addingTimeInterval(31))], now: now.addingTimeInterval(31))
        await session.refresh(now: now.addingTimeInterval(31))
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
        await session.refresh(now: now)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        let request = requests[0], body = try XCTUnwrap(request.httpBody)
        let publicKeyData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(request.value(forHTTPHeaderField: "X-Tokrate-Key"))))
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(request.value(forHTTPHeaderField: "X-Tokrate-Signature"))))
        XCTAssertTrue(try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData).isValidSignature(signature, for: body))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(Set(samples[0].keys), Set(["sampleId", "observedAt", "client", "clientVersion", "appVersion", "parserVersion", "metricVersion", "model", "provider", "reasoningEffort", "sourceKind", "outputTokens", "reasoningOutputTokens", "durationMs", "ttftMs"]))
        XCTAssertEqual(samples[0]["appVersion"] as? String, "0.1.13")
        XCTAssertEqual(samples[0]["reasoningEffort"] as? String, "unknown")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("LOCAL_PRIVATE_DIGEST"))
        let observed = try XCTUnwrap(ISO8601DateFormatter().date(from: try XCTUnwrap(samples[0]["observedAt"] as? String)))
        XCTAssertEqual(observed.timeIntervalSince1970.truncatingRemainder(dividingBy: 300), 0)
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertNotNil(session.board)
        session.disable()
        XCTAssertNil(session.board)
        await session.refresh(now: now.addingTimeInterval(100))
        let after = await transport.snapshot()
        XCTAssertEqual(after.count, 2)
    }

    func testUploadReportsOnlyAllowlistedEffortAndUsesUnknownFallback() throws {
        let reported = try XCTUnwrap(SharedSample(metric(reasoningEffort: "ultra")))
        XCTAssertEqual(reported.appVersion, "0.1.13")
        XCTAssertEqual(reported.reasoningEffort, "ultra")
        let missing = try XCTUnwrap(SharedSample(metric()))
        XCTAssertEqual(missing.reasoningEffort, "unknown")
        let invalidMetric = TurnMetric(id: "bad-effort", completedAt: now, model: "gpt-test", outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: nil, turnThroughputTPS: 10, reasoningEffort: "automatic")
        XCTAssertEqual(try XCTUnwrap(SharedSample(invalidMetric)).reasoningEffort, "unknown")
    }

    func testRetryKeepsRandomSampleIDAndRefreshIsRateLimited() async throws {
        let transport = MockTransport(), identity = MemoryIdentity()
        await transport.configure(uploadStatus: 503)
        let session = SharingSession(identity: identity, transport: transport)
        session.enable(now: now, startPolling: false)
        session.enqueue([metric()], now: now)
        await session.refresh(now: now)
        await session.refresh(now: now.addingTimeInterval(1))
        await session.refresh(now: now.addingTimeInterval(30))
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
        let task = Task { await session.refresh(now: now) }
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
            TurnMetric(id: parser, completedAt: now, model: "claude-test", outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: nil, turnThroughputTPS: 10, client: "claude-code", parserVersion: parser, metricVersion: "claude-observed-turn-v1", sourceKind: "primary", provider: "unknown")
        }
        XCTAssertNil(SharedSample(claude("claude-transcript-v1")))
        XCTAssertNil(SharedSample(claude("claude-transcript-v2")))
        XCTAssertNotNil(SharedSample(claude("claude-transcript-v3")))
        XCTAssertTrue(claude("claude-transcript-v2").isSupportedSourceTuple, "v2 stays displayable locally")
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
