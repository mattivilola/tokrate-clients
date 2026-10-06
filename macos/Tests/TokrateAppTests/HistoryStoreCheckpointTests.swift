import XCTest
import TokrateCore
@testable import TokrateApp

/// The read checkpoints of the monitors are saved in the history file and handed back to the monitors
/// at the next start. Everything uses synthetic temporary folders and fake sharing seams.
@MainActor
final class HistoryStoreCheckpointTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "tokrate.checkpoints.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var historyURL: URL { root.appendingPathComponent("history.json") }
    private var codexFolder: URL { root.appendingPathComponent("codex", isDirectory: true) }

    private func makeStore() -> HistoryStore {
        HistoryStore(
            persistenceURL: historyURL,
            codexFolder: codexFolder,
            claudeProjectsFolder: root.appendingPathComponent("claude", isDirectory: true),
            grokSessionsFolder: root.appendingPathComponent("grok", isDirectory: true),
            antigravityDataFolder: root.appendingPathComponent("gemini", isDirectory: true),
            openCodeDataFolder: root.appendingPathComponent("opencode", isDirectory: true),
            sharingPreferences: SharingPreferences(
                session: SharingSession(identity: StubIdentity(), transport: StubTransport()),
                store: StubPreferenceStore()
            ),
            defaults: defaults
        )
    }

    func testCheckpointsAreSavedWithTheHistoryAndLoadedByTheNextStore() async throws {
        try writeSession("first", turn: "a", tokens: 111)
        let store = makeStore()
        store.startMonitoring()
        try await waitUntil { !store.records.isEmpty && store.checkpoints.codex.count == 1 }
        store.stopMonitoring()

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let saved = try XCTUnwrap(object["checkpoints"] as? [String: Any])
        XCTAssertEqual((saved["codex"] as? [Any])?.count, 1)
        // Source paths stay off disk (contract "Privacy"): only a digest identifies the file.
        let text = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(text.contains("first.jsonl"))
        XCTAssertFalse(text.contains(codexFolder.lastPathComponent + "/"))
        XCTAssertFalse(text.contains(root.lastPathComponent))
        XCTAssertTrue(text.contains(SourceFileCheckpoint.digest(ofPath: codexFolder.appendingPathComponent("first.jsonl").standardizedFileURL.path)))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.records.map(\.outputTokens), [111])
        XCTAssertEqual(reloaded.checkpoints, store.checkpoints)
    }

    func testAHistoryWithoutCheckpointsStillLoadsAndAnOlderBuildIgnoresTheField() throws {
        let record = TurnMetric(
            id: "r", completedAt: .now.addingTimeInterval(-60), model: "m", outputTokens: 100, durationSeconds: 50,
            codexTTFTSeconds: nil, turnThroughputTPS: 2, sourceKind: "primary"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // A file written before checkpoints existed.
        try encoder.encode(LegacyPersistedHistory(schemaVersion: 1, records: [record])).write(to: historyURL)
        let legacy = makeStore()
        XCTAssertEqual(legacy.records.map(\.id), ["r"])
        XCTAssertEqual(legacy.checkpoints, SourceCheckpoints())

        // A file written with them, read the way an older build reads it.
        legacy.startMonitoring()
        legacy.stopMonitoring()
        let current = try Data(contentsOf: historyURL)
        XCTAssertTrue(String(decoding: current, as: UTF8.self).contains("\"checkpoints\""))
        XCTAssertEqual(try decoder.decode(LegacyPersistedHistory.self, from: current).records.map(\.id), ["r"])
    }

    func testCheckpointsOfFilesOlderThanTheRetentionAreDroppedOnLoad() throws {
        var set = SourceCheckpoints()
        set.codex = [
            SourceFileCheckpoint(pathDigest: "old", fileNumber: 1, size: 1, modifiedAt: .now.addingTimeInterval(-8 * 86_400), versionKey: "v"),
            SourceFileCheckpoint(pathDigest: "new", fileNumber: 2, size: 1, modifiedAt: .now.addingTimeInterval(-3_600), versionKey: "v")
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(CurrentPersistedHistory(schemaVersion: 1, records: [], checkpoints: set)).write(to: historyURL)
        XCTAssertEqual(makeStore().checkpoints.codex.map(\.pathDigest), ["new"])
    }

    func testAMatchingCheckpointKeepsTheNextStoreFromReadingTheFileAgain() async throws {
        try writeSession("first", turn: "a", tokens: 111)
        let store = makeStore()
        store.startMonitoring()
        try await waitUntil { !store.records.isEmpty && store.checkpoints.codex.count == 1 }
        store.stopMonitoring()

        // Forget the record but keep the checkpoint: a file that is read again would bring it back.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(CurrentPersistedHistory(schemaVersion: 1, records: [], checkpoints: store.checkpoints)).write(to: historyURL)
        try writeSession("second", turn: "b", tokens: 222)
        let skipping = makeStore()
        skipping.startMonitoring()
        try await waitUntil { !skipping.records.isEmpty }
        XCTAssertEqual(skipping.records.map(\.outputTokens), [222], "only the file without a checkpoint was read")
        skipping.stopMonitoring()

        // Without the checkpoint both files are read.
        try encoder.encode(LegacyPersistedHistory(schemaVersion: 1, records: [])).write(to: historyURL)
        let replaying = makeStore()
        replaying.startMonitoring()
        try await waitUntil { replaying.records.count == 2 }
        replaying.stopMonitoring()
    }

    func testRecordsArrivingSoonAfterTheFirstWriteWaitForTheThrottleAndTerminationWritesThem() async throws {
        try writeSession("first", turn: "a", tokens: 111)
        let store = makeStore()
        store.startMonitoring()
        try await waitUntil { savedOutputTokens() == [111] }

        // A turn appended to the same file is read by a later poll, well inside the ten-second write
        // interval. The set of files read is unchanged, so the write at the end of a replay does not apply
        // and only the throttle decides.
        try writeSession("first", turn: "b", tokens: 222, appending: true)
        try await waitUntil { store.records.count == 2 }
        XCTAssertEqual(savedOutputTokens(), [111], "the new record is not written yet")

        store.prepareForTermination()
        XCTAssertEqual(savedOutputTokens(), [111, 222])
        store.stopMonitoring()
    }

    func testRecordsWaitingForTheThrottleAreWrittenAtItsDeadlineEvenThoughNothingElseWakesThePoll() async throws {
        try writeSession("first", turn: "a", tokens: 111)
        let store = makeStore()
        store.startMonitoring()
        try await waitUntil { savedOutputTokens() == [111] }
        let firstWrite = Date.now
        try writeSession("first", turn: "b", tokens: 222, appending: true)
        // The monitors are idle after the append is read; an idle poll alone would come 30 s later.
        try await waitUntil(timeout: 25) { savedOutputTokens() == [111, 222] }
        XCTAssertGreaterThanOrEqual(Date.now.timeIntervalSince(firstWrite), HistorySaveThrottle.interval - 1)
        store.stopMonitoring()
    }

    private func savedOutputTokens() -> [Int] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: historyURL),
              let saved = try? decoder.decode(CurrentPersistedHistory.self, from: data)
        else { return [] }
        return saved.records.map(\.outputTokens).sorted()
    }

    // MARK: Fixtures

    /// A finished Codex turn from an hour ago, so it is final at once. With `appending` the turn is
    /// added to the session file written before, which keeps its modification date of now.
    private func writeSession(_ name: String, turn: String, tokens: Int, appending: Bool = false) throws {
        try FileManager.default.createDirectory(at: codexFolder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date.now.addingTimeInterval(-3_600)
        func line(_ seconds: Double, _ type: String, _ payload: [String: Any]) -> String {
            let object: [String: Any] = ["timestamp": formatter.string(from: start.addingTimeInterval(seconds)), "type": type, "payload": payload]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
        }
        let lines = (appending ? [] : [
            line(-1, "session_meta", ["id": name, "session_id": name, "source": "vscode", "model_provider": "openai"])
        ]) + [
            line(0, "event_msg", ["type": "task_started", "turn_id": turn]),
            line(0, "turn_context", ["turn_id": turn, "model": "gpt-test"]),
            line(2, "token_usage_record", ["turn_id": turn, "response_id": "r-\(turn)", "usage": ["output_tokens": tokens], "turn_token_usage": ["output_tokens": tokens]]),
            line(60, "event_msg", ["type": "task_complete", "turn_id": turn, "duration_ms": 60_000])
        ]
        let file = codexFolder.appendingPathComponent("\(name).jsonl")
        if appending {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(lines.joined().utf8))
            return
        }
        try Data(lines.joined().utf8).write(to: file)
        // Quiet for long enough that a checkpoint applies to it.
        try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: file.path)
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { return XCTFail("timed out waiting for the store") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// The envelope as builds before checkpoints (and, with them, as builds that ignore the field) read it.
private struct LegacyPersistedHistory: Codable {
    let schemaVersion: Int
    let records: [TurnMetric]
}

private struct CurrentPersistedHistory: Codable {
    let schemaVersion: Int
    let records: [TurnMetric]
    let checkpoints: SourceCheckpoints?
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
