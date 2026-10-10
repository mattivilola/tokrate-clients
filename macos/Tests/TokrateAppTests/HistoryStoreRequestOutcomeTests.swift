import XCTest
import TokrateCore
@testable import TokrateApp

/// Request outcomes (contract "Request outcomes (0.1.22)") travel from the monitors to the sharing
/// session and nowhere else: never into the history file. Synthetic folders and a recording transport.
@MainActor
final class HistoryStoreRequestOutcomeTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "tokrate.outcomes.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var historyURL: URL { root.appendingPathComponent("history.json") }
    private var claudeFolder: URL { root.appendingPathComponent("claude/project", isDirectory: true) }

    func testOutcomesReachTheSharingSessionAsRequestCountsAndNeverTheHistoryFile() async throws {
        try FileManager.default.createDirectory(at: claudeFolder, withIntermediateDirectories: true)
        let transport = RecordingTransport()
        let session = SharingSession(identity: StubIdentity(), transport: transport, jitter: { 0 })
        let preferences = SharingPreferences(session: session, store: StubPreferenceStore())
        preferences.consentToShare(startPolling: false)
        let store = HistoryStore(
            persistenceURL: historyURL,
            codexFolder: root.appendingPathComponent("codex", isDirectory: true),
            claudeProjectsFolder: root.appendingPathComponent("claude", isDirectory: true),
            grokSessionsFolder: root.appendingPathComponent("grok", isDirectory: true),
            antigravityDataFolder: root.appendingPathComponent("gemini", isDirectory: true),
            openCodeDataFolder: root.appendingPathComponent("opencode", isDirectory: true),
            kimiCodeFolder: root.appendingPathComponent("kimi-code", isDirectory: true),
            kimiDesktopFolder: root.appendingPathComponent("kimi-desktop", isDirectory: true),
            sharingPreferences: preferences,
            defaults: defaults
        )
        store.startMonitoring()
        // Only requests that finish after launch are counted: let the responses fall after it.
        try await Task.sleep(for: .milliseconds(500))
        try writeTranscript()
        try await waitUntil { !store.records.isEmpty }

        // The bucket is due a period after it closes; look past it.
        await session.refresh(now: .now.addingTimeInterval(1_000))
        let bodies = await transport.uploadBodies()
        XCTAssertEqual(bodies.count, 1)
        let upload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bodies.first)) as? [String: Any])
        XCTAssertEqual(upload["schemaVersion"] as? Int, 2)
        let entries = try XCTUnwrap(upload["requestCounts"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["client"] as? String, "claude-code")
        XCTAssertEqual(entries.first?["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(entries.first?["succeeded"] as? Int, 1)
        XCTAssertEqual(entries.first?["overloaded"] as? Int, 1)
        XCTAssertEqual(entries.first?["serverError"] as? Int, 0)

        store.prepareForTermination()
        store.stopMonitoring()
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        for word in ["overloaded", "serverError", "succeeded", "outcome", "requestCount", "dedupe"] {
            XCTAssertFalse(history.contains(word), "\(word) must not reach the history file")
        }
    }

    // MARK: Fixtures

    /// A complete turn whose response succeeded, followed by an overloaded failure, all stamped just now.
    private func writeTranscript() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let end = Date.now
        func record(_ seconds: Double, _ extra: [String: Any]) -> String {
            var value: [String: Any] = [
                "sessionId": "s", "isSidechain": false, "userType": "external", "version": "2.1.295",
                "uuid": "u\(Int(seconds * 10))", "timestamp": formatter.string(from: end.addingTimeInterval(seconds))
            ]
            value.merge(extra) { _, new in new }
            return String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n"
        }
        let lines = [
            record(-2, ["type": "user", "parentUuid": NSNull(), "message": ["role": "user", "content": "PRIVATE"]]),
            record(-0.2, ["type": "assistant", "requestId": "req_011CABCDEFGHIJKLMNOPQRST", "message": [
                "id": "msg_01ABCDEFGHIJKLMNOPQRSTUV", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": "end_turn",
                "content": [["type": "text", "text": "x"]], "usage": ["output_tokens": 400]
            ] as [String: Any]]),
            record(-0.1, ["type": "assistant", "isApiErrorMessage": true, "apiErrorStatus": 529, "message": [
                "id": "0f0d7a52", "role": "assistant", "model": "<synthetic>", "stop_reason": "stop_sequence",
                "content": [["type": "text", "text": "API Error: Repeated 529 Overloaded errors"]], "usage": ["output_tokens": 0]
            ] as [String: Any]])
        ]
        try Data(lines.joined().utf8).write(to: claudeFolder.appendingPathComponent("session.jsonl"))
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { return XCTFail("timed out waiting for the store") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private struct StubIdentity: SharingIdentity {
    func loadOrCreate() throws -> Data { Data(repeating: 7, count: 32) }
}

private actor RecordingTransport: SharingTransport {
    private var bodies: [Data] = []

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.httpMethod == "POST" {
            bodies.append(request.httpBody ?? Data())
            return (Data(), 202)
        }
        return (Data(), 500)
    }

    func uploadBodies() -> [Data] { bodies }
}

@MainActor
private final class StubPreferenceStore: SharingPreferenceStore {
    var sharingEnabled: Bool?
    var consentRecord: SharingConsentRecord?
}
