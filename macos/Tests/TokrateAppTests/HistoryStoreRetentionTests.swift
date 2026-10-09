import XCTest
import TokrateCore
@testable import TokrateApp

/// The seven-day retention holds on disk while monitoring is paused, and the history file is
/// readable by its owner alone. Everything uses synthetic temporary folders and fake sharing seams.
@MainActor
final class HistoryStoreRetentionTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "tokrate.retention.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var historyURL: URL { root.appendingPathComponent("history.json") }

    private func makeStore(retentionInterval: TimeInterval = 3_600) -> HistoryStore {
        HistoryStore(
            persistenceURL: historyURL,
            codexFolder: root.appendingPathComponent("codex", isDirectory: true),
            claudeProjectsFolder: root.appendingPathComponent("claude", isDirectory: true),
            grokSessionsFolder: root.appendingPathComponent("grok", isDirectory: true),
            antigravityDataFolder: root.appendingPathComponent("gemini", isDirectory: true),
            openCodeDataFolder: root.appendingPathComponent("opencode", isDirectory: true),
            kimiCodeFolder: root.appendingPathComponent("kimi-code", isDirectory: true),
            kimiDesktopFolder: root.appendingPathComponent("kimi-desktop", isDirectory: true),
            sharingPreferences: SharingPreferences(
                session: SharingSession(identity: StubIdentity(), transport: StubTransport()),
                store: StubPreferenceStore()
            ),
            defaults: defaults,
            pausedRetentionInterval: retentionInterval
        )
    }

    private func writeHistory(_ records: [TurnMetric]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(SavedHistory(schemaVersion: 1, records: records)).write(to: historyURL)
    }

    private func savedIDs() -> [String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: historyURL),
              let saved = try? decoder.decode(SavedHistory.self, from: data) else { return ["unreadable"] }
        return saved.records.map(\.id).sorted()
    }

    private func record(_ id: String, expiresIn seconds: TimeInterval) -> TurnMetric {
        TurnMetric(
            id: id, completedAt: Date.now.addingTimeInterval(seconds - MetricHistory.retention), model: "m",
            outputTokens: 100, durationSeconds: 50, codexTTFTSeconds: nil, turnThroughputTPS: 2, sourceKind: "primary"
        )
    }

    func testRecordsThatExpireWhileMonitoringIsPausedLeaveTheFileWithoutAnyPoll() async throws {
        try writeHistory([record("soon", expiresIn: 1.5), record("later", expiresIn: 3_600)])
        let store = makeStore(retentionInterval: 0.4)
        store.startMonitoring()
        store.stopMonitoring()
        XCTAssertFalse(store.isMonitoring)
        XCTAssertEqual(savedIDs(), ["later", "soon"], "nothing has expired at the moment of pausing")

        try await waitUntil { savedIDs() == ["later"] }
        XCTAssertEqual(store.records.map(\.id), ["later"])
    }

    func testPausingWritesOutRecordsThatExpiredSinceTheLastWrite() async throws {
        try writeHistory([record("soon", expiresIn: 0.5), record("later", expiresIn: 3_600)])
        let store = makeStore()
        store.startMonitoring()
        try await Task.sleep(for: .milliseconds(800))
        store.stopMonitoring()
        XCTAssertEqual(savedIDs(), ["later"], "the pause itself prunes and saves")
    }

    func testPausingAgainAfterResumingKeepsTheRetentionTimerRunning() async throws {
        try writeHistory([record("soon", expiresIn: 1.2)])
        let store = makeStore(retentionInterval: 0.3)
        store.startMonitoring()
        store.stopMonitoring()
        store.startMonitoring()
        store.stopMonitoring()
        try await waitUntil { savedIDs().isEmpty }
    }

    func testTheHistoryFileIsOwnerOnlyAndIsReplacedInOnePiece() throws {
        // A file left world-readable by an earlier build.
        try writeHistory([record("kept", expiresIn: 3_600)])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: historyURL.path)
        let store = makeStore()
        store.startMonitoring()
        store.stopMonitoring()

        func permissions() throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: historyURL.path)[.posixPermissions] as? Int)
        }
        XCTAssertEqual(try permissions(), 0o600)
        XCTAssertEqual(savedIDs(), ["kept"])
        // No temporary file is left next to it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }, [])

        // Whatever the process umask, a first write is owner-only too.
        try FileManager.default.removeItem(at: historyURL)
        let previous = umask(0)
        defer { umask(previous) }
        let fresh = makeStore()
        fresh.startMonitoring()
        fresh.stopMonitoring()
        XCTAssertEqual(try permissions(), 0o600)
    }

    func testAHistoryFileAboveTheSizeCapOrThatIsNotARegularFileLoadsAsNoHistory() throws {
        try writeHistory([record("kept", expiresIn: 3_600)])
        XCTAssertEqual(makeStore().records.map(\.id), ["kept"])

        // One byte over the cap, even though it begins like a valid history.
        let valid = try Data(contentsOf: historyURL)
        var oversized = valid
        oversized.append(Data(repeating: 0x20, count: HistoryStore.maximumHistoryBytes + 1 - valid.count))
        XCTAssertEqual(oversized.count, HistoryStore.maximumHistoryBytes + 1)
        try oversized.write(to: historyURL)
        XCTAssertTrue(makeStore().records.isEmpty)
        // At the cap it is read.
        try Data(valid + Data(repeating: 0x20, count: HistoryStore.maximumHistoryBytes - valid.count)).write(to: historyURL)
        XCTAssertEqual(makeStore().records.map(\.id), ["kept"])

        // A FIFO is not opened, so the store does not wait for a writer.
        try FileManager.default.removeItem(at: historyURL)
        XCTAssertEqual(mkfifo(historyURL.path, 0o600), 0)
        XCTAssertTrue(makeStore().records.isEmpty)

        // A link to a regular history is followed.
        try FileManager.default.removeItem(at: historyURL)
        let target = root.appendingPathComponent("real-history.json")
        try writeHistory([record("linked", expiresIn: 3_600)])
        try FileManager.default.moveItem(at: historyURL, to: target)
        try FileManager.default.createSymbolicLink(at: historyURL, withDestinationURL: target)
        XCTAssertEqual(makeStore().records.map(\.id), ["linked"])
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { return XCTFail("timed out waiting for the store") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private struct SavedHistory: Codable {
    let schemaVersion: Int
    let records: [TurnMetric]
}

private struct StubIdentity: SharingIdentity {
    func loadOrCreate() throws -> Data { Data(repeating: 7, count: 32) }
}

private struct StubTransport: SharingTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 202) }
}

@MainActor
private final class StubPreferenceStore: SharingPreferenceStore {
    var sharingEnabled: Bool?
    var consentRecord: SharingConsentRecord?
}
