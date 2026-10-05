import Foundation
import TokrateCore
import XCTest

final class SharedSampleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func claude(
        provider: String? = "anthropic", region: String? = nil, outputTokens: Int = 1_000, durationSeconds: Double = 100,
        tokens: Int? = nil, seconds: Double? = nil, count: Int? = nil
    ) -> TurnMetric {
        TurnMetric(
            id: "LOCAL_PRIVATE_DIGEST", completedAt: now, model: "claude-sonnet-4-5", outputTokens: outputTokens,
            durationSeconds: durationSeconds, codexTTFTSeconds: nil, turnThroughputTPS: Double(outputTokens) / durationSeconds,
            client: "claude-code", clientVersion: "2.1.37", parserVersion: "claude-transcript-v4",
            metricVersion: "claude-observed-turn-v1", sourceKind: "primary", provider: provider,
            responseOutputTokens: tokens, responseDurationSeconds: seconds, responseCount: count, providerRegion: region
        )
    }

    private func json(_ sample: SharedSample) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
    }

    func testAllowlistedKeysAppVersionAndAlwaysEncodedNulls() throws {
        let sample = try XCTUnwrap(SharedSample(claude()))
        let object = try json(sample)
        XCTAssertEqual(Set(object.keys), [
            "sampleId", "observedAt", "client", "clientVersion", "appVersion", "parserVersion", "metricVersion", "model", "provider",
            "reasoningEffort", "sourceKind", "outputTokens", "reasoningOutputTokens", "durationMs", "ttftMs",
            "responseOutputTokens", "responseDurationMs", "responseCount", "providerRegion"
        ])
        XCTAssertEqual(object["appVersion"] as? String, "0.1.14")
        XCTAssertEqual(sample.appVersion, "0.1.14")
        for key in ["responseOutputTokens", "responseDurationMs", "responseCount", "providerRegion", "ttftMs", "reasoningOutputTokens"] {
            XCTAssertTrue(object[key] is NSNull, "\(key) is encoded as null when absent")
        }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(sample), as: UTF8.self).contains("LOCAL_PRIVATE_DIGEST"))
    }

    func testValidResponseSpeedIsSharedInMilliseconds() throws {
        let sample = try XCTUnwrap(SharedSample(claude(tokens: 900, seconds: 18, count: 2)))
        XCTAssertEqual(sample.responseOutputTokens, 900)
        XCTAssertEqual(try XCTUnwrap(sample.responseDurationMs), 18_000, accuracy: 0.001)
        XCTAssertEqual(sample.responseCount, 2)
        let object = try json(sample)
        XCTAssertEqual(object["responseOutputTokens"] as? Int, 900)
        XCTAssertEqual(try XCTUnwrap(object["responseDurationMs"] as? Double), 18_000, accuracy: 0.001)
        XCTAssertEqual(object["responseCount"] as? Int, 2)

        // The limits are inclusive: all output in responses, all of the turn's time, exactly 2,000 tok/s, 200 tokens per response.
        XCTAssertNotNil(SharedSample(claude(tokens: 1_000, seconds: 100, count: 1)).flatMap { $0.responseOutputTokens })
        XCTAssertNotNil(SharedSample(claude(outputTokens: 5_000, tokens: 2_000, seconds: 1, count: 1)).flatMap { $0.responseOutputTokens })
        XCTAssertNotNil(SharedSample(claude(tokens: 1_000, seconds: 10, count: 5)).flatMap { $0.responseOutputTokens }) // exactly 200 per response
    }

    func testOutOfRangeResponseSpeedNullsAllThreeFields() throws {
        let invalid: [(String, TurnMetric)] = [
            ("tokens above the turn's output tokens", claude(tokens: 1_001, seconds: 10, count: 1)),
            ("duration above the turn duration", claude(tokens: 500, seconds: 100.5, count: 1)),
            ("implied speed above 2000 tokens per second", claude(outputTokens: 5_000, tokens: 2_001, seconds: 1, count: 1)),
            ("fewer than 200 tokens per counted response", claude(tokens: 999, seconds: 10, count: 5))
        ]
        for (reason, metric) in invalid {
            let sample = try XCTUnwrap(SharedSample(metric), reason)
            XCTAssertNil(sample.responseOutputTokens, reason)
            XCTAssertNil(sample.responseDurationMs, reason)
            XCTAssertNil(sample.responseCount, reason)
            let object = try json(sample)
            XCTAssertTrue(object["responseOutputTokens"] is NSNull, reason)
            XCTAssertTrue(object["responseDurationMs"] is NSNull, reason)
            XCTAssertTrue(object["responseCount"] is NSNull, reason)
            XCTAssertEqual(sample.outputTokens, metric.outputTokens, "the turn sample itself is still shared")
        }
    }

    func testDecodedZeroCountOrNegativeValuesNullAllThreeFields() throws {
        for fields in [
            #""responseOutputTokens":50,"responseDurationSeconds":5,"responseCount":0"#,
            #""responseOutputTokens":-5,"responseDurationSeconds":5,"responseCount":1"#,
            #""responseOutputTokens":50,"responseDurationSeconds":0,"responseCount":1"#,
            #""responseOutputTokens":50"#
        ] {
            let text = #"{"id":"x","completedAt":1800000000,"client":"claude-code","parserVersion":"claude-transcript-v4","metricVersion":"claude-observed-turn-v1","provider":"anthropic","outputTokens":100,"durationSeconds":10,"turnThroughputTPS":10,"# + fields + "}"
            let metric = try JSONDecoder().decode(TurnMetric.self, from: Data(text.utf8))
            let sample = try XCTUnwrap(SharedSample(metric), fields)
            XCTAssertNil(sample.responseOutputTokens, fields)
            XCTAssertNil(sample.responseDurationMs, fields)
            XCTAssertNil(sample.responseCount, fields)
        }
    }

    func testProviderRegionIsSharedOnlyForBedrockAndValidated() throws {
        for region in ["us", "eu", "apac", "global", "jp", "au", "ca", "us-gov", "unknown"] {
            let sample = try XCTUnwrap(SharedSample(claude(provider: "amazon-bedrock", region: region)))
            XCTAssertEqual(sample.providerRegion, region)
            XCTAssertEqual(try json(sample)["providerRegion"] as? String, region)
        }
        // Absent or unrecognised regions on Bedrock become `unknown`.
        for region in [nil, "xx", "US", "us-east-1", "", "eu "] as [String?] {
            XCTAssertEqual(try XCTUnwrap(SharedSample(claude(provider: "amazon-bedrock", region: region))).providerRegion, "unknown", region ?? "nil")
        }
        // Every other provider shares null, whatever the metric carries.
        for provider in ["anthropic", "google-vertex", "unknown", nil] as [String?] {
            let sample = try XCTUnwrap(SharedSample(claude(provider: provider, region: "us")))
            XCTAssertNil(sample.providerRegion, provider ?? "nil")
            XCTAssertTrue(try json(sample)["providerRegion"] is NSNull)
        }
        let codex = TurnMetric(id: "c", completedAt: now, model: "gpt-test", outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: nil, turnThroughputTPS: 10, provider: "openai", providerRegion: "us")
        XCTAssertNil(try XCTUnwrap(SharedSample(codex)).providerRegion)
        XCTAssertEqual(try XCTUnwrap(SharedSample(codex)).parserVersion, "codex-rollout-v2")
    }
}
