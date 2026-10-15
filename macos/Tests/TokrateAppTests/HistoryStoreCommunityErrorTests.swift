import XCTest
import TokrateCore
@testable import TokrateApp

/// Community error alerts (contract "Community error alerts (0.1.23)") reach the store from the board
/// the sharing session fetches: nothing new is requested, and nothing is persisted. A mock transport
/// serves the board; synthetic folders keep the user's real history out of it.
@MainActor
final class HistoryStoreCommunityErrorTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "tokrate.community.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var claudeFolder: URL { root.appendingPathComponent("claude/project", isDirectory: true) }

    private func turn(model: String) -> TurnMetric {
        TurnMetric(
            id: UUID().uuidString, completedAt: Date.now.addingTimeInterval(-3_600), model: model,
            outputTokens: 100, durationSeconds: 50, codexTTFTSeconds: nil, turnThroughputTPS: 2, sourceKind: "primary"
        )
    }

    private func alertJSON(_ model: String, contributors: Int) -> String {
        let last = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-120))
        return #"{"model":"\#(model)","provider":"anthropic","clients":["claude-code"],"failingContributors":\#(contributors),"overloaded":4,"serverError":0,"firstFailureAt":"\#(last)","lastFailureAt":"\#(last)"}"#
    }

    private func boardJSON(_ alerts: [String]) -> Data {
        Data(#"{"schemaVersion":1,"collectionEnabled":true,"state":"ready","window":"24h","cohorts":[],"alerts":[],"errors":{"alerts":[\#(alerts.joined(separator: ","))]}}"#.utf8)
    }

    private func makeStore(records: [TurnMetric], transport: BoardTransport, sharing: Bool) -> (HistoryStore, SharingSession, SharingPreferences) {
        let session = SharingSession(identity: StubIdentity(), transport: transport, jitter: { 0 })
        let preferences = SharingPreferences(session: session, store: StubPreferenceStore())
        if sharing { preferences.consentToShare(startPolling: false) }
        let store = HistoryStore(
            persistenceURL: root.appendingPathComponent("history.json"),
            codexFolder: root.appendingPathComponent("codex", isDirectory: true),
            claudeProjectsFolder: root.appendingPathComponent("claude", isDirectory: true),
            grokSessionsFolder: root.appendingPathComponent("grok", isDirectory: true),
            antigravityDataFolder: root.appendingPathComponent("gemini", isDirectory: true),
            t3StateFolder: root.appendingPathComponent("t3-userdata"),
            openCodeDataFolder: root.appendingPathComponent("opencode", isDirectory: true),
            kimiCodeFolder: root.appendingPathComponent("kimi-code", isDirectory: true),
            kimiDesktopFolder: root.appendingPathComponent("kimi-desktop", isDirectory: true),
            sharingPreferences: preferences,
            defaults: defaults,
            initialRecords: records
        )
        return (store, session, preferences)
    }

    func testAnAlertForAModelUsedThisWeekShowsWhenTheBoardArrivesAndClearsToARecoveryNote() async throws {
        let transport = BoardTransport(board: boardJSON([alertJSON("claude-opus-5-5", contributors: 3)]))
        let (store, session, _) = makeStore(records: [turn(model: "claude-opus-5-5")], transport: transport, sharing: true)
        XCTAssertNil(store.communityErrorLine)

        await session.refresh(now: .now)
        try await waitUntil { store.communityErrorLine != nil }
        XCTAssertEqual(store.communityErrorLine?.kind, .alert)
        XCTAssertEqual(
            store.communityErrorLine?.text,
            "Tokrate contributors are reporting provider errors on claude-opus-5-5: 4 overloaded / at capacity from 3 contributors in the last hour, latest 2 min ago."
        )

        // The next board no longer lists it.
        await transport.setBoard(boardJSON([]))
        await session.refresh(now: .now.addingTimeInterval(31))
        try await waitUntil { store.communityErrorLine?.kind == .recovery }
        XCTAssertEqual(store.communityErrorLine?.text, "claude-opus-5-5: contributors no longer report provider errors (cleared just now).")
    }

    func testAnAlertForAModelTheUserDoesNotUseIsNotShown() async throws {
        let transport = BoardTransport(board: boardJSON([alertJSON("gpt-5.5", contributors: 5)]))
        let (store, session, _) = makeStore(records: [turn(model: "claude-opus-5-5")], transport: transport, sharing: true)
        await session.refresh(now: .now)
        XCTAssertNotNil(session.board)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.communityErrorLine)
    }

    func testAFailedBoardFetchShowsNothingAndDoesNotCountAsARecovery() async throws {
        let transport = BoardTransport(board: boardJSON([alertJSON("claude-opus-5-5", contributors: 3)]))
        let (store, session, _) = makeStore(records: [turn(model: "claude-opus-5-5")], transport: transport, sharing: true)
        await session.refresh(now: .now)
        try await waitUntil { store.communityErrorLine?.kind == .alert }

        await transport.setBoard(nil)
        await session.refresh(now: .now.addingTimeInterval(31))
        try await waitUntil { store.communityErrorLine == nil }
        XCTAssertNil(session.board)
    }

    func testTurningSharingOffClearsTheAlertAndForgetsWhatWasShown() async throws {
        let transport = BoardTransport(board: boardJSON([alertJSON("claude-opus-5-5", contributors: 3)]))
        let (store, session, preferences) = makeStore(records: [turn(model: "claude-opus-5-5")], transport: transport, sharing: true)
        await session.refresh(now: .now)
        try await waitUntil { store.communityErrorLine?.kind == .alert }

        preferences.chooseLocalOnly()
        try await waitUntil { store.communityErrorLine == nil }
        // Back on with a board that has no alerts: the earlier alert is not reported as cleared.
        await transport.setBoard(boardJSON([]))
        preferences.consentToShare(startPolling: false)
        await session.refresh(now: .now)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.communityErrorLine)
    }

    func testOwnFailureSaysItIsNotJustYouAndSharingOffShowsTheHint() async throws {
        try FileManager.default.createDirectory(at: claudeFolder, withIntermediateDirectories: true)
        let transport = BoardTransport(board: boardJSON([alertJSON("claude-opus-5-5", contributors: 3)]))
        let (store, session, preferences) = makeStore(records: [], transport: transport, sharing: true)
        store.startMonitoring()
        try await Task.sleep(for: .milliseconds(500))
        try writeFailingTranscript()
        try await waitUntil { store.providerErrorLine != nil }

        await session.refresh(now: .now)
        try await waitUntil { store.communityErrorLine?.kind == .alert }
        XCTAssertEqual(store.communityErrorLine?.text, "It’s not just you: 2 other contributors hit provider errors on claude-opus-5-5 in the last hour.")

        preferences.chooseLocalOnly()
        try await waitUntil { store.communityErrorLine?.kind == .sharingHint }
        XCTAssertEqual(store.communityErrorLine?.text, "Turn on sharing to see whether other contributors hit the same errors.")
        store.stopMonitoring()
    }

    func testTheSharingHintNeedsTheLocalLine() async throws {
        let (store, _, _) = makeStore(records: [], transport: BoardTransport(board: boardJSON([])), sharing: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.providerErrorLine)
        XCTAssertNil(store.communityErrorLine)
    }

    // MARK: Fixtures

    private func writeFailingTranscript() throws {
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

/// Serves the board on GET (a 500 while there is none) and accepts uploads.
private actor BoardTransport: SharingTransport {
    private var board: Data?

    init(board: Data?) { self.board = board }

    func setBoard(_ board: Data?) { self.board = board }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.httpMethod == "POST" { return (Data(), 202) }
        guard let board else { return (Data(), 500) }
        return (board, 200)
    }
}

@MainActor
private final class StubPreferenceStore: SharingPreferenceStore {
    var sharingEnabled: Bool?
    var consentRecord: SharingConsentRecord?
}
