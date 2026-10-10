import Foundation

/// Watches one Kimi Code home: the CLI's (`$KIMI_CODE_HOME`, else `~/.kimi-code`) or the Kimi desktop
/// app's embedded one. Only the home's `sessions` folder is enumerated: the rest of the home (binaries,
/// caches, plugins, logs) is large, grows over time and holds no agent logs. Main-agent logs
/// (`sessions/<workspace>/<session>/agents/main/wire.jsonl`) and
/// subagent logs (`.../agents/<other>/wire.jsonl`) form two `JSONLSourceSessionMonitor` file sets, so a
/// burst of subagent files cannot consume the main agent's byte budget, live-file slots or 2,000-file
/// cap (and vice versa), as for Claude Code. The desktop app's chat-title sessions (`ctitle-…`) are
/// ignored completely.
///
/// The monitor attributes each subagent turn to the main turn of the same session that started it (see
/// `DelegationAttributor`): a main turn is emitted at once and re-emitted under the same id once its
/// delegated output tokens are final.
public actor KimiSessionMonitor {
    private let main: JSONLSourceSessionMonitor<KimiWireParser>
    private let subagents: JSONLSourceSessionMonitor<KimiWireParser>
    private var attributor: DelegationAttributor
    private let home: URL

    /// The folder a change watcher has to observe for this home: wakes only for changes in the sessions.
    public static func watchedFolder(home: URL) -> URL { home.appendingPathComponent("sessions", isDirectory: true) }

    /// `root` is the Kimi Code home. `surface` is where the home belongs (`cli` or `desktop`) and is recorded on every turn.
    /// `liveSince` is the moment from which completed responses count as live; earlier responses are
    /// history and never reach the live stream. `mainCheckpoints` and `subagentCheckpoints` are the files
    /// an earlier run read to their end, whose records are already in the history.
    public init(
        root: URL, surface: ToolSurface, liveSince: Date = .now,
        mainCheckpoints: [SourceFileCheckpoint] = [], subagentCheckpoints: [SourceFileCheckpoint] = [],
        scope: MonitorScope = .live
    ) {
        attributor = DelegationAttributor(scope: scope)
        home = root
        let sessions = Self.watchedFolder(home: root)
        let versionKey = SourceFileCheckpoint.versionKey(
            parser: KimiWireParser.parserVersion, metric: KimiWireParser.metricVersion
        )
        let rootComponents = sessions.standardizedFileURL.pathComponents
        main = JSONLSourceSessionMonitor(
            root: sessions, liveSince: liveSince, versionKey: versionKey, checkpoints: mainCheckpoints, scope: scope,
            includesFile: { url in Self.agent(ofLogAt: url, rootComponents: rootComponents).map { $0 == Self.mainAgent } ?? false },
            makeParser: { KimiWireParser(sourceIdentity: $0, scope: .main, surface: surface) }
        )
        subagents = JSONLSourceSessionMonitor(
            root: sessions, liveSince: liveSince, versionKey: versionKey, checkpoints: subagentCheckpoints, scope: scope,
            includesFile: { url in Self.agent(ofLogAt: url, rootComponents: rootComponents).map { $0 != Self.mainAgent } ?? false },
            makeParser: { KimiWireParser(sourceIdentity: $0, scope: .subagent, surface: surface) }
        )
    }

    public func poll(now: Date = .now) async throws -> MonitorUpdate {
        let mainUpdate = try await main.poll(now: now)
        // Discovery is the only throwing step and runs before any bytes are consumed, so a failed
        // subagent poll loses nothing and is retried on the next cycle.
        let subagentPoll = try? await subagents.poll(now: now)
        let subagentUpdate = subagentPoll ?? MonitorUpdate()
        attributor.ingest(events: mainUpdate.delegation + subagentUpdate.delegation, metrics: mainUpdate.metrics)
        // Without a successful subagent poll nothing is known about delegated work: finalize nothing.
        let backlog = subagentPoll == nil ? DelegationBacklog.unknown : await subagents.delegationBacklog
        let finals = attributor.finalize(now: now, backlog: backlog)
        return MonitorUpdate(
            metrics: DelegationAttributor.merging(mainUpdate.metrics, finals: finals),
            responses: mainUpdate.responses,
            outcomes: mainUpdate.outcomes + subagentUpdate.outcomes
        )
    }

    /// Forwards to both inner monitors; each ignores the paths its include rule rejects. Returns whether
    /// anything is now pending.
    @discardableResult
    public func noteChanges(_ change: SessionFolderChange) async -> Bool {
        let notedMain = await main.noteChanges(change)
        let notedSubagents = await subagents.noteChanges(change)
        return notedMain || notedSubagents
    }

    /// When to poll again if nothing else changes (see `CodexSessionMonitor.nextPollDeadline`).
    public func nextPollDeadline(now: Date) async -> Date? {
        let deadlines = [
            await main.nextPollDeadline(now: now),
            await subagents.nextPollDeadline(now: now),
            attributor.nextDeadline(now: now)
        ].compactMap { $0 }
        return deadlines.min()
    }

    /// The files of both sets read to their end, whose records are all in the history, for a later run
    /// to skip. Nil while the previous sets stay valid: before the first discovery, and while a main
    /// turn awaits its delegated total (it is not final, and skipping its file would leave it so).
    public func checkpoints() async -> (main: [SourceFileCheckpoint], subagents: [SourceFileCheckpoint])? {
        guard !attributor.hasPending, let main = await main.checkpoints(),
              let subagents = await subagents.checkpoints() else { return nil }
        return (main, subagents)
    }

    /// `rootAvailable` is whether the home exists, which is what a user sees as the source being found;
    /// a home without sessions yet has no files.
    public func status() async -> (rootAvailable: Bool, files: Int) {
        let mainFiles = await main.watchedFileCount, subagentFiles = await subagents.watchedFileCount
        var isDirectory: ObjCBool = false
        let homeExists = FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory) && isDirectory.boolValue
        return (homeExists, mainFiles + subagentFiles)
    }

    private static let mainAgent = "main"

    /// The agent folder of exactly `<sessions>/<workspace>/<session>/agents/<agent>/wire.jsonl`; nil for
    /// any other file and for a chat-title session (`ctitle-…`).
    private static func agent(ofLogAt url: URL, rootComponents: [String]) -> String? {
        guard url.lastPathComponent == "wire.jsonl" else { return nil }
        let components = url.standardizedFileURL.pathComponents
        let depth = rootComponents.count
        guard components.count == depth + 5, components.starts(with: rootComponents),
              components[depth + 2] == "agents", !components[depth + 1].hasPrefix("ctitle-") else { return nil }
        return components[depth + 3]
    }
}
