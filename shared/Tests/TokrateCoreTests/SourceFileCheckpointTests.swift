import Foundation
import XCTest
@testable import TokrateCore

/// Files read to their end by an earlier run are not read again (see `SourceFileCheckpoint`). Time is
/// driven by the `now:` of each poll; every timestamp is an offset in seconds from `origin`, and file
/// modification times are set explicitly.
final class SourceFileCheckpointTests: XCTestCase {
    /// Whole seconds, so timestamps (millisecond precision) round-trip exactly.
    private let origin = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
    private let codexVersion = SourceFileCheckpoint.versionKey(parser: TurnMetric.codexParserVersion, metric: TurnMetric.codexMetricVersion)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Codex

    func testACheckpointedFileIsNotReadAgainAndALaterAppendIsParsedWithItsSessionContext() async throws {
        let file = directory.appendingPathComponent("session.jsonl")
        try (codexRoot(turns: [codexTurn("t1", start: -200, end: -140, tokens: 111)]) + padding(270_000)).write(to: file)
        try touch(file, at: -1_000)

        let first = CodexSessionMonitor(root: directory, liveSince: at(-1_000))
        let before = await first.checkpoints()
        XCTAssertNil(before, "nothing is known before the first discovery")
        let replayed = try await readAll(first, at: 0)
        XCTAssertEqual(replayed.map(\.outputTokens), [111])
        let checkpoints = try await XCTUnwrapAsync(await first.checkpoints())
        XCTAssertEqual(checkpoints.map(\.pathDigest), [SourceFileCheckpoint.digest(ofPath: file.standardizedFileURL.path)])
        XCTAssertEqual(checkpoints.first?.size, UInt64(try Data(contentsOf: file).count))

        let second = CodexSessionMonitor(root: directory, liveSince: at(-1_000), checkpoints: checkpoints)
        let update = try await second.poll(now: at(1))
        XCTAssertTrue(update.metrics.isEmpty)
        let bytes = await second.bytesReadLastPoll
        XCTAssertEqual(bytes, 0)
        let deadline = await second.nextPollDeadline(now: at(1))
        XCTAssertNil(deadline, "a checkpointed file leaves nothing to read")
        let again = await second.checkpoints()
        XCTAssertEqual(again, checkpoints, "it stays checkpointed without being read")

        try append(codexTurn("t2", start: 100, end: 160, tokens: 222), to: file, modified: 160)
        await second.noteChanges(SessionFolderChange(paths: [file.standardizedFileURL.path]))
        var appended: [TurnMetric] = []
        for _ in 0..<4 { appended += try await second.poll(now: at(200)).metrics }
        XCTAssertEqual(appended.map(\.outputTokens), [222], "only the appended turn, none of the history")
        XCTAssertEqual(appended.first?.model, "gpt-test", "the model comes from the appended turn's own context")
        XCTAssertEqual(appended.first?.sourceKind, "primary", "the session header is recovered for the appended records")
        XCTAssertEqual(appended.first?.provider, "openai")
        XCTAssertNotNil(appended.first?.delegatedOutputTokens, "the turn settles like any other")
    }

