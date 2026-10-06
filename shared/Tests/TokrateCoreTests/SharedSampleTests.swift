import Foundation
import TokrateCore
import XCTest

final class SharedSampleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func claude(
        provider: String? = "anthropic", region: String? = nil, outputTokens: Int = 1_000, durationSeconds: Double = 100,
        tokens: Int? = nil, seconds: Double? = nil, count: Int? = nil, sourceKind: String = "primary", delegated: Int? = 0,
        surface: ToolSurface? = nil, input: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil
    ) -> TurnMetric {
        TurnMetric(
            id: "LOCAL_PRIVATE_DIGEST", completedAt: now, model: "claude-sonnet-4-5", outputTokens: outputTokens,
            durationSeconds: durationSeconds, codexTTFTSeconds: nil, turnThroughputTPS: Double(outputTokens) / durationSeconds,
            client: "claude-code", clientVersion: "2.1.37", parserVersion: "claude-transcript-v4",
            metricVersion: "claude-observed-turn-v1", sourceKind: sourceKind, provider: provider,
            responseOutputTokens: tokens, responseDurationSeconds: seconds, responseCount: count, providerRegion: region,
            delegatedOutputTokens: delegated, surface: surface,
            inputTokens: input, cacheReadInputTokens: cacheRead, cacheWriteInputTokens: cacheWrite
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
            "responseOutputTokens", "responseDurationMs", "responseCount", "providerRegion", "delegatedOutputTokens", "surface",
            "inputTokens", "cacheReadInputTokens", "cacheWriteInputTokens"
        ])
        XCTAssertEqual(object["appVersion"] as? String, "0.1.19")
        XCTAssertEqual(sample.appVersion, "0.1.19")
        for key in ["responseOutputTokens", "responseDurationMs", "responseCount", "providerRegion", "ttftMs", "reasoningOutputTokens", "surface",
                    "inputTokens", "cacheReadInputTokens", "cacheWriteInputTokens"] {
            XCTAssertTrue(object[key] is NSNull, "\(key) is encoded as null when absent")
        }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(sample), as: UTF8.self).contains("LOCAL_PRIVATE_DIGEST"))
    }

    func testSurfaceIsSharedAsACategoryOrAnExplicitNull() throws {
        for surface in ToolSurface.allCases {
            let sample = try XCTUnwrap(SharedSample(claude(surface: surface)))
            XCTAssertEqual(sample.surface, surface.rawValue)
            XCTAssertEqual(try json(sample)["surface"] as? String, surface.rawValue)
        }
        let unknown = try XCTUnwrap(SharedSample(claude(surface: nil)))
        XCTAssertNil(unknown.surface)
        XCTAssertTrue(try json(unknown)["surface"] is NSNull)
        // Subagent records carry their own session's surface like any other turn.
        XCTAssertEqual(try XCTUnwrap(SharedSample(claude(sourceKind: "subagent", delegated: nil, surface: .sdk))).surface, "sdk")
    }

    func testPromptCacheTokensAreSharedAndEncodedAsExplicitNullsWhenNotReported() throws {
        let reported = try XCTUnwrap(SharedSample(claude(input: 52_000, cacheRead: 40_000, cacheWrite: 9_000)))
        XCTAssertEqual(reported.inputTokens, 52_000)
        XCTAssertEqual(reported.cacheReadInputTokens, 40_000)
        XCTAssertEqual(reported.cacheWriteInputTokens, 9_000)
        let object = try json(reported)
        XCTAssertEqual(object["inputTokens"] as? Int, 52_000)
        XCTAssertEqual(object["cacheReadInputTokens"] as? Int, 40_000)
        XCTAssertEqual(object["cacheWriteInputTokens"] as? Int, 9_000)

        // Codex and Grok Build report no cache write: the key is present and null.
        let noWrite = try json(try XCTUnwrap(SharedSample(claude(input: 52_000, cacheRead: 0, cacheWrite: nil))))
        XCTAssertEqual(noWrite["cacheReadInputTokens"] as? Int, 0)
        XCTAssertTrue(noWrite["cacheWriteInputTokens"] is NSNull)

        for sourceKind in ["primary", "subagent"] {
            let none = try json(try XCTUnwrap(SharedSample(claude(sourceKind: sourceKind, delegated: sourceKind == "primary" ? 0 : nil))))
            for key in ["inputTokens", "cacheReadInputTokens", "cacheWriteInputTokens"] {
                XCTAssertTrue(none[key] is NSNull, "\(key) is encoded as null when not reported")
            }
        }
        // Subagent records carry their own turn's cache usage like any other turn.
        XCTAssertEqual(try XCTUnwrap(SharedSample(claude(sourceKind: "subagent", delegated: nil, input: 10, cacheRead: 4, cacheWrite: 1))).cacheReadInputTokens, 4)
    }

    func testDelegatedOutputTokensAreSharedForFinalPrimaryTurnsAndNullForSubagents() throws {
        let primary = try XCTUnwrap(SharedSample(claude(delegated: 4_321)))
        XCTAssertEqual(primary.delegatedOutputTokens, 4_321)
        XCTAssertEqual(try json(primary)["delegatedOutputTokens"] as? Int, 4_321)
        XCTAssertEqual(try XCTUnwrap(SharedSample(claude(delegated: 0))).delegatedOutputTokens, 0)

        // A subagent record is shared as before, with an explicit null whatever the metric holds.
        for delegated in [nil, 99] as [Int?] {
            let subagent = try XCTUnwrap(SharedSample(claude(sourceKind: "subagent", delegated: delegated)))
            XCTAssertNil(subagent.delegatedOutputTokens)
            XCTAssertTrue(try json(subagent)["delegatedOutputTokens"] is NSNull)
        }
        XCTAssertTrue(try json(try XCTUnwrap(SharedSample(claude(sourceKind: "unknown", delegated: nil))))["delegatedOutputTokens"] is NSNull)
    }

    func testPrimaryTurnWithoutAFinalDelegatedTotalOrOutOfRangeIsNotShared() {
        XCTAssertNil(SharedSample(claude(delegated: nil)), "attribution is not final yet")
        XCTAssertNil(SharedSample(claude(delegated: -1)))
        XCTAssertNotNil(SharedSample(claude(delegated: SharedSample.maximumDelegatedOutputTokens)))
        XCTAssertNil(SharedSample(claude(delegated: SharedSample.maximumDelegatedOutputTokens + 1)))
        XCTAssertEqual(SharedSample.maximumDelegatedOutputTokens, 100_000_000)
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
            ("fewer than 200 tokens per counted response", claude(tokens: 999, seconds: 10, count: 5)),
            ("more than 600 seconds per counted response", claude(outputTokens: 5_000, durationSeconds: 2_000, tokens: 3_000, seconds: 1_201, count: 2))
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

    func testResponseSecondsAreBoundedBySixHundredPerCountedResponse() throws {
        XCTAssertNotNil(SharedSample(claude(outputTokens: 5_000, durationSeconds: 2_000, tokens: 3_000, seconds: 1_200, count: 2))?.responseCount)
        XCTAssertNil(SharedSample(claude(outputTokens: 5_000, durationSeconds: 2_000, tokens: 3_000, seconds: 601, count: 1))?.responseCount)
    }

    func testTurnFasterThanTheSpeedBoundIsNotShared() {
        XCTAssertEqual(ResponseSpeed.maximumTokensPerSecond, 2_000)
        XCTAssertNotNil(SharedSample(claude(outputTokens: 2_000, durationSeconds: 1)), "exactly 2,000 tok/s is kept")
        XCTAssertNil(SharedSample(claude(outputTokens: 2_001, durationSeconds: 1)))
        XCTAssertNil(SharedSample(claude(outputTokens: 336, durationSeconds: 0.002)))
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
