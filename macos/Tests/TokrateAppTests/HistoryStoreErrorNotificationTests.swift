import XCTest
import TokrateCore
@testable import TokrateApp

/// Error notifications (contract "Error notifications (0.1.23)") reach the store from the board the
/// sharing session fetches, and leave it through the notifier. A mock transport serves the board and a
/// mock notifier records what is posted; synthetic folders keep the user's real history out of it.
@MainActor
final class HistoryStoreErrorNotificationTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "tokrate.errornotify.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func turn(model: String) -> TurnMetric {
        TurnMetric(
            id: UUID().uuidString, completedAt: Date.now.addingTimeInterval(-3_600), model: model,
            outputTokens: 100, durationSeconds: 50, codexTTFTSeconds: nil, turnThroughputTPS: 2, sourceKind: "primary"
        )
    }

    private func alertJSON(_ model: String, contributors: Int = 3, overloaded: Int = 4) -> String {
        let last = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-120))
        return #"{"model":"\#(model)","provider":"anthropic","clients":["claude-code"],"failingContributors":\#(contributors),"overloaded":\#(overloaded),"serverError":0,"firstFailureAt":"\#(last)","lastFailureAt":"\#(last)"}"#
    }

    private func boardJSON(_ alerts: [String]) -> Data {
        Data(#"{"schemaVersion":1,"collectionEnabled":true,"state":"ready","window":"24h","cohorts":[],"alerts":[],"errors":{"alerts":[\#(alerts.joined(separator: ","))]}}"#.utf8)
    }

    private struct Fixture {
        let store: HistoryStore
        let session: SharingSession
        let preferences: SharingPreferences
        let transport: BoardTransport
        let notifier: MockErrorNotifier
        /// The next refresh time, 31 seconds after the last one, so each refresh fetches the board.
        var clock = Date.now
    }

    private func makeFixture(
        board: [String], notificationsOn: Bool, sharing: Bool = true, notifier: MockErrorNotifier = MockErrorNotifier()
    ) -> Fixture {
        if notificationsOn { defaults.set(true, forKey: ErrorNotificationPreferences.defaultsKey) }
        let transport = BoardTransport(board: boardJSON(board))
        let session = SharingSession(identity: StubIdentity(), transport: transport, jitter: { 0 })
        let preferences = SharingPreferences(session: session, store: StubPreferenceStore())
        if sharing { preferences.consentToShare(startPolling: false) }
        let store = HistoryStore(
            persistenceURL: root.appendingPathComponent("history.json"),
            codexFolder: root.appendingPathComponent("codex", isDirectory: true),
            claudeProjectsFolder: root.appendingPathComponent("claude", isDirectory: true),
            grokSessionsFolder: root.appendingPathComponent("grok", isDirectory: true),
            antigravityDataFolder: root.appendingPathComponent("gemini", isDirectory: true),
            openCodeDataFolder: root.appendingPathComponent("opencode", isDirectory: true),
            kimiCodeFolder: root.appendingPathComponent("kimi-code", isDirectory: true),
            kimiDesktopFolder: root.appendingPathComponent("kimi-desktop", isDirectory: true),
            sharingPreferences: preferences,
            errorNotifier: notifier,
            defaults: defaults,
            initialRecords: [turn(model: "m1"), turn(model: "m2"), turn(model: "m3")]
        )
        return Fixture(store: store, session: session, preferences: preferences, transport: transport, notifier: notifier)
    }

    /// Serves `board` and refreshes the session once more.
    private func serve(_ board: [String], _ fixture: inout Fixture) async {
        await fixture.transport.setBoard(boardJSON(board))
        await fixture.session.refresh(now: fixture.clock)
        fixture.clock = fixture.clock.addingTimeInterval(31)
    }

    func testAlertsAlreadyOnTheFirstBoardAreNotNotifiedButANewOneIs() async throws {
        var fixture = makeFixture(board: [alertJSON("m1")], notificationsOn: true)
        await serve([alertJSON("m1")], &fixture)
        try await waitUntil { fixture.store.communityErrorLine?.kind == .alert }
        try await settle()
        XCTAssertEqual(fixture.notifier.posted, [], "the alert present at the first board is the baseline")

        await serve([alertJSON("m1"), alertJSON("m2", contributors: 5, overloaded: 1)], &fixture)
        try await waitUntil { !fixture.notifier.posted.isEmpty }
        XCTAssertEqual(fixture.notifier.posted, [
            ErrorNotification(
                kind: .start, model: "m2", title: "Provider errors on m2",
                body: "5 Tokrate contributors reported 1 overloaded / at capacity in the last hour."
            )
        ])

        // The same board again is the same episode.
        await serve([alertJSON("m1"), alertJSON("m2", contributors: 5, overloaded: 1)], &fixture)
        try await settle()
        XCTAssertEqual(fixture.notifier.posted.count, 1)
    }

    func testAnAlertForAModelTheUserDoesNotUseNeverNotifies() async throws {
        var fixture = makeFixture(board: [], notificationsOn: true)
        await serve([], &fixture)
        await serve([alertJSON("unused-model")], &fixture)
        try await settle()
        XCTAssertEqual(fixture.notifier.posted, [])
    }

    func testNothingIsPostedWhileTheSettingIsOff() async throws {
        var fixture = makeFixture(board: [], notificationsOn: false)
        await serve([], &fixture)
        await serve([alertJSON("m1")], &fixture)
        try await waitUntil { fixture.store.communityErrorLine?.kind == .alert }
        try await settle()
        XCTAssertEqual(fixture.notifier.posted, [])
    }

    func testSwitchingTheSettingOnTreatsTheShownAlertsAsNotified() async throws {
        var fixture = makeFixture(board: [], notificationsOn: false)
        await serve([alertJSON("m1")], &fixture)
        try await waitUntil { fixture.store.communityErrorLine?.kind == .alert }

        await fixture.store.errorNotifications.setEnabled(true)
        XCTAssertTrue(fixture.store.errorNotifications.isEnabled)
        try await settle()
        XCTAssertEqual(fixture.notifier.posted, [], "the alert showing when the setting turned on is the baseline")

        await serve([alertJSON("m1"), alertJSON("m3")], &fixture)
        try await waitUntil { !fixture.notifier.posted.isEmpty }
        XCTAssertEqual(fixture.notifier.posted.map(\.model), ["m3"])
    }

    func testADeniedPermissionKeepsTheSettingOffAndNothingIsPosted() async throws {
        var fixture = makeFixture(
            board: [], notificationsOn: false,
            notifier: MockErrorNotifier(permission: .notDetermined, afterRequest: .denied)
        )
        await serve([alertJSON("m1")], &fixture)
        try await waitUntil { fixture.store.communityErrorLine?.kind == .alert }
        await fixture.store.errorNotifications.setEnabled(true)
        XCTAssertFalse(fixture.store.errorNotifications.isEnabled)
        XCTAssertTrue(fixture.store.errorNotifications.isPermissionDenied)

        await serve([alertJSON("m1"), alertJSON("m2")], &fixture)
        try await settle()
        XCTAssertEqual(fixture.notifier.posted, [])
    }

    func testSharingTurningOffAndOnTakesANewBaseline() async throws {
        var fixture = makeFixture(board: [], notificationsOn: true)
        await serve([alertJSON("m1")], &fixture)
        try await waitUntil { fixture.store.communityErrorLine?.kind == .alert }

        fixture.preferences.chooseLocalOnly()
        try await waitUntil { fixture.store.communityErrorLine == nil }
        fixture.preferences.consentToShare(startPolling: false)
        // The first board after sharing is back lists two alerts: both are the baseline.
        fixture.clock = .now
        await serve([alertJSON("m1"), alertJSON("m2")], &fixture)
        try await waitUntil { fixture.store.communityErrorLine?.kind == .alert }
        try await settle()
        XCTAssertEqual(fixture.notifier.posted, [])

        await serve([alertJSON("m1"), alertJSON("m2"), alertJSON("m3")], &fixture)
        try await waitUntil { !fixture.notifier.posted.isEmpty }
        XCTAssertEqual(fixture.notifier.posted.map(\.model), ["m3"])
    }

    func testAtMostThreeNotificationsAnHour() async throws {
        var fixture = makeFixture(board: [], notificationsOn: true)
        await serve([], &fixture)
        await serve([alertJSON("m1"), alertJSON("m2"), alertJSON("m3"), alertJSON("m4")], &fixture)
        try await waitUntil { fixture.notifier.posted.count >= 3 }
        try await settle()
        XCTAssertEqual(fixture.notifier.posted.count, 3)
    }

    // MARK: Waiting

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { return XCTFail("timed out waiting for the store") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Long enough for a notification the store would post to have arrived.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
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