    func testAChangedFileIsReplayedInFull() async throws {
        let turns = [codexTurn("t1", start: -200, end: -140, tokens: 111)]
        let version = codexVersion
        let file = directory.appendingPathComponent("session.jsonl")
        let content = codexRoot(turns: turns) + padding(270_000)

        func prepare(modified: Double = -1_000) async throws -> [SourceFileCheckpoint] {
            try? FileManager.default.removeItem(at: file)
            try content.write(to: file)
            try touch(file, at: modified)
            let monitor = CodexSessionMonitor(root: directory, liveSince: at(-1_000))
            _ = try await readAll(monitor, at: 0)
            return try await XCTUnwrapAsync(await monitor.checkpoints())
        }
        func replayedTokens(_ checkpoints: [SourceFileCheckpoint]) async throws -> [Int] {
            let monitor = CodexSessionMonitor(root: directory, liveSince: at(-1_000), checkpoints: checkpoints)
            return try await readAll(monitor, at: 0).map(\.outputTokens)
        }

        var checkpoints = try await prepare()
        let unchanged = try await replayedTokens(checkpoints)
        XCTAssertEqual(unchanged, [], "control: an unchanged file is skipped")

        try append(Data([0x20, 0x0A]), to: file, modified: 0)
        let grown = try await replayedTokens(checkpoints)
        XCTAssertEqual(grown, [111], "a different size")

        checkpoints = try await prepare()
        try touch(file, at: -999)
        let touched = try await replayedTokens(checkpoints)
        XCTAssertEqual(touched, [111], "a different modification time")

        checkpoints = try await prepare()
        let replacement = directory.appendingPathComponent("replacement.tmp")
        try content.write(to: replacement)
        try touch(replacement, at: -1_000)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        try touch(file, at: -1_000)
        let replaced = try await replayedTokens(checkpoints)
        XCTAssertEqual(replaced, [111], "the same size and time, but another file")

        checkpoints = try await prepare()
        let otherVersion = checkpoints.map {
            SourceFileCheckpoint(pathDigest: $0.pathDigest, fileNumber: $0.fileNumber, size: $0.size, modifiedAt: $0.modifiedAt, versionKey: version + "-next")
        }
        let reparsed = try await replayedTokens(otherVersion)
        XCTAssertEqual(reparsed, [111], "another parser or metric version")

        checkpoints = try await prepare(modified: -(SourceFileCheckpoint.minimumQuietSeconds - 1))
        let recent = try await replayedTokens(checkpoints)
        XCTAssertEqual(recent, [111], "a file modified within the quiet period may hold a running turn")
        checkpoints = try await prepare(modified: -SourceFileCheckpoint.minimumQuietSeconds)
        let quiet = try await replayedTokens(checkpoints)
        XCTAssertEqual(quiet, [], "exactly the quiet period is enough")
    }

    func testCheckpointsAreHeldBackWhileATurnAwaitsItsDelegatedTotal() async throws {
        let file = directory.appendingPathComponent("session.jsonl")
        try codexRoot(turns: [codexTurn("t1", start: -20, end: 0, tokens: 111)]).write(to: file)
        try touch(file, at: 0)
        let monitor = CodexSessionMonitor(root: directory, liveSince: at(-1_000))
        let first = try await readAll(monitor, at: 1)
        XCTAssertEqual(first.first?.delegatedOutputTokens, nil, "the turn is not final yet")
        let pending = await monitor.checkpoints()
        XCTAssertNil(pending, "keep the previous set while a turn is pending")

        let final = try await readAll(monitor, at: DelegationAttributor.settleSeconds)
        XCTAssertEqual(final.first?.delegatedOutputTokens, 0)
        let settled = await monitor.checkpoints()
        XCTAssertEqual(settled?.count, 1)
    }

    func testAFileStillBeingReadIsNotCheckpointedAndTheFinishedOnesAre() async throws {
        let big = directory.appendingPathComponent("big.jsonl")
        try (codexRoot(id: "big", turns: []) + padding(3_000_000)).write(to: big)
        let small = directory.appendingPathComponent("small.jsonl")
        try codexRoot(id: "small", turns: []).write(to: small)
        for url in [big, small] { try touch(url, at: 0) }
        let monitor = CodexSessionMonitor(root: directory, liveSince: at(-1_000))
        _ = try await monitor.poll(now: at(0))
        _ = try await monitor.poll(now: at(0))
        let partial = try await XCTUnwrapAsync(await monitor.checkpoints())
        XCTAssertEqual(partial.map(\.pathDigest), [SourceFileCheckpoint.digest(ofPath: small.standardizedFileURL.path)], "the archive of the big file is still in progress")
        for _ in 0..<80 { _ = try await monitor.poll(now: at(0)) }
        let complete = try await XCTUnwrapAsync(await monitor.checkpoints())
        XCTAssertEqual(Set(complete.map(\.pathDigest)), Set([big, small].map { SourceFileCheckpoint.digest(ofPath: $0.standardizedFileURL.path) }))
    }

