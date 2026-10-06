import CryptoKit
import Foundation

/// Reads OpenCode's SQLite database and turns each finished user prompt (through its final answer) into
/// a `TurnMetric` (contract "OpenCode (0.1.18)"). OpenCode keeps every session in `<root>/opencode.db`;
/// every other file in its data folder (`snapshot/`, `tool-output/`, `log/`, `storage/`, `repos/`) is
/// ignored.
///
/// The database is opened read-only and only when its modification time or size, or its write-ahead
/// log's, changed. The first read takes the last seven days of messages; later reads take only messages
/// updated since a watermark and merge them into an in-memory index, and a full re-read every five
/// minutes of activity drops messages OpenCode deleted. Polling is event driven (`noteChanges`), and an
/// idle monitor does no file work beyond two `stat` calls.
public actor OpenCodeMonitor {
    static let databaseFileName = "opencode.db"
    /// Safety net: a full re-read this often while the database changes.
    static let fullReadInterval: TimeInterval = 300
    /// Later reads start this far before the watermark, as the contract specifies, in milliseconds.
    static let watermarkOverlapMilliseconds: Int64 = 2_000
    static let maximumIndexedMessages = 200_000
    private static let maximumRememberedItems = 16_384
    private static let initialRetryDelay: TimeInterval = 10
    private static let maximumRetryDelay: TimeInterval = 300

    private let root: URL
    private let scope: MonitorScope
    private let liveSinceMilliseconds: Int64
    private var signature: DatabaseFileSignature?
    /// The signature the last successful read started from.
    private var lastRead: DatabaseFileSignature?
    private var sessions: [String: OpenCodeSession] = [:]
    private var messages: [String: OpenCodeMessage] = [:]
    /// The largest `time_updated` seen, the start of the next incremental read.
    private var watermark: Int64?
    private var lastFullRead: Date?
    /// User messages whose turn is emitted with its delegated total final.
    private var settled: Set<String> = []
    /// User messages whose turn is emitted with a pending (nil) delegated total, and when each stops waiting.
    private var pending: [String: Date] = [:]
    private var publishedResponses = BoundedSet<String>(limit: OpenCodeMonitor.maximumRememberedItems)
    private var failureCount = 0
    private var nextAttemptAt = Date.distantPast
    private(set) var rootIsAvailable = false
    private(set) var databaseReadCount = 0

    /// `liveSince` is the moment from which completed model calls count as live; earlier calls are
    /// history and never reach the live stream.
    public init(root: URL, liveSince: Date = .now, scope: MonitorScope = .live) {
        self.root = root
        self.scope = scope
        liveSinceMilliseconds = Int64(liveSince.timeIntervalSince1970 * 1_000)
    }

    /// The database of a data root.
    public static func databaseURL(root: URL) -> URL {
        root.appendingPathComponent(databaseFileName, isDirectory: false)
    }

    /// Whether a data root holds the database.
    public static func hasDatabase(root: URL) -> Bool {
        DatabaseFileSignature.attributes(of: databaseURL(root: root).path) != nil
    }

    public func poll(now: Date = .now) -> MonitorUpdate {
        var update = MonitorUpdate()
        refreshSignature()
        var indexChanged = false
        if let signature, signature != lastRead, nextAttemptAt <= now {
            indexChanged = read(signature: signature, now: now)
        }
        if indexChanged || pending.values.contains(where: { $0 <= now }) {
            evaluate(now: now, into: &update)
        }
        update.metrics.sort { $0.completedAt > $1.completedAt }
        update.responses.sort { $0.completedAt > $1.completedAt }
        return update
    }

    public func status() -> (rootAvailable: Bool, sessions: Int) {
        (rootIsAvailable, sessions.values.filter(\.isPrimary).count)
    }

    /// Marks what a folder watcher reported so the next poll reads it. Only `opencode.db` and
    /// `opencode.db-wal` directly in the data folder matter; the folder also holds snapshots, tool
    /// output and logs that change constantly and must not wake a poll. Returns whether a poll has work now.
    @discardableResult
    public func noteChanges(_ change: SessionFolderChange) -> Bool {
        let database = Self.databaseURL(root: root).standardizedFileURL.path
        guard change.mustRescan || change.paths.contains(database) || change.paths.contains(database + "-wal") else { return false }
        refreshSignature()
        // A lost event is answered by a poll, which looks at the files itself.
        return change.mustRescan || signature != lastRead
    }

    /// When the monitor needs to poll again if nothing else changes: `now` while a changed database is
    /// waiting to be read, the retry time after a failed read, else the earliest moment a turn stops
    /// waiting for unfinished subagent messages; nil when nothing is pending.
    public func nextPollDeadline(now: Date) -> Date? {
        var earliest = pending.values.min()
        if let signature, signature != lastRead {
            let due = max(nextAttemptAt, now)
            if earliest.map({ due < $0 }) ?? true { earliest = due }
        }
        return earliest
    }

    // MARK: Reading

    private func refreshSignature() {
        signature = DatabaseFileSignature.of(Self.databaseURL(root: root))
        rootIsAvailable = signature != nil
    }

    private struct Snapshot {
        var messages: [OpenCodeDatabase.MessageRow] = []
        var sessions: [String: OpenCodeDatabase.SessionRow] = [:]
    }

    /// Reads and merges what changed. `false` (nothing applied, retried with backoff) when the database
    /// could not be opened or read.
    private func read(signature: DatabaseFileSignature, now: Date) -> Bool {
        databaseReadCount += 1
        let fullReadDue = lastFullRead.map { now.timeIntervalSince($0) >= Self.fullReadInterval } ?? true
        let full = watermark == nil || fullReadDue
        let cutoff = Int64((now.timeIntervalSince1970 - scope.retention) * 1_000)
        let known = full ? [] : Set(sessions.keys)
        let from = (watermark ?? 0) - Self.watermarkOverlapMilliseconds
        let snapshot: Snapshot
        do {
            let database = try OpenCodeDatabase(url: Self.databaseURL(root: root))
            defer { database.close() }
            snapshot = try database.readTransaction {
                var snapshot = Snapshot()
                snapshot.messages = full ? try database.messages(createdSince: cutoff) : try database.messages(updatedSince: from)
                // Sessions the index lacks, then their ancestors (a subagent's parents lead to the primary session).
                var wanted = Set(snapshot.messages.map(\.sessionID)).subtracting(known)
                for _ in 0..<16 where !wanted.isEmpty {
                    let fetched = try database.sessions(ids: Array(wanted))
                    for row in fetched { snapshot.sessions[row.id] = row }
                    wanted = Set(fetched.compactMap(\.parentID)).subtracting(snapshot.sessions.keys).subtracting(known)
                }
                return snapshot
            }
        } catch {
            failureCount += 1
            nextAttemptAt = now.addingTimeInterval(min(Self.initialRetryDelay * pow(2, Double(failureCount - 1)), Self.maximumRetryDelay))
            return false
        }
        failureCount = 0
        nextAttemptAt = .distantPast
        lastRead = signature
        if full {
            messages.removeAll(keepingCapacity: true)
            sessions.removeAll(keepingCapacity: true)
            lastFullRead = now
        }
        for (id, row) in snapshot.sessions { sessions[id] = OpenCodeSession(row: row) }
        for row in snapshot.messages {
            let message = OpenCodeMessage(row: row)
            if message.rowCreatedMs < cutoff { messages.removeValue(forKey: message.id) } else { messages[message.id] = message }
            watermark = max(watermark ?? row.timeUpdated, row.timeUpdated)
        }
        prune(cutoff: cutoff)
        return true
    }

    /// Keeps the index inside the retention window and its size cap, and forgets the state of turns
    /// whose user message left it.
    private func prune(cutoff: Int64) {
        messages = messages.filter { $0.value.rowCreatedMs >= cutoff }
        if messages.count > scope.maximumIndexedMessages {
            let keep = messages.values.sorted { $0.rowCreatedMs > $1.rowCreatedMs }.prefix(scope.maximumIndexedMessages)
            messages = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
        settled = settled.filter { messages[$0] != nil }
        pending = pending.filter { messages[$0.key] != nil }
    }

    // MARK: Emission

    private func evaluate(now: Date, into update: inout MonitorUpdate) {
        let builder = OpenCodeTurnBuilder(sessions: sessions, messages: messages.values)
        var stillPending: [String: Date] = [:]
        for evaluation in builder.evaluations(excluding: settled, now: now) {
            if evaluation.isFinal {
                // The same id is emitted again once its delegated total is settled.
                settled.insert(evaluation.userMessageID)
                update.metrics.append(evaluation.metric)
            } else {
                if pending[evaluation.userMessageID] == nil { update.metrics.append(evaluation.metric) }
                stillPending[evaluation.userMessageID] = evaluation.settlesAt
            }
        }
        pending = stillPending.compactMapValues { $0 }

        for message in builder.liveCandidates(completedSince: liveSinceMilliseconds) {
            guard let model = message.model, let seconds = message.responseDurationSeconds, let tokens = message.outputTokens,
                  let completed = message.completedMs, publishedResponses.insert(message.id) else { continue }
            let digest = SHA256.hash(data: Data("opencode-response|\(message.id)".utf8))
            update.responses.append(LiveResponse(
                id: digest.map { String(format: "%02x", $0) }.joined(),
                model: model,
                provider: message.provider,
                client: OpenCodeTurnBuilder.client,
                sourceKind: "primary",
                metricVersion: OpenCodeTurnBuilder.metricVersion,
                reasoningEffort: message.effort,
                completedAt: Date(timeIntervalSince1970: Double(completed) / 1_000),
                outputTokens: tokens,
                durationSeconds: seconds
            ))
        }
    }
}
