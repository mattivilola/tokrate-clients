import CryptoKit
import Foundation

/// Reads Antigravity conversation databases and turns each finished agent run into a `TurnMetric`
/// (contract "Antigravity (0.1.18)"). Antigravity keeps one SQLite database per conversation under
/// `<root>/antigravity`, `<root>/antigravity-ide` and `<root>/antigravity-cli` (`conversations/<id>.db`).
///
/// A database is opened only when the modification time or size of its `.db` or `.db-wal` file has
/// changed, read-only and at most `maximumReadsPerPoll` per poll. Polling is event driven: a folder
/// watcher reports changes through `noteChanges`, which accepts only a database or write-ahead log
/// directly inside a conversation folder (the data root also holds unrelated churn), and an idle
/// monitor does no file work. Execution ids and live-published steps are remembered per database in
/// bounded sets.
public actor AntigravityConversationMonitor {
    /// The three conversation folders under the data root, relative to it, and the surface a
    /// conversation found in each one ran on (contract "Surface (0.1.18)").
    private static let conversationSources: [(path: String, surface: ToolSurface)] = [
        ("antigravity/conversations", .desktop),
        ("antigravity-ide/conversations", .ide),
        ("antigravity-cli/conversations", .cli)
    ]
    public static let conversationFolderPaths = conversationSources.map(\.path)

    private static let maximumFiles = 2_000
    private static let maximumReadsPerPoll = 8
    /// Wall-clock cap on the reads of one poll; the rest wait for the next poll.
    private static let maximumReadSeconds: TimeInterval = 1
    /// Safety net for a folder watcher that missed a change; `noteChanges` normally triggers discovery.
    static let discoveryInterval = CodexSessionMonitor.discoveryInterval
    /// A database that failed to read (locked, corrupt, a different schema) is retried after this long,
    /// doubling per consecutive failure up to `maximumRetryDelay`, so a permanently unreadable file does
    /// not keep the app polling every few seconds.
    private static let retryDelay: TimeInterval = 10
    private static let maximumRetryDelay: TimeInterval = 300
    private static let maximumRememberedItems = 8_192
    private static let maximumCachedGenerations = 4_096

    private struct WatchedDatabase {
        let url: URL
        let conversationID: String
        let surface: ToolSurface
        var current: DatabaseFileSignature
        /// The signature the last successful read started from.
        var lastRead: DatabaseFileSignature?
        var nextAttemptAt = Date.distantPast
        var consecutiveFailures = 0
        /// Decoded generations by `gen_metadata.idx`, fetched once: their rows can be megabytes.
        var generations: [Int64: AntigravityGeneration] = [:]
        /// Generation rows that exist but could not be decoded; they are not fetched again.
        var unreadableGenerations: Set<Int64> = []
        var emittedExecutions = BoundedSet<String>(limit: AntigravityConversationMonitor.maximumRememberedItems)
        var publishedCalls = BoundedSet<Int64>(limit: AntigravityConversationMonitor.maximumRememberedItems)
    }

    private let root: URL
    private let liveSince: Date
    private var databases: [String: WatchedDatabase] = [:]
    private var lastDiscovery = Date.distantPast
    private var needsDiscovery = false
    private(set) var rootIsAvailable = false
    private(set) var databaseReadCount = 0

    /// `liveSince` is the moment from which completed model calls count as live; earlier calls are
    /// history and never reach the live stream.
    public init(root: URL, liveSince: Date = .now) {
        self.root = root
        self.liveSince = liveSince
    }

    /// The conversation folders of a data root.
    public static func conversationFolders(root: URL) -> [URL] {
        conversationFolderPaths.map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// Whether any of a data root's conversation folders exists.
    public static func hasConversationFolder(root: URL) -> Bool {
        conversationFolders(root: root).contains { isDirectory($0) }
    }

    public func poll(now: Date = .now) -> MonitorUpdate {
        if needsDiscovery || now.timeIntervalSince(lastDiscovery) >= Self.discoveryInterval || databases.isEmpty {
            // Cleared first so a failing enumeration is retried by the safety net, not on every poll.
            needsDiscovery = false
            discoverDatabases(now: now)
            lastDiscovery = now
        }

        let pending = databases.filter { $0.value.current != $0.value.lastRead && $0.value.nextAttemptAt <= now }
            .sorted { left, right in
                left.value.current.modifiedAt == right.value.current.modifiedAt
                    ? left.key < right.key : left.value.current.modifiedAt > right.value.current.modifiedAt
            }
        var update = MonitorUpdate()
        let started = ContinuousClock.now
        for (key, _) in pending.prefix(Self.maximumReadsPerPoll) {
            if ContinuousClock.now - started > .seconds(Self.maximumReadSeconds) { break }
            read(key: key, now: now, into: &update)
        }
        update.metrics.sort { $0.completedAt > $1.completedAt }
        update.responses.sort { $0.completedAt > $1.completedAt }
        return update
    }

    public func status() -> (rootAvailable: Bool, conversations: Int) {
        (rootIsAvailable, databases.count)
    }

    /// Marks what a folder watcher reported so the next poll reads it. Only a `<id>.db` or `<id>.db-wal`
    /// directly inside a conversation folder (or such a folder itself) matters; every other path below
    /// the data root is ignored. A change to a known database refreshes its signature, and a new
    /// database, a vanished one or a lost event triggers discovery. Returns whether a poll has work now.
    @discardableResult
    public func noteChanges(_ change: SessionFolderChange) -> Bool {
        var noted = change.mustRescan
        if change.mustRescan { needsDiscovery = true }
        let folders = Set(Self.conversationFolders(root: root).map(\.standardizedFileURL.path))
        for path in change.paths {
            let url = URL(fileURLWithPath: path)
            if folders.contains(path) {
                needsDiscovery = true
                noted = true
                continue
            }
            guard folders.contains(url.deletingLastPathComponent().path),
                  let databasePath = Self.databasePath(forEventPath: path) else { continue }
            if databases[databasePath] != nil {
                if let signature = DatabaseFileSignature.of(URL(fileURLWithPath: databasePath)) {
                    databases[databasePath]?.current = signature
                    // A report that changed nothing (the files already read) leaves nothing to poll for.
                    if signature != databases[databasePath]?.lastRead { noted = true }
                } else {
                    needsDiscovery = true
                    noted = true
                }
            } else if DatabaseFileSignature.attributes(of: databasePath) != nil {
                needsDiscovery = true
                noted = true
            }
        }
        return noted
    }

    /// When the monitor needs to poll again if nothing else changes: `now` while discovery is due or a
    /// changed database is waiting to be read (including reads the per-poll cap deferred), else the
    /// earliest retry of a database that failed to read, else nil.
    public func nextPollDeadline(now: Date) -> Date? {
        if needsDiscovery { return now }
        var earliest: Date?
        for watched in databases.values where watched.current != watched.lastRead {
            if watched.nextAttemptAt <= now { return now }
            if earliest.map({ watched.nextAttemptAt < $0 }) ?? true { earliest = watched.nextAttemptAt }
        }
        return earliest
    }

    /// The database a changed path belongs to: `<id>.db` is itself, `<id>.db-wal` is its log; nothing
    /// else (`.pb`, `-shm`, journals) is.
    private static func databasePath(forEventPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let database: String
        if name.hasSuffix(".db") { database = path } else if name.hasSuffix(".db-wal") { database = String(path.dropLast(4)) } else { return nil }
        return (database as NSString).lastPathComponent.count > 3 ? database : nil
    }

    // MARK: Reading

    private func read(key: String, now: Date, into update: inout MonitorUpdate) {
        guard var watched = databases[key] else { return }
        let signature = watched.current
        databaseReadCount += 1
        guard let snapshot = Self.snapshot(of: watched) else {
            watched.consecutiveFailures += 1
            let backoff = Self.retryDelay * pow(2, Double(min(watched.consecutiveFailures - 1, 5)))
            watched.nextAttemptAt = now.addingTimeInterval(min(backoff, Self.maximumRetryDelay))
            databases[key] = watched
            return
        }
        watched.consecutiveFailures = 0
        watched.lastRead = signature
        for (index, generation) in snapshot.generations {
            if let generation {
                if watched.generations.count < Self.maximumCachedGenerations { watched.generations[index] = generation }
            } else {
                watched.unreadableGenerations.insert(index)
            }
        }
        defer { databases[key] = watched }

        let builder = AntigravityTurnBuilder(
            conversationID: watched.conversationID, surface: watched.surface, steps: snapshot.steps, executors: snapshot.executors,
            generations: watched.generations
        )
        for execution in builder.finishedExecutions() where watched.emittedExecutions.insert(execution.executionID) {
            update.metrics.append(execution.metric)
        }
        for call in builder.modelCalls
        where call.qualifiesAsResponse && call.completedAt.date >= liveSince && !watched.publishedCalls.contains(call.stepIndex) {
            guard let generation = call.generation else { continue }
            watched.publishedCalls.insert(call.stepIndex)
            let digest = SHA256.hash(data: Data("antigravity-response|\(watched.conversationID)|\(call.stepIndex)".utf8))
            update.responses.append(LiveResponse(
                id: digest.map { String(format: "%02x", $0) }.joined(),
                model: generation.model,
                provider: generation.provider,
                client: AntigravityTurnBuilder.client,
                sourceKind: "primary",
                metricVersion: AntigravityTurnBuilder.metricVersion,
                reasoningEffort: builder.effort(of: call),
                completedAt: call.completedAt.date,
                outputTokens: call.outputTokens,
                durationSeconds: call.durationSeconds
            ))
        }
    }

    /// The decoded content of one consistent read. A database with nothing to measure (a subagent
    /// trajectory, or a step that is not a protobuf message) reads as empty.
    private struct Snapshot {
        var steps: [AntigravityStep] = []
        var executors: [AntigravityExecutor] = []
        /// Generations fetched by this read; `nil` marks a row that exists but cannot be decoded.
        var generations: [Int64: AntigravityGeneration?] = [:]
    }

    /// One consistent read of a database; `nil` when it could not be opened or read (retried later).
    private static func snapshot(of watched: WatchedDatabase) -> Snapshot? {
        guard let database = try? AntigravityDatabase(url: watched.url) else { return nil }
        defer { database.close() }
        return try? database.readTransaction {
            // A database with any parent reference is a subagent trajectory and is not measured.
            guard try database.parentReferenceCount() == 0 else { return Snapshot() }
            let stepRows = try database.steps()
            let steps = stepRows.compactMap(AntigravityStep.init(row:))
            // A step that is not a protobuf message could belong to any execution: measure nothing
            // rather than a run with a missing model call.
            guard steps.count == stepRows.count else { return Snapshot() }
            var snapshot = Snapshot(steps: steps, executors: try database.executorMetadata().compactMap(AntigravityExecutor.init(row:)))
            for index in Set(steps.filter(\.isModelCall).map(\.generationIndex))
            where watched.generations[index] == nil && !watched.unreadableGenerations.contains(index) {
                // No row yet is not remembered: the row can still be written.
                if let data = try database.generationData(idx: index) { snapshot.generations[index] = .some(AntigravityGeneration(data: data)) }
            }
            return snapshot
        }
    }

    // MARK: Discovery

    private func discoverDatabases(now: Date) {
        var available = false
        var candidates: [(url: URL, signature: DatabaseFileSignature, surface: ToolSurface)] = []
        for (path, surface) in Self.conversationSources {
            let folder = root.appendingPathComponent(path, isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            available = true
            for url in urls where url.pathExtension == "db" && !url.deletingPathExtension().lastPathComponent.isEmpty {
                // Files untouched for the retention period are not opened.
                guard let signature = DatabaseFileSignature.of(url),
                      signature.modifiedAt >= now.addingTimeInterval(-MetricHistory.retention) else { continue }
                candidates.append((url, signature, surface))
            }
        }
        rootIsAvailable = available
        candidates.sort { $0.signature.modifiedAt > $1.signature.modifiedAt }
        var seen = Set<String>()
        for candidate in candidates.prefix(Self.maximumFiles) {
            let key = candidate.url.standardizedFileURL.path
            seen.insert(key)
            if var watched = databases[key] {
                watched.current = candidate.signature
                databases[key] = watched
            } else {
                databases[key] = WatchedDatabase(
                    url: candidate.url,
                    conversationID: candidate.url.deletingPathExtension().lastPathComponent,
                    surface: candidate.surface,
                    current: candidate.signature
                )
            }
        }
        databases = databases.filter { seen.contains($0.key) }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