    /// A replayed turn whose delegated work sits in a skipped child file must keep the total the history
    /// already holds: summing only the child files that were read again would replace it with less.
    func testReplayingAPrimaryFileDoesNotRecomputeTotalsFromSkippedChildren() async throws {
        let root = directory.appendingPathComponent("root.jsonl")
        let child = directory.appendingPathComponent("child.jsonl")
        let primaryTurn = codexTurn("t1", start: -2_000, end: -1_940, tokens: 100)
        try (codexRoot(turns: [primaryTurn]) + padding(270_000)).write(to: root)
        try codexChild(turns: [codexTurn("c1", start: -1_990, end: -1_960, tokens: 500)]).write(to: child)
        for url in [root, child] { try touch(url, at: -1_000) }

        let first = CodexSessionMonitor(root: directory, liveSince: at(-5_000))
        let attributed = try await readAll(first, at: 0)
        XCTAssertEqual(attributed.first { $0.outputTokens == 100 }?.delegatedOutputTokens, 500)
        let checkpoints = try await XCTUnwrapAsync(await first.checkpoints())
        XCTAssertEqual(checkpoints.count, 2, "primary and child file")

        try append(codexTurn("t2", start: 1_000, end: 1_060, tokens: 200), to: root, modified: 1_060)
        let second = CodexSessionMonitor(root: directory, liveSince: at(-5_000), checkpoints: checkpoints)
        let update = try await readAll(second, at: 1_100)
        let replayed = update.filter { $0.outputTokens == 100 }
        XCTAssertFalse(replayed.isEmpty, "the changed primary file is read again")
        XCTAssertTrue(replayed.allSatisfy { $0.delegatedOutputTokens == nil }, "the settled total of the history is not replaced")
        XCTAssertEqual(update.first { $0.outputTokens == 200 }?.delegatedOutputTokens, 0, "a turn after the checkpoint is final")
        let after = await second.checkpoints()
        XCTAssertEqual(after?.count, 2, "nothing is left pending: both files are checkpointed again")
    }

    func testAChildFileResumedFromACheckpointStillReportsItsAppendedWork() async throws {
        let root = directory.appendingPathComponent("root.jsonl")
        let child = directory.appendingPathComponent("child.jsonl")
        try codexRoot(turns: [codexTurn("t1", start: -2_000, end: -1_940, tokens: 100)]).write(to: root)
        try codexChild(turns: [codexTurn("c1", start: -1_990, end: -1_960, tokens: 500)]).write(to: child)
        for url in [root, child] { try touch(url, at: -1_000) }
        let first = CodexSessionMonitor(root: directory, liveSince: at(-5_000))
        _ = try await readAll(first, at: 0)
        let checkpoints = try await XCTUnwrapAsync(await first.checkpoints())

        let second = CodexSessionMonitor(root: directory, liveSince: at(-5_000), checkpoints: checkpoints)
        _ = try await readAll(second, at: 10)
        // A new turn delegates to the existing child, which resumes at its end.
        try append(codexTurn("t2", start: 100, end: 200, tokens: 300), to: root, modified: 200)
        try append(codexTurn("c2", start: 110, end: 150, tokens: 700), to: child, modified: 150)
        await second.noteChanges(SessionFolderChange(paths: [root.standardizedFileURL.path, child.standardizedFileURL.path]))
        let update = try await readAll(second, at: 240)
        XCTAssertEqual(update.first { $0.outputTokens == 300 }?.delegatedOutputTokens, 700)
    }

    func testAReaderResumedAtTheEndStartsOverWhenItsFileIsReplaced() throws {
        let file = directory.appendingPathComponent("session.jsonl")
        let original = codexRoot(turns: [codexTurn("t1", start: -200, end: -140, tokens: 111)])
        try original.write(to: file)
        var reader = JSONLFileReader(url: file, startPosition: .resume(atOffset: UInt64(original.count)))
        XCTAssertTrue(try reader.poll().isEmpty)
        XCTAssertEqual(reader.bytesReadLastPoll, 0)
        XCTAssertTrue(reader.isCaughtUp)

        let replacement = directory.appendingPathComponent("replacement.tmp")
        try (codexRoot(turns: [codexTurn("t9", start: -200, end: -140, tokens: 999)])).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        var tokens: [Int] = []
        for _ in 0..<4 { tokens += try reader.poll().map(\.outputTokens) }
        XCTAssertEqual(tokens, [999], "a replaced file is read from its start")
    }

    // MARK: Claude

