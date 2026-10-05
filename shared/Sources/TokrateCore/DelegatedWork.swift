import CryptoKit
import Foundation

/// What a parser reports about delegated subagent work (contract: "Delegated output"). Local and
/// in-memory only: root sessions appear solely as one-way digests and nothing here is persisted or
/// uploaded.
enum DelegationEvent: Sendable, Equatable {
    /// A primary turn was emitted; `root` identifies the session its delegated work is attributed to.
    case primaryTurn(turnID: String, root: String)
    case workStarted(id: String, root: String, startedAt: Date)
    case workFinished(id: String, outputTokens: Int, finishedAt: Date)
    case workDiscarded(id: String)
}

/// One file of a delegated source as the backlog predicate sees it: an in-memory snapshot, never
/// persisted.
struct DelegationSourceFile: Sendable, Equatable {
    /// The file's last observed modification time.
    let modifiedAt: Date
    /// The live reader is not caught up, or the file has a modification it has not read.
    let livePending: Bool
    /// The archive reader, which covers the content before the live tail's start, is not done.
    let archivePending: Bool
    /// The wall-clock `now` of the poll that positioned the live reader; nil until it is positioned.
    let liveStartedAt: Date?
}

/// Which delegated-source files can still hold work a pending turn needs (contract: "Delegated
/// output", finalization condition 2). A work item's start record is written at or after the start of
/// the turn that spawned it, so a file last modified before that start never blocks the turn.
struct DelegationBacklog: Sendable, Equatable {
    /// Covers timestamp precision between a file's modification time and the records inside it.
    static let timestampTolerance: TimeInterval = 2
    /// Nothing is known about the delegated source (its poll failed): it blocks every turn.
    static let unknown = DelegationBacklog(files: [], isUnknown: true)
    static let none = DelegationBacklog(files: [])

    let files: [DelegationSourceFile]
    var isUnknown = false

    /// True when a file could still hold unread work items started at or after `start`.
    func hasBacklog(affectingWorkStartedAt start: Date) -> Bool {
        if isUnknown { return true }
        let earliest = start.addingTimeInterval(-Self.timestampTolerance)
        return files.contains { file in
            guard file.modifiedAt >= earliest else { return false }
            if file.livePending { return true }
            // The archive holds only content before the live tail: records at or after `start` can be in
            // it only when the tail was positioned after `start` (a reader not positioned yet will be).
            return file.archivePending && (file.liveStartedAt ?? .distantFuture) >= earliest
        }
    }
}

