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

    func testPruneReportsHowManyRecordsItRemoved() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let kept = metric(id: "kept", at: now.addingTimeInterval(-6 * 24 * 60 * 60))
        var history = MetricHistory(records: [kept], now: now)
        XCTAssertEqual(history.prune(now: now), 0, "nothing expired, so the saved copy is still current")
        // A week later the record has aged out while the app sat idle.
        let later = now.addingTimeInterval(2 * 24 * 60 * 60)
        XCTAssertEqual(history.prune(now: later), 1)
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertEqual(history.prune(now: later), 0)
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
        XCTAssertNil(decoded.delegatedOutputTokens, "records saved before 0.1.16 carry no delegated total")
        XCTAssertNil(decoded.responseSpeedTPS)
        XCTAssertTrue(decoded.isSupportedSourceTuple)

        // New records default to the current Codex parser.
        XCTAssertEqual(TurnMetric.codexParserVersion, "codex-rollout-v2")
        XCTAssertEqual(metric(id: "fresh", at: .now).parserVersion, "codex-rollout-v2")
        XCTAssertTrue(TurnMetric.isSupportedSourceTuple(client: "codex", parserVersion: "codex-rollout-v2", metricVersion: "turn-v1"))
        XCTAssertTrue(TurnMetric.isSupportedSourceTuple(client: "claude-code", parserVersion: "claude-transcript-v4", metricVersion: "claude-observed-turn-v1"))
        XCTAssertTrue(TurnMetric.isSupportedSourceTuple(client: "claude-code", parserVersion: "claude-transcript-v4", metricVersion: "claude-observed-subagent-turn-v1"))
    }

    func testDelegatedOutputTokensRoundTripAndAreEncodedOnlyWhenPresent() throws {
        let base = metric(id: "primary", at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])["delegatedOutputTokens"])
        let settled = base.withDelegatedOutputTokens(1_234)
        XCTAssertEqual(settled.id, base.id)
        XCTAssertEqual(settled.outputTokens, base.outputTokens)
        XCTAssertEqual(settled.delegatedOutputTokens, 1_234)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settled)) as? [String: Any])
        XCTAssertEqual(object["delegatedOutputTokens"] as? Int, 1_234)
        XCTAssertEqual(try JSONDecoder().decode(TurnMetric.self, from: JSONEncoder().encode(settled)), settled)
        XCTAssertEqual(settled.withDelegatedOutputTokens(nil), base)
    }

    func testASettledDelegatedTotalIsNeverReplacedByAPendingOne() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = metric(id: "turn", at: now.addingTimeInterval(-60))
        var history = MetricHistory()
        history.upsert(pending.withDelegatedOutputTokens(900), now: now)
        // A replay re-emits the turn before its delegated work is attributed again.
        history.upsert(pending, now: now)
        XCTAssertEqual(history.records.first?.delegatedOutputTokens, 900)
        // A settled re-emission replaces it, and a pending record replaces a pending one.
        history.upsert(pending.withDelegatedOutputTokens(0), now: now)
        XCTAssertEqual(history.records.first?.delegatedOutputTokens, 0)
        var fresh = MetricHistory()
        fresh.upsert(pending, now: now)
        fresh.upsert(pending.withDelegatedOutputTokens(50), now: now)
        XCTAssertEqual(fresh.records.map(\.delegatedOutputTokens), [50])
        XCTAssertEqual(fresh.records.count, 1)
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

    // MARK: Prompt cache (0.1.18)

    private func cached(input: Int?, read: Int?, write: Int?) -> TurnMetric {
        TurnMetric(
            id: "cache", completedAt: Date(timeIntervalSince1970: 1_800_000_000), model: "claude-sonnet-5-5", outputTokens: 1_000,
            durationSeconds: 60, codexTTFTSeconds: nil, turnThroughputTPS: 16.6, client: "claude-code",
            parserVersion: "claude-transcript-v4", metricVersion: "claude-observed-turn-v1",
            responseOutputTokens: 900, responseDurationSeconds: 18, responseCount: 2, providerRegion: "us",
            delegatedOutputTokens: 40, surface: .cli,
            inputTokens: input, cacheReadInputTokens: read, cacheWriteInputTokens: write
        )
    }

    func testPromptCacheFieldsRoundTripAndEveryCopyHelperKeepsThem() throws {
        let full = cached(input: 50_000, read: 40_000, write: 6_000)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        XCTAssertEqual(object["inputTokens"] as? Int, 50_000)
        XCTAssertEqual(object["cacheReadInputTokens"] as? Int, 40_000)
        XCTAssertEqual(object["cacheWriteInputTokens"] as? Int, 6_000)
        XCTAssertEqual(try JSONDecoder().decode(TurnMetric.self, from: JSONEncoder().encode(full)), full)

        for copy in [full.withoutResponseTiming(), full.withDelegatedOutputTokens(7)] {
            XCTAssertEqual(copy.inputTokens, 50_000)
            XCTAssertEqual(copy.cacheReadInputTokens, 40_000)
            XCTAssertEqual(copy.cacheWriteInputTokens, 6_000)
        }

        // Not reported (and Codex / Grok Build, which never report a write): encoded only when present.
        let noWrite = cached(input: 50_000, read: 40_000, write: nil)
        let noWriteObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(noWrite)) as? [String: Any])
        XCTAssertNil(noWriteObject["cacheWriteInputTokens"])
        XCTAssertEqual(try JSONDecoder().decode(TurnMetric.self, from: JSONEncoder().encode(noWrite)), noWrite)
        XCTAssertNil(noWrite.withDelegatedOutputTokens(1).cacheWriteInputTokens)
        let none = cached(input: nil, read: nil, write: nil)
        let noneObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(none)) as? [String: Any])
        for key in ["inputTokens", "cacheReadInputTokens", "cacheWriteInputTokens"] { XCTAssertNil(noneObject[key]) }
    }

    func testPromptCacheFieldsAreConsistentOrAllNil() {
        let valid = cached(input: 100, read: 100, write: 0)
        XCTAssertEqual([valid.inputTokens, valid.cacheReadInputTokens, valid.cacheWriteInputTokens], [100, 100, 0])
        XCTAssertEqual(cached(input: 100, read: 0, write: nil).cacheReadInputTokens, 0)
        for inconsistent in [
            cached(input: 100, read: 101, write: 5),  // a read larger than the input is bad source data
            cached(input: 100, read: nil, write: nil), cached(input: nil, read: 10, write: nil),
            cached(input: nil, read: nil, write: 5), cached(input: 100, read: nil, write: 5),
            cached(input: -1, read: 0, write: nil), cached(input: 100, read: -1, write: nil), cached(input: 100, read: 10, write: -1)
        ] {
            XCTAssertNil(inconsistent.inputTokens)
            XCTAssertNil(inconsistent.cacheReadInputTokens)
            XCTAssertNil(inconsistent.cacheWriteInputTokens)
        }
    }

    func testRecordsSavedBeforePromptCacheDecodeWithNilFieldsAndInconsistentStoredSetsReadAsNotReported() throws {
        let old = #"{"id":"x","completedAt":1,"outputTokens":100,"durationSeconds":10,"turnThroughputTPS":10,"surface":"cli"}"#
        let decoded = try JSONDecoder().decode(TurnMetric.self, from: Data(old.utf8))
        XCTAssertNil(decoded.inputTokens)
        XCTAssertNil(decoded.cacheReadInputTokens)
        XCTAssertNil(decoded.cacheWriteInputTokens)
        XCTAssertEqual(decoded.surface, .cli)

        let bad = #"{"id":"x","completedAt":1,"outputTokens":100,"durationSeconds":10,"turnThroughputTPS":10,"inputTokens":10,"cacheReadInputTokens":11,"cacheWriteInputTokens":2}"#
        let decodedBad = try JSONDecoder().decode(TurnMetric.self, from: Data(bad.utf8))
        XCTAssertNil(decodedBad.inputTokens)
        XCTAssertNil(decodedBad.cacheReadInputTokens)
        XCTAssertNil(decodedBad.cacheWriteInputTokens)
    }

    func testLoadingHistoryDropsImpossibleTurnsAndClearsImplausibleResponseTiming() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func claude(
            _ id: String, outputTokens: Int = 1_000, durationSeconds: Double = 100,
            tokens: Int? = nil, seconds: Double? = nil, count: Int? = nil
        ) -> TurnMetric {
            TurnMetric(
                id: id, completedAt: now.addingTimeInterval(-60), model: "claude-sonnet-5-5", outputTokens: outputTokens,
                durationSeconds: durationSeconds, codexTTFTSeconds: nil, turnThroughputTPS: Double(outputTokens) / durationSeconds,
                client: "claude-code", parserVersion: "claude-transcript-v4", metricVersion: "claude-observed-turn-v1",
                sourceKind: "primary", responseOutputTokens: tokens, responseDurationSeconds: seconds, responseCount: count
            )
        }
        let collapsed = claude("collapsed", outputTokens: 400, durationSeconds: 60, tokens: 336, seconds: 0.002, count: 1)
        let tooFast = claude("too-fast", outputTokens: 336, durationSeconds: 0.002)
        let tooManyResponses = claude("few-tokens", tokens: 300, seconds: 10, count: 2)
        let normal = claude("normal", tokens: 900, seconds: 18, count: 2)
        let plain = claude("plain")
        let history = MetricHistory(records: [collapsed, tooFast, tooManyResponses, normal, plain], now: now)

        XCTAssertEqual(Set(history.records.map(\.id)), ["collapsed", "few-tokens", "normal", "plain"], "a turn above 2,000 tok/s is dropped")
        let byID = Dictionary(uniqueKeysWithValues: history.records.map { ($0.id, $0) })
        for id in ["collapsed", "few-tokens"] {
            let record = byID[id]
            XCTAssertNil(record?.responseOutputTokens, id)
            XCTAssertNil(record?.responseDurationSeconds, id)
            XCTAssertNil(record?.responseCount, id)
            XCTAssertEqual(record?.outputTokens, id == "collapsed" ? 400 : 1_000, "the turn itself is kept")
        }
        XCTAssertEqual(byID["normal"], normal)
        XCTAssertEqual(byID["plain"], plain)
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