    func testClaudePrimaryTranscriptsAreCheckpointedAndSkippedUnlessChanged() async throws {
        let project = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        try jsonl([claudePrompt(1), claudeAnswer("m1", 5, 100)]).write(to: file)
        try touch(file, at: -1_000)

        let first = ClaudeSessionMonitor(root: directory, liveSince: at(-1_000))
        let unknown = await first.checkpoints()
        XCTAssertNil(unknown)
        let early = try await first.poll(now: at(6))
        XCTAssertEqual(early.metrics.map(\.outputTokens), [100])
        let pending = await first.checkpoints()
        XCTAssertNil(pending, "the turn awaits its delegated total")
        let late = try await first.poll(now: at(6 + DelegationAttributor.settleSeconds))
        XCTAssertEqual(late.metrics.first?.delegatedOutputTokens, 0)
        let saved = try await XCTUnwrapAsync(await first.checkpoints())
        XCTAssertEqual(saved.primary.map(\.pathDigest), [SourceFileCheckpoint.digest(ofPath: file.standardizedFileURL.path)])
        XCTAssertTrue(saved.subagents.isEmpty)

        let second = ClaudeSessionMonitor(root: directory, liveSince: at(-1_000), primaryCheckpoints: saved.primary)
        let skipped = try await second.poll(now: at(100))
        XCTAssertTrue(skipped.metrics.isEmpty)
        let deadline = await second.nextPollDeadline(now: at(100))
        XCTAssertNil(deadline)

        try append([claudePrompt(200), claudeAnswer("m2", 204, 250)], to: file, modified: 204)
        await second.noteChanges(SessionFolderChange(paths: [file.standardizedFileURL.path]))
        let appended = try await second.poll(now: at(210))
        XCTAssertEqual(appended.metrics.map(\.outputTokens), [250], "the first turn after the checkpoint is measured, the history is not replayed")
        XCTAssertEqual(appended.metrics.first?.sourceKind, "primary")

        // A changed file is replayed in full.
        let third = ClaudeSessionMonitor(root: directory, liveSince: at(-1_000), primaryCheckpoints: saved.primary)
        let replayed = try await third.poll(now: at(300))
        XCTAssertEqual(Set(replayed.metrics.map(\.outputTokens)), [100, 250])
    }

    func testATurnIsForgottenOnlyWhenASkippedFileCouldHoldItsWork() {
        /// A turn of 60 s that started at `origin`, against one skipped file last modified at `skippedThrough`.
        func finals(skippedThrough: TimeInterval?) -> (finals: Int, pending: Bool) {
            var attributor = DelegationAttributor()
            let metric = TurnMetric(
                id: "turn", completedAt: at(60), model: "m", outputTokens: 100, durationSeconds: 60, codexTTFTSeconds: nil,
                turnThroughputTPS: 1, sourceKind: "primary"
            )
            attributor.ingest(events: [.primaryTurn(turnID: "turn", root: "r")], metrics: [metric])
            let file = DelegationSourceFile(
                modifiedAt: at(0), livePending: false, archivePending: false, liveStartedAt: nil, skippedThrough: skippedThrough.map(at)
            )
            let result = attributor.finalize(now: at(60 + DelegationAttributor.settleSeconds), backlog: DelegationBacklog(files: [file]))
            return (result.count, attributor.hasPending)
        }
        XCTAssertEqual(finals(skippedThrough: nil).finals, 1, "control: nothing was skipped")
        XCTAssertEqual(finals(skippedThrough: 0).finals, 0, "a skipped file modified at the turn's start could hold its work")
        XCTAssertEqual(finals(skippedThrough: -2).finals, 0, "exactly at the tolerance")
        XCTAssertEqual(finals(skippedThrough: -2.001).finals, 1, "a file last modified before the turn cannot")
        XCTAssertFalse(finals(skippedThrough: 0).pending, "the turn is forgotten, not held")
    }

    // MARK: Polls that must not stop

    func testAClaudeTurnWaitingForItsTextBlockKeepsTheMonitorPolling() async throws {
        let project = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        let thinking = claudeRecord("assistant", uuid: "record-m1", at: 10, message: [
            "id": "m1", "role": "assistant", "model": "claude-sonnet-5-5", "content": [["type": "thinking", "thinking": "PRIVATE"]],
            "stop_reason": "end_turn", "usage": ["output_tokens": 300]
        ])
        try jsonl([claudePrompt(0), thinking]).write(to: file)
        try touch(file, at: -1_000)
        let monitor = ClaudeSessionMonitor(root: directory, liveSince: at(-1_000))
        let held = try await monitor.poll(now: at(0))
        XCTAssertTrue(held.metrics.isEmpty, "the text block may still follow")
        let waiting = await monitor.nextPollDeadline(now: at(0))
        XCTAssertEqual(waiting, at(0), "an idle file with a pending turn is polled again, or the timeout would never run")
        let held2 = await monitor.checkpoints()
        XCTAssertEqual(held2?.primary.count, 0, "the file is not checkpointed while a record sequence is open")
        let closed = try await monitor.poll(now: at(31))
        XCTAssertEqual(closed.metrics.map(\.outputTokens), [300])
    }

