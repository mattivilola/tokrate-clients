import Foundation

/// Reads every supported source from the beginning with fresh in-memory monitors, for the one-off
/// history export. It uses the live monitors unchanged (see `MonitorScope.replay`), so parsing,
/// pairing and delegated-output attribution are the app's own. Nothing is persisted: no checkpoints,
/// preferences, history or signing key are read or written.
public enum HistoryReplay {
    public struct Result: Sendable {
        /// One turn per id, in no particular order.
        public let metrics: [TurnMetric]
        /// Sources whose replay stopped before every file was read, by display name.
        public let incompleteSources: [String]
    }

    /// A poll that keeps asking for more with nothing to show for it is stuck on an unreadable file.
    private static let maximumEmptyPolls = 2_000
    /// Later than this and the monitor is waiting for something a replay cannot speed up (an unfinished
    /// delegated turn, a database retry backoff).
    private static let maximumWaitSeconds: TimeInterval = 10

    public static func run(folders: SourceFolders, retention: TimeInterval) async -> Result {
        let scope = MonitorScope.replay(retention: retention)
        let neverLive = Date.distantFuture
        var collected: [TurnMetric] = []
        var incomplete: [String] = []
        func record(_ name: String, _ outcome: (metrics: [TurnMetric], completed: Bool)) {
            collected += outcome.metrics
            if !outcome.completed { incomplete.append(name) }
        }

        if FileManager.default.fileExists(atPath: folders.codex.path) {
            let monitor = CodexSessionMonitor(root: folders.codex, liveSince: neverLive, scope: scope)
            record("Codex", await drain(
                poll: { try await monitor.poll(now: $0).metrics }, deadline: { await monitor.nextPollDeadline(now: $0) }
            ))
        }
        let claude = ClaudeSessionMonitor(root: folders.claudeCode, liveSince: neverLive, scope: scope)
        record("Claude Code", await drain(
            poll: { try await claude.poll(now: $0).metrics }, deadline: { await claude.nextPollDeadline(now: $0) }
        ))
        let grok = GrokSessionMonitor(root: folders.grokBuild, scope: scope)
        record("Grok Build", await drain(
            poll: { try await grok.poll(now: $0) }, deadline: { await grok.nextPollDeadline(now: $0) }
        ))
        let antigravity = AntigravityConversationMonitor(root: folders.antigravity, liveSince: neverLive, scope: scope)
        record("Antigravity", await drain(
            poll: { await antigravity.poll(now: $0).metrics }, deadline: { await antigravity.nextPollDeadline(now: $0) }
        ))
        let openCode = OpenCodeMonitor(root: folders.openCode, liveSince: neverLive, scope: scope)
        record("OpenCode", await drain(
            poll: { await openCode.poll(now: $0).metrics }, deadline: { await openCode.nextPollDeadline(now: $0) }
        ))
        for (name, root, surface) in [("Kimi Code", folders.kimiCode, ToolSurface.cli), ("Kimi desktop", folders.kimiDesktop, .desktop)] {
            let kimi = KimiSessionMonitor(root: root, surface: surface, liveSince: neverLive, scope: scope)
            record(name, await drain(
                poll: { try await kimi.poll(now: $0).metrics }, deadline: { await kimi.nextPollDeadline(now: $0) }
            ))
        }
        return Result(metrics: HistoryExport.deduplicated(collected), incompleteSources: incomplete)
    }

    /// Polls until the monitor has nothing left to read now. A failing poll ends the source as incomplete.
    private static func drain(
        poll: (Date) async throws -> [TurnMetric],
        deadline: (Date) async -> Date?
    ) async -> (metrics: [TurnMetric], completed: Bool) {
        var metrics: [TurnMetric] = []
        var emptyPolls = 0
        while true {
            let now = Date.now
            let batch: [TurnMetric]
            do { batch = try await poll(now) } catch { return (metrics, false) }
            metrics += batch
            emptyPolls = batch.isEmpty ? emptyPolls + 1 : 0
            guard let due = await deadline(.now) else { return (metrics, true) }
            guard emptyPolls < maximumEmptyPolls else { return (metrics, false) }
            let wait = due.timeIntervalSinceNow
            if wait > maximumWaitSeconds { return (metrics, true) }
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
    }
}