enum DelegationRoot {
    /// The in-memory attribution key of a root session: SHA-256 of `client|rawRootSessionId`.
    static func key(client: String, rawSessionID: String) -> String {
        SHA256.hash(data: Data("\(client)|\(rawSessionID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Attributes delegated work items to the primary turns that started them and finalizes
/// `TurnMetric.delegatedOutputTokens`. A monitor owns one value of this type; nothing in it is
/// persisted.
///
/// A primary turn is emitted at once with a nil total. It becomes final, and is re-emitted under the
/// same id with the total, when the settle time has passed, no delegated-source file that could still
/// hold unread work started inside the turn is behind (`DelegationBacklog`), and no work item that
/// started inside the turn is still open (or the maximum wait is over).
struct DelegationAttributor: Sendable {
    static let settleSeconds: TimeInterval = 30
    static let maximumWaitSeconds: TimeInterval = 30 * 60
    static let maximumWorkItems = 20_000
    static let maximumPendingTurns = 10_000

    private enum Status: Sendable {
        case open
        case finished(outputTokens: Int)
        case discarded
    }

    private struct Work: Sendable {
        let root: String
        let startedAt: Date
        var status: Status
    }

    private struct Pending: Sendable {
        let metric: TurnMetric
        let root: String
        let startedAt: Date
    }

    private var work: [String: Work] = [:]
    private var workByRoot: [String: Set<String>] = [:]
    private var pending: [String: Pending] = [:]

    /// Records one poll's events and the primary turns it emitted. `metrics` are the poll's
    /// candidate records; only primary turns without a final total become pending.
    mutating func ingest(events: [DelegationEvent], metrics: [TurnMetric]) {
        var roots: [String: String] = [:]
        for event in events {
            switch event {
            case .primaryTurn(let turnID, let root):
                roots[turnID] = root
            case .workStarted(let id, let root, let startedAt):
                guard work[id] == nil else { continue }
                work[id] = Work(root: root, startedAt: startedAt, status: .open)
                workByRoot[root, default: []].insert(id)
            case .workFinished(let id, let outputTokens, _):
                // The finished state is final: it also corrects an earlier discard after a reset.
                work[id]?.status = .finished(outputTokens: outputTokens)
            case .workDiscarded(let id):
                if case .open = work[id]?.status { work[id]?.status = .discarded }
            }
        }
        for metric in metrics where metric.sourceKind == "primary" && metric.delegatedOutputTokens == nil {
            guard let root = roots[metric.id] else { continue }
            pending[metric.id] = Pending(
                metric: metric, root: root,
                startedAt: metric.completedAt.addingTimeInterval(-metric.durationSeconds)
            )
        }
    }

    /// Returns the pending turns that became final, with their delegated totals, and forgets them.
    /// `backlog` describes the delegated source; each turn is held back only by the files that could
    /// still hold work started inside that turn.
    mutating func finalize(now: Date, backlog: DelegationBacklog) -> [TurnMetric] {
        trim(now: now)
        guard !pending.isEmpty else { return [] }
        var finals: [TurnMetric] = []
        for (id, entry) in pending {
            let completedAt = entry.metric.completedAt
            guard now >= completedAt.addingTimeInterval(Self.settleSeconds),
                  !backlog.hasBacklog(affectingWorkStartedAt: entry.startedAt) else { continue }
            var total = 0
            var hasOpenWork = false
            for workID in workByRoot[entry.root] ?? [] {
                guard let item = work[workID], item.startedAt >= entry.startedAt, item.startedAt <= completedAt else { continue }
                switch item.status {
                case .open: hasOpenWork = true
                case .finished(let tokens):
                    let (sum, overflow) = total.addingReportingOverflow(tokens)
                    total = overflow ? Int.max : sum
                case .discarded: break
                }
            }
            if hasOpenWork, now < completedAt.addingTimeInterval(Self.maximumWaitSeconds) { continue }
            finals.append(entry.metric.withDelegatedOutputTokens(total))
            pending.removeValue(forKey: id)
        }
        return finals.sorted { $0.completedAt > $1.completedAt }
    }

    /// A poll's own records with the re-emitted final records laid over those of the same id.
    static func merging(_ metrics: [TurnMetric], finals: [TurnMetric]) -> [TurnMetric] {
        guard !finals.isEmpty else { return metrics }
        var byID: [String: TurnMetric] = [:]
        for metric in metrics { byID[metric.id] = metric }
        for final in finals { byID[final.id] = final }
        return byID.values.sorted { $0.completedAt > $1.completedAt }
    }

    /// Bounds memory: nothing older than the history retention, and hard caps that drop the oldest.
    private mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-MetricHistory.retention)
        for (id, item) in work where item.startedAt < cutoff { removeWork(id) }
        pending = pending.filter { $0.value.metric.completedAt >= cutoff }
        if work.count > Self.maximumWorkItems {
            let oldest = work.sorted { $0.value.startedAt < $1.value.startedAt }.prefix(work.count - Self.maximumWorkItems)
            for (id, _) in oldest { removeWork(id) }
        }
        if pending.count > Self.maximumPendingTurns {
            let oldest = pending.sorted { $0.value.metric.completedAt < $1.value.metric.completedAt }
                .prefix(pending.count - Self.maximumPendingTurns)
            for (id, _) in oldest { pending.removeValue(forKey: id) }
        }
    }

    private mutating func removeWork(_ id: String) {
        guard let item = work.removeValue(forKey: id) else { return }
        workByRoot[item.root]?.remove(id)
        if workByRoot[item.root]?.isEmpty == true { workByRoot.removeValue(forKey: item.root) }
    }
}