    func testAVanishedFileIsPrunedByDiscoveryInsteadOfRetriedForever() async throws {
        let codex = directory.appendingPathComponent("codex", isDirectory: true)
        let claude = directory.appendingPathComponent("claude/project", isDirectory: true)
        for folder in [codex, claude] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let codexFile = codex.appendingPathComponent("session.jsonl")
        let claudeFile = claude.appendingPathComponent("session.jsonl")
        try (codexRoot(turns: []) + padding(3_000_000)).write(to: codexFile)
        try (jsonl([claudePrompt(1)]) + padding(3_000_000)).write(to: claudeFile)
        let codexMonitor = CodexSessionMonitor(root: codex, liveSince: at(-1_000))
        let claudeMonitor = ClaudeSessionMonitor(root: directory.appendingPathComponent("claude"), liveSince: at(-1_000))
        for _ in 0..<2 {
            _ = try await codexMonitor.poll(now: at(0))
            _ = try await claudeMonitor.poll(now: at(0))
        }
        let codexBusy = await codexMonitor.nextPollDeadline(now: at(0))
        let claudeBusy = await claudeMonitor.nextPollDeadline(now: at(0))
        XCTAssertNotNil(codexBusy)
        XCTAssertNotNil(claudeBusy)

        try FileManager.default.removeItem(at: codexFile)
        try FileManager.default.removeItem(at: claudeFile)
        // The failing read asks for discovery without any folder event; the next poll prunes the file.
        _ = try await codexMonitor.poll(now: at(1))
        _ = try await claudeMonitor.poll(now: at(1))
        _ = try await codexMonitor.poll(now: at(2))
        _ = try await claudeMonitor.poll(now: at(2))
        let codexIdle = await codexMonitor.nextPollDeadline(now: at(2))
        let claudeIdle = await claudeMonitor.nextPollDeadline(now: at(2))
        XCTAssertNil(codexIdle)
        XCTAssertNil(claudeIdle)
    }

    // MARK: Checkpoint set

    func testRetainedDropsFilesOlderThanTheHistoryAndBoundsEachSource() {
        let now = origin
        func checkpoint(_ path: String, daysAgo: Double) -> SourceFileCheckpoint {
            SourceFileCheckpoint(pathDigest: path, fileNumber: 1, size: 1, modifiedAt: now.addingTimeInterval(-daysAgo * 86_400), versionKey: "v")
        }
        var set = SourceCheckpoints()
        set.codex = [checkpoint("old", daysAgo: 8), checkpoint("recent", daysAgo: 1)]
        set.claudePrimary = (0...SourceFileCheckpoint.maximumPerSource).map { checkpoint("file-\($0)", daysAgo: 1 + Double($0) / 100_000) }
        let kept = set.retained(now: now)
        XCTAssertEqual(kept.codex.map(\.pathDigest), ["recent"])
        XCTAssertEqual(kept.claudePrimary.count, SourceFileCheckpoint.maximumPerSource)
        XCTAssertFalse(kept.claudePrimary.map(\.pathDigest).contains("file-\(SourceFileCheckpoint.maximumPerSource)"), "the oldest file is the one dropped")
    }

