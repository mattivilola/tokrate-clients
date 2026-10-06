import CryptoKit
import Foundation

/// Reads Antigravity conversation databases and turns each finished agent run into a `TurnMetric`
/// (contract "Antigravity (0.1.18)"). Antigravity keeps one SQLite database per conversation under
/// `<root>/antigravity`, `<root>/antigravity-ide` and `<root>/antigravity-cli` (`conversations/<id>.db`).
///
/// A database is opened only when the modification time or size of its `.db` or `.db-wal` file has
/// changed, read-only and at most `maximumReadsPerPoll` per poll, so polling an idle folder costs a few
/// `stat` calls. Execution ids and live-published steps are remembered per database in bounded sets.
public actor AntigravityConversationMonitor {
    /// The three conversation folders under the data root, relative to it.
    public static let conversationFolderPaths = ["antigravity/conversations", "antigravity-ide/conversations", "antigravity-cli/conversations"]

    private static let maximumFiles = 2_000
    private static let maximumReadsPerPoll = 8
    /// Wall-clock cap on the reads of one poll; the rest wait for the next poll.
    private static let maximumReadSeconds: TimeInterval = 1
    private static let discoveryInterval: TimeInterval = 10
    private static let hotDatabaseCount = 16
    /// A database that failed to read (locked, corrupt, a different schema) is retried after this long.
    private static let retryDelay: TimeInterval = 10
    private static let maximumRememberedItems = 8_192
    private static let maximumCachedGenerations = 4_096

    /// What changed on disk: the database and its write-ahead log.
    private struct FileSignature: Equatable {
        let databaseModifiedAt: Date
        let databaseSize: Int
        let walModifiedAt: Date?
        let walSize: Int?

        var modifiedAt: Date { max(databaseModifiedAt, walModifiedAt ?? .distantPast) }
    }

    private struct WatchedDatabase {
        let url: URL
        let conversationID: String
        var current: FileSignature
        /// The signature the last successful read started from.
        var lastRead: FileSignature?
        var nextAttemptAt = Date.distantPast
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
        if now.timeIntervalSince(lastDiscovery) >= Self.discoveryInterval || databases.isEmpty {
            discoverDatabases(now: now)
            lastDiscovery = now
        } else {
            refreshHotDatabases()
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

    // MARK: Reading

    private func read(key: String, now: Date, into update: inout MonitorUpdate) {
        guard var watched = databases[key] else { return }
        let signature = watched.current
        databaseReadCount += 1
        guard let snapshot = Self.snapshot(of: watched) else {
            watched.nextAttemptAt = now.addingTimeInterval(Self.retryDelay)
            databases[key] = watched
            return
        }
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
            conversationID: watched.conversationID, steps: snapshot.steps, executors: snapshot.executors,
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
        var candidates: [(url: URL, signature: FileSignature)] = []
        for folder in Self.conversationFolders(root: root) {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            available = true
            for url in urls where url.pathExtension == "db" && !url.deletingPathExtension().lastPathComponent.isEmpty {
                // Files untouched for the retention period are not opened.
                guard let signature = Self.signature(of: url),
                      signature.modifiedAt >= now.addingTimeInterval(-MetricHistory.retention) else { continue }
                candidates.append((url, signature))
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
                    current: candidate.signature
                )
            }
        }
        databases = databases.filter { seen.contains($0.key) }
    }

    /// Between discoveries only the most recently changed databases are checked: the active conversation.
    private func refreshHotDatabases() {
        let hot = databases.sorted { $0.value.current.modifiedAt > $1.value.current.modifiedAt }.prefix(Self.hotDatabaseCount)
        for (key, watched) in hot {
            if let signature = Self.signature(of: watched.url) {
                databases[key]?.current = signature
            }
        }
    }

    private static func signature(of databaseURL: URL) -> FileSignature? {
        guard let database = attributes(of: databaseURL.path) else { return nil }
        let wal = attributes(of: databaseURL.path + "-wal")
        return FileSignature(
            databaseModifiedAt: database.modifiedAt, databaseSize: database.size,
            walModifiedAt: wal?.modifiedAt, walSize: wal?.size
        )
    }

    private static func attributes(of path: String) -> (modifiedAt: Date, size: Int)? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: path),
              values[.type] as? FileAttributeType == .typeRegular,
              let modifiedAt = values[.modificationDate] as? Date,
              let size = (values[.size] as? NSNumber)?.intValue else { return nil }
        return (modifiedAt, size)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// A set that forgets its oldest members past a limit, so per-database bookkeeping cannot grow forever.
struct BoundedSet<Element: Hashable> {
    private let limit: Int
    private var members: Set<Element> = []
    private var order: [Element] = []
    private var oldest = 0

    init(limit: Int) { self.limit = limit }

    func contains(_ element: Element) -> Bool { members.contains(element) }

    /// Adds the element; `false` when it was already a member.
    @discardableResult
    mutating func insert(_ element: Element) -> Bool {
        guard members.insert(element).inserted else { return false }
        order.append(element)
        if members.count > limit {
            members.remove(order[oldest])
            oldest += 1
            // Compact the consumed prefix once it dominates the array.
            if oldest > limit { order.removeFirst(oldest); oldest = 0 }
        }
        return true
    }
}
