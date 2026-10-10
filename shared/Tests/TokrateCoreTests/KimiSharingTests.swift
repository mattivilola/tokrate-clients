import Foundation
import XCTest
@testable import TokrateCore

/// What Kimi Code adds to sharing, labels and saved checkpoints (contract "Kimi Code (0.1.21)").
final class KimiSharingTests: XCTestCase {
    private func kimi(provider: String? = "moonshot", cacheWrite: Int? = nil, delegated: Int? = 0, surface: ToolSurface? = .desktop) -> TurnMetric {
        TurnMetric(
            id: "LOCAL_PRIVATE_DIGEST", completedAt: Date(timeIntervalSince1970: 1_800_000_000), model: "k2d8-preview",
            outputTokens: 416, durationSeconds: 18.044, codexTTFTSeconds: nil, turnThroughputTPS: 23,
            client: "kimi-code", parserVersion: "kimi-wire-v1", metricVersion: "kimi-observed-turn-v1",
            sourceKind: "primary", provider: provider, reasoningEffort: "high",
            responseOutputTokens: 285, responseDurationSeconds: 10.28, responseCount: 1,
            delegatedOutputTokens: delegated, surface: surface,
            inputTokens: 36_590, cacheReadInputTokens: 30_976, cacheWriteInputTokens: cacheWrite
        )
    }

    func testAKimiCodeTurnIsSharedWithMoonshotAsItsProvider() throws {
        let sample = try XCTUnwrap(SharedSample(kimi()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertEqual(object["appVersion"] as? String, "0.1.22")
        XCTAssertEqual(object["client"] as? String, "kimi-code")
        XCTAssertEqual(object["parserVersion"] as? String, "kimi-wire-v1")
        XCTAssertEqual(object["metricVersion"] as? String, "kimi-observed-turn-v1")
        XCTAssertEqual(object["provider"] as? String, "moonshot")
        XCTAssertEqual(object["model"] as? String, "k2d8-preview")
        XCTAssertEqual(object["reasoningEffort"] as? String, "high")
        XCTAssertEqual(object["sourceKind"] as? String, "primary")
        XCTAssertEqual(object["surface"] as? String, "desktop")
        XCTAssertEqual(object["inputTokens"] as? Int, 36_590)
        XCTAssertEqual(object["cacheReadInputTokens"] as? Int, 30_976)
        XCTAssertTrue(object["cacheWriteInputTokens"] is NSNull)
        XCTAssertTrue(object["clientVersion"] as? String == "unknown")
        XCTAssertTrue(object["providerRegion"] is NSNull)
        XCTAssertTrue(object["ttftMs"] is NSNull)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(sample), as: UTF8.self).contains("LOCAL_PRIVATE_DIGEST"))
        XCTAssertNotNil(SharedSample(kimi(provider: "unknown")))
        XCTAssertNotNil(SharedSample(kimi(provider: nil)))
    }

    func testOnlyMoonshotAndUnknownProvidersAreSharedForKimiCode() {
        for provider in ["openai", "anthropic", "xai", "google", "amazon-bedrock", "google-vertex", "kimi", "deepseek", "Moonshot"] {
            XCTAssertEqual(SharedSample.rejection(of: kimi(provider: provider)), .providerNotShared, provider)
            XCTAssertNil(SharedSample(kimi(provider: provider)), provider)
        }
    }

    func testMoonshotIsSharedForNoOtherClient() {
        for client in ["codex", "claude-code", "grok-build", "antigravity", "opencode"] {
            XCTAssertFalse(SharedSample.isAllowedProvider("moonshot", client: client), client)
        }
        XCTAssertTrue(SharedSample.isAllowedProvider("moonshot", client: "kimi-code"))
    }

