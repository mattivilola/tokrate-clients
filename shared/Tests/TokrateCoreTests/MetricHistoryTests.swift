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

    func testRecordsSavedBeforeResponseSpeedDecodeWithNilFieldsAndTheLegacyParserVersion() throws {
        // History written before multi-client support and before response speed: no client,
        // parserVersion, metricVersion or any response field.
        let legacy = #"{"id":"legacy","completedAt":"2026-10-03T20:00:00Z","model":"gpt-test","outputTokens":100,"durationSeconds":10,"codexTTFTSeconds":1.5,"turnThroughputTPS":10}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TurnMetric.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.parserVersion, "codex-rollout-v1")
        XCTAssertEqual(decoded.parserVersion, TurnMetric.legacyCodexParserVersion)
        XCTAssertEqual(decoded.client, "codex")
        XCTAssertNil(decoded.responseOutputTokens)
        XCTAssertNil(decoded.responseDurationSeconds)
        XCTAssertNil(decoded.responseCount)
        XCTAssertNil(decoded.providerRegion)
        XCTAssertNil(decoded.responseSpeedTPS)
        XCTAssertTrue(decoded.isSupportedSourceTuple)

        // New records default to the current Codex parser.
        XCTAssertEqual(TurnMetric.codexParserVersion, "codex-rollout-v2")
        XCTAssertEqual(metric(id: "fresh", at: .now).parserVersion, "codex-rollout-v2")
        XCTAssertTrue(TurnMetric.isSupportedSourceTuple(client: "codex", parserVersion: "codex-rollout-v2", metricVersion: "turn-v1"))
        XCTAssertTrue(TurnMetric.isSupportedSourceTuple(client: "claude-code", parserVersion: "claude-transcript-v4", metricVersion: "claude-observed-turn-v1"))
        XCTAssertTrue(TurnMetric.isSupportedSourceTuple(client: "claude-code", parserVersion: "claude-transcript-v4", metricVersion: "claude-observed-subagent-turn-v1"))
    }

    func testResponseFieldsRoundTripAndAreEncodedOnlyWhenPresent() throws {
        let full = TurnMetric(
            id: "full", completedAt: Date(timeIntervalSince1970: 1_800_000_000), model: "claude-sonnet-4-5", outputTokens: 1_000,
            durationSeconds: 60, codexTTFTSeconds: nil, turnThroughputTPS: 16.6, client: "claude-code",
            parserVersion: "claude-transcript-v4", metricVersion: "claude-observed-turn-v1", provider: "amazon-bedrock",
            responseOutputTokens: 900, responseDurationSeconds: 18, responseCount: 2, providerRegion: "us"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        XCTAssertEqual(object["responseOutputTokens"] as? Int, 900)
        XCTAssertEqual(object["responseDurationSeconds"] as? Double, 18)
        XCTAssertEqual(object["responseCount"] as? Int, 2)
        XCTAssertEqual(object["providerRegion"] as? String, "us")
        let decoded = try JSONDecoder().decode(TurnMetric.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(decoded, full)
        XCTAssertEqual(try XCTUnwrap(decoded.responseSpeedTPS), 50, accuracy: 0.001)

        let bare = metric(id: "bare", at: Date(timeIntervalSince1970: 1_800_000_000))
        let bareObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? [String: Any])
        for key in ["responseOutputTokens", "responseDurationSeconds", "responseCount", "providerRegion"] {
            XCTAssertNil(bareObject[key], "\(key) is encoded only when present")
        }
        XCTAssertEqual(try JSONDecoder().decode(TurnMetric.self, from: JSONEncoder().encode(bare)), bare)
    }

    func testResponseFieldsTravelTogetherOrNotAtAll() {
        func make(tokens: Int?, seconds: Double?, count: Int?) -> TurnMetric {
            TurnMetric(
                id: "x", completedAt: Date(timeIntervalSince1970: 10), model: nil, outputTokens: 1_000, durationSeconds: 60,
                codexTTFTSeconds: nil, turnThroughputTPS: 1, responseOutputTokens: tokens, responseDurationSeconds: seconds, responseCount: count
            )
        }
        let valid = make(tokens: 500, seconds: 10, count: 1)
        XCTAssertEqual(valid.responseOutputTokens, 500)
        XCTAssertEqual(valid.responseDurationSeconds, 10)
        XCTAssertEqual(valid.responseCount, 1)
        for partial in [
            make(tokens: nil, seconds: 10, count: 1), make(tokens: 500, seconds: nil, count: 1), make(tokens: 500, seconds: 10, count: nil),
            make(tokens: 0, seconds: 10, count: 1), make(tokens: -5, seconds: 10, count: 1),
            make(tokens: 500, seconds: 0, count: 1), make(tokens: 500, seconds: -1, count: 1), make(tokens: 500, seconds: .infinity, count: 1),
            make(tokens: 500, seconds: .nan, count: 1), make(tokens: 500, seconds: 10, count: 0)
        ] {
            XCTAssertNil(partial.responseOutputTokens)
            XCTAssertNil(partial.responseDurationSeconds)
            XCTAssertNil(partial.responseCount)
            XCTAssertNil(partial.responseSpeedTPS)
        }
    }

    func testDecodedInconsistentResponseFieldsYieldNoSpeed() throws {
        let json = #"{"id":"x","completedAt":1,"outputTokens":100,"durationSeconds":10,"turnThroughputTPS":10,"responseOutputTokens":50,"responseDurationSeconds":5,"responseCount":0}"#
        let decoded = try JSONDecoder().decode(TurnMetric.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.responseCount, 0)
        XCTAssertNil(decoded.responseSpeedTPS, "a zero count is not a measurement")
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
