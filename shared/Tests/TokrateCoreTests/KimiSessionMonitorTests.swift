import Foundation
import XCTest
@testable import TokrateCore

/// Kimi Code file discovery, delegated output and checkpoints through `KimiSessionMonitor`
/// (contract "Kimi Code (0.1.21)"). Time is driven by the `now:` of each poll; every timestamp is an
/// offset in seconds from `KimiLog.origin`.
final class KimiSessionMonitorTests: XCTestCase {
    private var root: URL!
    private let settle = DelegationAttributor.settleSeconds

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func at(_ seconds: Double) -> Date { KimiLog.date(seconds) }

    @discardableResult
    private func write(
        _ lines: [Data], session: String = "conv-1", agent: String = "main", workspace: String = "wd_x",
        modified seconds: Double = 100, under folder: String = "sessions"
    ) throws -> URL {
        let directory = root.appendingPathComponent("\(folder)/\(workspace)/\(session)/agents/\(agent)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("wire.jsonl")
        try KimiLog.jsonl(lines).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: at(seconds)], ofItemAtPath: url.path)
        return url
    }

    private func append(_ lines: [Data], to url: URL, modified seconds: Double) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: KimiLog.jsonl(lines))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: at(seconds)], ofItemAtPath: url.path)
    }

    private func monitor(
        surface: ToolSurface = .cli, liveSince: Double = 0,
        mainCheckpoints: [SourceFileCheckpoint] = [], subagentCheckpoints: [SourceFileCheckpoint] = []
    ) -> KimiSessionMonitor {
        KimiSessionMonitor(
            root: root, surface: surface, liveSince: at(liveSince),
            mainCheckpoints: mainCheckpoints, subagentCheckpoints: subagentCheckpoints
        )
    }

    /// A user prompt at `start` and one `end_turn` step finishing at `end`.
    private func turn(
        _ id: String = "0", start: Double = 0, end: Double = 60, output: Int = 1_000, origin: [String: Any]? = ["kind": "user"]
    ) -> [Data] {
        [KimiLog.prompt(at: start, origin: origin)] + KimiLog.step(id, 1, begin: start + 1, end: end, finish: "end_turn", output: output)
    }

    // MARK: Real logs

    func testARealDesktopSessionBecomesOneTurnWithItsLiveResponseAndASettledTotal() async throws {
        let session = "conv-22ebc177fa959871b7c04a95"
        let fixture = KimiLog.jsonl(try KimiLog.fixture("desktop-k2d8-two-step-success"))
        let directory = root.appendingPathComponent("sessions/wd_x/\(session)/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("wire.jsonl")
        try fixture.write(to: file)
        let finished = Date(timeIntervalSince1970: 1_791_543_260.330)
        try FileManager.default.setAttributes([.modificationDate: finished.addingTimeInterval(1)], ofItemAtPath: file.path)

        let monitor = KimiSessionMonitor(root: root, surface: .desktop, liveSince: Date(timeIntervalSince1970: 1_791_543_000))
        let first = try await monitor.poll(now: finished.addingTimeInterval(5))
        let turn = try XCTUnwrap(first.metrics.first)
        XCTAssertEqual(first.metrics.count, 1)
        XCTAssertEqual(turn.outputTokens, 416)
        XCTAssertEqual(turn.surface, .desktop)
        XCTAssertNil(turn.delegatedOutputTokens, "emitted at once, before the delegated total is final")
        XCTAssertEqual(first.responses.map(\.outputTokens), [285])
        XCTAssertEqual(first.responses.first?.sourceKind, "primary")
        XCTAssertEqual(first.responses.first?.client, "kimi-code")
        XCTAssertEqual(first.responses.first?.metricVersion, "kimi-observed-turn-v1")

        let settled = try await monitor.poll(now: finished.addingTimeInterval(5 + settle))
        XCTAssertEqual(settled.metrics.map(\.id), [turn.id])
        XCTAssertEqual(settled.metrics.first?.delegatedOutputTokens, 0)
        XCTAssertTrue(settled.responses.isEmpty, "a live response is published once")
        let after = try await monitor.poll(now: finished.addingTimeInterval(60))
        XCTAssertTrue(after.metrics.isEmpty)
    }

    func testTheSurfaceOfTheMonitorIsRecordedOnItsTurns() async throws {
        try write(turn())
        for surface in [ToolSurface.cli, .desktop] {
            let result = try await monitor(surface: surface).poll(now: at(100))
            XCTAssertEqual(result.metrics.first?.surface, surface)
        }
    }

    // MARK: Discovery

    func testOnlyAgentLogsAtTheExactDepthOfASessionAreRead() async throws {
        try write(turn(), session: "conv-1")
        try write(turn("0", start: 0, end: 40), session: "conv-1", agent: "sub-a")
        // Everything below is not a Kimi Code agent log and must be ignored completely.
        try write(try KimiLog.fixture("desktop-ctitle"), session: "ctitle-abc123")
        try write(try KimiLog.fixture("desktop-ctitle"), session: "ctitle-abc123", agent: "sub-a")
        try write(turn(), session: "conv-deeper/extra")
        try write(turn(), session: "conv-2", agent: "main/extra")
        try write(turn(), session: "conv-3", under: "other")
        let shallow = root.appendingPathComponent("sessions/wd_x/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: shallow, withIntermediateDirectories: true)
        try KimiLog.jsonl(turn()).write(to: shallow.appendingPathComponent("wire.jsonl"))
        let misnamed = root.appendingPathComponent("sessions/wd_x/conv-4/agent/main", isDirectory: true)
        try FileManager.default.createDirectory(at: misnamed, withIntermediateDirectories: true)
        try KimiLog.jsonl(turn()).write(to: misnamed.appendingPathComponent("wire.jsonl"))
        let other = root.appendingPathComponent("sessions/wd_x/conv-5/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        for name in ["state.json", "wire.jsonl.bak", "events.jsonl", "input_history.jsonl"] {
            try KimiLog.jsonl(turn()).write(to: other.appendingPathComponent(name))
        }
        try KimiLog.jsonl(turn()).write(to: root.appendingPathComponent("sessions/wd_x/conv-5/session_index.jsonl"))
        try KimiLog.jsonl(turn()).write(to: root.appendingPathComponent("wire.jsonl"))
        // The same attributes keep every file recent.
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            try? FileManager.default.setAttributes([.modificationDate: at(100)], ofItemAtPath: url.path)
        }

        let monitor = monitor()
        let result = try await monitor.poll(now: at(100))
        let status = await monitor.status()
        XCTAssertTrue(status.rootAvailable)
        XCTAssertEqual(status.files, 2, "one main log and one subagent log")
        XCTAssertEqual(result.metrics.count, 1)
        XCTAssertEqual(result.responses.count, 1)
        XCTAssertEqual(Set(result.metrics.map(\.outputTokens)), [1_000])
    }

    func testAMissingRootIsNotAvailable() async throws {
        let monitor = KimiSessionMonitor(root: root.appendingPathComponent("nowhere"), surface: .cli)
        let result = try await monitor.poll(now: at(100))
        XCTAssertTrue(result.metrics.isEmpty)
        let status = await monitor.status()
        XCTAssertFalse(status.rootAvailable)
    }

    func testOnlyTheSessionsFolderOfTheHomeIsWatchedAndReported() async throws {
        XCTAssertEqual(KimiSessionMonitor.watchedFolder(home: root).lastPathComponent, "sessions")
        // A home that exists without sessions yet is found, with no files.
        let monitor = monitor()
        _ = try await monitor.poll(now: at(100))
        var status = await monitor.status()
        XCTAssertTrue(status.rootAvailable)
        XCTAssertEqual(status.files, 0)

        // Logs outside <home>/sessions are not Kimi Code sessions, whatever their shape.
        let stray = root.appendingPathComponent("cache/sessions/wd_x/conv-9/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try KimiLog.jsonl(turn()).write(to: stray.appendingPathComponent("wire.jsonl"))
        let noted = await monitor.noteChanges(SessionFolderChange(paths: [stray.appendingPathComponent("wire.jsonl").standardizedFileURL.path]))
        XCTAssertFalse(noted, "a change outside the sessions folder wakes nothing")

        let url = try write(turn(), session: "conv-1")
        let wakes = await monitor.noteChanges(SessionFolderChange(paths: [url.standardizedFileURL.path]))
        XCTAssertTrue(wakes, "a new log below sessions does")
        let result = try await monitor.poll(now: at(101))
        XCTAssertEqual(result.metrics.count, 1)
        status = await monitor.status()
        XCTAssertEqual(status.files, 1)
    }

    func testAFileOlderThanTheRetentionIsNotRead() async throws {
        try write(turn(), modified: 100)
        let monitor = monitor()
        let result = try await monitor.poll(now: at(100 + MetricHistory.retention + 60))
        XCTAssertTrue(result.metrics.isEmpty)
    }

    // MARK: Live responses

    func testOnlyResponsesCompletedAfterTheMonitorStartedAreLiveAndNeverTwice() async throws {
        let url = try write(
            [KimiLog.prompt(at: 0)] + KimiLog.step("0", 1, begin: 1, end: 11, output: 300) + KimiLog.step("0", 2, begin: 12, end: 22, output: 400),
            modified: 22
        )
        let monitor = monitor(liveSince: 15)
        let first = try await monitor.poll(now: at(23))
        XCTAssertEqual(first.responses.map(\.outputTokens), [400], "step 1 finished before the monitor started")
        let again = try await monitor.poll(now: at(24))
        XCTAssertTrue(again.responses.isEmpty)

        try append(KimiLog.step("0", 3, begin: 25, end: 35, finish: "end_turn", output: 500), to: url, modified: 35)
        await monitor.noteChanges(SessionFolderChange(paths: [url.standardizedFileURL.path]))
        let next = try await monitor.poll(now: at(36))
        XCTAssertEqual(next.responses.map(\.outputTokens), [500])
        XCTAssertEqual(next.metrics.first?.outputTokens, 1_200)
    }

    func testSubagentStepsAndTitleSessionsPublishNoLiveResponse() async throws {
        try write(turn(output: 500), agent: "sub-a")
        try write(try KimiLog.fixture("desktop-k2d8-capacity-failure"), session: "ctitle-x")
        let result = try await monitor().poll(now: at(100))
        XCTAssertTrue(result.responses.isEmpty)
        XCTAssertTrue(result.metrics.isEmpty)
    }

    func testTheLiveTailSkipsTheTurnItJoinedMidwayWhileTheArchiveReaderMeasuresItWhole() async throws {
        let padding = Data(repeating: 0x20, count: CodexSessionMonitor.recentTailBytes + 4_096) + Data([0x0A])
        var data = KimiLog.jsonl([KimiLog.prompt(at: 0)] + KimiLog.step("0", 1, begin: 1, end: 11, output: 300))
        data.append(padding)
        data.append(KimiLog.jsonl(
            KimiLog.step("0", 2, begin: 12, end: 22, finish: "end_turn", output: 400)
                + [KimiLog.prompt(at: 30)] + KimiLog.step("1", 1, begin: 31, end: 41, finish: "end_turn", output: 200)
        ))
        let directory = root.appendingPathComponent("sessions/wd_x/conv-1/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("wire.jsonl"))

        let monitor = KimiSessionMonitor(root: root, surface: .cli)
        var turns: [String: TurnMetric] = [:]
        var emitted: [TurnMetric] = []
        for step in 0..<12 {
            let records = try await monitor.poll(now: Date.now.addingTimeInterval(Double(step) * 11)).metrics
            emitted += records
            for record in records { turns[record.id] = record }
        }
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(Set(turns.values.map(\.outputTokens)), [700, 200], "the archive reader measures turn 0 whole")
        XCTAssertEqual(emitted.filter { $0.outputTokens == 400 }.count, 0, "the tail never emits the partial turn")
    }

    // MARK: Delegated output

    func testSubagentTurnsStartedInsideAMainTurnAreItsDelegatedOutput() async throws {
        try write(turn(start: 0, end: 61, output: 900), session: "conv-1")
        // Any prompt origin counts for a subagent, and every one of its sibling folders is its own source.
        try write(turn(start: 10, end: 40, output: 700, origin: ["kind": "system"]), session: "conv-1", agent: "sub-a")
        try write(turn(start: 20, end: 50, output: 300), session: "conv-1", agent: "sub-b")
        // Not counted: another session, a failed turn, work started before the main turn.
        try write(turn(start: 12, end: 40, output: 111), session: "conv-2", agent: "sub-a")
        try write([KimiLog.prompt(at: 15)] + KimiLog.step("0", 1, begin: 16, end: 30, finish: "error"), session: "conv-1", agent: "sub-c")
        try write(turn(start: -50, end: -10, output: 222), session: "conv-1", agent: "sub-d")
        let monitor = monitor()

        let first = try await monitor.poll(now: at(61))
        let parent = try XCTUnwrap(first.metrics.first)
        XCTAssertEqual(first.metrics.count, 1, "subagent files produce no TurnMetric")
        XCTAssertEqual(parent.outputTokens, 900)
        XCTAssertNil(parent.delegatedOutputTokens)
        let early = try await monitor.poll(now: at(61 + settle - 1))
        XCTAssertTrue(early.metrics.isEmpty, "not final before the settle time")
        let settled = try await monitor.poll(now: at(61 + settle))
        XCTAssertEqual(settled.metrics.map(\.id), [parent.id], "re-emitted under the same id")
        XCTAssertEqual(settled.metrics.first?.delegatedOutputTokens, 1_000)
        XCTAssertEqual(settled.metrics.first?.outputTokens, 900)
    }

    func testAnOpenSubagentTurnHoldsTheTotalUntilItFinishesOrTheMaximumWaitPasses() async throws {
        try write(turn(start: 0, end: 61, output: 900))
        let subagent = try write(
            [KimiLog.prompt(at: 10)] + KimiLog.step("0", 1, begin: 11, end: 30, output: 200), session: "conv-1", agent: "sub-a", modified: 30
        )
        let monitor = monitor()
        let first = try await monitor.poll(now: at(61))
        let parent = try XCTUnwrap(first.metrics.first)
        let held = try await monitor.poll(now: at(61 + settle + 1))
        XCTAssertTrue(held.metrics.isEmpty, "the subagent turn that started inside is still open")

        try append(KimiLog.step("0", 2, begin: 100, end: 130, finish: "end_turn", output: 450), to: subagent, modified: 130)
        await monitor.noteChanges(SessionFolderChange(paths: [subagent.standardizedFileURL.path]))
        let done = try await monitor.poll(now: at(131))
        XCTAssertEqual(done.metrics.map(\.id), [parent.id])
        XCTAssertEqual(done.metrics.first?.delegatedOutputTokens, 650, "both steps of the subagent turn: 200 + 450")
    }

    func testAnOpenSubagentTurnBeyondTheMaximumWaitIsIgnored() async throws {
        try write(turn(start: 0, end: 61, output: 900))
        try write(turn(start: 10, end: 30, output: 250), agent: "sub-a")
        try write([KimiLog.prompt(at: 12)] + KimiLog.step("0", 1, begin: 13, end: 20, finish: "tool_use", output: 80), agent: "sub-b")
        let monitor = monitor()
        _ = try await monitor.poll(now: at(61))
        let blocked = try await monitor.poll(now: at(61 + DelegationAttributor.maximumWaitSeconds - 1))
        XCTAssertTrue(blocked.metrics.isEmpty)
        let released = try await monitor.poll(now: at(61 + DelegationAttributor.maximumWaitSeconds))
        XCTAssertEqual(released.metrics.first?.delegatedOutputTokens, 250)
    }

    // MARK: Checkpoints

    func testFilesReadToTheirEndAreCheckpointedForBothSetsAndSkippedNextTime() async throws {
        try write(turn(start: 0, end: 61, output: 900), modified: 100)
        try write(turn(start: 10, end: 40, output: 700), agent: "sub-a", modified: 100)
        let first = monitor()
        let beforeDiscovery = await first.checkpoints()
        XCTAssertNil(beforeDiscovery, "nothing is known before the first discovery")
        _ = try await first.poll(now: at(61))
        let whileWaiting = await first.checkpoints()
        XCTAssertNil(whileWaiting, "the main turn still awaits its delegated total")
        let settled = try await first.poll(now: at(61 + settle))
        XCTAssertEqual(settled.metrics.first?.delegatedOutputTokens, 700)
        let saved = await first.checkpoints()
        let checkpoints = try XCTUnwrap(saved)
        XCTAssertEqual(checkpoints.main.count, 1)
        XCTAssertEqual(checkpoints.subagents.count, 1)

        // A later run skips both files, quiet since: nothing is read again.
        let resumed = monitor(mainCheckpoints: checkpoints.main, subagentCheckpoints: checkpoints.subagents)
        let later = try await resumed.poll(now: at(100 + SourceFileCheckpoint.minimumQuietSeconds + 1))
        XCTAssertTrue(later.metrics.isEmpty)
        XCTAssertTrue(later.responses.isEmpty)
        let status = await resumed.status()
        XCTAssertEqual(status.files, 2)

        // Without them the same files are read in full.
        let replayed = try await monitor().poll(now: at(100 + SourceFileCheckpoint.minimumQuietSeconds + 1))
        XCTAssertEqual(replayed.metrics.count, 1)
    }

    func testACheckpointIsIgnoredForAChangedFile() async throws {
        let url = try write(turn(start: 0, end: 61, output: 900), modified: 100)
        let first = monitor()
        _ = try await first.poll(now: at(101))
        _ = try await first.poll(now: at(101 + settle))
        let saved = await first.checkpoints()
        let checkpoints = try XCTUnwrap(saved)
        try append(turn("1", start: 200, end: 260, output: 500), to: url, modified: 300)
        let resumed = monitor(mainCheckpoints: checkpoints.main, subagentCheckpoints: checkpoints.subagents)
        let result = try await resumed.poll(now: at(300 + SourceFileCheckpoint.minimumQuietSeconds + 1))
        XCTAssertEqual(Set(result.metrics.map(\.outputTokens)), [900, 500], "the file changed, so it is read in full")
    }

    // MARK: Replay

    func testTheHistoryReplayReadsBothHomes() async throws {
        let desktop = root.appendingPathComponent("desktop-home", isDirectory: true)
        let cli = root.appendingPathComponent("cli-home", isDirectory: true)
        for (home, session) in [(cli, "conv-cli"), (desktop, "conv-desktop")] {
            let directory = home.appendingPathComponent("sessions/wd_x/\(session)/agents/main", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("wire.jsonl")
            try KimiLog.jsonl(try KimiLog.fixture("desktop-k2d8-two-step-success")).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3_600)], ofItemAtPath: file.path)
        }
        let nowhere = root.appendingPathComponent("absent", isDirectory: true)
        let folders = SourceFolders(
            codex: nowhere, claudeCode: nowhere, grokBuild: nowhere, antigravity: nowhere, openCode: nowhere,
            kimiCode: cli, kimiDesktop: desktop
        )
        let replay = await HistoryReplay.run(folders: folders, retention: 60 * 86_400)
        XCTAssertEqual(replay.incompleteSources, [])
        XCTAssertEqual(replay.metrics.count, 2)
        XCTAssertEqual(Set(replay.metrics.compactMap(\.surface)), [.cli, .desktop])
        XCTAssertEqual(Set(replay.metrics.map(\.client)), ["kimi-code"])
    }
}
