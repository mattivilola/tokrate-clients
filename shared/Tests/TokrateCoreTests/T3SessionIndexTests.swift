import Foundation
import SQLite3
import XCTest
@testable import TokrateCore

final class T3SessionIndexTests: XCTestCase {
    private var root: URL!
    private let session = "11111111-2222-4333-8444-555555555555"
    private let now = Date(timeIntervalSince1970: 1_792_059_600)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func createIndex(strength: String = "strong", driver: String = "claudeAgent", duplicate: Bool = false) throws -> T3SessionIndex {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("statev2.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let start = ISO8601DateFormatter().string(from: now.addingTimeInterval(-20)), end = ISO8601DateFormatter().string(from: now)
        let sql = """
            CREATE TABLE orchestration_v2_projection_provider_threads(provider_thread_id TEXT,payload_json TEXT);
            CREATE TABLE orchestration_v2_projection_provider_turns(provider_thread_id TEXT,started_at TEXT,completed_at TEXT);
            INSERT INTO orchestration_v2_projection_provider_threads VALUES('native','{"nativeThreadRef":{"driver":"\(driver)","nativeId":"\(session)","strength":"\(strength)"},"title":"PRIVATE_SENTINEL","messages":["NEVER_READ"]}');
            INSERT INTO orchestration_v2_projection_provider_turns VALUES('native','\(start)','\(end)');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        if duplicate { XCTAssertEqual(sqlite3_exec(db, "INSERT INTO orchestration_v2_projection_provider_turns SELECT * FROM orchestration_v2_projection_provider_turns", nil, nil, nil), SQLITE_OK) }
        let index = T3SessionIndex(root: root); index.refresh(now: now)
        return index
    }
    func testOnlyStrongSessionInsideOneTurnWindowQualifies() throws {
        let index = try createIndex()
        XCTAssertTrue(index.contains(session: session, at: now.addingTimeInterval(-10)))
        XCTAssertFalse(index.contains(session: UUID().uuidString, at: now))
        XCTAssertFalse(index.contains(session: session, at: now.addingTimeInterval(30)))
        XCTAssertFalse(index.contains(session: session, at: now.addingTimeInterval(-60)))
    }
    func testWeakAndAmbiguousAssociationsAreRejected() throws {
        let weak = try createIndex(strength: "weak")
        XCTAssertFalse(weak.contains(session: session, at: now))
        // A new fixture location avoids replacing or mutating a live source.
        let previous = root!
        defer { root = previous }
        root = root.appendingPathComponent("ambiguous")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ambiguous = try createIndex(duplicate: true)
        XCTAssertFalse(ambiguous.contains(session: session, at: now))
    }
    func testCodexOriginatorAndRuntimeCapabilitiesAreExact() {
        XCTAssertTrue(T3Runtime.isCodexOriginator(" T3 Code\n"))
        XCTAssertFalse(T3Runtime.isCodexOriginator("some-t3-code-proxy"))
        XCTAssertNil(T3Runtime.nativeClient(parser: "codex-rollout-v2", metric: "claude-observed-turn-v1"))
        let metric = TurnMetric(id: "m", completedAt: now, model: "gpt-6.1-sol", outputTokens: 200, durationSeconds: 10,
            codexTTFTSeconds: 1, turnThroughputTPS: 20, client: T3Runtime.client, parserVersion: "codex-rollout-v2", metricVersion: "turn-v1", sourceKind: "primary", provider: "openai", delegatedOutputTokens: 0)
        XCTAssertEqual(metric.ttftSeconds, 1)
        XCTAssertNotNil(SharedSample(metric))
        XCTAssertNotNil(RequestOutcome(dedupeKey: "native-id", occurredAt: now, client: T3Runtime.client, clientVersion: nil, parserVersion: "codex-rollout-v2", model: "gpt-6.1-sol", provider: "openai", kind: .succeeded))
        XCTAssertNil(RequestOutcome(dedupeKey: "native-id", occurredAt: now, client: T3Runtime.client, clientVersion: nil, parserVersion: "antigravity-conversation-v1", model: "gemini-3.8", provider: "google", kind: .succeeded))
    }
}