    func testCheckpointsRoundTripThroughTheHistoryEncoding() throws {
        let checkpoint = SourceFileCheckpoint(pathDigest: SourceFileCheckpoint.digest(ofPath: "/a/b.jsonl"), fileNumber: 42, size: 1_234, modifiedAt: origin.addingTimeInterval(0.123456), versionKey: "p|m")
        var set = SourceCheckpoints()
        set.codex = [checkpoint]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SourceCheckpoints.self, from: encoder.encode(set))
        XCTAssertEqual(decoded, set, "the modification time keeps its sub-second part")
    }

    // MARK: Fixtures

    private func at(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }

    private func touch(_ url: URL, at seconds: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: at(seconds)], ofItemAtPath: url.path)
    }

    private func append(_ data: Data, to url: URL, modified seconds: Double) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
        try touch(url, at: seconds)
    }

    private func append(_ lines: [Data], to url: URL, modified seconds: Double) throws {
        try append(jsonl(lines), to: url, modified: seconds)
    }

    private func jsonl(_ lines: [Data]) -> Data {
        lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
    }

    private func padding(_ bytes: Int) -> Data { Data(repeating: 0x20, count: bytes) + Data([0x0A]) }

    private func timestamp(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: at(seconds))
    }

    private func codexLine(_ type: String, _ payload: [String: Any], at seconds: Double) -> Data {
        try! JSONSerialization.data(withJSONObject: ["timestamp": timestamp(seconds), "type": type, "payload": payload] as [String: Any], options: [.sortedKeys])
    }

    /// One turn: task_started, context, one response, task_complete.
    private func codexTurn(_ id: String, start: Double, end: Double, tokens: Int) -> Data {
        jsonl([
            codexLine("event_msg", ["type": "task_started", "turn_id": id], at: start),
            codexLine("turn_context", ["turn_id": id, "model": "gpt-test"], at: start),
            codexLine("response_item", ["type": "reasoning"], at: start + 1),
            codexLine("token_usage_record", [
                "turn_id": id, "response_id": "resp-\(id)", "usage": ["output_tokens": tokens], "turn_token_usage": ["output_tokens": tokens]
            ], at: end - 1),
            codexLine("event_msg", ["type": "task_complete", "turn_id": id, "duration_ms": (end - start) * 1_000], at: end)
        ])
    }

    private func codexSession(id: String, session: String, parent: String?, source: Any, turns: [Data]) -> Data {
        var payload: [String: Any] = ["id": id, "session_id": session, "source": source, "model_provider": "openai"]
        if let parent { payload["parent_thread_id"] = parent }
        return jsonl([codexLine("session_meta", payload, at: -3_000)]) + turns.reduce(into: Data()) { $0.append($1) }
    }

    private func codexRoot(id: String = "root-1", turns: [Data]) -> Data {
        codexSession(id: id, session: id, parent: nil, source: "vscode", turns: turns)
    }

    private func codexChild(turns: [Data]) -> Data {
        codexSession(
            id: "child-1", session: "root-1", parent: "root-1",
            source: ["subagent": ["thread_spawn": ["parent_thread_id": "root-1", "depth": 1]]], turns: turns
        )
    }

    /// A new Codex file is read in steps (header, then content), so a few polls at one clock reading read it all.
    private func readAll(_ monitor: CodexSessionMonitor, at seconds: Double) async throws -> [TurnMetric] {
        var metrics: [String: TurnMetric] = [:]
        for _ in 0..<12 {
            for metric in try await monitor.poll(now: at(seconds)).metrics { metrics[metric.id] = metric }
        }
        return metrics.values.sorted { $0.completedAt < $1.completedAt }
    }

    private func claudeRecord(_ type: String, uuid: String, at seconds: Double, message: [String: Any]) -> Data {
        let value: [String: Any] = [
            "type": type, "uuid": uuid, "parentUuid": "previous", "sessionId": "claude-session-1", "userType": "external",
            "isSidechain": false, "version": "2.1.37", "timestamp": timestamp(seconds), "message": message
        ]
        return try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func claudePrompt(_ seconds: Double) -> Data {
        claudeRecord("user", uuid: "prompt-\(Int(seconds))", at: seconds, message: ["role": "user", "content": "PRIVATE_PROMPT"])
    }

    private func claudeAnswer(_ id: String, _ seconds: Double, _ output: Int) -> Data {
        claudeRecord("assistant", uuid: "record-\(id)", at: seconds, message: [
            "id": id, "role": "assistant", "model": "claude-sonnet-5-5", "content": "PRIVATE_RESPONSE",
            "stop_reason": "end_turn", "usage": ["output_tokens": output]
        ])
    }
}

/// `XCTUnwrap` for an optional that comes from an `await`.
private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let unwrapped = try await value()
    return try XCTUnwrap(unwrapped, file: file, line: line)
}