    func testTheOtherClientsKeepTheirProviderRules() {
        XCTAssertTrue(SharedSample.isAllowedProvider("openai", client: "codex"))
        XCTAssertTrue(SharedSample.isAllowedProvider("anthropic", client: "claude-code"))
        XCTAssertTrue(SharedSample.isAllowedProvider("xai", client: "grok-build"))
        XCTAssertTrue(SharedSample.isAllowedProvider("amazon-bedrock", client: "claude-code"))
        XCTAssertFalse(SharedSample.isAllowedProvider("amazon-bedrock", client: "kimi-code"))
        XCTAssertTrue(SharedSample.isAllowedProvider("google", client: "opencode"))
        XCTAssertTrue(SharedSample.isAllowedProvider(nil, client: "kimi-code"))
        XCTAssertTrue(SharedSample.isAllowedProvider("unknown", client: "kimi-code"))
    }

    func testAKimiCodeRecordThatClaimsCacheWritesIsNotShared() {
        XCTAssertEqual(SharedSample.rejection(of: kimi(cacheWrite: 0)), .unreportedCacheWrite)
        XCTAssertEqual(SharedSample.rejection(of: kimi(cacheWrite: 4_096)), .unreportedCacheWrite)
        XCTAssertNil(SharedSample(kimi(cacheWrite: 0)))
        XCTAssertNil(SharedSample.rejection(of: kimi()))
    }

    func testAKimiCodeTurnIsSharedOnlyOnceItsDelegatedTotalIsFinal() throws {
        XCTAssertEqual(SharedSample.rejection(of: kimi(delegated: nil)), .delegationNotFinal)
        XCTAssertEqual(try XCTUnwrap(SharedSample(kimi(delegated: 700))).delegatedOutputTokens, 700)
    }

    func testTheKimiCodeTupleIsASupportedMeasurementWithItsOwnExplanation() {
        let metric = kimi()
        XCTAssertTrue(metric.isSupportedSourceTuple)
        XCTAssertEqual(metric.throughputLabel, "Turn speed")
        XCTAssertEqual(metric.throughputExplanation, "Prompt through final answer, including tools & waiting")
        XCTAssertFalse(TurnMetric.isSupportedSourceTuple(client: "kimi-code", parserVersion: "kimi-wire-v2", metricVersion: "kimi-observed-turn-v1"))
        XCTAssertFalse(TurnMetric.isSupportedSourceTuple(client: "opencode", parserVersion: "kimi-wire-v1", metricVersion: "kimi-observed-turn-v1"))
    }

    func testCheckpointsSavedBeforeKimiCodeStillDecodeAndKimiCheckpointsRoundTrip() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = Data(#"{"codex":[],"claudePrimary":[],"claudeSubagents":[]}"#.utf8)
        XCTAssertEqual(try decoder.decode(SourceCheckpoints.self, from: legacy), SourceCheckpoints())

        let now = Date.now
        func checkpoint(_ path: String, hoursAgo: Double = 1) -> SourceFileCheckpoint {
            SourceFileCheckpoint(pathDigest: path, fileNumber: 1, size: 1, modifiedAt: now.addingTimeInterval(-hoursAgo * 3_600), versionKey: "kimi-wire-v1|kimi-observed-turn-v1")
        }
        var set = SourceCheckpoints()
        set.kimiCodeMain = [checkpoint("cli-main")]
        set.kimiCodeSubagents = [checkpoint("cli-sub")]
        set.kimiDesktopMain = [checkpoint("desktop-main"), checkpoint("desktop-old", hoursAgo: 24 * 8)]
        set.kimiDesktopSubagents = [checkpoint("desktop-sub")]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(SourceCheckpoints.self, from: encoder.encode(set)), set)
        XCTAssertEqual(set.pathDigests, ["cli-main", "cli-sub", "desktop-main", "desktop-old", "desktop-sub"])
        let kept = set.retained(now: now)
        XCTAssertEqual(kept.kimiDesktopMain.map(\.pathDigest), ["desktop-main"], "files older than the history are dropped")
        XCTAssertEqual(kept.kimiCodeMain.map(\.pathDigest), ["cli-main"])
        XCTAssertEqual(kept.kimiCodeSubagents.map(\.pathDigest), ["cli-sub"])
        XCTAssertEqual(kept.kimiDesktopSubagents.map(\.pathDigest), ["desktop-sub"])
    }
}
