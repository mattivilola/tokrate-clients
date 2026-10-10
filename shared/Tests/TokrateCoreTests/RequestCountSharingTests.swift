import CryptoKit
import Foundation
import XCTest
@testable import TokrateCore

private final class CountIdentity: SharingIdentity, @unchecked Sendable {
    let key = Curve25519.Signing.PrivateKey().rawRepresentation
    func loadOrCreate() throws -> Data { key }
}

private actor CountTransport: SharingTransport {
    private(set) var requests: [URLRequest] = []
    private var uploadStatus = 200

    func configure(uploadStatus: Int) { self.uploadStatus = uploadStatus }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if request.httpMethod == "POST" { return (Data(), uploadStatus) }
        return (Data(#"{"schemaVersion":1,"generatedAt":null,"dataAsOf":null,"collectionEnabled":true,"state":"insufficient_data","window":"15m","cohorts":[],"alerts":[]}"#.utf8), 200)
    }

    func uploads() -> [Upload] {
        requests.filter { $0.httpMethod == "POST" }.map {
            Upload(
                body: $0.httpBody ?? Data(), key: $0.value(forHTTPHeaderField: "X-Tokrate-Key"),
                signature: $0.value(forHTTPHeaderField: "X-Tokrate-Signature")
            )
        }
    }
}

private struct Upload: Sendable {
    let body: Data
    let key: String?
    let signature: String?
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
}

@MainActor
final class RequestCountSharingTests: XCTestCase {
    /// A five-minute UTC boundary; its bucket closes at +300 and its totals are due at +600.
    private let bucket = Date(timeIntervalSince1970: 1_791_020_400)
    private var consent: Date { bucket.addingTimeInterval(5) }

    private func at(_ seconds: Double) -> Date { bucket.addingTimeInterval(seconds) }

    private func outcome(
        _ kind: RequestOutcome.Kind = .succeeded, at seconds: Double = 10, key: String = UUID().uuidString,
        client: String = "claude-code", model: String = "claude-opus-5-5", provider: String = "anthropic", version: String? = "2.1.295"
    ) -> RequestOutcome {
        RequestOutcome(
            dedupeKey: key, occurredAt: at(seconds), client: client, clientVersion: version,
            parserVersion: RequestOutcome.parserVersions[client]!, model: model, provider: provider, kind: kind
        )!
    }

    private func metric(id: String = "local", completedAt: Double = 10, model: String = "gpt-test", version: String = "0.159.2") -> TurnMetric {
        TurnMetric(
            id: id, completedAt: at(completedAt), model: model, outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: 1,
            turnThroughputTPS: 10, clientVersion: version, sourceKind: "primary", provider: "openai", reasoningEffort: "medium",
            responseOutputTokens: 100_000, responseDurationSeconds: 90, responseCount: 3, delegatedOutputTokens: 99_999_999,
            surface: .cli, inputTokens: 90_000_000, cacheReadInputTokens: 80_000_000
        )
    }

    private func makeSession(_ transport: CountTransport, jitter: TimeInterval = 0) -> SharingSession {
        SharingSession(identity: CountIdentity(), transport: transport, jitter: { jitter })
    }

    private func counts(_ upload: Upload) -> [[String: Any]] {
        upload.json["requestCounts"] as? [[String: Any]] ?? []
    }

    // MARK: The entry

    func testAnEntryHasExactlyTheContractKeysAndValues() throws {
        let entry = try XCTUnwrap(SharedRequestCount(
            countId: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, observedAt: at(130), client: "claude-code",
            clientVersion: "2.1.295", parserVersion: "claude-transcript-v4", model: "claude-opus-5-5", provider: "anthropic",
            succeeded: 41, overloaded: 3, serverError: 0
        ))
        let data = try SampleEnvelope.makeEncoder().encode(entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["countId", "observedAt", "client", "clientVersion", "appVersion", "parserVersion", "metricVersion", "model", "provider", "succeeded", "overloaded", "serverError"])
        XCTAssertEqual(object["countId"] as? String, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(object["observedAt"] as? String, ISO8601DateFormatter().string(from: bucket), "floored to its five-minute period")
        XCTAssertEqual(object["appVersion"] as? String, "0.1.22")
        XCTAssertEqual(object["metricVersion"] as? String, "request-outcome-v1")
        XCTAssertEqual(object["succeeded"] as? Int, 41)
        XCTAssertEqual(object["overloaded"] as? Int, 3)
        XCTAssertEqual(object["serverError"] as? Int, 0)
    }

    func testAnEntryIsRefusedOnEveryRuleTheServerEnforces() {
        func make(
            client: String = "claude-code", parser: String = "claude-transcript-v4", model: String = "m", provider: String = "anthropic",
            version: String? = "1", s: Int = 1, o: Int = 0, e: Int = 0
        ) -> SharedRequestCount? {
            SharedRequestCount(
                observedAt: bucket, client: client, clientVersion: version, parserVersion: parser, model: model, provider: provider,
                succeeded: s, overloaded: o, serverError: e
            )
        }
        XCTAssertNotNil(make())
        XCTAssertNil(make(s: 0), "an all-zero entry is never sent")
        XCTAssertNil(make(s: 10_001))
        XCTAssertNotNil(make(s: 10_000, o: 10_000, e: 10_000))
        XCTAssertNil(make(s: -1, o: 5))
        XCTAssertNil(make(client: "grok-build", parser: "grok-session-v2"))
        XCTAssertNil(make(client: "antigravity", parser: "antigravity-conversation-v1", provider: "google"))
        XCTAssertNil(make(parser: "claude-transcript-v3"))
        XCTAssertNil(make(model: "unknown"))
        XCTAssertNil(make(model: "has space"))
        XCTAssertNil(make(model: String(repeating: "m", count: 81)))
        XCTAssertNotNil(make(model: String(repeating: "m", count: 80)))
        XCTAssertNil(make(provider: "unknown"))
        XCTAssertNil(make(provider: "openai"), "Claude Code has no OpenAI route")
        XCTAssertNil(make(client: "codex", parser: "codex-rollout-v2", provider: "anthropic"))
        XCTAssertNotNil(make(client: "opencode", parser: "opencode-db-v1", provider: "xai"))
        XCTAssertNil(make(client: "opencode", parser: "opencode-db-v1", provider: "moonshot"))
        XCTAssertNotNil(make(client: "kimi-code", parser: "kimi-wire-v1", provider: "moonshot"))
        XCTAssertEqual(make(version: "bad version!")?.clientVersion, "unknown")
        XCTAssertEqual(make(version: nil)?.clientVersion, "unknown")
    }

    func testTotalsAboveTheBoundAreSplitIntoSeveralEntries() {
        let entries = SharedRequestCount.entries(
            observedAt: bucket, client: "claude-code", clientVersion: "1", parserVersion: "claude-transcript-v4", model: "m",
            provider: "anthropic", succeeded: 25_000, overloaded: 10_001, serverError: 3
        )
        XCTAssertEqual(entries.map(\.succeeded), [10_000, 10_000, 5_000])
        XCTAssertEqual(entries.map(\.overloaded), [10_000, 1, 0])
        XCTAssertEqual(entries.map(\.serverError), [3, 0, 0])
        XCTAssertEqual(Set(entries.map(\.countId)).count, 3)
        XCTAssertTrue(SharedRequestCount.entries(
            observedAt: bucket, client: "claude-code", clientVersion: "1", parserVersion: "claude-transcript-v4", model: "m",
            provider: "anthropic", succeeded: 0, overloaded: 0, serverError: 0
        ).isEmpty)
        XCTAssertTrue(SharedRequestCount.entries(
            observedAt: bucket, client: "claude-code", clientVersion: "1", parserVersion: "claude-transcript-v4", model: "unknown",
            provider: "anthropic", succeeded: 5, overloaded: 0, serverError: 0
        ).isEmpty, "an invalid identity sends nothing")
    }

    // MARK: Collection

    func testTotalsLeaveOnePeriodAfterTheirBucketClosesAsOneEntryPerIdentity() async throws {
        let transport = CountTransport(), session = makeSession(transport)
        session.enable(now: consent, startPolling: false)
        session.enqueueOutcomes([
            outcome(.succeeded, at: 10), outcome(.succeeded, at: 100), outcome(.overloaded, at: 200), outcome(.serverError, at: 299),
            outcome(.succeeded, at: 50, model: "claude-sonnet-5-5"),
            outcome(.succeeded, at: 60, version: "2.1.300"),
            // The next bucket is a different entry.
            outcome(.succeeded, at: 301)
        ], now: at(310))
        await session.refresh(now: at(599))
        var uploads = await transport.uploads()
        XCTAssertTrue(uploads.isEmpty, "nothing leaves before one full period after the bucket closed")

        await session.refresh(now: at(601))
        uploads = await transport.uploads()
        XCTAssertEqual(uploads.count, 1)
        let entries = counts(try XCTUnwrap(uploads.first))
        XCTAssertEqual(entries.count, 3, "the next bucket is not due yet")
        let main = try XCTUnwrap(entries.first { $0["model"] as? String == "claude-opus-5-5" && $0["clientVersion"] as? String == "2.1.295" })
        XCTAssertEqual(main["succeeded"] as? Int, 2)
        XCTAssertEqual(main["overloaded"] as? Int, 1)
        XCTAssertEqual(main["serverError"] as? Int, 1)
        XCTAssertEqual(main["observedAt"] as? String, ISO8601DateFormatter().string(from: bucket))
        XCTAssertEqual(main["parserVersion"] as? String, "claude-transcript-v4")
        XCTAssertEqual(main["provider"] as? String, "anthropic")
        XCTAssertEqual(entries.compactMap { $0["clientVersion"] as? String }.sorted(), ["2.1.295", "2.1.295", "2.1.300"])

        await session.refresh(now: at(901))
        uploads = await transport.uploads()
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(counts(uploads[1]).count, 1)
        XCTAssertEqual(counts(uploads[1]).first?["observedAt"] as? String, ISO8601DateFormatter().string(from: at(300)))
    }

    func testAnOutcomeIsCountedOnceHoweverOftenItIsReadAgain() async throws {
        let transport = CountTransport(), session = makeSession(transport)
        session.enable(now: consent, startPolling: false)
        let first = outcome(.succeeded, at: 10, key: "same"), second = outcome(.overloaded, at: 20, key: "other")
        session.enqueueOutcomes([first, second, first], now: at(100))
        session.enqueueOutcomes([first, second], now: at(200))
        session.enqueueOutcomes([outcome(.succeeded, at: 10, key: "same")], now: at(250))
        await session.refresh(now: at(601))
        let uploads = await transport.uploads()
        let entry = try XCTUnwrap(counts(XCTUnwrap(uploads.first)).first)
        XCTAssertEqual(entry["succeeded"] as? Int, 1)
        XCTAssertEqual(entry["overloaded"] as? Int, 1)
    }

    func testOnlyOutcomesFromTheStartOfTheConsentAndNotInTheFutureCount() async throws {
        let transport = CountTransport(), session = makeSession(transport)
        session.enable(now: consent, startPolling: false)
        session.enqueueOutcomes([
            outcome(.succeeded, at: 4, key: "before-consent"),
            outcome(.succeeded, at: 5, key: "at-consent"),
            outcome(.succeeded, at: 200, key: "future")
        ], now: at(100))
        // The future one is not remembered as seen: once its time has come it counts.
        session.enqueueOutcomes([outcome(.succeeded, at: 200, key: "future")], now: at(250))
        await session.refresh(now: at(601))
        let uploads = await transport.uploads()
        let entry = try XCTUnwrap(counts(XCTUnwrap(uploads.first)).first)
        XCTAssertEqual(entry["succeeded"] as? Int, 2, "at-consent and the later-eligible one; never the earlier outcome")
    }

    func testNothingIsCollectedWhileSharingIsOff() async {
        let transport = CountTransport(), session = makeSession(transport)
        session.enqueueOutcomes([outcome()], now: at(100))
        session.enable(now: consent, startPolling: false)
        await session.refresh(now: at(601))
        let uploads = await transport.uploads()
        XCTAssertTrue(uploads.isEmpty, "an outcome offered before sharing started is gone")
    }

    func testALateOutcomeStartsANewEntryAtTheNextPeriodBoundary() async throws {
        let transport = CountTransport(), session = makeSession(transport)
        session.enable(now: consent, startPolling: false)
        session.enqueueOutcomes([outcome(.succeeded, at: 10)], now: at(100))
        await session.refresh(now: at(601))
        var uploads = await transport.uploads()
        let firstID = try XCTUnwrap(counts(XCTUnwrap(uploads.first)).first?["countId"] as? String)

        // The bucket was already sent: this is a new entry, queued at the next boundary (T+900).
        session.enqueueOutcomes([outcome(.overloaded, at: 20), outcome(.succeeded, at: 30)], now: at(700))
        await session.refresh(now: at(899))
        uploads = await transport.uploads()
        XCTAssertEqual(uploads.count, 1)
        await session.refresh(now: at(901))
        uploads = await transport.uploads()
        XCTAssertEqual(uploads.count, 2)
        let late = try XCTUnwrap(counts(uploads[1]).first)
        XCTAssertNotEqual(late["countId"] as? String, firstID)
        XCTAssertEqual(late["observedAt"] as? String, ISO8601DateFormatter().string(from: bucket), "it keeps its own bucket")
        XCTAssertEqual(late["succeeded"] as? Int, 1)
        XCTAssertEqual(late["overloaded"] as? Int, 1)
    }

    func testEntriesOlderThanADayAreDropped() async {
        let transport = CountTransport(), session = makeSession(transport)
        session.enable(now: consent, startPolling: false)
        session.enqueueOutcomes([outcome()], now: at(100))
        await session.refresh(now: at(90_000))
        let uploads = await transport.uploads()
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertEqual(session.pendingRequestCountEntries, 0)
    }

    func testABucketAboveTheBoundIsSentAsSeveralEntries() async throws {
        let transport = CountTransport(), session = makeSession(transport)
        session.enable(now: consent, startPolling: false)
        session.enqueueOutcomes((0..<10_050).map { outcome(.succeeded, at: 10, key: "r\($0)") } + [outcome(.serverError, at: 11)], now: at(100))
        await session.refresh(now: at(601))
        let uploads = await transport.uploads()
        let entries = counts(try XCTUnwrap(uploads.first))
        XCTAssertEqual(entries.compactMap { $0["succeeded"] as? Int }.sorted(), [50, 10_000])
        XCTAssertEqual(entries.compactMap { $0["serverError"] as? Int }.reduce(0, +), 1)
        XCTAssertEqual(entries.count, 2)
    }

    func testTheQueueOfEntriesIsCappedAtAThousandSeparatelyFromSamples() {
        let transport = CountTransport(), session = makeSession(transport)
        session.enable(now: consent, startPolling: false)
        session.enqueue([metric()], now: at(100))
        session.enqueueOutcomes((0..<1_100).map { outcome(.succeeded, at: 10, model: "model-\($0)") }, now: at(100))
        session.enqueueOutcomes([], now: at(650))
        XCTAssertEqual(session.pendingRequestCountEntries, 1_000)
        XCTAssertEqual(session.largestCountQueue, 1_000, "the cap holds at every moment")
        XCTAssertEqual(session.pendingCount, 1, "the sample queue is separate")
    }

    func testDisablingAndRequiredUpdatesForgetEveryPendingCount() async {
        let transport = CountTransport(), session = makeSession(transport)
        await transport.configure(uploadStatus: 500)
        session.enable(now: consent, startPolling: false)
        session.enqueueOutcomes([outcome(), outcome(model: "other")], now: at(100))
        await session.refresh(now: at(601))
        XCTAssertEqual(session.pendingRequestCountEntries, 2, "queued, not delivered")
        session.enqueueOutcomes([outcome(at: 700, model: "pending-group")], now: at(710))

        session.disable()
        XCTAssertEqual(session.pendingRequestCountEntries, 0)
        session.enable(now: at(720), startPolling: false)
        let before = await transport.uploads().count
        await session.refresh(now: at(2_000))
        let after = await transport.uploads().count
        XCTAssertEqual(after, before, "neither the queued entries nor the pending totals survive")

        // HTTP 426 clears them too.
        let blocked = CountTransport(), stopped = makeSession(blocked)
        await blocked.configure(uploadStatus: 426)
        stopped.enable(now: consent, startPolling: false)
        stopped.enqueueOutcomes([outcome()], now: at(100))
        stopped.enqueueOutcomes([outcome(at: 700, model: "pending-group")], now: at(710))
        await stopped.refresh(now: at(601))
        XCTAssertTrue(stopped.requiresUpdate)
        XCTAssertFalse(stopped.isEnabled)
        XCTAssertEqual(stopped.pendingRequestCountEntries, 0)
    }

    // MARK: The upload

    func testEveryUploadIsAnEnvelopeOfVersionTwoWithBothKeysSignedOverItsExactBytes() async throws {
        let transport = CountTransport(), identity = CountIdentity()
        let session = SharingSession(identity: identity, transport: transport, jitter: { 0 })
        session.enable(now: consent, startPolling: false)
        session.enqueueOutcomes([outcome()], now: at(100))
        await session.refresh(now: at(601))

        session.enqueue([metric(id: "m1", completedAt: 20)], now: at(660))
        await session.refresh(now: at(1_000))
        let uploads = await transport.uploads()
        XCTAssertEqual(uploads.count, 2)

        for upload in uploads {
            XCTAssertEqual(upload.json["schemaVersion"] as? Int, 2)
            XCTAssertNotNil(upload.json["samples"] as? [Any], "both keys are always present")
            XCTAssertNotNil(upload.json["requestCounts"] as? [Any])
            let body = upload.body
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Curve25519.Signing.PrivateKey(rawRepresentation: identity.key).publicKey.rawRepresentation)
            XCTAssertEqual(upload.key, publicKey.rawRepresentation.base64EncodedString())
            let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(upload.signature)))
            XCTAssertTrue(publicKey.isValidSignature(signature, for: body), "the signature covers the exact body")
            XCTAssertEqual(Set(upload.json.keys), ["schemaVersion", "sentAt", "samples", "requestCounts"])
        }
        let text = String(decoding: uploads[0].body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"samples\":[]"), "a counts-only upload carries an empty samples array: \(text)")
        XCTAssertTrue(text.contains("\"schemaVersion\":2"))
        XCTAssertEqual(counts(uploads[0]).count, 1)
        XCTAssertEqual(counts(uploads[1]).count, 0)
        XCTAssertTrue(String(decoding: uploads[1].body, as: UTF8.self).contains("\"requestCounts\":[]"))
        XCTAssertEqual((uploads[1].json["samples"] as? [Any])?.count, 1)
    }

    func testSamplesAndCountsOfOneSlotShareOneUploadAndOneJitter() async throws {
        let transport = CountTransport()
        let draws = DrawCounter()
        let session = SharingSession(identity: CountIdentity(), transport: transport, jitter: { draws.next(20) })
        session.enable(now: consent, startPolling: false)
        session.enqueue([metric(completedAt: 10)], now: at(280))
        session.enqueueOutcomes([outcome(at: 15)], now: at(290))
        await session.refresh(now: at(610))
        var uploads = await transport.uploads()
        XCTAssertTrue(uploads.isEmpty, "the slot's delay has not passed")
        await session.refresh(now: at(625))
        uploads = await transport.uploads()
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual((uploads[0].json["samples"] as? [Any])?.count, 1)
        XCTAssertEqual(counts(uploads[0]).count, 1)
        XCTAssertEqual(draws.count, 1, "one random delay for the whole slot")
    }

    func testASuccessfulUploadRemovesBothKinds() async {
        let transport = CountTransport(), session = makeSession(transport)
        session.enable(now: consent, startPolling: false)
        session.enqueue([metric()], now: at(280))
        session.enqueueOutcomes([outcome()], now: at(290))
        await session.refresh(now: at(601))
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertEqual(session.pendingRequestCountEntries, 0)
        await session.refresh(now: at(700))
        let uploads = await transport.uploads()
        XCTAssertEqual(uploads.count, 1, "nothing is sent twice")
    }

    func testARejectedUploadDropsBothKinds() async {
        for code in [400, 413, 422] {
            let transport = CountTransport(), session = makeSession(transport)
            await transport.configure(uploadStatus: code)
            session.enable(now: consent, startPolling: false)
            session.enqueue([metric()], now: at(280))
            session.enqueueOutcomes([outcome()], now: at(290))
            await session.refresh(now: at(601))
            XCTAssertEqual(session.pendingCount, 0, "\(code)")
            XCTAssertEqual(session.pendingRequestCountEntries, 0, "\(code)")
            XCTAssertTrue(session.isEnabled)
            await session.refresh(now: at(700))
            let uploads = await transport.uploads()
            XCTAssertEqual(uploads.count, 1, "\(code): not retried")
        }
    }

    func testAFailedUploadKeepsBothKindsAndRetriesTheSameIdsInANewEnvelope() async throws {
        let transport = CountTransport(), session = makeSession(transport)
        await transport.configure(uploadStatus: 503)
        session.enable(now: consent, startPolling: false)
        session.enqueue([metric()], now: at(280))
        session.enqueueOutcomes([outcome()], now: at(290))
        await session.refresh(now: at(601))
        XCTAssertEqual(session.pendingCount, 1)
        XCTAssertEqual(session.pendingRequestCountEntries, 1)
        await session.refresh(now: at(610))
        var uploads = await transport.uploads()
        XCTAssertEqual(uploads.count, 1, "at most one attempt per 30 seconds")
        await transport.configure(uploadStatus: 200)
        await session.refresh(now: at(640))
        uploads = await transport.uploads()
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(counts(uploads[0]).first?["countId"] as? String, counts(uploads[1]).first?["countId"] as? String)
        XCTAssertEqual((uploads[0].json["samples"] as? [[String: Any]])?.first?["sampleId"] as? String, (uploads[1].json["samples"] as? [[String: Any]])?.first?["sampleId"] as? String)
        XCTAssertNotEqual(uploads[0].json["sentAt"] as? String, uploads[1].json["sentAt"] as? String, "a fresh sentAt")
        XCTAssertEqual(session.pendingRequestCountEntries, 0)
    }

    func testAnUpdateRequiredResponseStopsSharingAndDiscardsBothKinds() async {
        let transport = CountTransport(), session = makeSession(transport)
        await transport.configure(uploadStatus: 426)
        session.enable(now: consent, startPolling: false)
        session.enqueue([metric()], now: at(280))
        session.enqueueOutcomes([outcome()], now: at(290))
        await session.refresh(now: at(601))
        XCTAssertTrue(session.requiresUpdate)
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertEqual(session.pendingRequestCountEntries, 0)
        session.enable(now: at(700), startPolling: false)
        XCTAssertFalse(session.isEnabled, "sharing stays off until the app is updated")
    }

    func testAFullBatchOfBothKindsFitsTheBodyLimitOrIsSplitAcrossAttempts() async throws {
        let transport = CountTransport(), session = makeSession(transport)
        let longModel = String(repeating: "m", count: 80)
        session.enable(now: consent, startPolling: false)
        session.enqueue((0..<60).map { metric(id: "s\($0)", model: String(longModel.dropLast(2)) + String(format: "%02d", $0), version: String(repeating: "9", count: 40)) }, now: at(280))
        session.enqueueOutcomes((0..<60).map { outcome(at: 15, model: String(longModel.dropLast(2)) + String(format: "%02d", $0), version: String(repeating: "9", count: 40)) }, now: at(290))
        for step in 0..<12 {
            await session.refresh(now: at(601 + Double(step) * 31))
        }
        let uploads = await transport.uploads()
        var samples = 0, entries = 0
        for upload in uploads {
            let size = upload.body.count
            XCTAssertLessThanOrEqual(size, 65_536)
            let sampleCount = (upload.json["samples"] as? [Any])?.count ?? 0, entryCount = counts(upload).count
            XCTAssertLessThanOrEqual(sampleCount, 50)
            XCTAssertLessThanOrEqual(entryCount, 50)
            XCTAssertGreaterThanOrEqual(sampleCount + entryCount, 1)
            samples += sampleCount
            entries += entryCount
        }
        // With the longest accepted names and maxed-out numbers, 50 + 50 items still fit in one body; the
        // trimming in `uploadBatch` is the guard that keeps it so should the entry shapes grow.
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(samples, 60)
        XCTAssertEqual(entries, 60)
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertEqual(session.pendingRequestCountEntries, 0)
    }

    func testQueuedEntriesAndDueTotalsWakeTheLoop() async {
        let transport = CountTransport()
        let session = SharingSession(identity: CountIdentity(), transport: transport, jitter: { 5 })
        session.enable(now: consent, startPolling: false)
        session.enqueueOutcomes([outcome(at: 10)], now: at(100))
        await session.refresh(now: at(590))
        XCTAssertEqual(session.secondsUntilNextRefresh(now: at(595)), 5, accuracy: 0.001, "the bucket's totals become due at T+600")
        await session.refresh(now: at(601))
        let early = await transport.uploads()
        XCTAssertTrue(early.isEmpty, "the slot's 5 s delay has not passed")
        XCTAssertEqual(session.pendingRequestCountEntries, 1)
        XCTAssertEqual(session.secondsUntilNextRefresh(now: at(602)), 3, accuracy: 0.001, "a queued entry wakes the loop at its upload time, before the board is due")
    }

    // MARK: Nothing reaches the history

    func testOutcomesNeverAppearInTheTurnRecordsOrTheirExports() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let text = String(decoding: try encoder.encode(metric()), as: UTF8.self)
        for word in ["outcome", "succeeded", "overloaded", "serverError", "requestCount", "dedupe"] {
            XCTAssertFalse(text.contains(word), word)
        }
    }

    func testReplaysAndExportsReadNoOutcomes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tokrate-outcome-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.jsonl")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func record(_ seconds: Double, _ extra: [String: Any]) throws -> String {
            var value: [String: Any] = ["sessionId": "s", "isSidechain": false, "userType": "external", "version": "2.1.295", "uuid": "u\(seconds)", "timestamp": formatter.string(from: at(seconds))]
            value.merge(extra) { _, new in new }
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n"
        }
        let lines = try [
            record(0, ["type": "user", "parentUuid": NSNull(), "message": ["role": "user", "content": "PRIVATE"]]),
            record(5, ["type": "assistant", "requestId": "req_011CABCDEFGHIJKLMNOPQRST", "message": [
                "id": "msg_01ABCDEFGHIJKLMNOPQRSTUV", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": "end_turn",
                "content": [["type": "text", "text": "x"]], "usage": ["output_tokens": 400]
            ] as [String: Any]]),
            record(8, ["type": "assistant", "isApiErrorMessage": true, "apiErrorStatus": 529, "message": [
                "id": "0f0d7a52", "role": "assistant", "model": "<synthetic>", "stop_reason": "stop_sequence",
                "content": [["type": "text", "text": "API Error: Repeated 529 Overloaded errors"]], "usage": ["output_tokens": 0]
            ] as [String: Any]])
        ]
        try Data(lines.joined().utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: at(20)], ofItemAtPath: file.path)

        let live = ClaudeSessionMonitor(root: folder, liveSince: .distantPast)
        let update = try await live.poll(now: at(100))
        XCTAssertEqual(update.outcomes.map(\.kind), [.succeeded, .overloaded])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metrics = String(decoding: try encoder.encode(update.metrics), as: UTF8.self)
        XCTAssertFalse(metrics.contains("overloaded"))
        XCTAssertFalse(metrics.contains("outcome"))

        // A replay for an export reads with `liveSince` in the future: no outcome is produced at all.
        let replay = ClaudeSessionMonitor(root: folder, liveSince: .distantFuture, scope: .replay(retention: 400 * 86_400))
        let replayed = try await replay.poll(now: at(100))
        XCTAssertTrue(replayed.outcomes.isEmpty)
        XCTAssertFalse(replayed.metrics.isEmpty)
    }
}

private final class DrawCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var drawn = 0
    var count: Int { lock.withLock { drawn } }
    func next(_ value: TimeInterval) -> TimeInterval { lock.withLock { drawn += 1; return value } }
}
