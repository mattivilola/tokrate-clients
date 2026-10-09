import CryptoKit
import Foundation
import TokrateCore
import XCTest

private final class MemoryIdentity: SharingIdentity, @unchecked Sendable {
    let key = Curve25519.Signing.PrivateKey().rawRepresentation
    func loadOrCreate() throws -> Data { key }
}

private actor CapturingTransport: SharingTransport {
    private var uploads: [Data] = []
    func firstUpload() -> Data? { uploads.first }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.httpMethod == "POST", let body = request.httpBody { uploads.append(body) }
        return (Data(), 200)
    }
}

@MainActor
final class HistoryExportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_020_401)

    private func codex(
        id: String, completedAt: Date, model: String? = "gpt-test", provider: String? = "openai",
        effort: String? = "high", delegated: Int? = 0, tokens: Int = 100, version: String? = "0.159.2"
    ) -> TurnMetric {
        TurnMetric(
            id: id, completedAt: completedAt, model: model, outputTokens: tokens, durationSeconds: 10, codexTTFTSeconds: 1,
            turnThroughputTPS: Double(tokens) / 10, clientVersion: version, reasoningOutputTokens: 40, sourceKind: "primary",
            provider: provider, reasoningEffort: effort, responseOutputTokens: 90, responseDurationSeconds: 8, responseCount: 2,
            delegatedOutputTokens: delegated, surface: .cli
        )
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testWindowKeepsTurnsCompletedFromStartInclusiveToEndExclusive() {
        let start = now.addingTimeInterval(-86_400), end = now
        let metrics = [
            codex(id: "before", completedAt: start.addingTimeInterval(-1)),
            codex(id: "at-start", completedAt: start),
            codex(id: "inside", completedAt: start.addingTimeInterval(3_600)),
            codex(id: "at-end", completedAt: end),
            codex(id: "after", completedAt: end.addingTimeInterval(60))
        ]
        let result = HistoryExport.samples(from: metrics, window: start..<end)
        XCTAssertEqual(result.samples.count, 2)
        XCTAssertEqual(result.skipped[.outsideWindow], 3)
        XCTAssertEqual(result.skippedByClient["codex"]?[.outsideWindow], 3)
    }

    func testMappingEqualsTheLiveSharingMappingForTheSameTurn() async throws {
        let metrics = [
            codex(id: "a", completedAt: now.addingTimeInterval(-90)),
            codex(id: "b", completedAt: now.addingTimeInterval(-30), model: "bad model!", effort: "not-an-effort", delegated: 250, version: "weird version")
        ]
        // The export, with sample ids fixed per turn so the two encodings can be compared whole.
        var ids = [UUID(), UUID()].makeIterator()
        let exported = HistoryExport.samples(from: metrics, window: now.addingTimeInterval(-3_600)..<now, makeSampleID: { ids.next()! })
        let exportedLines = try exported.samples.map { try object(SampleEnvelope.makeEncoder().encode($0)) }

        // The live path: a consenting session enqueues the turns and uploads them.
        let transport = CapturingTransport()
        let session = SharingSession(identity: MemoryIdentity(), transport: transport)
        let consent = now.addingTimeInterval(-3_600)
        session.enable(now: consent, startPolling: false)
        session.enqueue(metrics, now: now)
        // Uploads leave once the turn's five-minute bucket has closed.
        await session.refresh(now: now.addingTimeInterval(700))
        let firstUpload = await transport.firstUpload()
        let upload = try XCTUnwrap(firstUpload)
        let live = try XCTUnwrap(object(upload)["samples"] as? [[String: Any]])

        XCTAssertEqual(live.count, exportedLines.count)
        func withoutID(_ line: [String: Any]) -> NSDictionary {
            var copy = line
            copy.removeValue(forKey: "sampleId")
            return copy as NSDictionary
        }
        XCTAssertEqual(live.map(withoutID), exportedLines.map(withoutID))
    }

    func testSamplesCarryOnlyAllowlistedFieldsAndNeverTheLocalIdentifier() throws {
        let result = HistoryExport.samples(from: [codex(id: "LOCAL_PRIVATE_DIGEST", completedAt: now.addingTimeInterval(-60))], window: now.addingTimeInterval(-3_600)..<now)
        let line = try SampleEnvelope.makeEncoder().encode(try XCTUnwrap(result.samples.first))
        XCTAssertEqual(Set(try object(line).keys), [
            "sampleId", "observedAt", "client", "clientVersion", "appVersion", "parserVersion", "metricVersion", "model", "provider",
            "reasoningEffort", "sourceKind", "outputTokens", "reasoningOutputTokens", "durationMs", "ttftMs",
            "responseOutputTokens", "responseDurationMs", "responseCount", "providerRegion", "delegatedOutputTokens", "surface",
            "inputTokens", "cacheReadInputTokens", "cacheWriteInputTokens"
        ])
        XCTAssertFalse(String(decoding: line, as: UTF8.self).contains("LOCAL_PRIVATE_DIGEST"))
        XCTAssertFalse(String(decoding: line, as: UTF8.self).contains("\n"))
    }

    func testEligibilityRulesOfLiveSharingAreReportedAsSkipReasons() {
        let recent = now.addingTimeInterval(-60)
        let legacyClaude = TurnMetric(
            id: "c", completedAt: recent, model: "claude-sonnet-4-5", outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: nil,
            turnThroughputTPS: 10, client: "claude-code", clientVersion: "2.1.37", parserVersion: "claude-transcript-v2",
            metricVersion: "claude-observed-turn-v1", sourceKind: "primary", provider: "anthropic", delegatedOutputTokens: 0
        )
        let metrics = [
            codex(id: "ok", completedAt: recent),
            codex(id: "pending", completedAt: recent, delegated: nil),
            codex(id: "gateway", completedAt: recent, provider: "some-gateway"),
            legacyClaude
        ]
        let result = HistoryExport.samples(from: metrics, window: now.addingTimeInterval(-3_600)..<now)
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertEqual(result.skipped[.rejected(.delegationNotFinal)], 1)
        XCTAssertEqual(result.skipped[.rejected(.providerNotShared)], 1)
        XCTAssertEqual(result.skipped[.rejected(.legacyClaudeParser)], 1)
        XCTAssertEqual(result.skippedByClient["claude-code"]?[.rejected(.legacyClaudeParser)], 1)
        // The reported reason and the live decision are one rule.
        for metric in metrics {
            XCTAssertEqual(SharedSample.rejection(of: metric) == nil, SharedSample(metric) != nil, metric.id)
        }
    }

    func testSamplesAreSortedByObservedAt() {
        let metrics = (0..<6).map { codex(id: "t\($0)", completedAt: now.addingTimeInterval(Double($0 * -700) - 60)) }.shuffled()
        let result = HistoryExport.samples(from: metrics, window: now.addingTimeInterval(-86_400)..<now)
        XCTAssertEqual(result.samples.count, 6)
        XCTAssertEqual(result.samples.map(\.observedAt), result.samples.map(\.observedAt).sorted())
    }

    func testDeduplicationKeepsTheFirstFinalEmissionOfATurn() {
        let at = now.addingTimeInterval(-60)
        let pending = codex(id: "turn", completedAt: at, delegated: nil)
        let settled = codex(id: "turn", completedAt: at, delegated: 500)
        let later = codex(id: "turn", completedAt: at, delegated: 900)
        XCTAssertEqual(HistoryExport.deduplicated([pending, settled, later]).map(\.delegatedOutputTokens), [500])
        XCTAssertEqual(HistoryExport.deduplicated([settled, pending]).map(\.delegatedOutputTokens), [500])
        XCTAssertEqual(HistoryExport.deduplicated([pending]).map(\.delegatedOutputTokens), [nil])
    }

    func testDefaultSourceFoldersFollowTheToolsEnvironmentVariables() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let plain = SourceFolders.defaults(home: home, environment: [:])
        XCTAssertEqual(plain.codex.path, "/Users/example/.codex/sessions")
        XCTAssertEqual(plain.claudeCode.path, "/Users/example/.claude/projects")
        XCTAssertEqual(plain.grokBuild.path, "/Users/example/.grok/sessions")
        XCTAssertEqual(plain.antigravity.path, "/Users/example/.gemini")
        XCTAssertEqual(plain.openCode.path, "/Users/example/.local/share/opencode")
        XCTAssertEqual(plain.kimiCode.path, "/Users/example/.kimi-code")
        XCTAssertEqual(
            plain.kimiDesktop.path,
            "/Users/example/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home"
        )
        let overridden = SourceFolders.defaults(home: home, environment: [
            "CLAUDE_CONFIG_DIR": "/cfg/claude", "GROK_HOME": "/cfg/grok", "XDG_DATA_HOME": "/cfg/data", "KIMI_CODE_HOME": "/cfg/kimi"
        ])
        XCTAssertEqual(overridden.claudeCode.path, "/cfg/claude/projects")
        XCTAssertEqual(overridden.grokBuild.path, "/cfg/grok/sessions")
        XCTAssertEqual(overridden.openCode.path, "/cfg/data/opencode")
        XCTAssertEqual(overridden.kimiCode.path, "/cfg/kimi")
        XCTAssertEqual(overridden.kimiDesktop, plain.kimiDesktop, "the desktop app's home does not follow KIMI_CODE_HOME")
        let empty = SourceFolders.defaults(home: home, environment: ["KIMI_CODE_HOME": ""])
        XCTAssertEqual(empty.kimiCode.path, "/Users/example/.kimi-code")
    }

    func testReplayReadsOldFilesBeyondTheLiveWindowInFull() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexFolder = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date.now.addingTimeInterval(-30 * 86_400)
        let file = codexFolder.appendingPathComponent("old.jsonl")
        // The turn sits before the live tail window, so only a full read from the start finds it.
        let padding = Data(repeating: 0x20, count: 600_000) + Data([0x0A])
        try (sessionMeta() + timedTurn(finishedAt: finished) + padding).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: finished.addingTimeInterval(3_600)], ofItemAtPath: file.path)

        let nowhere = root.appendingPathComponent("absent", isDirectory: true)
        let folders = SourceFolders(codex: codexFolder, claudeCode: nowhere, grokBuild: nowhere, antigravity: nowhere, openCode: nowhere, kimiCode: nowhere, kimiDesktop: nowhere)
        let replay = await HistoryReplay.run(folders: folders, retention: 60 * 86_400)
        XCTAssertEqual(replay.incompleteSources, [])
        let turn = try XCTUnwrap(replay.metrics.first)
        XCTAssertEqual(replay.metrics.count, 1)
        XCTAssertEqual(turn.outputTokens, 321)
        XCTAssertTrue(turn.isDelegationFinal)
        XCTAssertNotNil(SharedSample(turn))

        // The live window is seven days: the same file is not even discovered.
        let live = await HistoryReplay.run(folders: folders, retention: MetricHistory.retention)
        XCTAssertTrue(live.metrics.isEmpty)
    }

    private func sessionMeta() -> Data {
        Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"s\",\"source\":\"vscode\",\"model_provider\":\"openai\"}}\n".utf8)
    }

    private func timedTurn(finishedAt: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ offset: Double, _ type: String, _ payload: [String: Any]) -> String {
            let object: [String: Any] = ["timestamp": formatter.string(from: finishedAt.addingTimeInterval(offset)), "type": type, "payload": payload]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
        }
        let usage: [String: Any] = ["turn_id": "t", "response_id": "r", "usage": ["output_tokens": 321], "turn_token_usage": ["output_tokens": 321]]
        return Data([
            line(-10, "event_msg", ["type": "task_started", "turn_id": "t"]),
            line(-10, "turn_context", ["turn_id": "t", "model": "gpt-test"]),
            line(-8, "token_usage_record", usage),
            line(0, "event_msg", ["type": "task_complete", "turn_id": "t", "duration_ms": 10_000])
        ].joined().utf8)
    }
}
